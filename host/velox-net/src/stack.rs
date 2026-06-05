//! The reactor: a single-threaded, event-driven netstack core.
//!
//! It blocks in `kqueue` waiting for readiness on the guest frame socket, the
//! wakeup pipe, the published-port listeners, and every host-side socket (TCP NAT
//! conns, UDP NAT conns, async DNS upstreams). It wakes only on real I/O readiness
//! or a smoltcp timer — never a busy spin. Per-flow READ/WRITE interest is toggled
//! for proper backpressure, and outbound connects + DNS forwarding are fully
//! non-blocking. smoltcp owns the guest side; raw host sockets own the host side.

use crate::device::FrameDevice;
use crate::{dns, Cmd, LogSink, Stats, VnConfig};
use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::socket::{tcp, udp};
use smoltcp::time::Instant;
use smoltcp::wire::{EthernetAddress, IpAddress, IpCidr, IpEndpoint, IpListenEndpoint, Ipv4Address};
use std::collections::{HashMap, HashSet};
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant as StdInstant};

const GATEWAY_MAC: [u8; 6] = [0x52, 0x55, 0x00, 0x00, 0x00, 0x01];
const TCP_BUF: usize = 512 * 1024; // smoltcp per-socket window
const BUF_CAP: usize = 512 * 1024; // host<->guest staging cap (backpressure threshold)
const UDP_IDLE: Duration = Duration::from_secs(60);
const DNS_TIMEOUT: Duration = Duration::from_secs(5);

type ConnKey = (u32, u16, u32, u16);

struct Tcp {
    handle: SocketHandle, // smoltcp socket
    fd: RawFd,            // host socket
    key: ConnKey,
    connecting: bool,    // outbound: host non-blocking connect in progress
    established: bool,    // smoltcp socket reached Established
    to_host: Vec<u8>,    // guest→host bytes awaiting write to the host socket
    to_guest: Vec<u8>,   // host→guest bytes awaiting send into smoltcp
    host_eof: bool,
    guest_fin_done: bool,    // shutdown(host, WR) done after the guest FIN
    fin_to_guest_done: bool, // smoltcp close() done after host EOF
    read_armed: bool,
    write_armed: bool,
}

