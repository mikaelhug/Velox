//! velox-net — Velox's host-side userspace network stack.
//!
//! A `staticlib` linked IN-PROCESS into the Swift host (no subprocess, no Go). It
//! receives the guest's raw ethernet frames over an AF_UNIX SOCK_DGRAM socket
//! shared with `VZFileHandleNetworkDeviceAttachment`, and (in later milestones)
//! NATs outbound TCP/UDP/ICMP to the host, answers DNS, and forwards published
//! ports — replacing VZNAT + the guest DHCP client + the polling port-forwarder.
//!
//! This file is the C ABI surface ONLY. With `panic = "abort"`, a panic crossing
//! the boundary is fatal, so every exported function is written to be panic-free
//! (validate pointers, no indexing/unwrap on attacker-influenced data).

mod device;
mod dns;
mod stack;

use std::ffi::{c_char, c_int, c_void, CString};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

/// Control commands from Swift to the stack thread (drained each poll iteration).
pub enum Cmd {
    Expose { proto: i32, host_port: u16, guest_port: u16 },
    Unexpose { proto: i32, host_port: u16 },
}

/// Static configuration passed at start. Plain POD; copied internally.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct VnConfig {
    /// Gateway (this stack's) IPv4 in host byte order, e.g. 0xC0A8_7F01 = 192.168.127.1.
    pub gateway_ip: u32,
    /// Guest's static IPv4 in host byte order, e.g. 0xC0A8_7F02 = 192.168.127.2.
    pub guest_ip: u32,
    /// Subnet prefix length, e.g. 24.
    pub prefix_len: u8,
    /// Link MTU, e.g. 1500.
    pub mtu: u16,
}

/// Counter snapshot returned by `velox_net_stats`.
#[repr(C)]
#[derive(Default)]
pub struct VnStats {
    pub rx_frames: u64,
    pub tx_frames: u64,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
}

/// Internal live counters (atomics; read lock-free by `velox_net_stats`).
#[derive(Default)]
pub struct Stats {
    pub rx_frames: AtomicU64,
    pub tx_frames: AtomicU64,
    pub rx_bytes: AtomicU64,
    pub tx_bytes: AtomicU64,
}

/// Log callback: level (0=err,1=warn,2=info,3=debug), NUL-terminated message valid
/// only for the duration of the call, plus the opaque context pointer.
pub type VnLogFn = Option<extern "C" fn(c_int, *const c_char, *mut c_void)>;

/// Carries the Swift log callback onto the stack thread. The context pointer is
/// owned by the caller (the Swift `NetworkStack`) for the stack's lifetime.
#[derive(Clone, Copy)]
pub struct LogSink {
    f: VnLogFn,
    ctx: *mut c_void,
}
// Safety: the Swift side keeps `ctx` (a retained object) alive until velox_net_stop.
unsafe impl Send for LogSink {}
impl LogSink {
    pub fn log(&self, level: i32, msg: &str) {
        if let Some(f) = self.f {
            if let Ok(c) = CString::new(msg) {
                f(level as c_int, c.as_ptr(), self.ctx);
            }
        }
    }
}

/// Opaque handle returned to Swift.
pub struct VeloxNet {
    stop: Arc<AtomicBool>,
    stats: Arc<Stats>,
    cmds: Arc<Mutex<Vec<Cmd>>>,
    thread: Option<JoinHandle<()>>,
}

/// Start the stack on `frame_fd` (this end of the socketpair; ownership is taken —
/// it is closed by `velox_net_stop`). Returns NULL on failure.
#[no_mangle]
pub extern "C" fn velox_net_start(
    frame_fd: c_int,
    cfg: *const VnConfig,
    log: VnLogFn,
    log_ctx: *mut c_void,
) -> *mut VeloxNet {
    if cfg.is_null() || frame_fd < 0 {
        return std::ptr::null_mut();
    }
    let cfg = unsafe { *cfg };

    // The frame socket must be non-blocking so the poll loop never stalls.
    unsafe {
        let fl = libc::fcntl(frame_fd, libc::F_GETFL, 0);
        if fl >= 0 {
            libc::fcntl(frame_fd, libc::F_SETFL, fl | libc::O_NONBLOCK);
        }
    }

    let stop = Arc::new(AtomicBool::new(false));
    let stats = Arc::new(Stats::default());
    let cmds = Arc::new(Mutex::new(Vec::new()));
    let sink = LogSink { f: log, ctx: log_ctx };
    let (stop_t, stats_t, cmds_t) = (stop.clone(), stats.clone(), cmds.clone());

    let thread = std::thread::Builder::new()
        .name("velox-net".to_string())
        .spawn(move || stack::run(frame_fd, cfg, stop_t, stats_t, cmds_t, sink))
        .ok();

    match thread {
        Some(thread) => Box::into_raw(Box::new(VeloxNet {
            stop,
            stats,
            cmds,
            thread: Some(thread),
        })),
        None => std::ptr::null_mut(),
    }
}

