//! vinit — Velox guest PID 1.
//!
//! A single static binary that is the entire guest userspace orchestration: it
//! mounts the virtual filesystems, sets the clock from the host (`velox.epoch`),
//! brings up networking natively (ioctl + a tiny DHCP client), formats/mounts the
//! persistent data disk, mounts the VirtioFS shares + registers Rosetta, launches
//! and supervises `dockerd`, runs the vsock bridge the Swift host talks to, and
//! reaps zombies. No busybox, no shell, no init scripts — every step is a syscall.
//!
//! The read-only erofs root is mounted by the kernel (`root=/dev/vda`); only the
//! writable state below lives on tmpfs, and `/var/lib/docker` is the data disk.

use std::ffi::CString;
use std::io::Read;
use std::os::fd::{IntoRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::process::Command;

// ---- tiny logging to the console (fd 2 → hvc0) ----
macro_rules! log {
    ($($a:tt)*) => {{ eprint!("[vinit] "); eprintln!($($a)*); }};
}

const CID_ANY: u32 = 0xFFFF_FFFF;
// VSOCK ports — keep in sync with the host's `VsockPort` enum (Sources/VeloxCore/Support/Paths.swift).
const DOCKER_PORT: u32 = 2375;
const CONTROL_PORT: u32 = 2374;
const REVERSE_PORT: u32 = 2376;
const CLOCK_PORT: u32 = 2377;
const GW_PORT: u32 = 2378; // host probes this once at boot; we reply "<gw> <ip> <mask>\n"
// TCP port (on the vmnet bridge, NOT a vsock port) the guest dials back to the host for the
// VZNAT reverse-dial conduit pool. Matches the host's `ConduitPort.pool` (Paths.swift).
const POOL_PORT: u16 = 2379;
const DOCKER_SOCK: &str = "/run/docker.sock";
/// PID of the currently-supervised dockerd. The reaper compares each reaped child
/// against this (atomic) value and signals the supervisor thread to respawn when it
/// dies; -1 means "no dockerd" (e.g. a data-disk failure refused startup).
static DOCKERD_PID: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1);

fn main() {
    // vinit IS the init — it must be PID 1. If it's ever exec'd otherwise (e.g.
    // a stray container/build step), bail immediately instead of running the
    // boot sequence forever (it never exits — it's a supervisor + reaper).
    if unsafe { libc::getpid() } != 1 {
        eprintln!("[vinit] not PID 1 — refusing to run");
        std::process::exit(1);
    }
    log!("starting (PID 1)");
    mount_all();
    set_clock();
    // Network (DHCP) and the data disk (first-boot mkfs/resize) are independent and
    // both potentially slow, so run them concurrently: the DHCP round-trip — and any
    // retries on a lossy bridge — is hidden behind the disk format instead of summed
    // with it. dockerd needs BOTH (the mounted /var/lib/docker, and GATEWAY_IP + DNS
    // from the lease), so the network thread is joined before dockerd starts (below).
    let net_handle = std::thread::spawn(|| {
        if let Err(e) = setup_network() {
            log!("network setup failed (continuing, no outbound until fixed): {e}");
        }
    });
    let data_ok = setup_data_disk();
    // Swap is a memory-pressure safety valve, not a startup dependency, and on first
    // boot make_swapfile() fallocate()s a multi-GiB file — pure stall before dockerd.
    // Build it off the critical path. Spawned only when data_ok, so the swapfile's
    // parent (/var/lib/docker) is already mounted.
    if data_ok { std::thread::spawn(setup_swap); }
    setup_virtiofs();
    // dockerd reads GATEWAY_IP (for host.docker.internal) and expects resolv.conf in
    // place, so the network must be fully applied before it starts.
    let _ = net_handle.join();
    enable_ip_forwarding();
    tune_network_sysctls(); // survive published-port connection churn (TIME_WAIT/port exhaustion)
    // dockerd lifecycle is supervised on a *separate* thread so the PID-1 reaper never
    // sleeps — a crash-looping dockerd must not stop us reaping orphaned shims/zombies.
    let (deaths_tx, deaths_rx) = std::sync::mpsc::channel::<()>();
    if data_ok {
        let pid = spawn_dockerd();
        DOCKERD_PID.store(pid, std::sync::atomic::Ordering::SeqCst);
        std::thread::spawn(move || dockerd_supervisor(deaths_rx));
    } else {
        // Persistence was expected (/dev/vdb present) but the data fs didn't mount.
        // Running dockerd now would silently use the tmpfs /var and lose every image
        // and volume on the next boot — refuse, and let the host surface this log.
        log!("FATAL: data disk mount failed — refusing to start dockerd (it would run on \
              non-persistent tmpfs and lose all images/volumes). Fix /dev/vdb and restart.");
    }
    start_vsock_agent();
    start_conduit_pool();
    log!("init complete — supervising");
    reap_forever(deaths_tx);
}

// =================== filesystems ===================

/// Returns true on success. Most callers ignore the result (best-effort pseudo-fs
/// mounts); the data-disk mount checks it so a failure can refuse to start dockerd.
fn do_mount(src: &str, target: &str, fstype: &str, flags: libc::c_ulong, data: Option<&str>) -> bool {
    // Create the mountpoint if missing (only works on tmpfs/writable parents).
    let _ = std::fs::create_dir_all(target);
    // Don't `.unwrap()` CString::new — a NUL byte in a host-supplied `velox.shares`
    // path/tag would panic, and with `panic = "abort"` a panic in PID 1 is a kernel
    // panic. Skip the mount instead of taking down the whole guest.
    let (Ok(csrc), Ok(ctgt), Ok(cfs)) = (CString::new(src), CString::new(target), CString::new(fstype)) else {
        log!("mount {target}: NUL in path/fstype — skipping");
        return false;
    };
    let cdata = match data.map(CString::new) {
        Some(Ok(c)) => Some(c),
        Some(Err(_)) => { log!("mount {target}: NUL in mount data — skipping"); return false; }
        None => None,
    };
    let dptr = cdata.as_ref().map_or(std::ptr::null(), |c| c.as_ptr());
    let r = unsafe {
        libc::mount(csrc.as_ptr(), ctgt.as_ptr(),
            if fstype.is_empty() { std::ptr::null() } else { cfs.as_ptr() },
            flags, dptr as *const libc::c_void)
    };
    if r != 0 {
        log!("mount {target} ({fstype}) failed: {}", std::io::Error::last_os_error());
        return false;
    }
    true
}

fn mount_all() {
    // Pseudo-filesystems. /dev is auto-mounted by CONFIG_DEVTMPFS_MOUNT, but mount
    // it defensively; the rest we own.
    do_mount("proc", "/proc", "proc", 0, None);
    do_mount("sysfs", "/sys", "sysfs", 0, None);
    do_mount("devtmpfs", "/dev", "devtmpfs", 0, Some("mode=0755"));
    do_mount("devpts", "/dev/pts", "devpts", 0, Some("mode=0620,gid=5"));
    do_mount("tmpfs", "/dev/shm", "tmpfs", 0, Some("mode=1777"));
    do_mount("tmpfs", "/run", "tmpfs", 0, Some("mode=0755"));
    do_mount("tmpfs", "/tmp", "tmpfs", libc::MS_NOSUID | libc::MS_NODEV, Some("mode=1777"));
    // Writable /var on tmpfs (the read-only root can't be written). The persistent
    // data disk is mounted over /var/lib/docker below; everything else under /var
    // (containerd state, /var/run) stays ephemeral — by design (no stale records).
    do_mount("tmpfs", "/var", "tmpfs", 0, Some("mode=0755"));
    let _ = std::fs::create_dir_all("/var/lib/docker");
    let _ = std::fs::create_dir_all("/var/lib/containerd");
    let _ = std::fs::create_dir_all("/var/run");
    // cgroup v2 unified hierarchy — dockerd/containerd require it.
    do_mount("cgroup2", "/sys/fs/cgroup", "cgroup2", libc::MS_NOSUID | libc::MS_NODEV | libc::MS_NOEXEC, None);
    // binfmt_misc for Rosetta.
    do_mount("binfmt_misc", "/proc/sys/fs/binfmt_misc", "binfmt_misc", 0, None);
}

// =================== clock ===================

fn cmdline() -> String {
    std::fs::read_to_string("/proc/cmdline").unwrap_or_default()
}

fn cmdline_value(key: &str) -> Option<String> {
    let prefix = format!("{key}=");
    cmdline().split_whitespace().find_map(|t| t.strip_prefix(&prefix).map(|v| v.to_string()))
}

fn set_clock() {
    let Some(epoch) = cmdline_value("velox.epoch").and_then(|v| v.parse::<i64>().ok()) else {
        log!("no velox.epoch on cmdline — clock stays at boot value");
        return;
    };
    let tv = libc::timeval { tv_sec: epoch as libc::time_t, tv_usec: 0 };
    if unsafe { libc::settimeofday(&tv, std::ptr::null()) } == 0 {
        log!("clock set from host: epoch {epoch}");
    } else {
        log!("settimeofday failed: {}", std::io::Error::last_os_error());
    }
}

// =================== networking (native, no udhcpc) ===================

const SIOCGIFFLAGS: libc::c_ulong = 0x8913;
const SIOCSIFFLAGS: libc::c_ulong = 0x8914;
const SIOCSIFADDR: libc::c_ulong = 0x8916;
const SIOCSIFNETMASK: libc::c_ulong = 0x891C;
const SIOCGIFHWADDR: libc::c_ulong = 0x8927;
const SIOCADDRT: libc::c_ulong = 0x890B;
const IFNAME: &str = "eth0";
/// The VZNAT gateway (the Mac on the vmnet bridge), learned from DHCP and read by
/// spawn_dockerd to wire `host.docker.internal` → the host. Also dialed by the conduit
/// pool (the reverse-dial datapath). All three are network-byte-order u32 (same as the
/// DHCP lease fields); 0 means "not learned yet".
static GATEWAY_IP: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
/// The guest's own VZNAT IP and netmask, reported to the host (`handle_gateway`) so it can
/// find the vmnet bridge interface to bind the conduit pool on and validate conduit peers.
static GUEST_IP: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
static GUEST_MASK: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

#[repr(C)]
struct IfReqAddr { name: [u8; 16], addr: libc::sockaddr_in }
#[repr(C)]
struct IfReqFlags { name: [u8; 16], flags: libc::c_short, _pad: [u8; 22] }
#[repr(C)]
struct IfReqHw { name: [u8; 16], hw: libc::sockaddr, _pad: [u8; 8] }
#[repr(C)]
struct RtEntry {
    rt_pad1: libc::c_ulong,
    rt_dst: libc::sockaddr,
    rt_gateway: libc::sockaddr,
    rt_genmask: libc::sockaddr,
    rt_flags: libc::c_ushort,
    rt_pad2: libc::c_short,
    rt_pad3: libc::c_ulong,
    rt_tos: u8,
    rt_class: u8,
    rt_pad4: [libc::c_short; 3],
    rt_metric: libc::c_short,
    rt_dev: *mut libc::c_char,
    rt_mtu: libc::c_ulong,
    rt_window: libc::c_ulong,
    rt_irtt: libc::c_ushort,
}

fn ifname_bytes() -> [u8; 16] {
    let mut n = [0u8; 16];
    n[..IFNAME.len()].copy_from_slice(IFNAME.as_bytes());
    n
}