pub fn run(
    fd: RawFd,
    cfg: VnConfig,
    stop: Arc<AtomicBool>,
    stats: Arc<Stats>,
    cmds: Arc<Mutex<Vec<Cmd>>>,
    wakeup_r: RawFd,
    sink: LogSink,
) {
    let start = StdInstant::now();
    let now = || Instant::from_micros(start.elapsed().as_micros() as i64);

    let mut device = FrameDevice::new(fd, cfg.mtu as usize, stats);
    let iface_cfg = Config::new(EthernetAddress(GATEWAY_MAC).into());
    let mut iface = Interface::new(iface_cfg, &mut device, now());
    let gw = u32_v4(cfg.gateway_ip);
    iface.update_ip_addrs(|a| {
        let _ = a.push(IpCidr::new(IpAddress::Ipv4(gw), cfg.prefix_len));
    });
    iface.set_any_ip(true);
    let _ = iface.routes_mut().add_default_ipv4_route(gw); // accept foreign-dst (NAT)

    let mut sockets = SocketSet::new(Vec::new());

    // DNS responder socket on the gateway, UDP :53.
    let dns_handle = {
        let rx = udp::PacketBuffer::new(vec![udp::PacketMetadata::EMPTY; 16], vec![0u8; 64 * 1024]);
        let tx = udp::PacketBuffer::new(vec![udp::PacketMetadata::EMPTY; 16], vec![0u8; 64 * 1024]);
        let mut s = udp::Socket::new(rx, tx);
        let _ = s.bind(IpListenEndpoint { addr: Some(IpAddress::Ipv4(gw)), port: 53 });
        sockets.add(s)
    };
    let upstreams = dns::system_resolvers();

    // kqueue + the always-watched fds.
    let kq = unsafe { libc::kqueue() };
    set_nonblocking(fd);
    kq_arm(kq, fd, libc::EVFILT_READ, true);
    kq_arm(kq, wakeup_r, libc::EVFILT_READ, true);

    // Reactor state.
    let mut tcp_by_fd: HashMap<RawFd, Tcp> = HashMap::new();
    let mut pending: HashMap<SocketHandle, ConnKey> = HashMap::new(); // outbound, pre-connect
    let mut syn_keys: HashSet<ConnKey> = HashSet::new();
    let mut listeners: HashMap<u16, (RawFd, u16)> = HashMap::new(); // host_port → (listener fd, guest_port)
    let mut listener_fd_to_port: HashMap<RawFd, u16> = HashMap::new();
    let mut udp_listeners: HashMap<(u32, u16), (SocketHandle, StdInstant)> = HashMap::new();
    let mut udp_flows: HashMap<ConnKey, (RawFd, StdInstant)> = HashMap::new();
    let mut udp_fd_to_key: HashMap<RawFd, ConnKey> = HashMap::new();
    let mut dns_pending: HashMap<RawFd, (IpEndpoint, StdInstant)> = HashMap::new();
    let mut ephemeral: u16 = 49152;

    sink.log(2, &format!("velox-net: reactor up — TCP+UDP NAT, DNS, ports (upstreams {:?})", upstreams));

    let mut events: Vec<libc::kevent> = (0..256).map(|_| empty_kevent()).collect();
    let mut last_sweep = StdInstant::now();

    while !stop.load(Ordering::Relaxed) {
        // Block until an fd is ready or the next smoltcp timer fires.
        let timeout = iface.poll_delay(now(), &sockets).map(|d| {
            Duration::from_micros(d.total_micros())
        });
        let n = kq_wait(kq, &mut events, timeout);
        if stop.load(Ordering::Relaxed) {
            break;
        }

        let mut frame_ready = false;
        let mut accept_ready: Vec<(RawFd, u16)> = Vec::new();
        let mut tcp_readable: Vec<RawFd> = Vec::new();
        let mut tcp_writable: Vec<RawFd> = Vec::new();
        let mut udp_reply: Vec<RawFd> = Vec::new();
        let mut dns_reply: Vec<RawFd> = Vec::new();

        for ev in &events[..n] {
            let efd = ev.ident as RawFd;
            if efd == fd {
                frame_ready = true;
            } else if efd == wakeup_r {
                drain_pipe(wakeup_r);
            } else if let Some(&port) = listener_fd_to_port.get(&efd) {
                accept_ready.push((efd, port));
            } else if dns_pending.contains_key(&efd) {
                dns_reply.push(efd);
            } else if udp_fd_to_key.contains_key(&efd) {
                udp_reply.push(efd);
            } else if tcp_by_fd.contains_key(&efd) {
                if ev.filter == libc::EVFILT_READ {
                    tcp_readable.push(efd);
                } else if ev.filter == libc::EVFILT_WRITE {
                    tcp_writable.push(efd);
                }
            }
        }

        // Control commands (expose/unexpose published ports).
        apply_commands(&cmds, kq, &mut listeners, &mut listener_fd_to_port, &sink);

        // Accept inbound connections on published ports.
        for (lfd, gport) in accept_ready {
            accept_inbound(lfd, gport, kq, &mut iface, &mut sockets, &mut tcp_by_fd, cfg, &mut ephemeral);
        }

        // Guest frames → device (pre-parse new outbound SYN/UDP to create sockets).
        if frame_ready {
            device.pump_in(|frame| {
                if let Some(key) = parse_syn(frame) {
                    if !syn_keys.contains(&key) {
                        let h = sockets.add(make_tcp_listener(key.2, key.3));
                        syn_keys.insert(key);
                        pending.insert(h, key);
                    }
                } else if let Some((_, _, dip, dport)) = parse_udp(frame) {
                    if !(dip == cfg.gateway_ip && dport == 53)
                        && !udp_listeners.contains_key(&(dip, dport))
                    {
                        let h = sockets.add(make_udp_listener(dip, dport));
                        udp_listeners.insert((dip, dport), (h, StdInstant::now()));
                    }
                }
            });
        }

        // Host TCP: connect completion / write side.
        for efd in tcp_writable {
            host_writable(efd, kq, &mut sockets, &mut tcp_by_fd);
        }
        // Host TCP: read side → to_guest.
        for efd in tcp_readable {
            host_readable(efd, kq, &mut tcp_by_fd);
        }
        // Host UDP replies → guest.
        for efd in udp_reply {
            udp_host_reply(efd, &mut sockets, &mut udp_listeners, &udp_fd_to_key);
        }
        // Async DNS upstream replies → guest.
        for efd in dns_reply {
            dns_upstream_reply(efd, kq, &mut sockets, dns_handle, &mut dns_pending);
        }

        // Poll #1: process inbound guest frames (populates smoltcp rx + sends any
        // already-queued tx). Then service every flow: drain rx → host, push host
        // data → smoltcp tx, answer DNS, relay UDP. Poll #2: flush the tx we just
        // queued out to the guest before blocking again.
        let _ = iface.poll(now(), &mut device, &mut sockets);
        service_tcp(kq, &mut sockets, &mut tcp_by_fd, &mut pending, &mut syn_keys, cfg, &mut ephemeral);
        service_dns(kq, &mut sockets, dns_handle, cfg, &upstreams, &mut dns_pending);
        service_udp_listeners(&mut sockets, kq, &mut udp_listeners, &mut udp_flows, &mut udp_fd_to_key, cfg);
        let _ = iface.poll(now(), &mut device, &mut sockets);

        // Periodic expiry of idle UDP flows/listeners and stale DNS forwards.
        if last_sweep.elapsed() >= Duration::from_secs(5) {
            last_sweep = StdInstant::now();
            sweep_udp(&mut sockets, kq, &mut udp_listeners, &mut udp_flows, &mut udp_fd_to_key);
            sweep_dns(kq, &mut dns_pending);
        }
    }

    unsafe {
        libc::close(kq);
        libc::close(wakeup_r);
        libc::close(fd);
    }
    sink.log(2, "velox-net: stopped");
}

