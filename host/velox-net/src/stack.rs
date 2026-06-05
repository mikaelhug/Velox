//! The stack thread: owns the smoltcp `Interface` + `SocketSet` + `Device` and
//! runs the single-threaded poll loop. M1 implements:
//!   - outbound TCP NAT: each guest TCP connection is proxied to a real host
//!     `TcpStream` (gvisor-tap-vsock model), with half-close semantics;
//!   - a DNS responder on the gateway (internal names + forward to host resolvers);
//!   - ARP + ICMP echo to the gateway (from M0, still handled by smoltcp).
//!
//! Host-side I/O is non-blocking and serviced inline on this one thread — simple
//! and correct. Worker threads + zero-copy are the M5 throughput upgrade.

use crate::device::FrameDevice;
use crate::{dns, LogSink, Stats, VnConfig};
use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::socket::{tcp, udp};
use smoltcp::time::Instant;
use smoltcp::wire::{EthernetAddress, IpAddress, IpCidr, IpListenEndpoint, Ipv4Address};
use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::net::{Ipv4Addr, Shutdown, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

const GATEWAY_MAC: [u8; 6] = [0x52, 0x55, 0x00, 0x00, 0x00, 0x01];
const TCP_BUF: usize = 64 * 1024;
const CHUNK: usize = 16 * 1024;
const MAX_PENDING: usize = 256 * 1024;

/// 4-tuple identifying a guest TCP flow (src_ip, src_port, dst_ip, dst_port), all host byte order.
type ConnKey = (u32, u16, u32, u16);

struct TcpFlow {
    key: ConnKey,
    dst_ip: u32,
    dst_port: u16,
    host: Option<TcpStream>,
    to_host: Vec<u8>,  // guest→host bytes awaiting write to the host socket
    to_guest: Vec<u8>, // host→guest bytes awaiting send into smoltcp
    host_eof: bool,
    guest_fin: bool,      // we've shutdown(Write) the host after the guest's FIN
    closed_to_guest: bool, // we've sent a FIN to the guest after host EOF
}

impl TcpFlow {
    fn new(key: ConnKey) -> Self {
        TcpFlow {
            key,
            dst_ip: key.2,
            dst_port: key.3,
            host: None,
            to_host: Vec::new(),
            to_guest: Vec::new(),
            host_eof: false,
            guest_fin: false,
            closed_to_guest: false,
        }
    }
}

pub fn run(fd: i32, cfg: VnConfig, stop: Arc<AtomicBool>, stats: Arc<Stats>, sink: LogSink) {
    let start = std::time::Instant::now();
    let now = || Instant::from_micros(start.elapsed().as_micros() as i64);

    let mut device = FrameDevice::new(fd, cfg.mtu as usize, stats);
    let iface_cfg = Config::new(EthernetAddress(GATEWAY_MAC).into());
    let mut iface = Interface::new(iface_cfg, &mut device, now());
    let go = cfg.gateway_ip.to_be_bytes();
    let gateway_v4 = Ipv4Address::new(go[0], go[1], go[2], go[3]);
    iface.update_ip_addrs(|addrs| {
        let _ = addrs.push(IpCidr::new(IpAddress::Ipv4(gateway_v4), cfg.prefix_len));
    });
    // Accept traffic addressed to ANY destination (we terminate it as a NAT),
    // not just the gateway's own IP. smoltcp's any_ip only accepts a foreign-dst
    // packet when a route resolves it to one of our own IPs — so add a default
    // route whose next hop is the gateway itself (us). Without this, foreign-dst
    // SYNs are silently dropped while same-IP traffic (ARP/DNS) still works.
    iface.set_any_ip(true);
    let _ = iface.routes_mut().add_default_ipv4_route(gateway_v4);

    let mut sockets = SocketSet::new(Vec::new());

    // DNS responder socket on the gateway, UDP :53.
    let dns_handle = {
        let rx = udp::PacketBuffer::new(
            vec![udp::PacketMetadata::EMPTY; 16],
            vec![0u8; 64 * 1024],
        );
        let tx = udp::PacketBuffer::new(
            vec![udp::PacketMetadata::EMPTY; 16],
            vec![0u8; 64 * 1024],
        );
        let mut s = udp::Socket::new(rx, tx);
        let _ = s.bind(IpListenEndpoint { addr: Some(IpAddress::Ipv4(gateway_v4)), port: 53 });
        sockets.add(s)
    };

    let upstreams = dns::system_resolvers();
    let mut flows: HashMap<SocketHandle, TcpFlow> = HashMap::new();
    let mut keys: HashSet<ConnKey> = HashSet::new();

    sink.log(2, &format!("velox-net: M1 up — TCP NAT + DNS (upstreams {:?})", upstreams));

    while !stop.load(Ordering::Relaxed) {
        // 1) Drain inbound frames; create a listening socket for each new outbound SYN
        //    so smoltcp accepts the connection during poll().
        device.pump_in(|frame| {
            if let Some(key) = parse_syn(frame) {
                if !keys.contains(&key) {
                    let s = make_listener(key.2, key.3);
                    let h = sockets.add(s);
                    keys.insert(key);
                    flows.insert(h, TcpFlow::new(key));
                }
            }
        });

        // 2) Let smoltcp run its state machines (ARP/ICMP/TCP/UDP).
        let _ = iface.poll(now(), &mut device, &mut sockets);

        // 3) Service DNS.
        service_dns(&mut sockets, dns_handle, cfg.gateway_ip, cfg.guest_ip, &upstreams);

        // 4) Service TCP flows: dial newly-established ones, pump bytes, reap dead ones.
        service_tcp(&mut sockets, &mut flows, &mut keys, cfg.gateway_ip);

        // 5) Sleep until the next timer or an inbound frame (kqueue + wakeup is M5).
        let delay = iface
            .poll_delay(now(), &sockets)
            .map(|d| d.total_millis() as i32)
            .unwrap_or(50)
            .clamp(1, 50);
        let mut pfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        unsafe { libc::poll(&mut pfd, 1, delay) };
    }

    unsafe { libc::close(fd) };
    sink.log(2, "velox-net: stopped");
}

fn make_listener(dst_ip: u32, dst_port: u16) -> tcp::Socket<'static> {
    let rx = tcp::SocketBuffer::new(vec![0u8; TCP_BUF]);
    let tx = tcp::SocketBuffer::new(vec![0u8; TCP_BUF]);
    let mut s = tcp::Socket::new(rx, tx);
    let o = dst_ip.to_be_bytes();
    let dst = Ipv4Address::new(o[0], o[1], o[2], o[3]);
    let _ = s.listen(IpListenEndpoint { addr: Some(IpAddress::Ipv4(dst)), port: dst_port });
    s
}

