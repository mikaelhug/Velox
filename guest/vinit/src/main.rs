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
const DOCKER_PORT: u32 = 2375;
const CONTROL_PORT: u32 = 2374;
const REVERSE_PORT: u32 = 2376;
const CLOCK_PORT: u32 = 2377;
const DOCKER_SOCK: &str = "/run/docker.sock";

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
    if let Err(e) = setup_network() {
        log!("network setup failed (continuing, no outbound until fixed): {e}");
    }
    setup_data_disk();
    setup_swap();
    setup_virtiofs();
    enable_ip_forwarding();
    let dockerd_pid = spawn_dockerd();
    start_vsock_agent();
    log!("init complete — supervising");
    reap_forever(dockerd_pid);
}

// =================== filesystems ===================

fn do_mount(src: &str, target: &str, fstype: &str, flags: libc::c_ulong, data: Option<&str>) {
    // Create the mountpoint if missing (only works on tmpfs/writable parents).
    let _ = std::fs::create_dir_all(target);
    let csrc = CString::new(src).unwrap();
    let ctgt = CString::new(target).unwrap();
    let cfs = CString::new(fstype).unwrap();
    let cdata = data.map(|d| CString::new(d).unwrap());
    let dptr = cdata.as_ref().map_or(std::ptr::null(), |c| c.as_ptr());
    let r = unsafe {
        libc::mount(csrc.as_ptr(), ctgt.as_ptr(),
            if fstype.is_empty() { std::ptr::null() } else { cfs.as_ptr() },
            flags, dptr as *const libc::c_void)
    };
    if r != 0 {
        log!("mount {target} ({fstype}) failed: {}", std::io::Error::last_os_error());
    }
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
/// spawn_dockerd to wire `host.docker.internal` → the host.
static GATEWAY_IP: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

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
    // Remember the gateway (the Mac on the vmnet bridge) for host.docker.internal.
    GATEWAY_IP.store(lease.router, std::sync::atomic::Ordering::Relaxed);
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
            let query = buf[..n].to_vec();
            let s = sock.clone();
            std::thread::spawn(move || answer_dns(&s, &query, src, gateway, upstream));
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
    up.set_read_timeout(Some(std::time::Duration::from_secs(4))).ok()?;
    let dst = std::net::SocketAddr::from((std::net::Ipv4Addr::from(upstream), 53));
    up.send_to(query, dst).ok()?;
    let mut buf = [0u8; 4096];
    let (n, _) = up.recv_from(&mut buf).ok()?;
    Some(buf[..n].to_vec())
}