fn sockaddr_in(ip: u32) -> libc::sockaddr_in {
    libc::sockaddr_in {
        sin_family: libc::AF_INET as libc::sa_family_t,
        sin_port: 0,
        sin_addr: libc::in_addr { s_addr: ip.to_be() },
        sin_zero: [0; 8],
    }
}

fn setup_network() -> std::io::Result<()> {
    // Apple's in-kernel VZNAT runs a DHCP server on the vmnet bridge. Bring lo +
    // eth0 up, take the lease, apply it, and remember the gateway (= the Mac on the
    // bridge) so dockerd can wire host.docker.internal to it.
    let s = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0) };
    if s < 0 { return Err(std::io::Error::last_os_error()); }
    iface_up(s, "lo");
    iface_up(s, IFNAME);

    let mac = get_mac(s)?;
    let lease = dhcp::acquire(IFNAME, mac)?;
    log!("DHCP lease: ip={} mask={} gw={} dns={:?}",
        ipstr(lease.ip), ipstr(lease.mask), ipstr(lease.router), lease.dns.iter().map(|d| ipstr(*d)).collect::<Vec<_>>());

    // address
    let mut ra = IfReqAddr { name: ifname_bytes(), addr: sockaddr_in(lease.ip) };
    if unsafe { libc::ioctl(s, SIOCSIFADDR as _, &mut ra) } != 0 {
        log!("set address failed: {}", std::io::Error::last_os_error());
    }
    // netmask
    let mut rm = IfReqAddr { name: ifname_bytes(), addr: sockaddr_in(lease.mask) };
    if unsafe { libc::ioctl(s, SIOCSIFNETMASK as _, &mut rm) } != 0 {
        log!("set netmask failed: {}", std::io::Error::last_os_error());
    }
    iface_up(s, IFNAME); // re-up after addressing
    // default route via gateway
    if lease.router != 0 {
        add_default_route(s, lease.router);
    }
    // Remember the gateway (the Mac on the vmnet bridge) for host.docker.internal, plus our
    // own IP/mask so the host can locate the bridge interface for the conduit pool.
    GATEWAY_IP.store(lease.router, std::sync::atomic::Ordering::Relaxed);
    GUEST_IP.store(lease.ip, std::sync::atomic::Ordering::Relaxed);
    GUEST_MASK.store(lease.mask, std::sync::atomic::Ordering::Relaxed);
    unsafe { libc::close(s); }

    // DNS: run an in-guest responder so every container gets `host.docker.internal`
    // (Docker-Desktop parity — vanilla dockerd never injects it, on any network).
    // Bind :53 first, then point resolv.conf at our own eth0 IP: the responder
    // becomes the primary nameserver for the guest and — because dockerd copies this
    // file to default-bridge containers and uses it as the embedded resolver's
    // ExtServer on user-defined nets — for every container too. The real upstream(s)
    // follow as a fallback. dockerd strips loopback from the copied file, so we must
    // advertise eth0's address here, never 127.0.0.1.
    let upstream = lease.dns.first().copied().unwrap_or(lease.router);
    start_dns_proxy(lease.ip, lease.router, upstream);
    let mut nameservers = vec![lease.ip];
    nameservers.extend_from_slice(&lease.dns);
    write_resolv_conf(&nameservers);

    // Keep the lease alive. Apple's NAT hands out finite leases; without renewal
    // a long-running VM would eventually lose its address. Renew in the
    // background at ~half the lease interval (best-effort).
    let (ip, server, lease_secs) = (lease.ip, lease.server, lease.lease_secs);
    std::thread::spawn(move || dhcp::renew_loop(IFNAME, mac, ip, server, lease_secs));
    Ok(())
}

/// Enable IPv4/IPv6 packet forwarding before dockerd starts. Docker 29's native
/// nftables firewall backend *checks* `net.ipv4.ip_forward=1` and refuses to
/// initialize the bridge network if it isn't (the legacy iptables path set it
/// itself). Containers can't route out without this anyway.
fn enable_ip_forwarding() {
    for (path, val) in [
        ("/proc/sys/net/ipv4/ip_forward", "1"),
        ("/proc/sys/net/ipv4/conf/all/forwarding", "1"),
        ("/proc/sys/net/ipv6/conf/all/forwarding", "1"),
    ] {
        if let Err(e) = std::fs::write(path, val) { log!("sysctl {path}={val} failed: {e}"); }
    }
}

/// Tune the guest TCP stack for high outbound-connection churn. The published-port datapath dials
/// a fresh conduit (guest→host over VZNAT) *and* a fresh container connection per non-keep-alive
/// request; both are guest-side outbound sockets that land in TIME_WAIT on close. Under a churn
/// storm (thousands of req/s) the default ~28k ephemeral-port range fills with TIME_WAIT sockets
/// in seconds, `connect()` starts returning EADDRNOTAVAIL, the conduit pool can't redial, and the
/// whole published-port path stalls. Widening the port range and enabling TIME_WAIT reuse (safe —
/// it relies on TCP timestamps to reject stale segments) keeps source ports available.
fn tune_network_sysctls() {
    for (path, val) in [
        ("/proc/sys/net/ipv4/ip_local_port_range", "10240\t65535"), // ~55k ephemeral ports (was ~28k)
        ("/proc/sys/net/ipv4/tcp_tw_reuse", "1"),                    // reuse TIME_WAIT for new outbound conns
        ("/proc/sys/net/ipv4/tcp_fin_timeout", "10"),               // drain FIN-WAIT-2 faster
        ("/proc/sys/net/ipv4/tcp_max_tw_buckets", "262144"),        // don't overflow TIME_WAIT under churn (default 32k stalls)
        ("/proc/sys/net/core/somaxconn", "1024"),                   // deeper accept backlog for guest listeners
    ] {
        if let Err(e) = std::fs::write(path, val) { log!("sysctl {path}={val} failed: {e}"); }
    }
}

fn iface_up(s: RawFd, name: &str) {
    let mut n = [0u8; 16];
    n[..name.len().min(15)].copy_from_slice(&name.as_bytes()[..name.len().min(15)]);
    let mut rf = IfReqFlags { name: n, flags: 0, _pad: [0; 22] };
    if unsafe { libc::ioctl(s, SIOCGIFFLAGS as _, &mut rf) } != 0 {
        log!("get flags {name} failed: {}", std::io::Error::last_os_error());
        return;
    }
    rf.flags |= (libc::IFF_UP | libc::IFF_RUNNING) as libc::c_short;
    if unsafe { libc::ioctl(s, SIOCSIFFLAGS as _, &mut rf) } != 0 {
        log!("set UP {name} failed: {}", std::io::Error::last_os_error());
    }
}