/// Hand-rolled SYN detector (avoids depending on smoltcp wire enum names). Returns
/// the (src_ip, src_port, dst_ip, dst_port) of a pure TCP SYN, else None.
fn parse_syn(f: &[u8]) -> Option<ConnKey> {
    if f.len() < 14 + 20 + 20 {
        return None;
    }
    if f[12] != 0x08 || f[13] != 0x00 {
        return None; // not IPv4
    }
    let ihl = (f[14] & 0x0f) as usize * 4;
    if ihl < 20 || f.get(14 + 9) != Some(&6) {
        return None; // not TCP
    }
    let src_ip = u32::from_be_bytes([f[26], f[27], f[28], f[29]]);
    let dst_ip = u32::from_be_bytes([f[30], f[31], f[32], f[33]]);
    let t = 14 + ihl;
    if f.len() < t + 14 {
        return None;
    }
    let src_port = u16::from_be_bytes([f[t], f[t + 1]]);
    let dst_port = u16::from_be_bytes([f[t + 2], f[t + 3]]);
    let flags = f[t + 13];
    if flags & 0x02 != 0 && flags & 0x10 == 0 {
        Some((src_ip, src_port, dst_ip, dst_port))
    } else {
        None
    }
}

fn service_dns(
    sockets: &mut SocketSet,
    handle: SocketHandle,
    gateway_ip: u32,
    guest_ip: u32,
    upstreams: &[Ipv4Addr],
) {
    let sock = sockets.get_mut::<udp::Socket>(handle);
    loop {
        let pending = match sock.recv() {
            Ok((data, meta)) => Some((data.to_vec(), meta.endpoint)),
            Err(_) => None,
        };
        let Some((query, endpoint)) = pending else { break };
        if let Some(resp) = dns::handle(&query, gateway_ip, guest_ip, upstreams) {
            let _ = sock.send_slice(&resp, endpoint);
        }
    }
}