// =================== TCP NAT ===================

fn make_tcp_listener(dst_ip: u32, dst_port: u16) -> tcp::Socket<'static> {
    let rx = tcp::SocketBuffer::new(vec![0u8; TCP_BUF]);
    let tx = tcp::SocketBuffer::new(vec![0u8; TCP_BUF]);
    let mut s = tcp::Socket::new(rx, tx);
    let _ = s.listen(IpListenEndpoint { addr: Some(IpAddress::Ipv4(u32_v4(dst_ip))), port: dst_port });
    s
}

/// Promote established outbound listeners to connected flows; service smoltcp rx/tx
/// for every flow with proper backpressure; reap finished flows.
fn service_tcp(
    kq: RawFd,
    sockets: &mut SocketSet,
    tcp_by_fd: &mut HashMap<RawFd, Tcp>,
    pending: &mut HashMap<SocketHandle, ConnKey>,
    syn_keys: &mut HashSet<ConnKey>,
    cfg: VnConfig,
    _ephemeral: &mut u16,
) {
    // Outbound: a guest SYN created a listening smoltcp socket. Once Established,
    // dial the real host (non-blocking) and turn it into a flow.
    let mut promote: Vec<(SocketHandle, ConnKey)> = Vec::new();
    let mut drop_pending: Vec<SocketHandle> = Vec::new();
    for (&h, &key) in pending.iter() {
        match sockets.get::<tcp::Socket>(h).state() {
            tcp::State::Established => promote.push((h, key)),
            tcp::State::Closed => drop_pending.push(h),
            _ => {}
        }
    }
    for h in drop_pending {
        if let Some(k) = pending.remove(&h) {
            syn_keys.remove(&k);
        }
        sockets.remove(h);
    }
    for (h, key) in promote {
        pending.remove(&h);
        match tcp_connect_nb(key.2, key.3, cfg.gateway_ip) {
            Some(hfd) => {
                set_nonblocking(hfd);
                kq_arm(kq, hfd, libc::EVFILT_READ, true);
                kq_arm(kq, hfd, libc::EVFILT_WRITE, true); // detect connect completion
                tcp_by_fd.insert(hfd, Tcp {
                    handle: h, fd: hfd, key, connecting: true, established: true,
                    to_host: Vec::new(), to_guest: Vec::new(), host_eof: false,
                    guest_fin_done: false, fin_to_guest_done: false,
                    read_armed: true, write_armed: true,
                });
            }
            None => {
                sockets.get_mut::<tcp::Socket>(h).abort();
                syn_keys.remove(&key);
                sockets.remove(h);
            }
        }
    }

    // Service every connected flow.
    let mut reap: Vec<RawFd> = Vec::new();
    for (&hfd, t) in tcp_by_fd.iter_mut() {
        if t.connecting {
            continue; // waiting on the host writable (connect) event
        }
        // inbound: wait for the guest connect to establish
        if !t.established {
            match sockets.get::<tcp::Socket>(t.handle).state() {
                tcp::State::Established => t.established = true,
                tcp::State::Closed => { reap.push(hfd); continue; }
                _ => continue,
            }
        }
        let sock = sockets.get_mut::<tcp::Socket>(t.handle);

        // host→guest: drain to_guest into smoltcp tx; re-arm host READ if it drains.
        while !t.to_guest.is_empty() && sock.can_send() {
            match sock.send_slice(&t.to_guest) {
                Ok(0) => break,
                Ok(written) => { t.to_guest.drain(..written); }
                Err(_) => break,
            }
        }
        if t.to_guest.len() < BUF_CAP && !t.read_armed && !t.host_eof {
            kq_arm(kq, hfd, libc::EVFILT_READ, true);
            t.read_armed = true;
        }

        // guest→host: pull smoltcp rx into to_host (bounded), then write to host.
        let mut buf = [0u8; 64 * 1024];
        while sock.can_recv() && t.to_host.len() < BUF_CAP {
            match sock.recv_slice(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(got) => t.to_host.extend_from_slice(&buf[..got]),
            }
        }
        flush_to_host(kq, hfd, t);

        // half-close: guest FIN → shutdown host write; host EOF → smoltcp close.
        if !t.guest_fin_done && !sock.may_recv() && t.to_host.is_empty() {
            unsafe { libc::shutdown(hfd, libc::SHUT_WR) };
            t.guest_fin_done = true;
        }
        if t.host_eof && t.to_guest.is_empty() && !t.fin_to_guest_done {
            sock.close();
            t.fin_to_guest_done = true;
        }
        if sock.state() == tcp::State::Closed && t.to_host.is_empty() && t.to_guest.is_empty() {
            reap.push(hfd);
        }
    }
    for hfd in reap {
        if let Some(t) = tcp_by_fd.remove(&hfd) {
            syn_keys.remove(&t.key);
            sockets.remove(t.handle);
            unsafe { libc::close(t.fd) };
        }
    }
}