fn get_mac(s: RawFd) -> std::io::Result<[u8; 6]> {
    let mut rh = IfReqHw { name: ifname_bytes(), hw: unsafe { std::mem::zeroed() }, _pad: [0; 8] };
    if unsafe { libc::ioctl(s, SIOCGIFHWADDR as _, &mut rh) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    let mut mac = [0u8; 6];
    for i in 0..6 { mac[i] = rh.hw.sa_data[i] as u8; }
    Ok(mac)
}

fn add_default_route(s: RawFd, gw: u32) {
    const RTF_UP: libc::c_ushort = 0x0001;
    const RTF_GATEWAY: libc::c_ushort = 0x0002;
    let to_sa = |ip: u32| -> libc::sockaddr {
        let sin = sockaddr_in(ip);
        unsafe { std::mem::transmute_copy(&sin) }
    };
    let mut rt: RtEntry = unsafe { std::mem::zeroed() };
    rt.rt_dst = to_sa(0);
    rt.rt_genmask = to_sa(0);
    rt.rt_gateway = to_sa(gw);
    rt.rt_flags = RTF_UP | RTF_GATEWAY;
    if unsafe { libc::ioctl(s, SIOCADDRT as _, &mut rt) } != 0 {
        log!("add default route via {} failed: {}", ipstr(gw), std::io::Error::last_os_error());
    }
}

fn write_resolv_conf(dns: &[u32]) {
    let mut s = String::new();
    for d in dns { s.push_str(&format!("nameserver {}\n", ipstr(*d))); }
    if s.is_empty() { s.push_str("nameserver 1.1.1.1\n"); }
    if let Err(e) = std::fs::write("/run/resolv.conf", &s) {
        log!("write resolv.conf failed: {e}");
        return;
    }
    // The root is read-only erofs, so bind-mount the tmpfs copy over the real
    // (empty) /etc/resolv.conf file so dockerd + containers resolve DNS.
    let src = CString::new("/run/resolv.conf").unwrap();
    let tgt = CString::new("/etc/resolv.conf").unwrap();
    let r = unsafe { libc::mount(src.as_ptr(), tgt.as_ptr(), std::ptr::null(), libc::MS_BIND, std::ptr::null()) };
    if r != 0 { log!("bind /etc/resolv.conf failed: {}", std::io::Error::last_os_error()); }
}

fn ipstr(ip: u32) -> String {
    format!("{}.{}.{}.{}", (ip >> 24) & 0xff, (ip >> 16) & 0xff, (ip >> 8) & 0xff, ip & 0xff)
}

// =================== DNS responder (host.docker.internal parity) ===================
//
// Docker Desktop auto-resolves `host.docker.internal` on every container network;
// vanilla dockerd never does. We match it with no host code: a tiny UDP resolver on
// :53 answers the two `*.docker.internal` names with the vmnet gateway (the Mac) and
// forwards everything else to the real upstream. resolv.conf points all consumers
// here (see setup_network), so the name resolves on default-bridge and user-defined
// networks alike — exactly like Docker Desktop.
const DOCKER_INTERNAL_NAMES: [&str; 2] = ["host.docker.internal", "gateway.docker.internal"];

/// Cap on concurrent DNS handler threads. `:53` is reachable by every container, and a
/// query whose upstream is dead parks a thread for the recv timeout — so an unbounded
/// thread-per-datagram model lets a flood exhaust PID 1. Over the cap, queries are
/// dropped (the resolver retries). 64 is far above any real per-VM query concurrency.
static DNS_INFLIGHT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
const DNS_MAX_INFLIGHT: usize = 64;

fn start_dns_proxy(bind_ip: u32, gateway: u32, upstream: u32) {
    // Bind to eth0's *specific* address, not 0.0.0.0: a wildcard socket sources its
    // reply from the route-chosen IP (docker0's gateway), but a default-bridge
    // container queried us at eth0's IP and rejects the mismatched reply. Binding the
    // exact address makes every reply originate from the address that was queried.
    let listen = std::net::SocketAddr::from((std::net::Ipv4Addr::from(bind_ip), 53));
    let sock = match std::net::UdpSocket::bind(listen) {
        Ok(s) => s,
        Err(e) => { log!("dns: bind {listen} failed ({e}); host.docker.internal unavailable"); return; }
    };
    log!("dns: responder on {} (*.docker.internal -> {}, upstream {})", listen, ipstr(gateway), ipstr(upstream));
    std::thread::spawn(move || {
        let sock = std::sync::Arc::new(sock);
        let mut buf = [0u8; 1500];
        loop {
            let (n, src) = match sock.recv_from(&mut buf) { Ok(v) => v, Err(_) => continue };
            // Bound concurrent handlers so a query flood (or a dead upstream parking
            // threads on the forward recv) can't exhaust PID 1's threads/fds.
            if DNS_INFLIGHT.fetch_add(1, std::sync::atomic::Ordering::SeqCst) >= DNS_MAX_INFLIGHT {
                DNS_INFLIGHT.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                continue; // drop; the stub resolver retries
            }
            let query = buf[..n].to_vec();
            let s = sock.clone();
            std::thread::spawn(move || {
                answer_dns(&s, &query, src, gateway, upstream);
                DNS_INFLIGHT.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
            });
        }
    });
}

fn answer_dns(sock: &std::net::UdpSocket, query: &[u8], src: std::net::SocketAddr, gateway: u32, upstream: u32) {
    if let Some((name, qtype, qend)) = parse_qname(query) {
        if DOCKER_INTERNAL_NAMES.contains(&name.as_str()) {
            // A -> gateway; anything else (e.g. AAAA) -> empty NOERROR so the client
            // falls back to the A record instead of chasing a bogus NXDOMAIN.
            let reply = if qtype == 1 { build_a_reply(query, qend, gateway) }
                        else { build_empty_reply(query, qend) };
            let _ = sock.send_to(&reply, src);
            return;
        }
    }
    if let Some(reply) = forward_dns(query, upstream) {
        let _ = sock.send_to(&reply, src);
    }
}

/// Extract the (lowercased) query name, qtype, and the offset just past the question.
fn parse_qname(q: &[u8]) -> Option<(String, u16, usize)> {
    if q.len() < 12 { return None; }
    let mut pos = 12usize;
    let mut name = String::new();
    loop {
        let len = *q.get(pos)? as usize; pos += 1;
        if len == 0 { break; }
        if len & 0xC0 != 0 { return None; } // compression isn't valid in a question
        if pos + len > q.len() { return None; }
        if !name.is_empty() { name.push('.'); }
        for &b in &q[pos..pos + len] { name.push((b as char).to_ascii_lowercase()); }
        pos += len;
    }
    let qtype = u16::from_be_bytes([*q.get(pos)?, *q.get(pos + 1)?]);
    Some((name, qtype, pos + 4))
}

fn build_a_reply(query: &[u8], qend: usize, addr: u32) -> Vec<u8> {
    let mut r = query[..qend].to_vec();
    r[2] = 0x84 | (query[2] & 0x01); // QR=1, AA=1, RD copied
    r[3] = 0x80;                     // RA=1, RCODE=0
    r[6] = 0; r[7] = 1;              // ANCOUNT=1
    r[8] = 0; r[9] = 0; r[10] = 0; r[11] = 0; // NSCOUNT=ARCOUNT=0
    // Answer: name pointer to the question, type A, class IN, TTL 30s, 4-byte addr.
    r.extend_from_slice(&[0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1E, 0x00, 0x04]);
    r.extend_from_slice(&addr.to_be_bytes());
    r
}

fn build_empty_reply(query: &[u8], qend: usize) -> Vec<u8> {
    let mut r = query[..qend].to_vec();
    r[2] = 0x84 | (query[2] & 0x01);
    r[3] = 0x80;
    r[6] = 0; r[7] = 0; r[8] = 0; r[9] = 0; r[10] = 0; r[11] = 0; // ANCOUNT=NS=AR=0
    r
}

fn forward_dns(query: &[u8], upstream: u32) -> Option<Vec<u8>> {
    let up = std::net::UdpSocket::bind(("0.0.0.0", 0)).ok()?;
    up.set_read_timeout(Some(std::time::Duration::from_secs(2))).ok()?;
    let dst = std::net::SocketAddr::from((std::net::Ipv4Addr::from(upstream), 53));
    up.send_to(query, dst).ok()?;
    let mut buf = [0u8; 4096];
    let (n, _) = up.recv_from(&mut buf).ok()?;
    Some(buf[..n].to_vec())
}

mod dhcp {
    use std::io::{Error, ErrorKind, Result};

    // BOOTP/DHCP wire format (RFC 2131/2132). Apple's vmnet server only needs the
    // classic DISCOVER→OFFER→REQUEST→ACK exchange (plus a renewing REQUEST), so a
    // small hand-rolled codec replaces a full DHCP crate — zero dependencies in PID 1.
    const OP_BOOTREQUEST: u8 = 1;
    const OP_BOOTREPLY: u8 = 2;
    const HTYPE_ETHERNET: u8 = 1;
    const HLEN_ETHERNET: u8 = 6;
    const FLAG_BROADCAST: u16 = 0x8000;
    const MAGIC_COOKIE: [u8; 4] = [99, 130, 83, 99];
    /// Length of the fixed BOOTP header up to and including the magic cookie;
    /// option TLVs follow from here.
    const COOKIE_END: usize = 240;

    // DHCP message types (option 53): the two we send (DISCOVER/REQUEST) and the
    // two replies we accept (OFFER/ACK). Validating the reply type means a DHCPNAK
    // (6) can never be mistaken for a lease — it fails the check and we retry.
    const DISCOVER: u8 = 1;
    const OFFER: u8 = 2;
    const REQUEST: u8 = 3;
    const ACK: u8 = 5;

    // Option codes we read or write.
    const OPT_SUBNET_MASK: u8 = 1;
    const OPT_ROUTER: u8 = 3;
    const OPT_DNS: u8 = 6;
    const OPT_REQUESTED_IP: u8 = 50;
    const OPT_LEASE_TIME: u8 = 51;
    const OPT_MESSAGE_TYPE: u8 = 53;
    const OPT_SERVER_ID: u8 = 54;
    const OPT_PARAM_REQUEST: u8 = 55;
    const OPT_PAD: u8 = 0;
    const OPT_END: u8 = 255;

    /// A decoded BOOTP reply — the two header fields we need plus the raw option
    /// TLVs, read through the typed helpers below.
    struct Reply {
        xid: u32,
        yiaddr: u32,
        /// DHCP message type (option 53) — OFFER / ACK / NAK / …
        msg_type: u8,
        opts: Vec<(u8, Vec<u8>)>,
    }

    impl Reply {
        fn option(&self, code: u8) -> Option<&[u8]> {
            self.opts.iter().find(|(c, _)| *c == code).map(|(_, v)| v.as_slice())
        }
        /// First IPv4 address in an option (single-value options, or the first
        /// entry of a list such as Router).
        fn addr(&self, code: u8) -> Option<u32> {
            let v = self.option(code)?;
            (v.len() >= 4).then(|| u32::from_be_bytes([v[0], v[1], v[2], v[3]]))
        }
        /// Every IPv4 address packed into an option (e.g. the DNS server list).
        fn addrs(&self, code: u8) -> Vec<u32> {
            self.option(code)
                .map(|v| v.chunks_exact(4).map(|c| u32::from_be_bytes([c[0], c[1], c[2], c[3]])).collect())
                .unwrap_or_default()
        }
        /// A 4-byte option read as a big-endian u32 (e.g. the lease time).
        fn read_u32(&self, code: u8) -> Option<u32> {
            let v = self.option(code)?;
            (v.len() >= 4).then(|| u32::from_be_bytes([v[0], v[1], v[2], v[3]]))
        }
    }

    pub struct Lease {
        pub ip: u32,
        pub mask: u32,
        pub router: u32,
        pub dns: Vec<u32>,
        /// DHCP server identifier (option 54), for renewal.
        pub server: u32,
        /// Lease time in seconds (option 51); 0 if the server didn't send one.
        pub lease_secs: u32,
    }

    fn rand_xid() -> u32 {
        let mut b = [0u8; 4];
        let _ = std::fs::File::open("/dev/urandom").and_then(|mut f| std::io::Read::read_exact(&mut f, &mut b));
        u32::from_ne_bytes(b)
    }

    pub fn acquire(ifname: &str, mac: [u8; 6]) -> Result<Lease> {
        // Apple's vmnet DHCP server can drop the first DISCOVER (notably right after
        // the bridge comes up). Retransmit a few times with linear backoff before
        // giving up, so a transient miss self-heals instead of leaving the guest with
        // no address — and therefore no DNS — for the whole session.
        let mut last = Error::new(ErrorKind::TimedOut, "no DHCP offer");
        for attempt in 0..12u32 {
            match try_acquire(ifname, mac) {
                Ok(lease) => return Ok(lease),
                Err(e) => {
                    log!("DHCP attempt {} failed: {e}", attempt + 1);
                    last = e;
                    // Flat, short backoff: retransmit ~every 1.25s so we grab a lease
                    // the moment the bridge is ready, instead of escalating into long gaps.
                    std::thread::sleep(std::time::Duration::from_millis(250));
                }
            }
        }
        Err(last)
    }

    fn try_acquire(ifname: &str, mac: [u8; 6]) -> Result<Lease> {
        // Open the socket here and close it on every path (including the `?` errors
        // in the handshake) so a retried acquire doesn't leak a descriptor per miss.
        let sock = open_socket(ifname)?;
        let res = handshake(sock, &mac);
        unsafe { libc::close(sock); }
        res
    }

    fn handshake(sock: i32, mac: &[u8; 6]) -> Result<Lease> {
        let xid = rand_xid();
        // DISCOVER
        let discover = build(mac, xid, DISCOVER, None, None);
        send(sock, &discover)?;
        let offer = recv(sock, xid, OFFER).ok_or_else(|| Error::new(ErrorKind::TimedOut, "no DHCP offer"))?;
        let offered_ip = offer.yiaddr;
        let server = offer.addr(OPT_SERVER_ID);
        // REQUEST
        let request = build(mac, xid, REQUEST, Some(offered_ip), server);
        send(sock, &request)?;
        let ack = recv(sock, xid, ACK).ok_or_else(|| Error::new(ErrorKind::TimedOut, "no DHCP ack"))?;
        Ok(Lease {
            ip: ack.yiaddr,
            mask: ack.addr(OPT_SUBNET_MASK).unwrap_or(0),
            router: ack.addr(OPT_ROUTER).unwrap_or(0),
            dns: ack.addrs(OPT_DNS),
            server: ack.addr(OPT_SERVER_ID).or(server).unwrap_or(0),
            lease_secs: ack.read_u32(OPT_LEASE_TIME).unwrap_or(0),
        })
    }

    /// Renew the current lease in place (INIT-REBOOT style: broadcast REQUEST for
    /// the IP we already hold). Returns Ok once the server ACKs. Best-effort.
    pub fn renew(ifname: &str, mac: [u8; 6], ip: u32, server: u32) -> Result<()> {
        let sock = open_socket(ifname)?;
        let xid = rand_xid();
        let server_opt = if server != 0 { Some(server) } else { None };
        let request = build(&mac, xid, REQUEST, Some(ip), server_opt);
        send(sock, &request)?;
        let res = recv(sock, xid, ACK).map(|_| ())
            .ok_or_else(|| Error::new(ErrorKind::TimedOut, "no DHCP ack on renew"));
        unsafe { libc::close(sock); }
        res
    }

    /// Background renewal loop: re-request the lease at ~half its lifetime (or
    /// every 30 min if the server gave no lease time). Runs for the life of the VM.
    pub fn renew_loop(ifname: &'static str, mac: [u8; 6], ip: u32, server: u32, lease_secs: u32) {
        let interval = if lease_secs >= 120 { (lease_secs / 2) as u64 } else { 1800 };
        loop {
            std::thread::sleep(std::time::Duration::from_secs(interval));
            match renew(ifname, mac, ip, server) {
                Ok(()) => log!("DHCP lease renewed ({})", super::ipstr(ip)),
                Err(e) => log!("DHCP renew failed: {e} (retrying next cycle)"),
            }
        }
    }

    /// Encode a BOOTREQUEST (DISCOVER or REQUEST) carrying the options Apple's
    /// vmnet server expects. `req_ip`/`server` are host-order IPv4 and are emitted
    /// only when present (REQUEST sets them; DISCOVER omits them).
    fn build(mac: &[u8; 6], xid: u32, msg_type: u8, req_ip: Option<u32>, server: Option<u32>) -> Vec<u8> {
        let mut p = Vec::with_capacity(300);
        p.push(OP_BOOTREQUEST);
        p.push(HTYPE_ETHERNET);
        p.push(HLEN_ETHERNET);
        p.push(0); // hops
        p.extend_from_slice(&xid.to_be_bytes());
        p.extend_from_slice(&0u16.to_be_bytes()); // secs
        p.extend_from_slice(&FLAG_BROADCAST.to_be_bytes()); // broadcast: replies come back before we have an IP
        p.extend_from_slice(&[0u8; 4]); // ciaddr
        p.extend_from_slice(&[0u8; 4]); // yiaddr
        p.extend_from_slice(&[0u8; 4]); // siaddr
        p.extend_from_slice(&[0u8; 4]); // giaddr
        p.extend_from_slice(mac); // chaddr: 6-byte MAC ...
        p.extend_from_slice(&[0u8; 10]); // ... padded out to the 16-byte chaddr field
        p.extend_from_slice(&[0u8; 64]); // sname
        p.extend_from_slice(&[0u8; 128]); // file
        p.extend_from_slice(&MAGIC_COOKIE);
        // Options: message type, the parameter request list, then the optional
        // requested-IP / server-id, terminated by END.
        p.extend_from_slice(&[OPT_MESSAGE_TYPE, 1, msg_type]);
        p.extend_from_slice(&[OPT_PARAM_REQUEST, 3, OPT_SUBNET_MASK, OPT_ROUTER, OPT_DNS]);
        if let Some(ip) = req_ip {
            p.push(OPT_REQUESTED_IP);
            p.push(4);
            p.extend_from_slice(&ip.to_be_bytes());
        }
        if let Some(s) = server {
            p.push(OPT_SERVER_ID);
            p.push(4);
            p.extend_from_slice(&s.to_be_bytes());
        }
        p.push(OPT_END);
        p
    }

    /// Decode a BOOTREPLY, or None if it isn't a well-formed reply (wrong op,
    /// missing cookie, or a truncated option).
    fn parse_reply(buf: &[u8]) -> Option<Reply> {
        if buf.len() < COOKIE_END || buf[0] != OP_BOOTREPLY || buf[236..240] != MAGIC_COOKIE {
            return None;
        }
        let xid = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]);
        let yiaddr = u32::from_be_bytes([buf[16], buf[17], buf[18], buf[19]]);
        let mut opts: Vec<(u8, Vec<u8>)> = Vec::new();
        let mut i = COOKIE_END;
        while i < buf.len() {
            match buf[i] {
                OPT_END => break,
                OPT_PAD => i += 1,
                code => {
                    let len = *buf.get(i + 1)? as usize;
                    let start = i + 2;
                    let end = start + len;
                    if end > buf.len() {
                        break;
                    }
                    opts.push((code, buf[start..end].to_vec()));
                    i = end;
                }
            }
        }
        let msg_type = opts.iter()
            .find(|(c, _)| *c == OPT_MESSAGE_TYPE)
            .and_then(|(_, v)| v.first().copied())
            .unwrap_or(0);
        Some(Reply { xid, yiaddr, msg_type, opts })
    }

    fn open_socket(ifname: &str) -> Result<i32> {
        let s = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0) };
        if s < 0 { return Err(Error::last_os_error()); }
        let on: libc::c_int = 1;
        unsafe {
            libc::setsockopt(s, libc::SOL_SOCKET, libc::SO_BROADCAST, &on as *const _ as *const _, 4);
            libc::setsockopt(s, libc::SOL_SOCKET, libc::SO_REUSEADDR, &on as *const _ as *const _, 4);
            // bind to the device so broadcast goes out eth0 before we have an IP
            libc::setsockopt(s, libc::SOL_SOCKET, libc::SO_BINDTODEVICE, ifname.as_ptr() as *const _, ifname.len() as u32);
            // Short per-try OFFER/ACK wait: the vmnet bridge often isn't ready for
            // the very first DISCOVER, so we'd rather retransmit quickly than block
            // 5s. Standard DHCP retransmission — costs nothing when it answers fast.
            let tv = libc::timeval { tv_sec: 1, tv_usec: 0 };
            libc::setsockopt(s, libc::SOL_SOCKET, libc::SO_RCVTIMEO, &tv as *const _ as *const _, std::mem::size_of::<libc::timeval>() as u32);
        }
        let bind = libc::sockaddr_in {
            sin_family: libc::AF_INET as _, sin_port: 68u16.to_be(),
            sin_addr: libc::in_addr { s_addr: 0 }, sin_zero: [0; 8],
        };
        if unsafe { libc::bind(s, &bind as *const _ as *const _, std::mem::size_of::<libc::sockaddr_in>() as u32) } != 0 {
            unsafe { libc::close(s); }
            return Err(Error::last_os_error());
        }
        Ok(s)
    }

    fn send(s: i32, buf: &[u8]) -> Result<()> {
        let dst = libc::sockaddr_in {
            sin_family: libc::AF_INET as _, sin_port: 67u16.to_be(),
            sin_addr: libc::in_addr { s_addr: u32::MAX }, sin_zero: [0; 8], // 255.255.255.255
        };
        let n = unsafe {
            libc::sendto(s, buf.as_ptr() as *const _, buf.len(), 0,
                &dst as *const _ as *const _, std::mem::size_of::<libc::sockaddr_in>() as u32)
        };
        if n < 0 { return Err(Error::last_os_error()); }
        Ok(())
    }

    fn recv(s: i32, xid: u32, expect: u8) -> Option<Reply> {
        // Retry within the socket timeout for a reply that matches both our xid and
        // the expected message type (OFFER or ACK) — so a stray/duplicate packet or a
        // NAK is skipped rather than taken for the lease.
        for _ in 0..4 {
            let mut buf = [0u8; 1024];
            let n = unsafe { libc::recv(s, buf.as_mut_ptr() as *mut _, buf.len(), 0) };
            if n <= 0 { return None; }
            if let Some(m) = parse_reply(&buf[..n as usize]) {
                if m.xid == xid && m.msg_type == expect { return Some(m); }
            }
        }
        log!("DHCP: no matching reply");
        None
    }
}

