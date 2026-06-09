import Foundation

/// Bulk-optimized bidirectional relay for the VZNAT conduit datapath: one thread per
/// direction doing large blocking read/write with half-close. For a saturated bulk transfer
/// (the conduit's whole purpose) this is far cheaper per byte than `SocketPump`'s DispatchIO
/// small-chunk wakeups — measured to roughly halve host CPU at multi-Gbit/s. The cost is two
/// threads per active connection, which is fine for published ports: they're bounded by the
/// conduit pool and long-lived. Mirrors the guest's `pump()` (128 KiB blocking copy).
///
/// Hijacked Docker streams (`attach`/`exec`/`logs -f`) never use this path — they go over the
/// Docker API proxy on vsock via `SocketPump`, which keeps low-latency small-message handling.
final class BulkPump: @unchecked Sendable {
    private let fdA: Int32
    private let fdB: Int32
    private let onClose: @Sendable () -> Void
    private let lock = NSLock()
    private var done = 0
    private var closed = false

    init(fdA: Int32, fdB: Int32, onClose: @escaping @Sendable () -> Void) {
        self.fdA = fdA
        self.fdB = fdB
        self.onClose = onClose
    }

    func start() {
        // macOS/BSD `accept()` inherits the listener's O_NONBLOCK, so both fds may be
        // non-blocking — clear it, since this pump uses blocking read/write.
        Self.setBlocking(fdA)
        Self.setBlocking(fdB)
        Thread.detachNewThread { self.pump(from: self.fdA, to: self.fdB); self.finish() }
        Thread.detachNewThread { self.pump(from: self.fdB, to: self.fdA); self.finish() }
    }

    private static func setBlocking(_ fd: Int32) {
        let fl = fcntl(fd, F_GETFL, 0)
        if fl >= 0 { _ = fcntl(fd, F_SETFL, fl & ~O_NONBLOCK) }
    }

    /// Copy `from` → `to` until EOF/error, then half-close `to`'s write side so the peer
    /// observes EOF while the other direction keeps flowing (matches the guest pump).
    private func pump(from: Int32, to: Int32) {
        let cap = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
        defer { buf.deallocate() }
        while true {
            let n = read(from, buf, cap)
            if n <= 0 { break }
            var off = 0
            while off < n {
                let w = write(to, buf.advanced(by: off), n - off)
                if w <= 0 { shutdown(to, SHUT_WR); return }
                off += w
            }
        }
        shutdown(to, SHUT_WR)
    }

    /// Both directions done → close both fds and fire `onClose` exactly once.
    private func finish() {
        lock.lock()
        done += 1
        let shouldClose = (done == 2) && !closed
        if shouldClose { closed = true }
        lock.unlock()
        guard shouldClose else { return }
        close(fdA)
        close(fdB)
        onClose()
    }
}