/// Write as much of to_host as possible; manage WRITE interest + EOF.
fn flush_to_host(kq: RawFd, hfd: RawFd, t: &mut Tcp) {
    while !t.to_host.is_empty() {
        match fd_write(hfd, &t.to_host) {
            Io::N(w) => { t.to_host.drain(..w); }
            Io::Block => {
                if !t.write_armed {
                    kq_arm(kq, hfd, libc::EVFILT_WRITE, true);
                    t.write_armed = true;
                }
                return;
            }
            Io::Eof => { t.host_eof = true; t.to_host.clear(); return; }
        }
    }
    if t.write_armed {
        kq_arm(kq, hfd, libc::EVFILT_WRITE, false);
        t.write_armed = false;
    }
}

fn host_writable(efd: RawFd, kq: RawFd, sockets: &mut SocketSet, tcp_by_fd: &mut HashMap<RawFd, Tcp>) {
    let Some(t) = tcp_by_fd.get_mut(&efd) else { return };
    if t.connecting {
        let err = so_error(efd);
        if err == 0 {
            t.connecting = false;
            // Keep WRITE armed only if we have pending data; otherwise disarm.
            if t.to_host.is_empty() && t.write_armed {
                kq_arm(kq, efd, libc::EVFILT_WRITE, false);
                t.write_armed = false;
            }
        } else {
            // Connect failed → RST the guest and let service_tcp reap it.
            sockets.get_mut::<tcp::Socket>(t.handle).abort();
            t.host_eof = true;
        }
        return;
    }
    flush_to_host(kq, efd, t);
}

fn host_readable(efd: RawFd, kq: RawFd, tcp_by_fd: &mut HashMap<RawFd, Tcp>) {
    let Some(t) = tcp_by_fd.get_mut(&efd) else { return };
    let mut buf = [0u8; 64 * 1024];
    loop {
        if t.to_guest.len() >= BUF_CAP {
            // smoltcp can't take more yet; stop reading until it drains.
            if t.read_armed {
                kq_arm(kq, efd, libc::EVFILT_READ, false);
                t.read_armed = false;
            }
            break;
        }
        match fd_read(efd, &mut buf) {
            Io::N(got) => t.to_guest.extend_from_slice(&buf[..got]),
            Io::Block => break,
            Io::Eof => { t.host_eof = true; break; }
        }
    }
}

fn tcp_connect_nb(dst_ip: u32, dst_port: u16, gateway_ip: u32) -> Option<RawFd> {
    let ip = if dst_ip == gateway_ip { 0x7F00_0001 } else { dst_ip }; // host.docker.internal → loopback
    let fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return None;
    }
    set_nonblocking(fd);
    let addr = sockaddr_in_be(ip, dst_port);
    let r = unsafe {
        libc::connect(fd, &addr as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_in>() as u32)
    };
    if r == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EINPROGRESS) {
        Some(fd)
    } else {
        unsafe { libc::close(fd) };
        None
    }
}