// =================== data disk ===================

enum ResizeDir { Grow, Shrink }

/// ext4 `(block_size, block_count)` read straight from the on-disk superblock — used
/// to decide whether the data fs must grow or shrink to match the configured size.
fn ext4_geometry(dev: &str) -> Option<(u64, u64)> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(dev).ok()?;
    f.seek(SeekFrom::Start(1024)).ok()?; // the ext4 superblock starts at byte 1024
    let mut sb = [0u8; 64];
    f.read_exact(&mut sb).ok()?;
    let block_count = u32::from_le_bytes([sb[4], sb[5], sb[6], sb[7]]) as u64;        // s_blocks_count_lo (0x04)
    let log_block_size = u32::from_le_bytes([sb[24], sb[25], sb[26], sb[27]]) as u64; // s_log_block_size (0x18)
    if block_count == 0 { return None; }
    Some((1024u64 << log_block_size, block_count))
}

/// Byte size of /dev/vdb from sysfs (512-byte sectors) — caps a grow so resize2fs is
/// never asked for more blocks than the block device actually has.
fn vdb_byte_size() -> Option<u64> {
    std::fs::read_to_string("/sys/block/vdb/size")
        .ok()?.trim().parse::<u64>().ok().map(|sectors| sectors * 512)
}

/// Whether the data ext4 must grow or shrink to match `velox.disk` (GiB on the kernel
/// cmdline), and to how many blocks. `None` when it already matches (within one block)
/// or the target/geometry can't be read. A grow is clamped to the real device size, so
/// a re-raise after a shrink (device still larger than the old ext4) stops at the
/// requested size rather than overshooting to the device and oscillating each boot.
fn planned_resize(dev: &str) -> Option<(ResizeDir, u64)> {
    let target_gib = cmdline_value("velox.disk").and_then(|v| v.parse::<u64>().ok())?;
    let (block_size, block_count) = ext4_geometry(dev)?;
    let current = block_size * block_count;
    let target = target_gib * 1024 * 1024 * 1024;
    if target + block_size < current {
        Some((ResizeDir::Shrink, target / block_size))
    } else if target > current + block_size {
        let mut blocks = target / block_size;
        if let Some(dev_bytes) = vdb_byte_size() { blocks = blocks.min(dev_bytes / block_size); }
        if blocks > block_count { Some((ResizeDir::Grow, blocks)) } else { None }
    } else {
        None
    }
}

/// Returns true if `/var/lib/docker` is on durable storage (or intentionally on tmpfs
/// because no data disk was attached). Returns **false** only when a data disk *was*
/// attached (`/dev/vdb` present) but couldn't be formatted/mounted — in which case the
/// caller refuses to start dockerd rather than silently run on non-persistent tmpfs.
fn setup_data_disk() -> bool {
    let dev = "/dev/vdb";
    if !std::path::Path::new(dev).exists() {
        log!("no {dev} — /var/lib/docker stays on tmpfs (non-persistent)");
        return true; // intentional (dev/test) — not a failure
    }
    if !is_ext4(dev) {
        log!("formatting {dev} ext4 (first boot)");
        // -m 0: a dedicated data disk needs no 5%-reserved root headroom (dockerd
        // runs as root anyway) — reclaim it for image/container storage. Applies to
        // the first-boot format only; existing disks keep whatever they were made with.
        let st = Command::new("/sbin/mkfs.ext4").args(["-F", "-q", "-m", "0", dev]).status();
        if !st.as_ref().map(|s| s.success()).unwrap_or(false) {
            log!("mkfs.ext4 failed: {st:?}");
            return false;
        }
    }
    // Resize the data fs to the configured size (velox.disk on the cmdline). ext4
    // can only SHRINK while unmounted (and needs a prior e2fsck), so do a shrink
    // here, before the mount; a GROW is done online right after it. One-shot —
    // planned_resize returns None once the fs already matches the target, so a
    // normal boot pays nothing. resize2fs ships in e2fsprogs-extra; e2fsck is base.
    let resize = planned_resize(dev);
    if let Some((ResizeDir::Shrink, blocks)) = resize {
        log!("data disk: shrinking ext4 → {blocks} blocks (velox.disk)");
        let _ = Command::new("/sbin/e2fsck").args(["-f", "-y", dev]).status();
        match Command::new("/usr/sbin/resize2fs").args([dev, &blocks.to_string()]).status() {
            Ok(s) if s.success() => {}, other => log!("resize2fs shrink failed: {other:?}"),
        }
    }
    // /var/lib/docker is overlay-snapshot churn central — every `docker run`
    // mounts/unmounts a snapshot. noatime drops read-driven atime writes; lazytime
    // keeps inode mtime/ctime in memory and flushes them lazily (on fsync / sync /
    // 24h) instead of journalling every metadata touch — less write amplification on
    // the container hot path, and nothing under here needs atime/precise timestamps.
    //
    // barrier=0: the host attaches this disk in writeback (VMConfiguration uses
    // `synchronizationMode: .none`), so the guest's per-commit FLUSH barrier is dead
    // weight — the host just no-ops it. Dropping it removes a virtio FLUSH round-trip
    // per fsync; measured ~3x the durable commits/s of Docker Desktop (which keeps
    // barriers on). Velox is a development engine — image/volume state is recreatable —
    // so this speed-over-crash-ordering trade is the right default. Its one cost is
    // crash *ordering*: after an unclean shutdown the journal/metadata can be torn, so
    // preen-fsck first. A clean boot (the norm — graceful stop unmounts cleanly) reads
    // a clean superblock and pays nothing.
    if !data_disk_clean(dev) {
        log!("data disk: not cleanly unmounted — running e2fsck -p before mount");
        let _ = Command::new("/sbin/e2fsck").args(["-p", dev]).status();
    }
    if !do_mount(dev, "/var/lib/docker", "ext4",
                 libc::MS_NOATIME | libc::MS_LAZYTIME, Some("barrier=0")) {
        return false; // mount failed — caller refuses dockerd (don't run on tmpfs)
    }
    if let Some((ResizeDir::Grow, blocks)) = resize {
        log!("data disk: growing ext4 → {blocks} blocks (velox.disk)");
        match Command::new("/usr/sbin/resize2fs").args([dev, &blocks.to_string()]).status() {
            Ok(s) if s.success() => {}, other => log!("resize2fs grow failed: {other:?}"),
        }
    }
    start_fstrim_timer();
    true
}

