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

/// Spawn a detached worker, dropping the work if the thread can't be created.
///
/// `std::thread::spawn` is `Builder::spawn(..).expect(..)`, so it PANICS when `clone(2)`
/// returns EAGAIN/ENOMEM — and with `panic = "abort"` a panic in PID 1 is
/// `Kernel panic - not syncing: Attempted to kill init!`, i.e. the whole VM dies.
/// That is reachable from an unprivileged container: dockerd sets no default pids limit,
/// so a fork bomb can exhaust the guest's global `pid_max`, and the very next DNS query or
/// vsock connect (one thread each) takes PID 1 down with it. Dropping one query or one
/// connection is always better than killing the machine.
fn spawn_worker<F: FnOnce() + Send + 'static>(what: &str, f: F) -> bool {
    match std::thread::Builder::new().spawn(f) {
        Ok(_) => true,
        Err(e) => {
            log!("vinit: cannot spawn {what} thread ({e}) — dropping this work");
            false
        }
    }
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
    let net_setup = || {
        if let Err(e) = setup_network() {
            log!("network setup failed (continuing, no outbound until fixed): {e}");
        }
    };
    // Overlapped with the data-disk work below when we can; run inline if the thread can't
    // be created, because panicking here would take PID 1 (and the VM) down at boot.
    let net_handle = match std::thread::Builder::new().spawn(net_setup) {
        Ok(h) => Some(h),
        Err(e) => { log!("vinit: network thread spawn failed ({e}) — running it inline"); net_setup(); None }
    };
    let data_ok = setup_data_disk();
    // Swap is a memory-pressure safety valve, not a startup dependency, and on first
    // boot make_swapfile() fallocate()s a multi-GiB file — pure stall before dockerd.
    // Build it off the critical path. Spawned only when data_ok, so the swapfile's
    // parent (/var/lib/docker) is already mounted.
    if data_ok { spawn_worker("swap-setup", setup_swap); }
    let rosetta_ok = setup_virtiofs();
    // Emulators before dockerd: BuildKit enumerates supported platforms at daemon start.
    setup_binfmt(rosetta_ok);
    // Diagnosability: one line when the host granted nested virtualization (shows
    // in Engine Logs / Copy Diagnostics). KVM self-disables without EL2 — silent.
    if std::path::Path::new("/dev/kvm").exists() {
        log!("KVM available — nested virtualization enabled");
    }
    // dockerd reads GATEWAY_IP (for host.docker.internal) and expects resolv.conf in
    // place, so the network must be fully applied before it starts.
    if let Some(h) = net_handle { let _ = h.join(); }
    enable_ip_forwarding();
    tune_network_sysctls(); // survive published-port connection churn (TIME_WAIT/port exhaustion)
    // dockerd lifecycle is supervised on a *separate* thread so the PID-1 reaper never
    // sleeps — a crash-looping dockerd must not stop us reaping orphaned shims/zombies.
    let (deaths_tx, deaths_rx) = std::sync::mpsc::channel::<()>();
    // Direct-access (named containers) re-asserts its nft rules on every dockerd
    // (re)spawn and on every docker network event — both signal this channel; nothing polls.
    let (nft_tx, nft_rx) = std::sync::mpsc::channel::<()>();
    if data_ok {
        let pid = spawn_dockerd();
        DOCKERD_PID.store(pid, std::sync::atomic::Ordering::SeqCst);
        start_docker_events_informer(nft_tx.clone());
        spawn_worker("dockerd-supervisor", move || dockerd_supervisor(deaths_rx, nft_tx));
    } else {
        // Persistence was expected (/dev/vdb present) but the data fs didn't mount.
        // Running dockerd now would silently use the tmpfs /var and lose every image
        // and volume on the next boot — refuse, and let the host surface this log.
        log!("FATAL: data disk mount failed — refusing to start dockerd (it would run on \
              non-persistent tmpfs and lose all images/volumes). Fix /dev/vdb and restart.");
    }
    start_vsock_agent();
    start_conduit_pool();
    start_direct_access(nft_rx);
    log!("init complete — supervising");
    reap_forever(deaths_tx);
}

// =================== filesystems ===================

/// CString from a KNOWN-CONSTANT (or fully vinit-computed) path — never call this on
/// host-supplied input. With `panic = "abort"` a panic in PID 1 is a kernel panic, so
/// anything that can carry outside bytes must handle the NUL error instead (do_mount).
fn cstr(s: &str) -> CString {
    CString::new(s).expect("BUG: NUL in constant path")
}

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
    // (containerd state, the /run symlink) stays ephemeral — by design (no stale records).
    do_mount("tmpfs", "/var", "tmpfs", 0, Some("mode=0755"));
    let _ = std::fs::create_dir_all("/var/lib/docker");
    let _ = std::fs::create_dir_all("/var/lib/containerd");
    // /var/run is a SYMLINK to /run, as on every mainstream distro — NOT a real dir.
    // dockerd listens on /run/docker.sock, but the near-universal socket-mount idiom is
    // `-v /var/run/docker.sock:/var/run/docker.sock`. With a real (empty) /var/run that bind
    // SOURCE doesn't exist, and Docker's rule for a missing source is to CREATE it — so the
    // container silently gets an empty directory instead of the API socket (measured).
    // Side effect (intended): dockerd's default exec-root /var/run/docker resolves to
    // /run/docker — same ephemeral tmpfs, same flags/propagation, so nothing else changes.
    if let Err(e) = std::os::unix::fs::symlink("/run", "/var/run") {
        log!("symlink /var/run -> /run failed: {e}");
    }
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
    // Not libc::time_t: that alias is deprecated pending musl's 64-bit switch; on
    // aarch64-musl the field already IS 64-bit, so name the concrete width.
    let tv = libc::timeval { tv_sec: epoch, tv_usec: 0 };
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

    // Close before propagating: `get_mac(s)?` used to early-return leaving `s` open.
    let mac = match get_mac(s) {
        Ok(m) => m,
        Err(e) => { unsafe { libc::close(s); } return Err(e); }
    };
    unsafe { libc::close(s); } // apply_lease opens its own socket for addressing
    let lease = dhcp::acquire(IFNAME, mac)?;
    log!("DHCP lease: ip={} mask={} gw={} dns={:?} lease={}s",
        ipstr(lease.ip), ipstr(lease.mask), ipstr(lease.router),
        lease.dns.iter().map(|d| ipstr(*d)).collect::<Vec<_>>(), lease.lease_secs);
    apply_lease(&lease);

    // Keep the lease alive. Apple's NAT hands out finite leases; without renewal
    // a long-running VM would eventually lose its address. Renew in the
    // background at ~half the lease interval (best-effort). `velox.dhcprenew=<secs>`
    // on the cmdline (via VELOX_KCMDLINE_EXTRA) forces the interval — a test/ops
    // knob to exercise renewal without waiting out a long vmnet lease.
    let (ip, server, lease_secs) = (lease.ip, lease.server, lease.lease_secs);
    let force = cmdline_value("velox.dhcprenew").and_then(|v| v.parse::<u64>().ok());
    spawn_worker("dhcp-renew", move || dhcp::renew_loop(IFNAME, mac, ip, server, lease_secs, force));
    Ok(())
}