fn accept_inbound(
    lfd: RawFd,
    guest_port: u16,
    kq: RawFd,
    iface: &mut Interface,
    sockets: &mut SocketSet,
    tcp_by_fd: &mut HashMap<RawFd, Tcp>,
    cfg: VnConfig,
    ephemeral: &mut u16,
) {
    loop {
        let cfd = unsafe { libc::accept(lfd, std::ptr::null_mut(), std::ptr::null_mut()) };
        if cfd < 0 {
            break; // EWOULDBLOCK / drained
        }
        set_nonblocking(cfd);
        let mut s = tcp::Socket::new(
            tcp::SocketBuffer::new(vec![0u8; TCP_BUF]),
            tcp::SocketBuffer::new(vec![0u8; TCP_BUF]),
        );
        let local_port = next_ephemeral(ephemeral);
        let remote = IpEndpoint { addr: IpAddress::Ipv4(u32_v4(cfg.guest_ip)), port: guest_port };
        let local = IpListenEndpoint { addr: Some(IpAddress::Ipv4(u32_v4(cfg.gateway_ip))), port: local_port };
        if s.connect(iface.context(), remote, local).is_err() {
            unsafe { libc::close(cfd) };
            continue;
        }
        let h = sockets.add(s);
        kq_arm(kq, cfd, libc::EVFILT_READ, true);
        let key = (cfg.gateway_ip, local_port, cfg.guest_ip, guest_port);
        tcp_by_fd.insert(cfd, Tcp {
            handle: h, fd: cfd, key, connecting: false, established: false,
            to_host: Vec::new(), to_guest: Vec::new(), host_eof: false,
            guest_fin_done: false, fin_to_guest_done: false,
            read_armed: true, write_armed: false,
        });
    }
}

// =================== published ports (commands) ===================

fn apply_commands(
    cmds: &Arc<Mutex<Vec<Cmd>>>,
    kq: RawFd,
    listeners: &mut HashMap<u16, (RawFd, u16)>,
    listener_fd_to_port: &mut HashMap<RawFd, u16>,
    sink: &LogSink,
) {
    let drained: Vec<Cmd> = match cmds.lock() {
        Ok(mut q) => std::mem::take(&mut *q),
        Err(_) => return,
    };
    for c in drained {
        match c {
            Cmd::Expose { proto, host_port, guest_port } => {
                if proto != 0 || listeners.contains_key(&host_port) {
                    continue; // TCP only; ignore dup
                }
                match bind_listener(host_port) {
                    Some(lfd) => {
                        kq_arm(kq, lfd, libc::EVFILT_READ, true);
                        listeners.insert(host_port, (lfd, guest_port));
                        listener_fd_to_port.insert(lfd, host_port);
                        sink.log(2, &format!("expose tcp 127.0.0.1:{host_port} -> guest:{guest_port}"));
                    }
                    None => sink.log(1, &format!("expose tcp :{host_port} failed to bind")),
                }
            }
            Cmd::Unexpose { proto, host_port } => {
                if proto != 0 {
                    continue;
                }
                if let Some((lfd, _)) = listeners.remove(&host_port) {
                    kq_arm(kq, lfd, libc::EVFILT_READ, false);
                    listener_fd_to_port.remove(&lfd);
                    unsafe { libc::close(lfd) };
                    sink.log(2, &format!("unexpose tcp :{host_port}"));
                }
            }
        }
    }
}

fn bind_listener(port: u16) -> Option<RawFd> {
    let fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return None;
    }
    let yes: libc::c_int = 1;
    unsafe {
        libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_REUSEADDR, &yes as *const _ as *const _, 4);
    }
    let addr = sockaddr_in_be(0x7F00_0001, port); // 127.0.0.1
    let r = unsafe {
        libc::bind(fd, &addr as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_in>() as u32)
    };
    if r != 0 || unsafe { libc::listen(fd, 128) } != 0 {
        unsafe { libc::close(fd) };
        return None;
    }
    set_nonblocking(fd);
    Some(fd)
}

// =================== DNS (async) ===================