/// Periodically TRIM the data disk so blocks freed by deleted image layers /
/// containers are released back to the host. Paired with the host's ASIF data disk,
/// the discard hole-punches the backing file — so the disk shrinks instead of
/// growing forever like Docker Desktop's `Docker.raw`. Periodic (not `-o discard`)
/// to keep delete latency off the hot path, exactly like OrbStack/Docker Desktop.
fn start_fstrim_timer() {
    // FITRIM: _IOWR('X', 121, struct fstrim_range) — trims the whole filesystem.
    const FITRIM: libc::c_ulong = 0xC018_5879;
    #[repr(C)]
    struct FstrimRange { start: u64, len: u64, minlen: u64 }
    std::thread::spawn(|| {
        // One pass shortly after boot (reclaims anything freed last session), then hourly.
        let mut delay = std::time::Duration::from_secs(60);
        loop {
            std::thread::sleep(delay);
            delay = std::time::Duration::from_secs(3600);
            let path = match CString::new("/var/lib/docker") { Ok(p) => p, Err(_) => continue };
            let fd = unsafe { libc::open(path.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC) };
            if fd < 0 { continue; }
            let mut range = FstrimRange { start: 0, len: u64::MAX, minlen: 0 };
            if unsafe { libc::ioctl(fd, FITRIM as _, &mut range) } < 0 {
                log!("fstrim failed: {}", std::io::Error::last_os_error());
            }
            unsafe { libc::close(fd); }
        }
    });
}

fn is_ext4(dev: &str) -> bool {
    use std::io::{Seek, SeekFrom};
    let Ok(mut f) = std::fs::File::open(dev) else { return false };
    if f.seek(SeekFrom::Start(1080)).is_err() { return false; }
    let mut magic = [0u8; 2];
    if f.read_exact(&mut magic).is_err() { return false; }
    magic == [0x53, 0xEF] // EXT4 superblock magic 0xEF53 (LE)
}

/// True if the ext4 data disk was cleanly unmounted — superblock `s_state` has
/// VALID_FS set and ERROR_FS clear. Read before the `barrier=0` mount to decide
/// whether a preen-fsck is needed first. The kernel clears VALID_FS while the fs is
/// mounted rw and re-sets it on a clean unmount, so a clear bit here means last
/// session crashed. Unreadable → assume clean (never stall boot on a probe).
fn data_disk_clean(dev: &str) -> bool {
    use std::io::{Seek, SeekFrom};
    let Ok(mut f) = std::fs::File::open(dev) else { return true };
    // ext4 superblock starts at byte 1024; s_state is the __le16 at sb offset 58.
    if f.seek(SeekFrom::Start(1024 + 58)).is_err() { return true; }
    let mut s = [0u8; 2];
    if f.read_exact(&mut s).is_err() { return true; }
    let state = u16::from_le_bytes(s);
    (state & 0x0001) != 0 && (state & 0x0002) == 0 // VALID_FS set, ERROR_FS clear
}

// =================== swap ===================

/// If the host requested swap (`velox.swap=<MiB>` on the cmdline), create a
/// swapfile on the persistent data disk and enable it. No mkswap binary in the
/// image — we write the swap v1 header ourselves and `swapon(2)` directly.
fn setup_swap() {
    let Some(mib) = cmdline_value("velox.swap").and_then(|v| v.parse::<u64>().ok()) else { return };
    if mib == 0 { return; }
    // Swap only makes sense on the persistent ext4 data disk; if it isn't mounted
    // (no /dev/vdb), /var/lib/docker is tmpfs and swapping there is pointless.
    if !std::path::Path::new("/dev/vdb").exists() {
        log!("velox.swap set but no data disk — skipping swap");
        return;
    }
    let path = "/var/lib/docker/.velox-swapfile";
    match make_swapfile(path, mib * 1024 * 1024) {
        Ok(()) => {
            let cpath = CString::new(path).unwrap();
            if unsafe { libc::swapon(cpath.as_ptr(), 0) } == 0 {
                log!("swap enabled: {mib} MiB at {path}");
            } else {
                log!("swapon failed: {}", std::io::Error::last_os_error());
            }
        }
        Err(e) => log!("swapfile setup failed: {e}"),
    }
}

/// Build a valid Linux v1 swapfile of (at least) `bytes`, allocated with no holes
/// (swapon rejects sparse files) and stamped with the swap header + magic.
fn make_swapfile(path: &str, bytes: u64) -> std::io::Result<()> {
    use std::io::{Seek, SeekFrom, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::io::AsRawFd;

    let page = match unsafe { libc::sysconf(libc::_SC_PAGESIZE) } {
        n if n > 0 => n as u64,
        _ => 4096,
    };
    let pages = bytes / page;
    if pages < 10 {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "swap size too small"));
    }
    let size = pages * page;

    let mut f = std::fs::OpenOptions::new()
        .read(true).write(true).create(true).truncate(true).open(path)?;
    // Swap must not be world/group readable.
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    // Allocate real blocks — a sparse (ftruncate'd) file fails swapon with "has holes".
    if unsafe { libc::fallocate(f.as_raw_fd(), 0, 0, size as libc::off_t) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    // swap_header (union, one page): info.version @1024, info.last_page @1028,
    // info.nr_badpages @1032; magic "SWAPSPACE2" at the END of the first page.
    f.seek(SeekFrom::Start(1024))?;
    f.write_all(&1u32.to_ne_bytes())?;                 // version = 1
    f.write_all(&((pages - 1) as u32).to_ne_bytes())?; // last_page
    f.write_all(&0u32.to_ne_bytes())?;                 // nr_badpages = 0
    f.seek(SeekFrom::Start(page - 10))?;
    f.write_all(b"SWAPSPACE2")?;
    f.flush()?;
    Ok(())
}

// =================== VirtioFS + Rosetta ===================

fn setup_virtiofs() {
    // host /Users → /Users, shared propagation so container bind mounts resolve.
    let _ = std::fs::create_dir_all("/Users");
    do_mount("vlxusers", "/Users", "virtiofs", 0, None);
    make_rshared("/Users");

    // extra shares advertised on the cmdline as velox.shares=<base64 of "tag\tpath\n">
    if let Some(b64) = cmdline_value("velox.shares") {
        if let Some(decoded) = b64_decode(&b64) {
            for line in String::from_utf8_lossy(&decoded).lines() {
                let mut it = line.splitn(2, '\t');
                if let (Some(tag), Some(path)) = (it.next(), it.next()) {
                    if tag.is_empty() || path.is_empty() { continue; }
                    let _ = std::fs::create_dir_all(path);
                    do_mount(tag, path, "virtiofs", 0, None);
                    make_rshared(path);
                    log!("mounted share {tag} at {path}");
                }
            }
        }
    }

    // Rosetta x86-64 translation (optional — only if the host attached the share).
    let _ = std::fs::create_dir_all("/run/rosetta");
    let csrc = CString::new("rosetta").unwrap();
    let ctgt = CString::new("/run/rosetta").unwrap();
    let cfs = CString::new("virtiofs").unwrap();
    let r = unsafe { libc::mount(csrc.as_ptr(), ctgt.as_ptr(), cfs.as_ptr(), 0, std::ptr::null()) };
    if r == 0 {
        // The kernel hex-unescapes the magic/mask itself (string_unescape_inplace,
        // UNESCAPE_HEX), so we write the LITERAL `\xNN` escaped form — NOT raw
        // bytes (raw NULs would truncate the magic at scanarg, matching every
        // 64-bit ELF and breaking arm64 exec). magic matches x86-64 (e_machine
        // 0x3e at offset 18); arm64 binaries don't match.
        let reg = ":rosetta:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00:\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:/run/rosetta/rosetta:OCF";
        match std::fs::write("/proc/sys/fs/binfmt_misc/register", reg) {
            Ok(_) => log!("rosetta registered"),
            Err(e) => log!("rosetta binfmt register failed: {e}"),
        }
    } else {
        log!("no rosetta share — x86 emulation off");
    }
}

fn make_rshared(target: &str) {
    let ctgt = CString::new(target).unwrap();
    unsafe {
        libc::mount(std::ptr::null(), ctgt.as_ptr(), std::ptr::null(),
            libc::MS_SHARED | libc::MS_REC, std::ptr::null());
    }
}

/// Minimal standard base64 decoder (no external crate).
fn b64_decode(s: &str) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u8> {
        match c {
            b'A'..=b'Z' => Some(c - b'A'),
            b'a'..=b'z' => Some(c - b'a' + 26),
            b'0'..=b'9' => Some(c - b'0' + 52),
            b'+' => Some(62), b'/' => Some(63),
            _ => None,
        }
    }
    let mut out = Vec::new();
    let mut buf = 0u32;
    let mut bits = 0u32;
    for &c in s.trim().as_bytes() {
        if c == b'=' { break; }
        let Some(v) = val(c) else { continue };
        buf = (buf << 6) | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
        }
    }
    Some(out)
}

// =================== dockerd ===================

/// Launch dockerd once and return its PID (or -1 if the spawn itself failed).
/// The reaper (`reap_forever`) watches this PID and relaunches the daemon if it
/// ever exits, so a dockerd crash never leaves the engine permanently dead.
fn spawn_dockerd() -> i32 {
    // dockerd discovers containerd/runc/nft/iptables on PATH and manages its own
    // containerd. Unix socket (not TCP) — the vsock agent bridges to it directly.
    let mut args: Vec<String> = vec![
        "--host=unix:///run/docker.sock".into(),
        "--feature=containerd-snapshotter=true".into(),
        // Docker 29's native in-kernel nftables firewall (drives `nft` directly via a
        // batched ruleset) instead of shelling out to the iptables-nft compat binary
        // per rule. Native dockerd capability over an extra package: the
        // iptables/ip6tables binaries are dropped from the rootfs. Requires the nft
        // `fib` expression (kernel fragment) and ip_forward preset (below).
        "--firewall-backend=nftables".into(),
    ];
    // In netstack (static) mode the gateway IP is fixed and is also
    // host.docker.internal; tell dockerd so `--add-host host.docker.internal:
    // host-gateway` (and compose extra_hosts) resolve to the Mac.
    // host.docker.internal → the vmnet gateway (the Mac), so containers can reach
    // host services. Containers add it via `--add-host host.docker.internal:host-gateway`
    // (Docker Desktop sets the same hostname automatically too).
    let gw = GATEWAY_IP.load(std::sync::atomic::Ordering::Relaxed);
    if gw != 0 {
        args.push(format!("--host-gateway-ip={}", ipstr(gw)));
    }
    let child = Command::new("/bin/dockerd")
        .args(&args)
        .env("PATH", "/bin:/usr/bin:/sbin:/usr/sbin")
        // dockerd 29's default firewall backend is nftables; the `nft` binary is in
        // the image (nftables pkg). NOTE: we deliberately do NOT set DOCKER_RAMDISK
        // — the root is a real erofs block device, so runc can pivot_root normally.
        .spawn();
    match child {
        Ok(c) => { let pid = c.id() as i32; log!("dockerd started (pid {pid})"); pid }
        Err(e) => { log!("FAILED to start dockerd: {e}"); -1 }
    }
}

