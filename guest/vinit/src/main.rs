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
    // With the host userspace netstack (velox-net), the host advertises
    // `velox.net=static`: there is no DHCP server, so configure eth0 statically
    // (gateway 192.168.127.1, guest 192.168.127.2/24, DNS at the gateway). Without
    // it, fall back to DHCP (the Apple-NAT path). This dual mode lets the netstack
    // be brought up without breaking the default until it's the validated default.
    if cmdline_value("velox.net").as_deref() == Some("static") {
        return setup_network_static();
    }

    // bring lo up + eth0 up, then DHCP, then apply lease.
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
    // DNS
    write_resolv_conf(&lease.dns);
    unsafe { libc::close(s); }

    // Keep the lease alive. Apple's NAT hands out finite leases; without renewal
    // a long-running VM would eventually lose its address. Renew in the
    // background at ~half the lease interval (best-effort).
    let (ip, server, lease_secs) = (lease.ip, lease.server, lease.lease_secs);
    std::thread::spawn(move || dhcp::renew_loop(IFNAME, mac, ip, server, lease_secs));
    Ok(())
}

/// Static eth0 config for the velox-net host stack (no DHCP). Matches the gateway
/// (192.168.127.1) and guest (192.168.127.2/24) the host's NetworkStack assigns.
fn setup_network_static() -> std::io::Result<()> {
    let s = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0) };
    if s < 0 { return Err(std::io::Error::last_os_error()); }
    iface_up(s, "lo");
    iface_up(s, IFNAME);

    let ip: u32 = 0xC0A8_7F02; // 192.168.127.2
    let mask: u32 = 0xFFFF_FF00; // /24
    let gw: u32 = 0xC0A8_7F01; // 192.168.127.1

    let mut ra = IfReqAddr { name: ifname_bytes(), addr: sockaddr_in(ip) };
    if unsafe { libc::ioctl(s, SIOCSIFADDR as _, &mut ra) } != 0 {
        log!("static set address failed: {}", std::io::Error::last_os_error());
    }
    let mut rm = IfReqAddr { name: ifname_bytes(), addr: sockaddr_in(mask) };
    if unsafe { libc::ioctl(s, SIOCSIFNETMASK as _, &mut rm) } != 0 {
        log!("static set netmask failed: {}", std::io::Error::last_os_error());
    }
    iface_up(s, IFNAME);
    add_default_route(s, gw);
    write_resolv_conf(&[gw]); // nameserver = the gateway's DNS responder
    unsafe { libc::close(s); }
    log!("network: static {}/24 gw {} (velox-net)", ipstr(ip), ipstr(gw));
    Ok(())
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
        let sock = open_socket(ifname)?;
        let xid = rand_xid();
        // DISCOVER
        let discover = build(&mac, xid, v4::MessageType::Discover, None, None);
        send(sock, &discover)?;
        let offer = recv(sock, xid).ok_or_else(|| Error::new(ErrorKind::TimedOut, "no DHCP offer"))?;
        let offered_ip = offer.yiaddr();
        let server = opt_addr(&offer, v4::OptionCode::ServerIdentifier);
        // REQUEST
        let request = build(&mac, xid, v4::MessageType::Request, Some(offered_ip), server);
        send(sock, &request)?;
        let ack = recv(sock, xid).ok_or_else(|| Error::new(ErrorKind::TimedOut, "no DHCP ack"))?;
        unsafe { libc::close(sock); }
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
            let tv = libc::timeval { tv_sec: 5, tv_usec: 0 };
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
            let st = Command::new("/bin/mkfs.ext4").args(["-F", "-q", dev]).status();
            match st { Ok(s) if s.success() => {}, other => log!("mkfs.ext4 failed: {other:?}") }
        }
        do_mount(dev, "/var/lib/docker", "ext4", 0, None);
    } else {
        log!("no {dev} — /var/lib/docker stays on tmpfs (non-persistent)");
    }
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
    ];
    // In netstack (static) mode the gateway IP is fixed and is also
    // host.docker.internal; tell dockerd so `--add-host host.docker.internal:
    // host-gateway` (and compose extra_hosts) resolve to the Mac.
    if cmdline_value("velox.net").as_deref() == Some("static") {
        args.push("--host-gateway-ip=192.168.127.1".into());
        // The netstack is IPv4-only (v1); stop dockerd from trying (and failing) to
        // program IPv6 NAT rules. Avoids a noisy ip6tables warning at boot.
        args.push("--ip6tables=false".into());
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
    let mut target = String::from_utf8_lossy(&line).trim().to_string();
    if target.is_empty() { unsafe { libc::close(fd); } return; }
    if !target.contains(':') { target = format!("127.0.0.1:{target}"); }
    match std::net::TcpStream::connect(&target) {
        Ok(up) => bridge(fd, up.into_raw_fd()),
        Err(e) => { log!("reverse dial {target}: {e}"); unsafe { libc::close(fd); } }
    }
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
