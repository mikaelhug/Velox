//! smoltcp `Device` over the AF_UNIX SOCK_DGRAM frame socket shared with VZ.
//!
//! Queue-backed: the run loop calls `pump_in` to drain all pending frames from
//! the fd (pre-parsing each, e.g. to create a listening socket for a new outbound
//! SYN's destination) before `iface.poll` consumes them via `receive`. `transmit`
//! writes frames straight back to the fd. Datagram boundaries == frame boundaries.

use crate::Stats;
use smoltcp::phy::{Device, DeviceCapabilities, Medium, RxToken, TxToken};
use smoltcp::time::Instant;
use std::collections::VecDeque;
use std::os::fd::RawFd;
use std::sync::atomic::Ordering;
use std::sync::Arc;

pub struct FrameDevice {
    fd: RawFd,
    mtu: usize,
    stats: Arc<Stats>,
    rx: VecDeque<Vec<u8>>,
}

impl FrameDevice {
    pub fn new(fd: RawFd, mtu: usize, stats: Arc<Stats>) -> Self {
        Self { fd, mtu, stats, rx: VecDeque::new() }
    }

    /// Drain all currently-available frames from the fd into the rx queue,
    /// invoking `on_frame` for each so the caller can pre-process (e.g. create a
    /// per-destination listener for an outbound SYN) before smoltcp polls.
    pub fn pump_in<F: FnMut(&[u8])>(&mut self, mut on_frame: F) {
        loop {
            let mut buf = vec![0u8; self.mtu + 18];
            let n = unsafe {
                libc::recv(self.fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len(), 0)
            };
            if n <= 0 {
                break; // EAGAIN (drained) or error
            }
            buf.truncate(n as usize);
            self.stats.rx_frames.fetch_add(1, Ordering::Relaxed);
            self.stats.rx_bytes.fetch_add(n as u64, Ordering::Relaxed);
            on_frame(&buf);
            self.rx.push_back(buf);
        }
    }
}

impl Device for FrameDevice {
    type RxToken<'a> = FrameRxToken;
    type TxToken<'a> = FrameTxToken;

    fn receive(&mut self, _t: Instant) -> Option<(FrameRxToken, FrameTxToken)> {
        let frame = self.rx.pop_front()?;
        Some((
            FrameRxToken { buf: frame },
            FrameTxToken { fd: self.fd, stats: self.stats.clone() },
        ))
    }

    fn transmit(&mut self, _t: Instant) -> Option<FrameTxToken> {
        Some(FrameTxToken { fd: self.fd, stats: self.stats.clone() })
    }

    fn capabilities(&self) -> DeviceCapabilities {
        let mut c = DeviceCapabilities::default();
        c.medium = Medium::Ethernet;
        c.max_transmission_unit = self.mtu;
        c
    }
}

pub struct FrameRxToken {
    buf: Vec<u8>,
}
impl RxToken for FrameRxToken {
    fn consume<R, F: FnOnce(&[u8]) -> R>(self, f: F) -> R {
        f(&self.buf)
    }
}

pub struct FrameTxToken {
    fd: RawFd,
    stats: Arc<Stats>,
}
impl TxToken for FrameTxToken {
    fn consume<R, F: FnOnce(&mut [u8]) -> R>(self, len: usize, f: F) -> R {
        let mut buf = vec![0u8; len];
        let r = f(&mut buf);
        let n = unsafe { libc::send(self.fd, buf.as_ptr() as *const libc::c_void, len, 0) };
        if n > 0 {
            self.stats.tx_frames.fetch_add(1, Ordering::Relaxed);
            self.stats.tx_bytes.fetch_add(n as u64, Ordering::Relaxed);
        }
        r
    }
}