// =================== vsock agent ===================

fn start_vsock_agent() {
    spawn_listener(CONTROL_PORT, handle_control);
    spawn_listener(REVERSE_PORT, handle_reverse);
    spawn_listener(CLOCK_PORT, handle_clock);
    spawn_listener(DOCKER_PORT, handle_data);
    spawn_listener(GW_PORT, handle_gateway);
}

fn vsock_listen(port: u32) -> std::io::Result<RawFd> {
    let fd = unsafe { libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM, 0) };
    if fd < 0 { return Err(std::io::Error::last_os_error()); }
    #[repr(C)]
    struct SockaddrVm { family: libc::sa_family_t, _r0: u16, port: u32, cid: u32, _z: [u8; 4] }
    let addr = SockaddrVm { family: libc::AF_VSOCK as _, _r0: 0, port, cid: CID_ANY, _z: [0; 4] };
    let r = unsafe { libc::bind(fd, &addr as *const _ as *const _, std::mem::size_of::<SockaddrVm>() as u32) };
    if r != 0 { let e = std::io::Error::last_os_error(); unsafe { libc::close(fd); } return Err(e); }
    if unsafe { libc::listen(fd, 128) } != 0 {
        let e = std::io::Error::last_os_error(); unsafe { libc::close(fd); } return Err(e);
    }
    Ok(fd)
}

/// Cap on concurrent vsock handler threads across all agent ports. Each accepted
/// connection spawns a handler (and the data/reverse bridges spawn 2 more pump threads
/// each), so without a ceiling a host-side connection storm could exhaust PID 1's
/// threads/fds. Over the cap, the connection is closed (the host retries). 256 is far
/// above the ~25-30 persistent streams Velox actually opens.
static VSOCK_INFLIGHT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
const VSOCK_MAX_INFLIGHT: usize = 256;

fn spawn_listener(port: u32, handler: fn(RawFd)) {
    std::thread::spawn(move || {
        let lfd = match vsock_listen(port) {
            Ok(f) => f,
            Err(e) => { log!("vsock listen {port} failed: {e}"); return; }
        };
        log!("vsock listening on {port}");
        loop {
            let cfd = unsafe { libc::accept(lfd, std::ptr::null_mut(), std::ptr::null_mut()) };
            if cfd < 0 {
                // Don't busy-spin on a persistent error. Transient → retry; resource
                // exhaustion → back off (so the spin doesn't starve the threads that
                // would free fds); fatal → the listener is dead, stop it.
                let err = std::io::Error::last_os_error();
                match err.raw_os_error() {
                    Some(libc::EINTR) | Some(libc::ECONNABORTED) => {}
                    Some(libc::EMFILE) | Some(libc::ENFILE) | Some(libc::ENOBUFS) | Some(libc::ENOMEM) => {
                        log!("vsock accept on {port}: {err} — backing off");
                        std::thread::sleep(std::time::Duration::from_millis(100));
                    }
                    _ => { log!("vsock accept on {port} fatal: {err} — listener stopping"); return; }
                }
                continue;
            }
            // Bound concurrent handlers so a connection storm can't exhaust PID 1.
            if VSOCK_INFLIGHT.fetch_add(1, std::sync::atomic::Ordering::SeqCst) >= VSOCK_MAX_INFLIGHT {
                VSOCK_INFLIGHT.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                log!("vsock {port}: too many in-flight connections — rejecting");
                unsafe { libc::close(cfd); }
                continue;
            }
            std::thread::spawn(move || {
                handler(cfd);
                VSOCK_INFLIGHT.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
            });
        }
    });
}

fn handle_control(fd: RawFd) {
    unsafe { libc::sync(); }
    let _ = nix_write(fd, b"OK\n");
    unsafe { libc::close(fd); }
}

/// Clock re-sync: the host writes "<unix-epoch>\n" (at start and whenever the Mac
/// wakes). Apple VZ has no RTC, so a slept-then-resumed guest is behind by the
/// sleep duration — enough to break TLS. Re-set the clock only on large drift to
/// avoid needless jitter. Host-authoritative, no NTP daemon (see CLAUDE.md §6).
fn handle_clock(fd: RawFd) {
    let mut line = Vec::new();
    let mut b = [0u8; 1];
    loop {
        let n = unsafe { libc::read(fd, b.as_mut_ptr() as *mut _, 1) };
        if n <= 0 { unsafe { libc::close(fd); } return; }
        if b[0] == b'\n' { break; }
        line.push(b[0]);
        if line.len() > 32 { break; }
    }
    unsafe { libc::close(fd); }
    let Ok(epoch) = String::from_utf8_lossy(&line).trim().parse::<i64>() else { return };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    if (epoch - now).abs() <= 2 { return; } // already aligned
    let tv = libc::timeval { tv_sec: epoch as libc::time_t, tv_usec: 0 };
    if unsafe { libc::settimeofday(&tv, std::ptr::null()) } == 0 {
        log!("clock re-synced from host: {now} -> {epoch}");
    } else {
        log!("clock re-sync failed: {}", std::io::Error::last_os_error());
    }
}

fn handle_data(fd: RawFd) {
    match UnixStream::connect(DOCKER_SOCK) {
        Ok(up) => bridge(fd, up.into_raw_fd()),
        Err(e) => { log!("dial docker.sock: {e}"); unsafe { libc::close(fd); } }
    }
}

/// Gateway probe. The host's `GatewayProbe` connects once at boot; reply with the vmnet
/// gateway, our own IP, and our mask (`"<gw> <ip> <mask>\n"`) so the host can locate the
/// bridge interface to bind the conduit pool on and validate conduit peers. Block briefly
/// until DHCP has populated these (normally sub-second; cap ~10s so we never wedge a probe).
fn handle_gateway(fd: RawFd) {
    let mut tries = 0;
    let gw = loop {
        let gw = GATEWAY_IP.load(std::sync::atomic::Ordering::Relaxed);
        if gw != 0 || tries >= 200 { break gw; }
        tries += 1;
        std::thread::sleep(std::time::Duration::from_millis(50));
    };
    let ip = GUEST_IP.load(std::sync::atomic::Ordering::Relaxed);
    let mask = GUEST_MASK.load(std::sync::atomic::Ordering::Relaxed);
    let line = format!("{} {} {}\n", ipstr(gw), ipstr(ip), ipstr(mask));
    let _ = nix_write(fd, line.as_bytes());
    unsafe { libc::close(fd); }
}

// =================== VZNAT reverse-dial conduit pool ===================
//
// Published-port data normally relays over vsock (host→guest 2376), which Apple caps at
// ~6 Gbit/s. Instead we keep a pool of TCP conduits dialed guest→host over VZNAT (the fast
// direction, ~95 up / ~17 down), each parked waiting for the host to assign it a published
// port. The host pops a warm conduit, writes "<port>\n", and splices the client to it — so
// the data rides VZNAT and the connection handshake is pre-paid off the hot path.
//
// We keep ~CONDUIT_FLOOR conduits *idle and parked* at rest, and grow the pool under load: the
// moment a slot is assigned and the idle count is below the floor (demand outran the warm pool),
// it spawns another slot, up to CONDUIT_CAP total. Over-floor idle slots reap after a timeout
// when load subsides. A slot is only ever a thread while *idle* (parked, blocked) — the actual
// data relaying is done by the epoll workers (relay_submit), so active connections cost no
// threads. The host pairs these conduits to waiting clients, so concurrent connections all take
// the fast path instead of capping at a fixed count.
const CONDUIT_FLOOR: usize = 16;       // warm idle conduits at true idle (lean baseline)
// Hard cap on total slots. Kept modest on purpose: the guest has only a handful of vCPUs, and a
// large pool *hurts* — hundreds of slots maintaining/redialing idle conduits thrash the scheduler
// and overrun the host listener's accept backlog (SYN drops → redial storm). ~128 covers the
// largest realistic keep-alive fan-out; excess connections spill to the vsock relay, which is fine.
const CONDUIT_CAP: usize = 128;
const CONDUIT_REAP_MS: i32 = 10_000;   // an over-target idle conduit reaps after this with no work
const CONDUIT_GROW_STEP: usize = 16;   // target growth per starvation signal
static CONDUIT_IDLE: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
static CONDUIT_SLOTS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
// Adaptive target for total slots: starts at the floor, rises on starvation (a burst drained the
// warm pool, so clients would otherwise wait), decays back to the floor when load subsides. This
// keeps the pool lean at idle yet deep enough under sustained load that clients rarely wait for a
// conduit — which is what was costing connection-churn throughput.
static DESIRED_SLOTS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(CONDUIT_FLOOR);

struct PoolMgr { pending: std::sync::Mutex<bool>, cv: std::sync::Condvar }
static POOL_MGR: std::sync::OnceLock<PoolMgr> = std::sync::OnceLock::new();

fn start_conduit_pool() {
    relay_init(); // epoll workers must exist before any conduit is assigned
    POOL_MGR.get_or_init(|| PoolMgr {
        pending: std::sync::Mutex::new(false),
        cv: std::sync::Condvar::new(),
    });
    // The manager owns all spawning; its first pass grows the pool up to the floor, then it adapts.
    std::thread::spawn(conduit_manager);
}

fn spawn_conduit_slot() {
    CONDUIT_SLOTS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    std::thread::spawn(conduit_slot);
}

/// Wake the pool manager: a slot saw the warm pool run low and raised `DESIRED_SLOTS`.
fn notify_manager() {
    if let Some(m) = POOL_MGR.get() {
        *m.pending.lock().unwrap() = true;
        m.cv.notify_one();
    }
}

/// Sole owner of slot *spawning*. Centralising it means a burst that drains the pool can't
/// trigger a thundering herd of simultaneous spawns (the failure mode of per-slot growth): the
/// manager grows toward `DESIRED_SLOTS` in one place, then parks on a condvar until the next
/// starvation signal. While the target sits above the floor it also wakes ~1×/s to decay the
/// target back down, so the pool unwinds to its lean idle size once load subsides. At true idle
/// (target == floor) it parks indefinitely — no timer, no wakeups (event-driven, per convention).
fn conduit_manager() {
    use std::sync::atomic::Ordering::Relaxed;
    let m = POOL_MGR.get().unwrap();
    loop {
        // Grow toward the target. `CONDUIT_SLOTS` is incremented up-front in `spawn_conduit_slot`,
        // so it counts in-flight (still-dialing) slots — no overshoot even before they park idle.
        let target = DESIRED_SLOTS.load(Relaxed).min(CONDUIT_CAP);
        while CONDUIT_SLOTS.load(Relaxed) < target { spawn_conduit_slot(); }

        // Park until a starvation signal (or, while decaying, a 1s tick to step the target down).
        let decaying = DESIRED_SLOTS.load(Relaxed) > CONDUIT_FLOOR;
        {
            let mut pending = m.pending.lock().unwrap();
            while !*pending {
                if decaying {
                    let (g, to) = m.cv.wait_timeout(pending, std::time::Duration::from_millis(1000)).unwrap();
                    pending = g;
                    if to.timed_out() { break; }
                } else {
                    pending = m.cv.wait(pending).unwrap();
                }
            }
            *pending = false;
        }
        // Decay the target toward the floor only when there's comfortable idle headroom — during a
        // burst idle stays low, so this never fights active growth.
        let (idle, cur) = (CONDUIT_IDLE.load(Relaxed), DESIRED_SLOTS.load(Relaxed));
        if cur > CONDUIT_FLOOR && idle > CONDUIT_FLOOR {
            DESIRED_SLOTS.store((cur - (cur / 8).max(1)).max(CONDUIT_FLOOR), Relaxed);
        }
    }
}