fn service_dns(
    kq: RawFd,
    sockets: &mut SocketSet,
    dns_handle: SocketHandle,
    cfg: VnConfig,
    upstreams: &[std::net::Ipv4Addr],
    dns_pending: &mut HashMap<RawFd, (IpEndpoint, StdInstant)>,
) {
    loop {
        let query = {
            let s = sockets.get_mut::<udp::Socket>(dns_handle);
            match s.recv() {
                Ok((data, meta)) => Some((data.to_vec(), meta.endpoint)),
                Err(_) => None,
            }
        };
        let Some((q, reply_to)) = query else { break };
        // Internal names answered immediately; everything else forwarded async.
        if let Some(resp) = dns::handle_internal(&q, cfg.gateway_ip, cfg.guest_ip) {
            let _ = sockets.get_mut::<udp::Socket>(dns_handle).send_slice(&resp, reply_to);
        } else if let Some(up) = upstreams.first() {
            if let Some(ufd) = dns_forward_start(&q, *up) {
                kq_arm(kq, ufd, libc::EVFILT_READ, true);
                dns_pending.insert(ufd, (reply_to, StdInstant::now()));
            }
        }
    }
}

fn dns_forward_start(query: &[u8], upstream: std::net::Ipv4Addr) -> Option<RawFd> {
    let fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0) };
    if fd < 0 {
        return None;
    }
    set_nonblocking(fd);
    let o = upstream.octets();
    let ip = u32::from_be_bytes(o);
    let addr = sockaddr_in_be(ip, 53);
    let sent = unsafe {
        libc::sendto(fd, query.as_ptr() as *const _, query.len(), 0,
            &addr as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_in>() as u32)
    };
    if sent < 0 {
        unsafe { libc::close(fd) };
        return None;
    }
    Some(fd)
}

fn dns_upstream_reply(
    efd: RawFd,
    kq: RawFd,
    sockets: &mut SocketSet,
    dns_handle: SocketHandle,
    dns_pending: &mut HashMap<RawFd, (IpEndpoint, StdInstant)>,
) {
    let Some((reply_to, _)) = dns_pending.remove(&efd) else { return };
    let mut buf = [0u8; 2048];
    let n = unsafe { libc::recv(efd, buf.as_mut_ptr() as *mut _, buf.len(), 0) };
    if n > 0 {
        let _ = sockets.get_mut::<udp::Socket>(dns_handle).send_slice(&buf[..n as usize], reply_to);
    }
    kq_arm(kq, efd, libc::EVFILT_READ, false);
    unsafe { libc::close(efd) };
}

fn sweep_dns(kq: RawFd, dns_pending: &mut HashMap<RawFd, (IpEndpoint, StdInstant)>) {
    let stale: Vec<RawFd> = dns_pending
        .iter()
        .filter(|(_, (_, t))| t.elapsed() >= DNS_TIMEOUT)
        .map(|(&fd, _)| fd)
        .collect();
    for fd in stale {
        dns_pending.remove(&fd);
        kq_arm(kq, fd, libc::EVFILT_READ, false);
        unsafe { libc::close(fd) };
    }
}

// =================== UDP NAT ===================

fn make_udp_listener(dst_ip: u32, dst_port: u16) -> udp::Socket<'static> {
    let rx = udp::PacketBuffer::new(vec![udp::PacketMetadata::EMPTY; 32], vec![0u8; 256 * 1024]);
    let tx = udp::PacketBuffer::new(vec![udp::PacketMetadata::EMPTY; 32], vec![0u8; 256 * 1024]);
    let mut s = udp::Socket::new(rx, tx);
    let _ = s.bind(IpListenEndpoint { addr: Some(IpAddress::Ipv4(u32_v4(dst_ip))), port: dst_port });
    s
}

/// Drain each UDP NAT socket (guest→host) and forward datagrams to the real dst,
/// registering the host UDP socket so replies wake the reactor.
fn service_udp_listeners(
    sockets: &mut SocketSet,
    kq: RawFd,
    udp_listeners: &mut HashMap<(u32, u16), (SocketHandle, StdInstant)>,
    udp_flows: &mut HashMap<ConnKey, (RawFd, StdInstant)>,
    udp_fd_to_key: &mut HashMap<RawFd, ConnKey>,
    cfg: VnConfig,
) {
    for (&(dip, dport), (handle, last)) in udp_listeners.iter_mut() {
        loop {
            let pkt = {
                let s = sockets.get_mut::<udp::Socket>(*handle);
                match s.recv() {
                    Ok((data, meta)) => Some((data.to_vec(), meta.endpoint)),
                    Err(_) => None,
                }
            };
            let Some((data, src)) = pkt else { break };
            *last = StdInstant::now();
            let key = (ipv4_u32(src.addr), src.port, dip, dport);
            let hfd = match udp_flows.get_mut(&key) {
                Some((fd, t)) => { *t = StdInstant::now(); *fd }
                None => match udp_connect(dip, dport, cfg.gateway_ip) {
                    Some(fd) => {
                        kq_arm(kq, fd, libc::EVFILT_READ, true);
                        udp_flows.insert(key, (fd, StdInstant::now()));
                        udp_fd_to_key.insert(fd, key);
                        fd
                    }
                    None => continue,
                },
            };
            unsafe { libc::send(hfd, data.as_ptr() as *const _, data.len(), 0) };
        }
    }
}