/// Apply a DHCP lease to eth0: address, netmask, default route, the atomics the rest of
/// the guest reads (gateway / our IP+mask), a `:53` DNS responder, and resolv.conf. Used
/// for the initial lease AND to adopt a *changed* IP on re-acquire (a vmnet lease-table
/// reset), so the guest recovers its network instead of staying dark until a VM restart.
fn apply_lease(lease: &dhcp::Lease) {
    use std::sync::atomic::Ordering::Relaxed;
    let s = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0) };
    if s < 0 { log!("apply_lease: socket failed: {}", std::io::Error::last_os_error()); return; }
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
    GATEWAY_IP.store(lease.router, Relaxed);
    GUEST_IP.store(lease.ip, Relaxed);
    GUEST_MASK.store(lease.mask, Relaxed);
    unsafe { libc::close(s); }

    // DNS: run an in-guest responder so every container gets `host.docker.internal`
    // (Docker-Desktop parity — vanilla dockerd never injects it, on any network).
    // Bind :53 first, then point resolv.conf at our own eth0 IP: the responder
    // becomes the primary nameserver for the guest and — because dockerd copies this
    // file to default-bridge containers and uses it as the embedded resolver's
    // ExtServer on user-defined nets — for every container too. The real upstream(s)
    // follow as a fallback. dockerd strips loopback from the copied file, so we must
    // advertise eth0's address here, never 127.0.0.1. (On a changed-IP re-adopt this
    // starts a fresh responder on the new address; the old one idles on the vanished IP.)
    let upstream = lease.dns.first().copied().unwrap_or(lease.router);
    start_dns_proxy(lease.ip, lease.router, upstream);
    let mut nameservers = vec![lease.ip];
    nameservers.extend_from_slice(&lease.dns);
    write_resolv_conf(&nameservers);
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
    // c_char IS u8 on aarch64 (the only target vinit builds for), so no cast.
    for (m, b) in mac.iter_mut().zip(rh.hw.sa_data.iter()) { *m = *b; }
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
    let src = cstr("/run/resolv.conf");
    let tgt = cstr("/etc/resolv.conf");
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
static DNS_DROPPED: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
const DNS_MAX_INFLIGHT: usize = 64;
/// Per-source share of the in-flight budget. The global cap alone has no fairness: one
/// container issuing ~64 concurrent queries against a slow upstream pinned every slot for up
/// to the 2 s forward timeout, capping DNS for the WHOLE VM — dockerd and every other
/// container included — with the rest silently dropped.
///
/// It is a share under CONTENTION, not a reservation. Enforced unconditionally it was a
/// regression in its own right: a single container — the common case, and the only case for
/// most users — went from 64 concurrent queries to 16, so an `npm install` or a multi-registry
/// build took ~84 silent drops where it used to take ~36, each costing the stub resolver a
/// retry timeout. libnetwork's own resolver allows up to 100 concurrent forwards per sandbox.
/// Below the watermark a source may use the whole budget; at or above it, the share applies,
/// so a hog cannot claim MORE while someone else needs a slot and the split converges as its
/// queries drain.
const DNS_MAX_INFLIGHT_PER_SOURCE: usize = 16;
/// Global in-flight level at which the per-source share starts being enforced.
const DNS_CONTENDED: usize = DNS_MAX_INFLIGHT / 2;

/// In-flight queries per source IP. Small map (one entry per active resolver), only touched
/// on the DNS path.
static DNS_PER_SOURCE: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<std::net::IpAddr, usize>>> =
    std::sync::OnceLock::new();

/// Claim a per-source slot, or false if that source is over its share while the global budget
/// is contended. `inflight` is the global count this claim was already counted into.
fn dns_claim_source(src: std::net::IpAddr, inflight: usize) -> bool {
    let m = DNS_PER_SOURCE.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()));
    let Ok(mut map) = m.lock() else { return true }; // never fail closed on DNS
    let e = map.entry(src).or_insert(0);
    // (A rejection implies *e >= 16, so `or_insert` never leaves a stray zero entry behind.)
    if inflight >= DNS_CONTENDED && *e >= DNS_MAX_INFLIGHT_PER_SOURCE { return false }
    *e += 1;
    true
}

fn dns_release_source(src: std::net::IpAddr) {
    let m = DNS_PER_SOURCE.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()));
    let Ok(mut map) = m.lock() else { return };
    if let Some(e) = map.get_mut(&src) {
        *e = e.saturating_sub(1);
        if *e == 0 { map.remove(&src); }
    }
}

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
    spawn_worker("dns-udp-listener", move || {
        let sock = std::sync::Arc::new(sock);
        let mut buf = [0u8; 1500];
        loop {
            let (n, src) = match sock.recv_from(&mut buf) {
                Ok(v) => v,
                Err(e) => {
                    if e.kind() != std::io::ErrorKind::Interrupted {
                        std::thread::sleep(std::time::Duration::from_millis(50)); // don't spin
                    }
                    continue;
                }
            };
            // Bound concurrent handlers so a query flood (or a dead upstream parking
            // threads on the forward recv) can't exhaust PID 1's threads/fds.
            let level = DNS_INFLIGHT.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
            if level > DNS_MAX_INFLIGHT {
                DNS_INFLIGHT.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                // Rate-limited visibility (1st, 101st, …): silent drops read as a
                // network partition from inside a container — leave a trace instead.
                let dropped = DNS_DROPPED.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
                if dropped % 100 == 1 {
                    log!("dns: dropped {dropped} queries so far (inflight cap {DNS_MAX_INFLIGHT})");
                }
                continue; // drop; the stub resolver retries
            }
            if !dns_claim_source(src.ip(), level) {
                DNS_INFLIGHT.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                continue; // this source is at its share; others keep resolving
            }
            let query = buf[..n].to_vec();
            let s = sock.clone();
            let srcip = src.ip();
            if !spawn_worker("dns-udp", move || {
                answer_dns(&s, &query, src, gateway, upstream);
                dns_release_source(srcip);
                DNS_INFLIGHT.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
            }) {
                dns_release_source(srcip);
                DNS_INFLIGHT.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
            }
        }
    });
    // TCP :53 fallback — a stub resolver that got a truncated (TC) UDP reply retries
    // over TCP, and without this listener large records simply fail. Same answers,
    // `[u16 BE len]` framing; shares the UDP inflight budget so a flood on either
    // transport hits the one cap.
    match std::net::TcpListener::bind(listen) {
        Ok(l) => {
            spawn_worker("dns-tcp-listener", move || {
                for conn in l.incoming() {
                    let conn = match conn {
                        Ok(c) => c,
                        Err(e) => {
                            // A sticky EMFILE/ENFILE would otherwise spin this PID-1 thread
                            // at 100% CPU; back off so the guest can recover.
                            if e.kind() != std::io::ErrorKind::Interrupted {
                                std::thread::sleep(std::time::Duration::from_millis(50));
                            }
                            continue;
                        }
                    };
                    let level = DNS_INFLIGHT.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
                    if level > DNS_MAX_INFLIGHT {
                        DNS_INFLIGHT.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                        continue; // drop (conn closes on drop); the resolver retries
                    }
                    let srcip = conn.peer_addr().map(|a| a.ip())
                        .unwrap_or(std::net::IpAddr::V4(std::net::Ipv4Addr::UNSPECIFIED));
                    if !dns_claim_source(srcip, level) {
                        DNS_INFLIGHT.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                        continue; // conn closes on drop; the resolver retries
                    }
                    if !spawn_worker("dns-tcp", move || {
                        handle_dns_tcp(conn, gateway, upstream);
                        dns_release_source(srcip);
                        DNS_INFLIGHT.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                    }) {
                        dns_release_source(srcip);
                        DNS_INFLIGHT.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                    }
                }
            });
        }
        Err(e) => log!("dns: tcp bind {listen} failed ({e}); UDP only"),
    }
}

fn answer_dns(sock: &std::net::UdpSocket, query: &[u8], src: std::net::SocketAddr, gateway: u32, upstream: u32) {
    if let Some(reply) = dns_reply_for(query, gateway, upstream, false) {
        let _ = sock.send_to(&reply, src);
    }
}