enum Assignment { Got(String), Idle, Dead }

/// One idle-conduit slot: dial, park waiting for an assignment, hand the connection to the
/// epoll relay on assignment (then redial to stay warm), grow the pool when demand is high, and
/// reap itself when over the floor and idle.
fn conduit_slot() {
    use std::sync::atomic::Ordering::Relaxed;
    loop {
        let fd = match dial_conduit() {
            Some(fd) => fd,
            None => { std::thread::sleep(std::time::Duration::from_millis(250)); continue; }
        };
        // Park on this conduit; re-park on idle (at floor) so we don't churn it needlessly.
        loop {
            CONDUIT_IDLE.fetch_add(1, Relaxed);
            let res = read_assignment_timed(fd, CONDUIT_REAP_MS);
            CONDUIT_IDLE.fetch_sub(1, Relaxed);
            match res {
                Assignment::Got(target) => {
                    // The warm pool ran low (a burst outran it) → raise the adaptive target and
                    // wake the manager, which grows the pool centrally (no thundering herd).
                    if CONDUIT_IDLE.load(Relaxed) < CONDUIT_FLOOR {
                        let cur = DESIRED_SLOTS.load(Relaxed);
                        if cur < CONDUIT_CAP {
                            DESIRED_SLOTS.store((cur + CONDUIT_GROW_STEP).min(CONDUIT_CAP), Relaxed);
                            notify_manager();
                        }
                    }
                    bridge_to_target(fd, &target); // dials container + hands to the relay (fast)
                    break; // redial a fresh warm conduit
                }
                Assignment::Idle => {
                    // Reap toward the (decaying) adaptive target, not the hard floor, so the pool
                    // holds depth while the target is still high but unwinds as load subsides.
                    if CONDUIT_SLOTS.load(Relaxed) > DESIRED_SLOTS.load(Relaxed) {
                        unsafe { libc::close(fd); }
                        CONDUIT_SLOTS.fetch_sub(1, Relaxed);
                        return; // reap this slot — load has subsided
                    }
                    // else keep cycling on the same conduit (re-park)
                }
                Assignment::Dead => break, // conduit closed before assignment → redial
            }
        }
    }
}

/// Dial one conduit to the host's pool listener over VZNAT, with keepalive so a silently
/// evicted idle conduit is detected + redialled within ~40s. None on failure (caller backs off).
fn dial_conduit() -> Option<RawFd> {
    let gw = GATEWAY_IP.load(std::sync::atomic::Ordering::Relaxed);
    if gw == 0 { return None; }
    let addr = std::net::SocketAddr::from((std::net::Ipv4Addr::from(gw), POOL_PORT));
    match std::net::TcpStream::connect_timeout(&addr, std::time::Duration::from_secs(5)) {
        Ok(stream) => {
            let _ = stream.set_nodelay(true); // assignment + data flow without Nagle delay
            let fd = stream.into_raw_fd();
            set_conduit_keepalive(fd);
            Some(fd)
        }
        Err(_) => None,
    }
}

/// Short TCP keepalive on a parked conduit: if VZNAT's conntrack silently evicts an idle
/// conduit, the probes fail and `read()` in `handle_conduit` errors, so the slot redials a
/// fresh one (~25s idle + 3×5s probes ≈ 40s) instead of parking a dead connection forever.
fn set_conduit_keepalive(fd: RawFd) {
    let on: libc::c_int = 1;
    let idle: libc::c_int = 25;
    let intvl: libc::c_int = 5;
    let cnt: libc::c_int = 3;
    let sz = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
    unsafe {
        libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_KEEPALIVE, &on as *const _ as *const _, sz);
        libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_KEEPIDLE, &idle as *const _ as *const _, sz);
        libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, &intvl as *const _ as *const _, sz);
        libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_KEEPCNT, &cnt as *const _ as *const _, sz);
    }
}

/// Wait up to `timeout_ms` for the host's "<target>\n" assignment on a parked conduit. `Got` =
/// assigned; `Idle` = timed out (conduit still alive — caller reaps or re-parks); `Dead` = the
/// conduit closed/errored (fd already closed). Same line framing as `handle_reverse`.
fn read_assignment_timed(fd: RawFd, timeout_ms: i32) -> Assignment {
    let mut pfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    let r = unsafe { libc::poll(&mut pfd, 1, timeout_ms) };
    if r == 0 { return Assignment::Idle; }
    if r < 0 { unsafe { libc::close(fd); } return Assignment::Dead; }
    let mut line = Vec::new();
    let mut b = [0u8; 1];
    loop {
        let n = unsafe { libc::read(fd, b.as_mut_ptr() as *mut _, 1) };
        if n <= 0 { unsafe { libc::close(fd); } return Assignment::Dead; }
        if b[0] == b'\n' { break; }
        line.push(b[0]);
        if line.len() > 64 { break; }
    }
    let header = String::from_utf8_lossy(&line).trim().to_string();
    if header.is_empty() { unsafe { libc::close(fd); } return Assignment::Dead; }
    Assignment::Got(header)
}

/// Dial the assigned target inside the guest and bridge it to the conduit. The host sends
/// either `<container-ip>:<port>` (direct-dial — the guest reaches the container over docker0
/// in its root netns, skipping docker-proxy's userspace copy) or a bare `<port>` (→
/// 127.0.0.1:<port>, i.e. docker-proxy) when it couldn't resolve an unambiguous endpoint.
fn bridge_to_target(fd: RawFd, header: &str) {
    let mut target = header.to_string();
    if !target.contains(':') { target = format!("127.0.0.1:{target}"); }
    match std::net::TcpStream::connect(&target) {
        // Hand the pair to the epoll relay (no thread per connection) instead of bridge().
        Ok(up) => relay_submit(fd, up.into_raw_fd()),
        Err(e) => { log!("conduit dial {target}: {e}"); unsafe { libc::close(fd); } }
    }
}

// =================== epoll event-loop relay (conduit datapath) ===================
//
// bridge() spawns 2 pump threads per connection — fine for a handful of conduits, but under
// real serving load (100s of short/concurrent connections) it explodes to 100s of threads
// and wrecks tail latency. Instead a small pool of epoll workers multiplexes many
// conduit<->container pairs each: non-blocking, with backpressure (a stalled write disables
// reads on the source) and half-close. Only the conduit datapath uses this; the vsock relays
// keep bridge(). 256 KiB buffers + a per-event drain loop preserve bulk throughput.

const RELAY_WORKERS: usize = 4;

struct RelayWorker { epfd: RawFd, evfd: RawFd, queue: std::sync::Mutex<std::collections::VecDeque<(RawFd, RawFd)>> }
struct Relay { workers: Vec<std::sync::Arc<RelayWorker>>, next: std::sync::atomic::AtomicUsize }
static RELAY: std::sync::OnceLock<Relay> = std::sync::OnceLock::new();

fn relay_init() {
    RELAY.get_or_init(|| {
        let mut workers = Vec::new();
        for _ in 0..RELAY_WORKERS {
            let epfd = unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) };
            let evfd = unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) };
            let mut ev = libc::epoll_event { events: libc::EPOLLIN as u32, u64: evfd as u64 };
            unsafe { libc::epoll_ctl(epfd, libc::EPOLL_CTL_ADD, evfd, &mut ev); }
            let w = std::sync::Arc::new(RelayWorker { epfd, evfd, queue: std::sync::Mutex::new(std::collections::VecDeque::new()) });
            let wc = w.clone();
            std::thread::spawn(move || relay_worker_loop(wc));
            workers.push(w);
        }
        Relay { workers, next: std::sync::atomic::AtomicUsize::new(0) }
    });
}

/// Submit a (conduit, target) fd pair to a worker. Falls back to bridge() if the relay isn't
/// initialised yet (shouldn't happen — relay_init runs before the pool dials).
fn relay_submit(conduit: RawFd, container: RawFd) {
    let Some(r) = RELAY.get() else { bridge(conduit, container); return };
    relay_set_nonblocking(conduit); relay_set_nonblocking(container);
    let i = r.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed) % r.workers.len();
    let w = &r.workers[i];
    w.queue.lock().unwrap().push_back((conduit, container));
    let one: u64 = 1;
    unsafe { libc::write(w.evfd, &one as *const u64 as *const _, 8); }
}

fn relay_set_nonblocking(fd: RawFd) {
    unsafe { let fl = libc::fcntl(fd, libc::F_GETFL, 0); libc::fcntl(fd, libc::F_SETFL, fl | libc::O_NONBLOCK); }
}

struct Dir { src: RawFd, dst: RawFd, buf: Vec<u8>, off: usize, len: usize, eof: bool }
impl Dir {
    fn new(src: RawFd, dst: RawFd) -> Self { Dir { src, dst, buf: vec![0u8; 256 * 1024], off: 0, len: 0, eof: false } }
    fn finished(&self) -> bool { self.eof && self.len == 0 }
}
struct Conn { a: RawFd, b: RawFd, ab: Dir, ba: Dir }

fn relay_worker_loop(w: std::sync::Arc<RelayWorker>) {
    use std::collections::HashMap; use std::rc::Rc; use std::cell::RefCell;
    let mut conns: HashMap<RawFd, Rc<RefCell<Conn>>> = HashMap::new();
    let mut events = vec![libc::epoll_event { events: 0, u64: 0 }; 512];
    loop {
        let n = unsafe { libc::epoll_wait(w.epfd, events.as_mut_ptr(), 512, -1) };
        if n < 0 { continue; }
        for i in 0..n as usize {
            let ev = events[i];
            let fd = ev.u64 as RawFd;
            let mask = ev.events;
            if fd == w.evfd {
                let mut b = [0u8; 8];
                while unsafe { libc::read(w.evfd, b.as_mut_ptr() as *mut _, 8) } > 0 {}
                let mut q = w.queue.lock().unwrap();
                while let Some((a, bfd)) = q.pop_front() {
                    let conn = Rc::new(RefCell::new(Conn { a, b: bfd, ab: Dir::new(a, bfd), ba: Dir::new(bfd, a) }));
                    conns.insert(a, conn.clone()); conns.insert(bfd, conn.clone());
                    relay_add(w.epfd, a); relay_add(w.epfd, bfd);
                }
                continue;
            }
            let Some(conn) = conns.get(&fd).cloned() else { continue };
            let finished = {
                let mut c = conn.borrow_mut();
                if mask & (libc::EPOLLIN as u32) != 0 {
                    if fd == c.a { relay_read(&mut c.ab); } else { relay_read(&mut c.ba); }
                }
                if mask & (libc::EPOLLOUT as u32) != 0 {
                    if fd == c.a { relay_flush(&mut c.ba); } else { relay_flush(&mut c.ab); }
                }
                if mask & ((libc::EPOLLHUP | libc::EPOLLERR) as u32) != 0 {
                    if fd == c.a && !c.ab.eof { c.ab.eof = true; unsafe { libc::shutdown(c.ab.dst, libc::SHUT_WR); } }
                    if fd == c.b && !c.ba.eof { c.ba.eof = true; unsafe { libc::shutdown(c.ba.dst, libc::SHUT_WR); } }
                }
                let done = c.ab.finished() && c.ba.finished();
                if !done { relay_update(w.epfd, &*c, c.a); relay_update(w.epfd, &*c, c.b); }
                done
            };
            if finished {
                let c = conn.borrow();
                conns.remove(&c.a); conns.remove(&c.b);
                unsafe { libc::close(c.a); libc::close(c.b); }
            }
        }
    }
}