fn service_tcp(
    sockets: &mut SocketSet,
    flows: &mut HashMap<SocketHandle, TcpFlow>,
    keys: &mut HashSet<ConnKey>,
    gateway_ip: u32,
) {
    let mut remove: Vec<SocketHandle> = Vec::new();
    for (&h, flow) in flows.iter_mut() {
        let sock = sockets.get_mut::<tcp::Socket>(h);
        if flow.host.is_none() {
            match sock.state() {
                tcp::State::Established => match dial(flow.dst_ip, flow.dst_port, gateway_ip) {
                    Ok(stream) => flow.host = Some(stream),
                    Err(_) => {
                        sock.abort();
                        remove.push(h);
                        continue;
                    }
                },
                tcp::State::Closed => {
                    remove.push(h);
                    continue;
                }
                _ => continue, // still handshaking
            }
        }
        if pump_flow(sock, flow) {
            remove.push(h);
        }
    }
    for h in remove {
        if let Some(f) = flows.remove(&h) {
            keys.remove(&f.key);
        }
        sockets.remove(h);
    }
}

fn dial(dst_ip: u32, dst_port: u16, gateway_ip: u32) -> std::io::Result<TcpStream> {
    // Traffic to the gateway IP is host.docker.internal → reach host services on loopback.
    let ip = if dst_ip == gateway_ip {
        Ipv4Addr::new(127, 0, 0, 1)
    } else {
        let o = dst_ip.to_be_bytes();
        Ipv4Addr::new(o[0], o[1], o[2], o[3])
    };
    let addr = SocketAddr::from((ip, dst_port));
    let stream = TcpStream::connect_timeout(&addr, Duration::from_secs(5))?;
    stream.set_nonblocking(true)?;
    Ok(stream)
}

/// One service pass over a connected flow. Returns true when the flow is fully
/// done and should be removed. Mirrors the half-close pump used elsewhere in Velox.
fn pump_flow(sock: &mut tcp::Socket, flow: &mut TcpFlow) -> bool {
    let Some(host) = flow.host.as_mut() else { return false };

    // guest → host
    flush_to_host(host, &mut flow.to_host, &mut flow.host_eof);
    if flow.to_host.is_empty() {
        let mut buf = [0u8; CHUNK];
        while sock.can_recv() && flow.to_host.len() < MAX_PENDING {
            match sock.recv_slice(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => flow.to_host.extend_from_slice(&buf[..n]),
            }
        }
        flush_to_host(host, &mut flow.to_host, &mut flow.host_eof);
    }
    // guest closed its send side → half-close the host write side
    if !flow.guest_fin && !sock.may_recv() && flow.to_host.is_empty() {
        let _ = host.shutdown(Shutdown::Write);
        flow.guest_fin = true;
    }

    // host → guest
    flush_to_guest(sock, &mut flow.to_guest);
    if flow.to_guest.is_empty() && !flow.host_eof {
        let mut buf = [0u8; CHUNK];
        loop {
            if flow.to_guest.len() >= MAX_PENDING {
                break;
            }
            match host.read(&mut buf) {
                Ok(0) => {
                    flow.host_eof = true;
                    break;
                }
                Ok(n) => flow.to_guest.extend_from_slice(&buf[..n]),
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(_) => {
                    flow.host_eof = true;
                    break;
                }
            }
        }
        flush_to_guest(sock, &mut flow.to_guest);
    }
    // host closed → send FIN to the guest
    if flow.host_eof && flow.to_guest.is_empty() && !flow.closed_to_guest {
        sock.close();
        flow.closed_to_guest = true;
    }

    sock.state() == tcp::State::Closed && flow.to_host.is_empty() && flow.to_guest.is_empty()
}

fn flush_to_host(host: &mut TcpStream, buf: &mut Vec<u8>, host_eof: &mut bool) {
    if buf.is_empty() {
        return;
    }
    match host.write(buf) {
        Ok(0) => {}
        Ok(n) => {
            buf.drain(..n);
        }
        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
        Err(_) => *host_eof = true,
    }
}

fn flush_to_guest(sock: &mut tcp::Socket, buf: &mut Vec<u8>) {
    if buf.is_empty() || !sock.can_send() {
        return;
    }
    if let Ok(n) = sock.send_slice(buf) {
        buf.drain(..n);
    }
}