/// Reply bytes for one DNS query: `*.docker.internal` answered locally (A → gateway;
/// anything else, e.g. AAAA → empty NOERROR so the client falls back to the A record
/// instead of chasing a bogus NXDOMAIN), everything else forwarded upstream. `via_tcp`
/// picks the upstream transport: TCP clients are here because UDP truncated, so try TCP
/// first, falling back to UDP if the upstream has no TCP :53.
fn dns_reply_for(query: &[u8], gateway: u32, upstream: u32, via_tcp: bool) -> Option<Vec<u8>> {
    if let Some((name, qtype, qend)) = parse_qname(query) {
        if DOCKER_INTERNAL_NAMES.contains(&name.as_str()) {
            return Some(if qtype == 1 { build_a_reply(query, qend, gateway) }
                        else { build_empty_reply(query, qend) });
        }
    }
    if via_tcp { forward_dns_tcp(query, upstream).or_else(|| forward_dns(query, upstream)) }
    else { forward_dns(query, upstream) }
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
    let qend = pos + 4; // 2 qtype + 2 qclass bytes
    // Reject a question truncated before its qclass: build_a_reply/build_empty_reply
    // slice query[..qend], and the crate is `panic = "abort"`, so an out-of-bounds
    // slice here would abort PID 1 and take down the whole VM. A malformed query
    // simply returns None and is forwarded upstream instead of answered locally.
    if qend > q.len() { return None; }
    Some((name, qtype, qend))
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

/// Forward one query to the upstream over TCP :53 (`[u16 BE len]` framing, RFC 1035 §4.2.2).
fn forward_dns_tcp(query: &[u8], upstream: u32) -> Option<Vec<u8>> {
    use std::io::{Read, Write};
    let t = std::time::Duration::from_secs(2);
    let dst = std::net::SocketAddr::from((std::net::Ipv4Addr::from(upstream), 53));
    let mut s = std::net::TcpStream::connect_timeout(&dst, t).ok()?;
    s.set_read_timeout(Some(t)).ok()?;
    s.set_write_timeout(Some(t)).ok()?;
    let mut msg = Vec::with_capacity(2 + query.len());
    msg.extend_from_slice(&u16::try_from(query.len()).ok()?.to_be_bytes());
    msg.extend_from_slice(query);
    s.write_all(&msg).ok()?;
    let mut lenb = [0u8; 2];
    s.read_exact(&mut lenb).ok()?;
    let len = u16::from_be_bytes(lenb) as usize;
    if len < 12 { return None; }
    let mut reply = vec![0u8; len];
    s.read_exact(&mut reply).ok()?;
    Some(reply)
}

/// Serve one TCP DNS client — stub resolvers retry here after a truncated (TC) UDP
/// reply. Same answers as UDP, `[u16 BE len]` framing; a handful of queries per
/// connection with bounded timeouts so a chatty client can't pin an inflight slot.
fn handle_dns_tcp(mut conn: std::net::TcpStream, gateway: u32, upstream: u32) {
    use std::io::{Read, Write};
    let t = std::time::Duration::from_secs(2);
    let _ = conn.set_read_timeout(Some(t));
    let _ = conn.set_write_timeout(Some(t));
    for _ in 0..8 {
        let mut lenb = [0u8; 2];
        if conn.read_exact(&mut lenb).is_err() { return; }
        let len = u16::from_be_bytes(lenb) as usize;
        if !(12..=4096).contains(&len) { return; }
        let mut q = vec![0u8; len];
        if conn.read_exact(&mut q).is_err() { return; }
        let Some(reply) = dns_reply_for(&q, gateway, upstream, true) else { return };
        let Ok(rlen) = u16::try_from(reply.len()) else { return };
        let mut out = Vec::with_capacity(2 + reply.len());
        out.extend_from_slice(&rlen.to_be_bytes());
        out.extend_from_slice(&reply);
        if conn.write_all(&out).is_err() { return; }
    }
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
            // `as_chunks` over `chunks_exact`: a newer clippy flags a constant chunk size,
            // and this one gives the compiler the `[u8; 4]` directly instead of indexing a
            // slice it can't prove the length of.
            self.option(code)
                .map(|v| v.as_chunks::<4>().0.iter().map(|c| u32::from_be_bytes(*c)).collect())
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
        // `?` here used to early-return WITHOUT closing `sock` — one fd leaked per failed
        // send (ENETDOWN/ENETUNREACH while the link flaps), forever. `try_acquire` documents
        // avoiding exactly this.
        if let Err(e) = send(sock, &request) {
            unsafe { libc::close(sock); }
            return Err(e);
        }
        let res = recv(sock, xid, ACK).map(|_| ())
            .ok_or_else(|| Error::new(ErrorKind::TimedOut, "no DHCP ack on renew"));
        unsafe { libc::close(sock); }
        res
    }

    /// Consecutive failed renewals before falling back to a full re-acquire.
    const REACQUIRE_AFTER: u32 = 5;

    /// Background renewal loop: re-request the lease at ~half its lifetime (or
    /// every 30 min if the server gave no lease time). Runs for the life of the VM.
    /// `force_interval` (from `velox.dhcprenew`) overrides the cadence for testing.
    pub fn renew_loop(ifname: &'static str, mac: [u8; 6], mut ip: u32, mut server: u32,
                      lease_secs: u32, force_interval: Option<u64>) {
        let interval = force_interval
            .unwrap_or(if lease_secs >= 120 { (lease_secs / 2) as u64 } else { 1800 });
        let mut failures = 0u32;
        loop {
            std::thread::sleep(std::time::Duration::from_secs(interval));
            match renew(ifname, mac, ip, server) {
                Ok(()) => { failures = 0; log!("DHCP lease renewed ({})", super::ipstr(ip)) }
                Err(e) => {
                    failures += 1;
                    log!("DHCP renew failed: {e} ({failures}/{REACQUIRE_AFTER} before re-acquire)");
                    if failures >= REACQUIRE_AFTER {
                        failures = 0;
                        // A server that lost its lease table (e.g. a vmnet restart)
                        // ignores renewing REQUESTs for an IP it no longer knows —
                        // forever. A fresh DISCOVER re-registers us; vmnet re-offers
                        // the same IP per MAC, so addressing normally needs no change.
                        match acquire(ifname, mac) {
                            Ok(l) if l.ip == ip =>
                                log!("DHCP lease re-acquired after failed renewals ({})",
                                     super::ipstr(ip)),
                            Ok(l) => {
                                // vmnet handed us a DIFFERENT address (its lease table reset).
                                // Adopt it — re-address eth0, re-point routing/DNS, and renew
                                // the NEW ip henceforth — instead of leaving the guest dark on
                                // the stale address until a VM restart.
                                log!("DHCP re-acquire returned a different lease (ip {} -> {}) — adopting it",
                                     super::ipstr(ip), super::ipstr(l.ip));
                                super::apply_lease(&l);
                                ip = l.ip;
                                if l.server != 0 { server = l.server; }
                            }
                            Err(e) => log!("DHCP re-acquire failed: {e} (retrying next cycle)"),
                        }
                    }
                }
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

/// The filesystem's estimated minimum size in blocks (`resize2fs -P`) — the floor a
/// shrink can reach given the used data. `None` if resize2fs isn't runnable or its output
/// can't be parsed, in which case the caller just attempts the shrink as before.
fn ext4_min_blocks(dev: &str) -> Option<u64> {
    let out = Command::new("/usr/sbin/resize2fs").args(["-P", dev]).output().ok()?;
    if !out.status.success() { return None; }
    // "Estimated minimum size of the filesystem: <blocks>"
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .find_map(|l| l.rsplit(':').next().and_then(|v| v.trim().parse::<u64>().ok()))
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
    // `velox.disk` is host cmdline input; a wrapped product would select the Shrink branch
    // with a tiny target. Bail rather than compute a nonsense resize.
    let target = target_gib.checked_mul(1024 * 1024 * 1024)?;
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
        // No valid ext4 superblock: either a genuinely blank first-boot disk (format it), or a disk
        // that holds data we don't recognise (NEVER reformat — let the mount below fail so the
        // caller refuses dockerd, leaving the data intact, rather than wiping a disk we don't
        // understand). The raw + `.fsync` data disk commits the superblock durably, so a non-blank
        // disk reaching here is real content, not a torn primary: an unclean stop leaves the
        // superblock valid and only the journal to replay (handled by the preen-fsck below).
        if disk_is_blank(dev) {
            log!("formatting {dev} ext4 (first boot — blank disk)");
            // -m 0: a dedicated data disk needs no 5%-reserved root headroom (dockerd runs as root
            // anyway) — reclaim it for image/container storage. First-boot format only.
            let st = Command::new("/sbin/mkfs.ext4").args(["-F", "-q", "-m", "0", dev]).status();
            if !st.as_ref().map(|s| s.success()).unwrap_or(false) {
                log!("mkfs.ext4 failed: {st:?}");
                return false;
            }
        } else {
            log!("WARNING: {dev} holds data but no valid ext4 superblock — NOT reformatting; attempting mount (dockerd refused if it fails)");
        }
    }
    // Resize the data fs to the configured size (velox.disk on the cmdline). ext4
    // can only SHRINK while unmounted (and needs a prior e2fsck), so do a shrink
    // here, before the mount; a GROW is done online right after it. One-shot —
    // planned_resize returns None once the fs already matches the target, so a
    // normal boot pays nothing. resize2fs ships in e2fsprogs-extra; e2fsck is base.
    let resize = planned_resize(dev);
    if let Some((ResizeDir::Shrink, blocks)) = resize {
        // A shrink below the filesystem's used space can never succeed, and the geometry
        // then stays large — so planned_resize would return Shrink on EVERY subsequent boot,
        // re-running a full `e2fsck -f` + a doomed resize2fs indefinitely (a multi-second
        // boot penalty on a misconfigured velox.disk). Skip when the target is below the
        // filesystem's own estimated minimum. (`-P` reads the fs without a full check; if it
        // can't tell, we fall through and attempt the shrink as before — no regression.)
        if let Some(min) = ext4_min_blocks(dev).filter(|&min| blocks < min) {
            log!("data disk: velox.disk asks for {blocks} blocks but the fs needs ≥ {min} for its \
                  used data — skipping shrink (raise velox.disk or free space)");
        } else {
            log!("data disk: shrinking ext4 → {blocks} blocks (velox.disk)");
            let _ = Command::new("/sbin/e2fsck").args(["-f", "-y", dev]).status();
            match Command::new("/usr/sbin/resize2fs").args([dev, &blocks.to_string()]).status() {
                Ok(s) if s.success() => {}, other => log!("resize2fs shrink failed: {other:?}"),
            }
        }
    }
    // /var/lib/docker is overlay-snapshot churn central — every `docker run`
    // mounts/unmounts a snapshot. noatime drops read-driven atime writes; lazytime
    // keeps inode mtime/ctime in memory and flushes them lazily (on fsync / sync /
    // 24h) instead of journalling every metadata touch — less write amplification on
    // the container hot path, and nothing under here needs atime/precise timestamps.
    //
    // Barriers stay ON (no barrier=0). The data disk is a raw image attached
    // `synchronizationMode: .fsync` (VMConfiguration), so each ext4 journal-commit FLUSH
    // becomes a durable host fsync — that's what keeps the filesystem consistent across a
    // crash. Drop the FLUSH (barrier=0) and the host never durably commits, so an unclean
    // stop can leave a torn journal. The FLUSH round-trip per fsync is the price of
    // persistence — and cheap on a raw image (an fdatasync of the dirty page, ~0.3 ms).
    // After an unclean stop the journal may need replay, so preen-fsck first; a clean boot
    // reads a clean superblock and pays nothing.
    if !data_disk_clean(dev) {
        log!("data disk: not cleanly unmounted — running e2fsck -p before mount");
        let _ = Command::new("/sbin/e2fsck").args(["-p", dev]).status();
    }
    if !do_mount(dev, "/var/lib/docker", "ext4",
                 libc::MS_NOATIME | libc::MS_LAZYTIME, None) {
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
/// containers are released back to the host. VZ honours the discard by hole-punching
/// the raw backing file (verified: a deleted 4 GiB file reclaims after a trim pass) —
/// so the disk shrinks instead of growing forever like Docker Desktop's `Docker.raw`.
/// Periodic (not `-o discard`) to keep delete latency off the hot path, like OrbStack/DD.
fn start_fstrim_timer() {
    // FITRIM: _IOWR('X', 121, struct fstrim_range) — trims the whole filesystem.
    const FITRIM: libc::c_ulong = 0xC018_5879;
    #[repr(C)]
    struct FstrimRange { start: u64, len: u64, minlen: u64 }
    spawn_worker("fstrim", || {
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

/// Direct (named) container access: once dockerd has built its nftables ruleset, allow the Mac
/// (the vmnet gateway) to reach containers directly past dockerd 29's TWO host→container drops —
/// the per-bridge "UNPUBLISHED PORT DROP" in `filter-FORWARD` (forward hook) and the per-container
/// "DROP DIRECT ACCESS" in `raw-PREROUTING` (a separate prerouting hook, so the forward allow alone
/// doesn't cover it). One `ip saddr <gateway> accept` at the TOP of each chain. The allow can be
/// flushed out from under us — a dockerd *restart* rebuilds the whole table, and dockerd rewrites
/// `raw-PREROUTING`'s per-container drops on every network endpoint change (measured: the first
/// `docker run` after boot wipes the allow from that chain). Both have events (CLAUDE.md §8): the
/// supervisor signals `triggers` on every respawn, and the `/events` informer signals it on every
/// network event; the idempotent assert below is the reconcile. Inert until the host adds a route
/// to the container subnets, so it exposes nothing on its own — and a container cannot spoof the
/// gateway IP (it lives on eth0, not docker0). Verified by spike + e2e (curl → 200 by name).
fn start_direct_access(triggers: std::sync::mpsc::Receiver<()>) {
    spawn_worker("direct-access", move || loop {
        assert_direct_access_rules();
        // Block until a respawn/network event — pure event wait, no timer. Senders live
        // in main (never returns), the supervisor, and the events informer, so Err is
        // unreachable; treat it as terminal anyway rather than spinning.
        if triggers.recv().is_err() { return }
        while triggers.try_recv().is_ok() {} // coalesce a burst into one assert
    });
}

/// Docker `/events` informer for direct access. dockerd rewrites its per-container drop
/// rules (flushing our gateway allow from `raw-PREROUTING`) whenever a container joins or
/// leaves a bridge — which surfaces as a `network` event on the local docker socket. Each
/// burst of stream bytes just pings `trigger` (the event is only the trigger; the assert
/// re-checks both chains — the informer rule). Reconnects with a short backoff: the socket
/// vanishes across a dockerd restart, and the supervisor's respawn signal covers that gap.
fn start_docker_events_informer(trigger: std::sync::mpsc::Sender<()>) {
    use std::io::{Read, Write};
    spawn_worker("events-informer", move || loop {
        if let Ok(mut s) = std::os::unix::net::UnixStream::connect(DOCKER_SOCK) {
            // filters={"type":["network"]} (URL-encoded) — connect/disconnect fire exactly
            // when dockerd rebuilds the drop chains. Headers/chunk framing aren't parsed:
            // any traffic (including the response head) is a harmless idempotent re-assert.
            let req = "GET /events?filters=%7B%22type%22%3A%5B%22network%22%5D%7D HTTP/1.1\r\nHost: docker\r\n\r\n";
            if s.write_all(req.as_bytes()).is_ok() {
                log!("direct-access: events informer connected");
                // Informer rule: reconcile unconditionally on (re)connect — an event
                // emitted before this subscription existed is lost forever (no replay),
                // and dockerd may not flush response bytes until the next event.
                let _ = trigger.send(());
                let mut buf = [0u8; 4096];
                while let Ok(n) = s.read(&mut buf) {
                    if n == 0 { break }
                    let _ = trigger.send(());
                }
            }
        }
        // Quick retry: the subscription must be live before any API client can start a
        // container (events from before it are unrecoverable). Cheap — this only spins
        // while dockerd's socket is down (boot / restart), then blocks in read above.
        std::thread::sleep(std::time::Duration::from_millis(250));
    });
}

/// Insert the gateway allow into both drop chains, retrying until dockerd has built its
/// table (a bounded settle delay after boot/restart — not a status poll: it stops the
/// moment both rules are in, and gives up after ~2 min if dockerd never comes up).
/// Block containers from reaching the host's conduit-pool listener.
///
/// The pool on `GATEWAY_IP:POOL_PORT` authenticates a conduit ONLY by source IP, and a
/// container's egress is masqueraded by dockerd to the guest's eth0 address — which is
/// exactly the address the host checks for. So without this, any unprivileged container
/// could open sockets to the pool, have them parked as conduits, and then be spliced into a
/// host client's published-port connection: interception and response-spoofing of any
/// published port, plus a trivial DoS by flooding the pool.
///
/// vinit's own conduits are locally generated, so they take the `output` hook and never
/// traverse `forward` — only routed container traffic does. Kept in Velox's OWN table so
/// dockerd's periodic chain rebuilds can't flush it, at a priority ahead of docker's filter.
fn assert_conduit_guard() {
    use std::sync::atomic::Ordering::Relaxed;
    let gw = GATEWAY_IP.load(Relaxed);
    if gw == 0 { return }
    let gws = ipstr(gw);
    let nft = |args: &[&str]| run_capture(
        Command::new("nft").env("PATH", "/bin:/usr/bin:/sbin:/usr/sbin").args(args));
    // Idempotent: create the table/chain, then only insert the rule if it isn't there.
    let _ = nft(&["add", "table", "ip", "velox"]);
    let _ = nft(&["add", "chain", "ip", "velox", "forward",
                  "{ type filter hook forward priority -10; policy accept; }"]);
    let want = format!("daddr {gws} tcp dport {POOL_PORT}");
    if let Some((true, out, _)) = nft(&["list", "chain", "ip", "velox", "forward"]) {
        if String::from_utf8_lossy(&out).contains(&want) { return }
    }
    match nft(&["add", "rule", "ip", "velox", "forward",
                "ip", "daddr", &gws, "tcp", "dport", &POOL_PORT.to_string(), "drop"]) {
        Some((true, _, _)) => log!("conduit-guard: containers blocked from {gws}:{POOL_PORT}"),
        _ => log!("conduit-guard: could not install the block rule for {gws}:{POOL_PORT}"),
    }
}

fn assert_direct_access_rules() {
    use std::sync::atomic::Ordering::Relaxed;
    // `run_capture`, not `Command::output()`: the reaper's `waitpid(-1)` races `Child::wait`
    // and wins often enough (measured ~40%) that `output()` returns ECHILD for a command that
    // actually succeeded — which read as failure here and pushed every assertion into 2 s
    // retry passes with named access dead in between.
    let nft = |args: &[&str]| run_capture(
        Command::new("nft").env("PATH", "/bin:/usr/bin:/sbin:/usr/sbin").args(args));
    // Called on the first iteration where the gateway is known, not at the top of the
    // function: at the top it returns immediately while GATEWAY_IP is still 0, and if the
    // DHCP lease then landed mid-loop the allow rules went in and we returned — leaving
    // containers able to reach GATEWAY_IP:2379 until some later trigger re-ran this. Guarded
    // by a flag so the wait loop can't re-run it up to 60 times: it is idempotent but costs
    // three `nft` spawns a pass, and this loop can spin for two minutes waiting for dockerd.
    let mut guarded = false;
    for _ in 0..60 {
        let gw = GATEWAY_IP.load(Relaxed);
        if gw != 0 {
            if !guarded { assert_conduit_guard(); guarded = true; }
            let gws = ipstr(gw);
            // The whole table appears only once dockerd's nft init has run — before
            // that there is nothing to assert into; keep waiting.
            let table_up = nft(&["list", "table", "ip", "docker-bridges"])
                .map(|(ok, _, _)| ok).unwrap_or(false);
            if table_up {
                let mut settled = true;
                for chain in ["filter-FORWARD", "raw-PREROUTING"] {
                    match nft(&["list", "chain", "ip", "docker-bridges", chain]) {
                        Some((true, out, _)) => {
                            // Trailing space anchors the match: nft prints `ip saddr <ip> counter
                            // … accept`, so `saddr 1.2.3.1 ` can't be satisfied by `saddr 1.2.3.10`.
                            if String::from_utf8_lossy(&out).contains(&format!("saddr {gws} ")) {
                                continue; // rule already in place
                            }
                            match nft(&["insert", "rule", "ip", "docker-bridges", chain,
                                        "ip", "saddr", &gws, "counter", "accept"]) {
                                Some((true, _, _)) =>
                                    log!("direct-access: allowed {gws} → containers ({chain})"),
                                _ => settled = false,
                            }
                        }
                        // Genuinely-absent chain: dockerd creates the drop chains lazily
                        // (raw-PREROUTING exists only while a container is attached), and
                        // an absent chain has no drops to bypass — nothing to do until
                        // the informer re-triggers on the event that creates it. Any OTHER
                        // failure (e.g. a transient error while dockerd is mid-rebuild)
                        // must retry, or a rebuilt chain slips through unallowed.
                        Some((_, _, err)) if String::from_utf8_lossy(&err)
                                                 .contains("No such file or directory") => {}
                        _ => settled = false,
                    }
                }
                if settled { return }
            }
        }
        std::thread::sleep(std::time::Duration::from_secs(2));
    }
    log!("direct-access: gave up waiting for dockerd's nft table (no named access)");
}

fn is_ext4(dev: &str) -> bool {
    use std::io::{Seek, SeekFrom};
    let Ok(mut f) = std::fs::File::open(dev) else { return false };
    if f.seek(SeekFrom::Start(1080)).is_err() { return false; }
    let mut magic = [0u8; 2];
    if f.read_exact(&mut magic).is_err() { return false; }
    magic == [0x53, 0xEF] // EXT4 superblock magic 0xEF53 (LE)
}

/// True only if the first 1 MiB of `dev` is entirely zero — i.e. a freshly-created, never-written
/// image. This gates `mkfs`: a positively-blank disk is a legitimate first-boot format, but a disk
/// with *any* non-zero content holds data we must not destroy (its superblock may merely be torn).
/// Any read error → false (treat as non-blank: never format on doubt).
fn disk_is_blank(dev: &str) -> bool {
    let Ok(mut f) = std::fs::File::open(dev) else { return false };
    let mut buf = vec![0u8; 1024 * 1024];
    let mut filled = 0;
    while filled < buf.len() {
        match f.read(&mut buf[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(_) => return false,
        }
    }
    filled > 0 && buf[..filled].iter().all(|&b| b == 0)
}

/// True if the ext4 data disk was cleanly unmounted — superblock `s_state` has
/// VALID_FS set and ERROR_FS clear. Read before the mount to decide whether a
/// preen-fsck is needed first. The kernel clears VALID_FS while the fs is
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
    let Some(swap_bytes) = mib.checked_mul(1024 * 1024) else {
        log!("velox.swap value is out of range — skipping swap");
        return;
    };
    match make_swapfile(path, swap_bytes) {
        Ok(()) => {
            let cpath = cstr(path);
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

/// Raise the sequential read-ahead window on a just-mounted VirtioFS share.
///
/// The kernel hands a FUSE/virtiofs backing-dev a 128 KiB read-ahead window — against 8 MiB
/// for the virtio-blk disks — which leaves bulk reads latency-bound on the host round-trip
/// rather than bandwidth-bound. Measured on an M4 Pro, 1 GiB sequential read through the
/// share (guest caches dropped, 3 runs each): 128 KiB → ~1.68 GB/s, **512 KiB → ~2.13 GB/s
/// (+27%)**, 1 MiB → ~2.02 GB/s, 4 MiB → ~1.81 GB/s. 512 KiB is the peak — below it the
/// window can't cover the round-trip, above it the surplus pages are wasted work. Purely
/// best-effort: a missing bdi node just leaves the kernel default in place.
fn tune_virtiofs_readahead(path: &str) {
    // NOT `cstr()`: that is `CString::new(..).expect(..)`, and its own doc says never to call
    // it on host-supplied input — a NUL byte would panic, which in PID 1 (panic = "abort")
    // takes the whole VM down. `path` comes from the `velox.shares` kernel cmdline payload.
    // `do_mount` and `make_rshared` already handle this; this tuner (added later) didn't.
    let Ok(c) = CString::new(path) else {
        log!("virtiofs: refusing to tune readahead for a path containing NUL");
        return;
    };
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::stat(c.as_ptr(), &mut st) } != 0 { return; }
    // Linux dev_t encoding — virtiofs gets an anonymous major 0.
    let dev = st.st_dev as u64;
    let major = (dev >> 8) & 0xfff;
    let minor = (dev & 0xff) | ((dev >> 12) & !0xffu64);
    let bdi = format!("/sys/class/bdi/{major}:{minor}/read_ahead_kb");
    match std::fs::write(&bdi, b"512") {
        Ok(_) => log!("virtiofs {path}: read_ahead_kb=512"),
        Err(e) => log!("virtiofs {path}: read-ahead tune skipped ({e})"),
    }
}

/// Mount the VirtioFS shares. Returns whether the **Rosetta** share mounted — the binfmt
/// registration that goes with it lives in `setup_binfmt()`, with every other emulator, so
/// there is exactly one place that touches binfmt_misc.
fn setup_virtiofs() -> bool {
    // host /Users → /Users, shared propagation so container bind mounts resolve.
    let _ = std::fs::create_dir_all("/Users");
    do_mount("vlxusers", "/Users", "virtiofs", 0, None);
    tune_virtiofs_readahead("/Users");
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
                    tune_virtiofs_readahead(path);
                    make_rshared(path);
                    log!("mounted share {tag} at {path}");
                }
            }
        }
    }

    // Rosetta x86-64 translation (optional — only if the host attached the share).
    // The mount is here with the other shares; the binfmt entry it enables is registered in
    // setup_binfmt(), which owns the ordering against the qemu emulators.
    let _ = std::fs::create_dir_all("/run/rosetta");
    let csrc = cstr("rosetta");
    let ctgt = cstr("/run/rosetta");
    let cfs = cstr("virtiofs");
    let r = unsafe { libc::mount(csrc.as_ptr(), ctgt.as_ptr(), cfs.as_ptr(), 0, std::ptr::null()) };
    if r != 0 {
        log!("no rosetta share — linux/amd64 falls back to qemu");
    }
    r == 0
}

// =================== binfmt_misc: multi-arch emulation ===================

/// The QEMU user-mode emulators baked into the rootfs (guest/rootfs/Dockerfile), as
/// `(binfmt name, magic, mask, interpreter)`. Apple silicon has no AArch32 EL0 and the kernel
/// is built without CONFIG_COMPAT, so these are the ONLY way a 32-bit image can run.
///
/// magic/mask are copied VERBATIM from qemu's own `scripts/qemu-binfmt-conf.sh` — never
/// hand-derived. They match the ELF header: class at offset 4, e_type at 16 (masked 0xfe so
/// ET_EXEC and ET_DYN both hit) and e_machine at 18 (0x28 = EM_ARM, 0x03 = EM_386).
///
/// linux/amd64 is deliberately absent here — it is handled in `setup_binfmt()` because Rosetta
/// takes precedence over `qemu-x86_64`.
const QEMU_EMULATORS: &[(&str, &str, &str, &str)] = &[
    ("qemu-arm",                                       // linux/arm/v5, /v6, /v7
     "\\x7fELF\\x01\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x28\\x00",
     "\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff",
     "/usr/bin/qemu-arm"),
    ("qemu-i386",                                      // linux/386
     "\\x7fELF\\x01\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x03\\x00",
     "\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff",
     "/usr/bin/qemu-i386"),
];

/// x86-64 ELF magic/mask — shared by the two possible linux/amd64 handlers (Rosetta and
/// qemu-x86_64), which is exactly why only one of them may ever be registered.
const X86_64_MAGIC: &str =
    "\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00";
const X86_64_MASK: &str =
    "\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff";

/// Register one binfmt_misc ELF handler.
///
/// The kernel hex-unescapes magic/mask itself (`string_unescape_inplace`, UNESCAPE_HEX), so we
/// write the LITERAL `\xNN` escaped form — NOT raw bytes, whose NULs would truncate the magic
/// at `scanarg` and match every ELF of that class (breaking native arm64 exec).
///
/// Flags `OCF` — the same set qemu's `qemu-binfmt-conf.sh` and Docker's own binfmt installer use:
///   * `O` — hand the target binary to the interpreter as an already-open fd.
///   * `C` — apply the *target's* credentials (setuid/setgid), not the interpreter's.
///   * `F` — "fix binary": the kernel opens the interpreter ONCE, here, and clones that open
///     file for every exec. This is what makes emulation work inside containers at all (a
///     container rootfs has no `/usr/bin/qemu-*`), and it keeps exec cheap — no path lookup in
///     the container's mount namespace, no re-open, interpreter pages stay hot in page cache.
fn register_binfmt(name: &str, magic: &str, mask: &str, interp: &str) -> bool {
    let reg = format!(":{name}:M::{magic}:{mask}:{interp}:OCF");
    match std::fs::write("/proc/sys/fs/binfmt_misc/register", reg) {
        Ok(_) => true,
        Err(e) => { log!("binfmt: {name} failed to register: {e}"); false }
    }
}

/// Register every emulator the guest carries, so `docker run --platform linux/arm/v7 …` works
/// with no privileged `multiarch/qemu-user-static` / `tonistiigi/binfmt` setup container.
/// (Those work by writing the same file from inside a container, but their entries live in the
/// guest kernel and die with the VM — they must be re-run after every engine restart. Doing it
/// from PID 1 is the only form that is actually reliable, and it is what Docker Desktop's
/// LinuxKit `pkg/binfmt` does too.)
///
/// Runs before `spawn_dockerd()`: dockerd's embedded BuildKit worker probes the supported
/// platforms once at startup, so anything registered later can never appear in `docker buildx
/// inspect`. (That list is advisory — measured, buildx builds `--platform linux/arm/v7` fine
/// even though it does not advertise it — but registering first costs nothing.)
fn setup_binfmt(rosetta_ok: bool) {
    let mut registered: Vec<&str> = Vec::new();
    for (name, magic, mask, interp) in QEMU_EMULATORS {
        // The emulator set is a build-time choice; tolerate a rootfs built without one.
        if !std::path::Path::new(interp).exists() {
            log!("binfmt: {interp} missing — {name} not registered");
            continue;
        }
        if register_binfmt(name, magic, mask, interp) { registered.push(name); }
    }

    // linux/amd64: Rosetta when the host attached its share (far faster than TCG emulation),
    // and qemu-x86_64 ONLY as the fallback. Never both: binfmt_misc matches the MOST RECENTLY
    // registered entry first (`hlist_add_head_rcu` since 6.7, `list_add` before), so a
    // qemu-x86_64 registered after Rosetta would silently shadow it and make every amd64
    // container an order of magnitude slower — a regression with no error to notice.
    //
    // The fallback keys on the REGISTRATION, not just the mount: the `F` flag makes the kernel
    // open /run/rosetta/rosetta at registration time, so the write can fail on a mounted-but-
    // unusable share. Falling back then is shadow-safe by construction — a failed registration
    // put nothing in the list to shadow — and the alternative is amd64 not running at all while
    // a working emulator sits unused in the rootfs.
    let rosetta_registered =
        rosetta_ok && register_binfmt("rosetta", X86_64_MAGIC, X86_64_MASK, "/run/rosetta/rosetta");
    if rosetta_registered {
        registered.push("rosetta[amd64]");
    } else if std::path::Path::new("/usr/bin/qemu-x86_64").exists()
        && register_binfmt("qemu-x86_64", X86_64_MAGIC, X86_64_MASK, "/usr/bin/qemu-x86_64")
    {
        if rosetta_ok { log!("binfmt: rosetta unusable — falling back to qemu for linux/amd64"); }
        registered.push("qemu-x86_64");
    }

    if registered.is_empty() {
        log!("binfmt: nothing registered — only native arm64 images will run");
    } else {
        log!("binfmt: {}", registered.join(", "));
    }
}

fn make_rshared(target: &str) {
    // NUL-safe: `target` can be a host-supplied share path (velox.shares). With
    // `panic = "abort"` a panic in PID 1 is a kernel panic, so never `cstr()` outside
    // input here — skip the propagation on a NUL rather than take down the whole VM.
    let Ok(ctgt) = CString::new(target) else {
        log!("make_rshared {target}: NUL in path — skipping");
        return;
    };
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
    // dockerd discovers containerd/runc/nft on PATH and manages its own containerd
    // (no iptables binary is shipped — see the nftables firewall backend below). Unix
    // socket (not TCP) — the vsock agent bridges to it directly.
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
    // A failed spawn here means this vsock port is never served — the Docker API (2375) or
    // the control channel (2374) would be silently unreachable for the VM's whole life.
    if !spawn_worker("vsock-listener", move || {
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
            if !spawn_worker("vsock-conn", move || {
                handler(cfd);
                VSOCK_INFLIGHT.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
            }) {
                VSOCK_INFLIGHT.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                unsafe { libc::close(cfd); }
            }
        }
    }) {
        log!("vinit: vsock port {port} will not be served (listener thread could not start)");
    }
}

fn handle_control(fd: RawFd) {
    unsafe { libc::sync(); }
    let _ = nix_write(fd, b"OK\n");
    unsafe { libc::close(fd); }
}

/// Clock re-sync: the host writes "<unix-epoch>\n" (at start and whenever the Mac
/// wakes). Apple VZ has no RTC, so a slept-then-resumed guest is behind by the
/// sleep duration — enough to break TLS. Re-set the clock only when it drifts by more
/// than ~2s (normal periodic pushes are sub-second), to avoid needless jitter.
/// Host-authoritative, no NTP daemon (see CLAUDE.md §6).
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
    // Saturating: `epoch` is peer-supplied, so a hostile value makes the subtraction (and
    // `i64::MIN.abs()`) overflow — which panics under `overflow-checks`, i.e. kills PID 1.
    if epoch.saturating_sub(now).saturating_abs() <= 2 { return; } // already aligned
    let tv = libc::timeval { tv_sec: epoch, tv_usec: 0 };
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
    spawn_worker("conduit-manager", conduit_manager);
}

/// Returns false if the slot thread could not be started.
fn spawn_conduit_slot() -> bool {
    CONDUIT_SLOTS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    // Give the slot back if the thread never started — only the thread's own reap path
    // decrements, so a discarded failure leaks the slot forever and the manager stops
    // topping the pool up (silently costing ~59 Gbit/s → 1.4 Gbit/s on published ports).
    // The result MUST reach the growth loop: with the count restored but no thread, a
    // `while CONDUIT_SLOTS < target` loop never advances and spins PID 1 at 100% — and
    // spawn failure means fork exhaustion or ENOMEM, i.e. exactly when the guest can least
    // afford it.
    if spawn_worker("conduit-slot", conduit_slot) { return true }
    CONDUIT_SLOTS.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
    false
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
        while CONDUIT_SLOTS.load(Relaxed) < target {
            // Stop growing the moment a spawn fails, and park until the next starvation
            // signal instead of retrying in a tight loop. The pool simply runs smaller;
            // published ports fall back to the vsock relay rather than the guest wedging.
            if !spawn_conduit_slot() {
                log!("conduit: could not start a slot thread — pool will run below target");
                break
            }
        }

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
        // Park on this conduit. At (or below) the floor, park INDEFINITELY: a timeout
        // has nothing to do there (reaping only applies over the target, and a dead
        // conduit surfaces as EOF via TCP keepalive) — the old unconditional 10s poll
        // had the 16 floor slots collectively waking every ~0.6s at idle for nothing.
        // Over the floor, keep the timeout so excess slots reap once the burst passes.
        loop {
            let timeout = if CONDUIT_SLOTS.load(Relaxed) > CONDUIT_FLOOR { CONDUIT_REAP_MS } else { -1 };
            CONDUIT_IDLE.fetch_add(1, Relaxed);
            let res = read_assignment_timed(fd, timeout);
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
/// First resolved socket address for `host:port`, as an io::Result so it composes with
/// `connect_timeout` (which, unlike `connect`, takes a resolved address).
fn resolve_one(target: &str) -> std::io::Result<std::net::SocketAddr> {
    use std::net::ToSocketAddrs;
    target.to_socket_addrs()?.next().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::AddrNotAvailable, "no address for target")
    })
}

fn bridge_to_target(fd: RawFd, header: &str) {
    let mut target = header.to_string();
    if !target.contains(':') { target = format!("127.0.0.1:{target}"); }
    // Bounded: `connect` with no timeout parks this thread for the full SYN timeout (~2 min)
    // on a blackholed container IP, and a conduit slot is neither idle nor redialing while it
    // waits — enough such dials starve the warm pool.
    match resolve_one(&target)
        .and_then(|a| std::net::TcpStream::connect_timeout(&a, std::time::Duration::from_secs(5))) {
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
            // Only keep a worker whose loop actually came up. Discarding this Bool left a
            // thread-less worker in the round-robin: relay_submit would queue a pair to it,
            // write the eventfd nobody reads, and the connection would hang with both fds
            // held — 1 in N published-port connections, permanently, after a single EAGAIN.
            if spawn_worker("relay-worker", move || relay_worker_loop(wc)) {
                workers.push(w);
            } else {
                unsafe { libc::close(w.epfd); libc::close(w.evfd); }
            }
        }
        Relay { workers, next: std::sync::atomic::AtomicUsize::new(0) }
    });
}

/// Submit a (conduit, target) fd pair to a worker. Falls back to bridge() if the relay isn't
/// initialised yet (shouldn't happen — relay_init runs before the pool dials).
fn relay_submit(conduit: RawFd, container: RawFd) {
    let Some(r) = RELAY.get() else { bridge(conduit, container); return };
    // No live worker (every epoll thread failed to spawn): fall back to the direct bridge
    // rather than `% 0`. A divide-by-zero panic here is unwinding-free (`panic = "abort"`)
    // in PID 1, which the kernel turns into "Attempted to kill init" — the whole VM. The
    // host's `EventRelay` makes the same check for the same reason; keep the two mirrored.
    if r.workers.is_empty() { bridge(conduit, container); return }
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
        if n < 0 {
            // EINTR is normal; anything else is unrecoverable (a bad epfd spins this thread
            // at 100% CPU forever, which is exactly when the guest can least afford it).
            if std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) { continue }
            log!("relay worker: epoll_wait failed ({}) — stopping this worker",
                 std::io::Error::last_os_error());
            return;
        }
        for ev in events.iter().copied().take(n as usize) {
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
                // EPOLLHUP/EPOLLERR is a hang-up or error on the SOCKET, not a graceful
                // half-close (that arrives as read()==0 and is handled in `relay_read`). Only
                // marking the firing direction meant a peer that ignores our `SHUT_WR` kept
                // the pair — and both fds, and 512 KiB of buffers — alive forever, an
                // unbounded leak in the `conns` map. End the whole connection.
                let hangup = mask & ((libc::EPOLLHUP | libc::EPOLLERR) as u32) != 0;
                if hangup {
                    c.ab.eof = true; c.ab.len = 0;
                    c.ba.eof = true; c.ba.len = 0;
                    unsafe { libc::shutdown(c.a, libc::SHUT_RDWR); libc::shutdown(c.b, libc::SHUT_RDWR); }
                }
                let done = c.ab.finished() && c.ba.finished();
                if !done { relay_update(w.epfd, &c, c.a); relay_update(w.epfd, &c, c.b); }
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
    // Bounded: `connect` with no timeout parks this thread for the full SYN timeout (~2 min)
    // on a blackholed container IP, and a conduit slot is neither idle nor redialing while it
    // waits — enough such dials starve the warm pool.
    match resolve_one(&target)
        .and_then(|a| std::net::TcpStream::connect_timeout(&a, std::time::Duration::from_secs(5))) {
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
    let t = match std::thread::Builder::new().spawn(move || udp_frames_to_dgrams(vsock, udp)) {
        Ok(h) => h,
        Err(e) => {
            log!("vinit: cannot spawn udp-relay thread ({e}) — dropping flow");
            unsafe { libc::close(vsock); }
            drop(sock);
            return;
        }
    };
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
    // One direction on a helper thread, the other on this one: half the threads per bridged
    // connection, and no `thread::spawn` panic path (which in PID 1 is a whole-VM abort).
    let t1 = match std::thread::Builder::new().spawn(move || pump(a, b)) {
        Ok(h) => h,
        Err(e) => {
            log!("vinit: cannot spawn bridge thread ({e}) — dropping connection");
            unsafe { libc::close(a); libc::close(b); }
            return;
        }
    };
    pump(b, a);
    let _ = t1.join();
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
/// daemon that crashes on startup doesn't spin the CPU. Each successful respawn pings
/// `nft_restarted` so direct-access re-asserts its rules in the rebuilt nft table.
fn dockerd_supervisor(deaths: std::sync::mpsc::Receiver<()>, nft_restarted: std::sync::mpsc::Sender<()>) {
    let mut spawned_at = std::time::Instant::now();
    let mut fast_deaths: u32 = 0;
    while deaths.recv().is_ok() {
        // Crash-loop backoff: a dockerd that dies within 10s of spawning doubles the
        // respawn delay (1,2,4,…,30s cap); one that ran ≥60s resets it (10–60s keeps
        // the current level). Never gives up — an appliance must keep self-healing —
        // but a wedged engine can't respawn-storm the CPU at 1 Hz forever.
        let uptime = spawned_at.elapsed();
        if uptime < std::time::Duration::from_secs(10) {
            fast_deaths = (fast_deaths + 1).min(5);
        } else if uptime >= std::time::Duration::from_secs(60) {
            fast_deaths = 0;
        }
        let delay = (1u64 << fast_deaths).min(30);
        if fast_deaths > 0 {
            log!("dockerd exited after {}s — restarting in {delay}s (crash loop #{fast_deaths})", uptime.as_secs());
        } else {
            log!("dockerd exited — restarting");
        }
        std::thread::sleep(std::time::Duration::from_secs(delay));
        loop {
            let pid = spawn_dockerd();
            if pid >= 0 {
                DOCKERD_PID.store(pid, std::sync::atomic::Ordering::SeqCst);
                spawned_at = std::time::Instant::now();
                let _ = nft_restarted.send(());
                break;
            }
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
    }
}

/// PID-1 reaper: a tight blocking `waitpid` loop that reaps every child immediately and
/// never sleeps on the dockerd-restart path (that's the supervisor thread's job) — so a
/// crash-looping dockerd can't leave orphaned shims/containers piling up as zombies.
/// Single-slot handshake between `reap_forever` and the one place that needs a child's exit
/// status (`assert_direct_access_rules`).
///
/// The reaper blocks in `waitpid(-1, ..)` for the life of the VM, so it can collect any
/// child before `std::process::Child::wait` gets there — and `wait` then fails with ECHILD
/// rather than tolerating it. Measured ~40% of `Command::output()` calls failing that way,
/// which made every named-access assertion after a `docker run` read as failure and take
/// several 2 s retry passes instead of one, with `<name>.velox.local` dead in between.
struct ChildStatus {
    slot: std::sync::Mutex<Option<(i32, Option<i32>)>>, // (claimed pid, status once reaped)
    cv: std::sync::Condvar,
}
static CHILD_STATUS: std::sync::OnceLock<ChildStatus> = std::sync::OnceLock::new();
fn child_status() -> &'static ChildStatus {
    CHILD_STATUS.get_or_init(|| ChildStatus {
        slot: std::sync::Mutex::new(None),
        cv: std::sync::Condvar::new(),
    })
}

/// Called by the reaper for every pid it collects.
fn child_status_deliver(pid: i32, status: i32) {
    let cs = child_status();
    let Ok(mut slot) = cs.slot.lock() else { return };
    if let Some((claimed, st @ None)) = slot.as_mut().map(|s| (s.0, &mut s.1)) {
        if claimed == pid {
            *st = Some(status);
            cs.cv.notify_all();
        }
    }
}

/// Run `cmd`, capturing stdout and stderr, and return `(exit_ok, stdout, stderr)`.
/// Serialized: only one claim can be outstanding, which is fine — the sole caller is the
/// single direct-access thread. (stdout is drained before stderr; both stay far below a
/// pipe buffer for `nft`, so there is no fill-the-other-pipe deadlock.)
fn run_capture(cmd: &mut Command) -> Option<(bool, Vec<u8>, Vec<u8>)> {
    use std::io::Read;
    let cs = child_status();
    // Hold the slot lock ACROSS the spawn. The reaper delivers into this slot, and claiming
    // after `spawn()` returns left a window where it could collect the child first: the
    // status was dropped, `try_wait` returned ECHILD, and the condvar then blocked the full
    // 10 s before reporting a failure for a command that had actually succeeded. Downstream
    // that made `assert_direct_access_rules` re-insert an nft rule it already had, so the
    // ruleset accreted duplicates over a long session.
    let mut slot = cs.slot.lock().ok()?;
    let mut child = cmd
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .stdin(std::process::Stdio::null())   // don't hand PID 1's console to the child
        .spawn().ok()?;
    let pid = child.id() as i32;
    *slot = Some((pid, None));
    drop(slot);
    let mut out = Vec::new();
    let mut err = Vec::new();
    if let Some(mut so) = child.stdout.take() { let _ = so.read_to_end(&mut out); }
    if let Some(mut se) = child.stderr.take() { let _ = se.read_to_end(&mut err); }
    // Whoever gets there first wins; both paths are correct.
    let status = match child.try_wait() {
        Ok(Some(st)) => st.code().unwrap_or(-1),
        _ => {
            let mut slot = cs.slot.lock().ok()?;
            let deadline = std::time::Duration::from_secs(10);
            loop {
                match slot.as_ref().and_then(|s| s.1) {
                    Some(st) => break if st & 0x7f == 0 { (st >> 8) & 0xff } else { -1 },
                    None => {
                        let (g, timeout) = cs.cv.wait_timeout(slot, deadline).ok()?;
                        slot = g;
                        if timeout.timed_out() { break -1 }
                    }
                }
            }
        }
    };
    if let Ok(mut slot) = cs.slot.lock() { *slot = None; }
    Some((status == 0, out, err))
}

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
            // Clear it FIRST. The supervisor backs off for up to 30 s before respawning, and
            // the kernel recycles pids freely (pid_max 32768, several burned per `docker run`)
            // — so leaving the dead pid here meant an unrelated orphan reusing it produced a
            // spurious "dockerd died". The supervisor then counted a fast death and spawned a
            // SECOND dockerd next to the live one; that one lost the socket bind and exited,
            // and because DOCKERD_PID now pointed at it, the real dockerd's eventual death was
            // never noticed again.
            DOCKERD_PID.store(-1, std::sync::atomic::Ordering::SeqCst);
            // dockerd died — hand the restart to the supervisor and keep reaping now.
            log!("dockerd exited (status {status:#x}) — signalling restart");
            let _ = deaths.send(());
        }
        // Hand the status to a waiter that claimed this pid (see `run_capture`).
        child_status_deliver(pid, status);
        // Any other pid is an orphaned grandchild (container proc, shim) — already reaped.
    }
}