fn relay_read(d: &mut Dir) {
    if d.len > 0 { return; } // currently flushing
    loop {
        let n = unsafe { libc::read(d.src, d.buf.as_mut_ptr() as *mut _, d.buf.len()) };
        if n > 0 {
            let n = n as usize;
            let w = unsafe { libc::write(d.dst, d.buf.as_ptr() as *const _, n) };
            if w == n as isize { continue; } // fully written — keep draining the source (bulk)
            d.off = if w > 0 { w as usize } else { 0 };
            d.len = n;
            return; // backpressure: wait for EPOLLOUT on dst
        } else if n == 0 {
            d.eof = true; unsafe { libc::shutdown(d.dst, libc::SHUT_WR); }
            return;
        } else {
            let e = std::io::Error::last_os_error();
            if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted) { return; }
            d.eof = true; unsafe { libc::shutdown(d.dst, libc::SHUT_WR); }
            return;
        }
    }
}

fn relay_flush(d: &mut Dir) {
    while d.off < d.len {
        let w = unsafe { libc::write(d.dst, d.buf[d.off..].as_ptr() as *const _, d.len - d.off) };
        if w > 0 { d.off += w as usize; }
        else {
            let e = std::io::Error::last_os_error();
            if w < 0 && matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted) { return; }
            d.eof = true; d.off = 0; d.len = 0; return; // write error → finish this direction
        }
    }
    d.off = 0; d.len = 0;
}

fn relay_add(epfd: RawFd, fd: RawFd) {
    let mut ev = libc::epoll_event { events: libc::EPOLLIN as u32, u64: fd as u64 };
    unsafe { libc::epoll_ctl(epfd, libc::EPOLL_CTL_ADD, fd, &mut ev); }
}

fn relay_update(epfd: RawFd, c: &Conn, fd: RawFd) {
    let mut m: u32 = 0;
    if fd == c.a {
        if c.ab.len == 0 && !c.ab.eof { m |= libc::EPOLLIN as u32; }
        if c.ba.len > 0 { m |= libc::EPOLLOUT as u32; }
    } else {
        if c.ba.len == 0 && !c.ba.eof { m |= libc::EPOLLIN as u32; }
        if c.ab.len > 0 { m |= libc::EPOLLOUT as u32; }
    }
    let mut ev = libc::epoll_event { events: m, u64: fd as u64 };
    unsafe { libc::epoll_ctl(epfd, libc::EPOLL_CTL_MOD, fd, &mut ev); }
}

fn handle_reverse(fd: RawFd) {
    // read "<port>\n" or "host:port\n"
    let mut line = Vec::new();
    let mut b = [0u8; 1];
    loop {
        let n = unsafe { libc::read(fd, b.as_mut_ptr() as *mut _, 1) };
        if n <= 0 { unsafe { libc::close(fd); } return; }
        if b[0] == b'\n' { break; }
        line.push(b[0]);
        if line.len() > 64 { break; }
    }
    let header = String::from_utf8_lossy(&line).trim().to_string();
    if header.is_empty() { unsafe { libc::close(fd); } return; }
    // "udp <port>" → datagram relay; otherwise the original TCP stream relay.
    if let Some(port) = header.strip_prefix("udp ") {
        return handle_reverse_udp(fd, port.trim());
    }
    let mut target = header;
    if !target.contains(':') { target = format!("127.0.0.1:{target}"); }
    match std::net::TcpStream::connect(&target) {
        Ok(up) => bridge(fd, up.into_raw_fd()),
        Err(e) => { log!("reverse dial {target}: {e}"); unsafe { libc::close(fd); } }
    }
}

/// UDP reverse relay. The host tunnels each datagram length-prefixed
/// (`[u16 BE len][payload]`) over the vsock stream; we dial the published UDP
/// port inside the guest (docker-proxy on 127.0.0.1:port, same as the TCP path)
/// and shuttle datagrams both ways until the host closes the flow (idle) or errors.
fn handle_reverse_udp(vsock: RawFd, port: &str) {
    use std::os::unix::io::AsRawFd;
    let target = format!("127.0.0.1:{port}");
    let sock = match std::net::UdpSocket::bind("127.0.0.1:0") {
        Ok(s) => s, Err(e) => { log!("udp reverse bind: {e}"); unsafe { libc::close(vsock); } return; }
    };
    if let Err(e) = sock.connect(&target) {
        log!("udp reverse connect {target}: {e}"); unsafe { libc::close(vsock); } return;
    }
    let udp = sock.as_raw_fd();
    // vsock(framed) → udp(datagrams), and udp → vsock, until one side ends.
    let t = std::thread::spawn(move || udp_frames_to_dgrams(vsock, udp));
    udp_dgrams_to_frames(udp, vsock);
    // unblock the peer thread, then tear down (sock drop closes `udp`).
    unsafe { libc::shutdown(vsock, libc::SHUT_RDWR); libc::shutdown(udp, libc::SHUT_RDWR); }
    let _ = t.join();
    unsafe { libc::close(vsock); }
    drop(sock);
}

/// Read `[u16 len][payload]` frames off the vsock stream, send each as one datagram.
fn udp_frames_to_dgrams(vsock: RawFd, udp: RawFd) {
    let mut hdr = [0u8; 2];
    let mut buf = vec![0u8; 65535];
    loop {
        if !read_exact_fd(vsock, &mut hdr) { break; }
        let len = u16::from_be_bytes(hdr) as usize;
        if len == 0 { continue; }
        if !read_exact_fd(vsock, &mut buf[..len]) { break; }
        let _ = unsafe { libc::send(udp, buf.as_ptr() as *const _, len, 0) };
    }
}

/// Receive datagrams, frame each as `[u16 len][payload]` onto the vsock stream.
fn udp_dgrams_to_frames(udp: RawFd, vsock: RawFd) {
    let mut buf = vec![0u8; 65535];
    loop {
        let n = unsafe { libc::recv(udp, buf.as_mut_ptr() as *mut _, buf.len(), 0) };
        if n <= 0 { break; }
        let len = n as usize;
        if !write_all_fd(vsock, &(len as u16).to_be_bytes()) { break; }
        if !write_all_fd(vsock, &buf[..len]) { break; }
    }
}

/// Read exactly `buf.len()` bytes (retrying EINTR/partial); false on EOF/error.
fn read_exact_fd(fd: RawFd, buf: &mut [u8]) -> bool {
    let mut off = 0;
    while off < buf.len() {
        let n = unsafe { libc::read(fd, buf[off..].as_mut_ptr() as *mut _, buf.len() - off) };
        if n == 0 { return false; }
        if n < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted { continue; }
            return false;
        }
        off += n as usize;
    }
    true
}

/// Write all of `buf` (retrying EINTR/partial); false on error.
fn write_all_fd(fd: RawFd, buf: &[u8]) -> bool {
    let mut off = 0;
    while off < buf.len() {
        let n = unsafe { libc::write(fd, buf[off..].as_ptr() as *const _, buf.len() - off) };
        if n <= 0 {
            if n < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted { continue; }
            return false;
        }
        off += n as usize;
    }
    true
}

/// Bidirectional copy with independent half-close (so Docker's hijacked
/// attach/exec/logs streams aren't truncated). Closes both fds when done.
fn bridge(a: RawFd, b: RawFd) {
    let t1 = std::thread::spawn(move || pump(a, b));
    let t2 = std::thread::spawn(move || pump(b, a));
    let _ = t1.join();
    let _ = t2.join();
    unsafe { libc::close(a); libc::close(b); }
}

fn pump(from: RawFd, to: RawFd) {
    // Heap (not stack) so the larger size doesn't bloat each pump thread's stack.
    // 128 KiB cuts read/write syscalls on bulk transfers vs 32 KiB. This pump carries
    // the docker.sock API proxy (port 2375) and the reverse port-forward TCP datapath
    // (port 2376) — i.e. Docker-API traffic (image push/pull, build context, logs) and
    // published-port localhost throughput. NOT container↔internet, which is direct VZNAT.
    let mut buf = vec![0u8; 128 * 1024];
    loop {
        let n = unsafe { libc::read(from, buf.as_mut_ptr() as *mut _, buf.len()) };
        if n <= 0 { break; }
        let mut off = 0isize;
        while off < n {
            let w = unsafe { libc::write(to, buf.as_ptr().offset(off) as *const _, (n - off) as usize) };
            if w <= 0 { unsafe { libc::shutdown(to, libc::SHUT_WR); } return; }
            off += w;
        }
    }
    unsafe { libc::shutdown(to, libc::SHUT_WR); }
}

fn nix_write(fd: RawFd, data: &[u8]) -> std::io::Result<()> {
    let n = unsafe { libc::write(fd, data.as_ptr() as *const _, data.len()) };
    if n < 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
}

// =================== PID1 reaper ===================

/// Respawn dockerd whenever the reaper signals it died. Runs on its own thread so the
/// reaper itself stays a tight `waitpid` loop. Backs off before each (re)spawn so a
/// daemon that crashes on startup doesn't spin the CPU.
fn dockerd_supervisor(deaths: std::sync::mpsc::Receiver<()>) {
    while deaths.recv().is_ok() {
        log!("dockerd exited — restarting");
        std::thread::sleep(std::time::Duration::from_secs(1));
        loop {
            let pid = spawn_dockerd();
            if pid >= 0 {
                DOCKERD_PID.store(pid, std::sync::atomic::Ordering::SeqCst);
                break;
            }
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
    }
}

/// PID-1 reaper: a tight blocking `waitpid` loop that reaps every child immediately and
/// never sleeps on the dockerd-restart path (that's the supervisor thread's job) — so a
/// crash-looping dockerd can't leave orphaned shims/containers piling up as zombies.
fn reap_forever(deaths: std::sync::mpsc::Sender<()>) -> ! {
    loop {
        let mut status = 0;
        let pid = unsafe { libc::waitpid(-1, &mut status, 0) };
        if pid < 0 {
            // ECHILD (no children yet) or EINTR — nothing to reap; brief sleep.
            std::thread::sleep(std::time::Duration::from_millis(200));
            continue;
        }
        if pid == DOCKERD_PID.load(std::sync::atomic::Ordering::SeqCst) {
            // dockerd died — hand the restart to the supervisor and keep reaping now.
            log!("dockerd exited (status {status:#x}) — signalling restart");
            let _ = deaths.send(());
        }
        // Any other pid is an orphaned grandchild (container proc, shim) — already reaped.
    }
}