mod dhcp {
    use dhcproto::{v4, Decodable, Decoder, Encodable, Encoder};
    use std::io::{Error, ErrorKind, Result};

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
        let discover = build(mac, xid, v4::MessageType::Discover, None, None);
        send(sock, &discover)?;
        let offer = recv(sock, xid).ok_or_else(|| Error::new(ErrorKind::TimedOut, "no DHCP offer"))?;
        let offered_ip = offer.yiaddr();
        let server = opt_addr(&offer, v4::OptionCode::ServerIdentifier);
        // REQUEST
        let request = build(mac, xid, v4::MessageType::Request, Some(offered_ip), server);
        send(sock, &request)?;
        let ack = recv(sock, xid).ok_or_else(|| Error::new(ErrorKind::TimedOut, "no DHCP ack"))?;
        Ok(Lease {
            ip: u32::from(ack.yiaddr()),
            mask: opt_addr(&ack, v4::OptionCode::SubnetMask).unwrap_or(0),
            router: opt_addr(&ack, v4::OptionCode::Router).unwrap_or(0),
            dns: opt_addrs(&ack, v4::OptionCode::DomainNameServer),
            server: opt_addr(&ack, v4::OptionCode::ServerIdentifier).or(server).unwrap_or(0),
            lease_secs: opt_u32(&ack, v4::OptionCode::AddressLeaseTime).unwrap_or(0),
        })
    }

    /// Renew the current lease in place (INIT-REBOOT style: broadcast REQUEST for
    /// the IP we already hold). Returns Ok once the server ACKs. Best-effort.
    pub fn renew(ifname: &str, mac: [u8; 6], ip: u32, server: u32) -> Result<()> {
        let sock = open_socket(ifname)?;
        let xid = rand_xid();
        let req_ip = std::net::Ipv4Addr::from(ip);
        let server_opt = if server != 0 { Some(server) } else { None };
        let request = build(&mac, xid, v4::MessageType::Request, Some(req_ip), server_opt);
        send(sock, &request)?;
        let res = recv(sock, xid).map(|_| ())
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

    fn build(mac: &[u8; 6], xid: u32, mt: v4::MessageType, req_ip: Option<std::net::Ipv4Addr>, server: Option<u32>) -> Vec<u8> {
        let mut msg = v4::Message::default();
        msg.set_flags(v4::Flags::default().set_broadcast())
            .set_xid(xid)
            .set_chaddr(mac);
        msg.opts_mut().insert(v4::DhcpOption::MessageType(mt));
        msg.opts_mut().insert(v4::DhcpOption::ParameterRequestList(vec![
            v4::OptionCode::SubnetMask, v4::OptionCode::Router, v4::OptionCode::DomainNameServer,
        ]));
        if let Some(ip) = req_ip { msg.opts_mut().insert(v4::DhcpOption::RequestedIpAddress(ip)); }
        if let Some(s) = server { msg.opts_mut().insert(v4::DhcpOption::ServerIdentifier(s.into())); }
        let mut buf = Vec::new();
        msg.encode(&mut Encoder::new(&mut buf)).ok();
        buf
    }

    fn opt_addr(m: &v4::Message, code: v4::OptionCode) -> Option<u32> {
        match m.opts().get(code) {
            Some(v4::DhcpOption::SubnetMask(a)) | Some(v4::DhcpOption::ServerIdentifier(a)) => Some((*a).into()),
            Some(v4::DhcpOption::Router(a)) => a.first().map(|x| (*x).into()),
            Some(v4::DhcpOption::RequestedIpAddress(a)) => Some((*a).into()),
            _ => None,
        }
    }
    fn opt_addrs(m: &v4::Message, code: v4::OptionCode) -> Vec<u32> {
        match m.opts().get(code) {
            Some(v4::DhcpOption::DomainNameServer(v)) => v.iter().map(|x| (*x).into()).collect(),
            _ => Vec::new(),
        }
    }
    fn opt_u32(m: &v4::Message, code: v4::OptionCode) -> Option<u32> {
        match m.opts().get(code) {
            Some(v4::DhcpOption::AddressLeaseTime(s)) => Some(*s),
            _ => None,
        }
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

    fn recv(s: i32, xid: u32) -> Option<v4::Message> {
        // retry a few times within the socket timeout for a matching xid
        for _ in 0..4 {
            let mut buf = [0u8; 1024];
            let n = unsafe { libc::recv(s, buf.as_mut_ptr() as *mut _, buf.len(), 0) };
            if n <= 0 { return None; }
            if let Ok(m) = v4::Message::decode(&mut Decoder::new(&buf[..n as usize])) {
                if m.xid() == xid { return Some(m); }
            }
        }
        log!("DHCP: no matching reply");
        None
    }
}

// =================== data disk ===================

fn setup_data_disk() {
    let dev = "/dev/vdb";
    if std::path::Path::new(dev).exists() {
        if !is_ext4(dev) {
            log!("formatting {dev} ext4 (first boot)");
            // -m 0: a dedicated data disk needs no 5%-reserved root headroom (dockerd
            // runs as root anyway) — reclaim it for image/container storage. Applies to
            // the first-boot format only; existing disks keep whatever they were made with.
            let st = Command::new("/sbin/mkfs.ext4").args(["-F", "-q", "-m", "0", dev]).status();
            match st { Ok(s) if s.success() => {}, other => log!("mkfs.ext4 failed: {other:?}") }
        }
        // /var/lib/docker is overlay-snapshot churn central — every `docker run`
        // mounts/unmounts a snapshot. noatime drops read-driven atime writes; lazytime
        // keeps inode mtime/ctime in memory and flushes them lazily (on fsync / sync /
        // 24h) instead of journalling every metadata touch — less write amplification on
        // the container hot path, and nothing under here needs atime/precise timestamps.
        do_mount(dev, "/var/lib/docker", "ext4",
                 libc::MS_NOATIME | libc::MS_LAZYTIME, None);
        start_fstrim_timer();
    } else {
        log!("no {dev} — /var/lib/docker stays on tmpfs (non-persistent)");
    }
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

fn spawn_listener(port: u32, handler: fn(RawFd)) {
    std::thread::spawn(move || {
        let lfd = match vsock_listen(port) {
            Ok(f) => f,
            Err(e) => { log!("vsock listen {port} failed: {e}"); return; }
        };
        log!("vsock listening on {port}");
        loop {
            let cfd = unsafe { libc::accept(lfd, std::ptr::null_mut(), std::ptr::null_mut()) };
            if cfd < 0 { continue; }
            std::thread::spawn(move || handler(cfd));
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
    let mut buf = [0u8; 32 * 1024];
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

fn reap_forever(mut dockerd_pid: i32) -> ! {
    loop {
        let mut status = 0;
        let pid = unsafe { libc::waitpid(-1, &mut status, 0) };
        if pid < 0 {
            // ECHILD or EINTR — nothing to reap right now; brief sleep.
            std::thread::sleep(std::time::Duration::from_millis(200));
            continue;
        }
        if pid == dockerd_pid {
            // The engine itself died (crash, OOM, fatal config error). Relaunch
            // it — a single dockerd exit must never leave Velox dead. Back off
            // first so a daemon that crashes on startup doesn't spin the CPU,
            // and retry the spawn until we have a live PID to watch again.
            log!("dockerd exited (status {status:#x}) — restarting");
            std::thread::sleep(std::time::Duration::from_secs(1));
            loop {
                dockerd_pid = spawn_dockerd();
                if dockerd_pid >= 0 { break; }
                std::thread::sleep(std::time::Duration::from_secs(2));
            }
        } else {
            // An orphaned grandchild (container process, containerd-shim, etc.)
            // reparented to PID 1 — just reap it.
            log!("reaped child pid {pid} (status {status:#x})");
        }
    }
}