fn udp_host_reply(
    efd: RawFd,
    sockets: &mut SocketSet,
    udp_listeners: &mut HashMap<(u32, u16), (SocketHandle, StdInstant)>,
    udp_fd_to_key: &HashMap<RawFd, ConnKey>,
) {
    let Some(&(src_ip, src_port, dip, dport)) = udp_fd_to_key.get(&efd) else { return };
    let Some((handle, last)) = udp_listeners.get_mut(&(dip, dport)) else { return };
    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = unsafe { libc::recv(efd, buf.as_mut_ptr() as *mut _, buf.len(), 0) };
        if n <= 0 {
            break;
        }
        *last = StdInstant::now();
        let dst = IpEndpoint { addr: IpAddress::Ipv4(u32_v4(src_ip)), port: src_port };
        let _ = sockets.get_mut::<udp::Socket>(*handle).send_slice(&buf[..n as usize], dst);
    }
}

fn udp_connect(dst_ip: u32, dst_port: u16, gateway_ip: u32) -> Option<RawFd> {
    let ip = if dst_ip == gateway_ip { 0x7F00_0001 } else { dst_ip };
    let fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0) };
    if fd < 0 {
        return None;
    }
    set_nonblocking(fd);
    let addr = sockaddr_in_be(ip, dst_port);
    let r = unsafe {
        libc::connect(fd, &addr as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_in>() as u32)
    };
    if r != 0 {
        unsafe { libc::close(fd) };
        return None;
    }
    Some(fd)
}

fn sweep_udp(
    sockets: &mut SocketSet,
    kq: RawFd,
    udp_listeners: &mut HashMap<(u32, u16), (SocketHandle, StdInstant)>,
    udp_flows: &mut HashMap<ConnKey, (RawFd, StdInstant)>,
    udp_fd_to_key: &mut HashMap<RawFd, ConnKey>,
) {
    let dead: Vec<ConnKey> = udp_flows
        .iter()
        .filter(|(_, (_, t))| t.elapsed() >= UDP_IDLE)
        .map(|(&k, _)| k)
        .collect();
    for k in dead {
        if let Some((fd, _)) = udp_flows.remove(&k) {
            udp_fd_to_key.remove(&fd);
            kq_arm(kq, fd, libc::EVFILT_READ, false);
            unsafe { libc::close(fd) };
        }
    }
    let idle: Vec<(u32, u16)> = udp_listeners
        .iter()
        .filter(|(&(dip, dport), (_, t))| {
            t.elapsed() >= UDP_IDLE && !udp_flows.keys().any(|kk| kk.2 == dip && kk.3 == dport)
        })
        .map(|(&k, _)| k)
        .collect();
    for k in idle {
        if let Some((h, _)) = udp_listeners.remove(&k) {
            sockets.remove(h);
        }
    }
}

// =================== packet parsing ===================

fn parse_syn(f: &[u8]) -> Option<ConnKey> {
    let (s, sp, d, dp, t) = parse_l4(f, 6)?;
    let flags = *f.get(t + 13)?;
    if flags & 0x02 != 0 && flags & 0x10 == 0 {
        Some((s, sp, d, dp))
    } else {
        None
    }
}

fn parse_udp(f: &[u8]) -> Option<ConnKey> {
    let (s, sp, d, dp, _) = parse_l4(f, 17)?;
    Some((s, sp, d, dp))
}