/// Stop the stack: signal the loop, join the thread, close the fd, free the handle.
/// Idempotent against NULL.
#[no_mangle]
pub extern "C" fn velox_net_stop(h: *mut VeloxNet) {
    if h.is_null() {
        return;
    }
    let mut net = unsafe { Box::from_raw(h) };
    net.stop.store(true, Ordering::SeqCst);
    if let Some(t) = net.thread.take() {
        let _ = t.join();
    }
    // Box dropped here.
}

/// Publish a host port (127.0.0.1:host_port) → guest_ip:guest_port. proto: 0=TCP, 1=UDP.
#[no_mangle]
pub extern "C" fn velox_net_expose(
    h: *mut VeloxNet,
    proto: c_int,
    host_port: u16,
    guest_port: u16,
) -> c_int {
    if h.is_null() {
        return -1;
    }
    let net = unsafe { &*h };
    if let Ok(mut q) = net.cmds.lock() {
        q.push(Cmd::Expose { proto, host_port, guest_port });
        0
    } else {
        -1
    }
}

/// Remove a published host port.
#[no_mangle]
pub extern "C" fn velox_net_unexpose(h: *mut VeloxNet, proto: c_int, host_port: u16) -> c_int {
    if h.is_null() {
        return -1;
    }
    let net = unsafe { &*h };
    if let Ok(mut q) = net.cmds.lock() {
        q.push(Cmd::Unexpose { proto, host_port });
        0
    } else {
        -1
    }
}

/// Copy current counters into `out`. Returns 0 on success, -1 on bad args.
#[no_mangle]
pub extern "C" fn velox_net_stats(h: *const VeloxNet, out: *mut VnStats) -> c_int {
    if h.is_null() || out.is_null() {
        return -1;
    }
    let net = unsafe { &*h };
    let s = &net.stats;
    unsafe {
        (*out).rx_frames = s.rx_frames.load(Ordering::Relaxed);
        (*out).tx_frames = s.tx_frames.load(Ordering::Relaxed);
        (*out).rx_bytes = s.rx_bytes.load(Ordering::Relaxed);
        (*out).tx_bytes = s.tx_bytes.load(Ordering::Relaxed);
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    /// End-to-end M0 check: feed the stack a real ARP request over the frame
    /// socket and confirm smoltcp answers (proves the device + poll loop +
    /// interface all work, no VM required).
    #[test]
    fn arp_request_to_gateway_is_answered() {
        let mut fds = [0i32; 2];
        assert_eq!(
            unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_DGRAM, 0, fds.as_mut_ptr()) },
            0
        );
        let (vz, net) = (fds[0], fds[1]);
        let tv = libc::timeval { tv_sec: 2, tv_usec: 0 };
        unsafe {
            libc::setsockopt(vz, libc::SOL_SOCKET, libc::SO_RCVTIMEO,
                &tv as *const _ as *const libc::c_void,
                std::mem::size_of::<libc::timeval>() as u32);
        }

        let cfg = VnConfig { gateway_ip: 0xC0A8_7F01, guest_ip: 0xC0A8_7F02, prefix_len: 24, mtu: 1500 };
        let h = velox_net_start(vz_dup_into(net), &cfg, None, std::ptr::null_mut());
        assert!(!h.is_null());

        // ARP: who-has 192.168.127.1, tell 192.168.127.2 (guest mac 02:..:02).
        let guest_mac = [0x02u8, 0x00, 0x00, 0x00, 0x00, 0x02];
        let mut f = Vec::new();
        f.extend_from_slice(&[0xff; 6]);          // dst broadcast
        f.extend_from_slice(&guest_mac);          // src
        f.extend_from_slice(&[0x08, 0x06]);       // ethertype ARP
        f.extend_from_slice(&[0x00, 0x01, 0x08, 0x00, 6, 4, 0x00, 0x01]); // hdr + request
        f.extend_from_slice(&guest_mac);          // sha
        f.extend_from_slice(&[192, 168, 127, 2]); // spa
        f.extend_from_slice(&[0x00; 6]);          // tha
        f.extend_from_slice(&[192, 168, 127, 1]); // tpa
        assert_eq!(
            unsafe { libc::send(vz, f.as_ptr() as *const libc::c_void, f.len(), 0) },
            f.len() as isize
        );

        let mut buf = [0u8; 1518];
        let mut replied = false;
        for _ in 0..5 {
            let r = unsafe { libc::recv(vz, buf.as_mut_ptr() as *mut libc::c_void, buf.len(), 0) };
            if r < 42 { break; }
            // ethertype ARP + oper == reply(2) + sender-proto == gateway
            if buf[12] == 0x08 && buf[13] == 0x06 && buf[20] == 0x00 && buf[21] == 0x02 {
                assert_eq!(&buf[28..32], &[192, 168, 127, 1]);
                replied = true;
                break;
            }
        }
        assert!(replied, "gateway did not answer ARP");

        let mut s = VnStats::default();
        assert_eq!(velox_net_stats(h, &mut s), 0);
        assert!(s.rx_frames >= 1 && s.tx_frames >= 1, "stats not counting frames");

        velox_net_stop(h);
        unsafe { libc::close(vz) };
    }

    // The stack takes ownership of its fd; the test keeps `vz` for I/O. We pass the
    // stack its own end (`net`) — this just returns it (named for clarity).
    fn vz_dup_into(net: i32) -> i32 { net }
}