/// Parse an IPv4 frame of L4 `proto`, returning (src_ip, src_port, dst_ip, dst_port,
/// l4_offset). Hand-rolled to avoid depending on smoltcp wire enum names.
fn parse_l4(f: &[u8], proto: u8) -> Option<(u32, u16, u32, u16, usize)> {
    if f.len() < 14 + 20 + 8 || f[12] != 0x08 || f[13] != 0x00 {
        return None;
    }
    let ihl = (f[14] & 0x0f) as usize * 4;
    if ihl < 20 || f.get(14 + 9) != Some(&proto) {
        return None;
    }
    let src_ip = u32::from_be_bytes([f[26], f[27], f[28], f[29]]);
    let dst_ip = u32::from_be_bytes([f[30], f[31], f[32], f[33]]);
    let t = 14 + ihl;
    if f.len() < t + 4 {
        return None;
    }
    let src_port = u16::from_be_bytes([f[t], f[t + 1]]);
    let dst_port = u16::from_be_bytes([f[t + 2], f[t + 3]]);
    Some((src_ip, src_port, dst_ip, dst_port, t))
}

fn next_ephemeral(e: &mut u16) -> u16 {
    let p = *e;
    *e = if *e >= 65535 { 49152 } else { *e + 1 };
    p
}

fn ipv4_u32(a: IpAddress) -> u32 {
    let IpAddress::Ipv4(v4) = a;
    u32::from_be_bytes(v4.octets())
}

fn u32_v4(ip: u32) -> Ipv4Address {
    let o = ip.to_be_bytes();
    Ipv4Address::new(o[0], o[1], o[2], o[3])
}

// =================== libc plumbing ===================

enum Io {
    N(usize),
    Block,
    Eof,
}

fn fd_read(fd: RawFd, buf: &mut [u8]) -> Io {
    let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut _, buf.len()) };
    if n > 0 {
        Io::N(n as usize)
    } else if n == 0 {
        Io::Eof
    } else if std::io::Error::last_os_error().raw_os_error() == Some(libc::EAGAIN) {
        Io::Block
    } else {
        Io::Eof
    }
}

fn fd_write(fd: RawFd, buf: &[u8]) -> Io {
    let n = unsafe { libc::write(fd, buf.as_ptr() as *const _, buf.len()) };
    if n > 0 {
        Io::N(n as usize)
    } else if n < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::EAGAIN) {
        Io::Block
    } else {
        Io::Eof
    }
}

fn set_nonblocking(fd: RawFd) {
    unsafe {
        let fl = libc::fcntl(fd, libc::F_GETFL, 0);
        if fl >= 0 {
            libc::fcntl(fd, libc::F_SETFL, fl | libc::O_NONBLOCK);
        }
    }
}

fn so_error(fd: RawFd) -> i32 {
    let mut err: libc::c_int = 0;
    let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
    unsafe {
        libc::getsockopt(fd, libc::SOL_SOCKET, libc::SO_ERROR, &mut err as *mut _ as *mut _, &mut len);
    }
    err
}

fn sockaddr_in_be(ip_host_order: u32, port_host_order: u16) -> libc::sockaddr_in {
    libc::sockaddr_in {
        sin_len: std::mem::size_of::<libc::sockaddr_in>() as u8,
        sin_family: libc::AF_INET as libc::sa_family_t,
        sin_port: port_host_order.to_be(),
        sin_addr: libc::in_addr { s_addr: ip_host_order.to_be() },
        sin_zero: [0; 8],
    }
}

fn drain_pipe(fd: RawFd) {
    let mut buf = [0u8; 64];
    loop {
        let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut _, buf.len()) };
        if n <= 0 {
            break;
        }
    }
}

fn empty_kevent() -> libc::kevent {
    libc::kevent { ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: std::ptr::null_mut() }
}

fn kq_arm(kq: RawFd, fd: RawFd, filter: i16, on: bool) {
    let ev = libc::kevent {
        ident: fd as libc::uintptr_t,
        filter,
        flags: if on { libc::EV_ADD | libc::EV_ENABLE } else { libc::EV_DELETE },
        fflags: 0,
        data: 0,
        udata: std::ptr::null_mut(),
    };
    unsafe {
        libc::kevent(kq, &ev, 1, std::ptr::null_mut(), 0, std::ptr::null());
    }
}

fn kq_wait(kq: RawFd, events: &mut [libc::kevent], timeout: Option<Duration>) -> usize {
    let ts;
    let tsp = match timeout {
        Some(d) => {
            ts = libc::timespec { tv_sec: d.as_secs() as libc::time_t, tv_nsec: d.subsec_nanos() as _ };
            &ts as *const libc::timespec
        }
        None => std::ptr::null(),
    };
    let n = unsafe {
        libc::kevent(kq, std::ptr::null(), 0, events.as_mut_ptr(), events.len() as libc::c_int, tsp)
    };
    if n < 0 {
        0
    } else {
        n as usize
    }
}
