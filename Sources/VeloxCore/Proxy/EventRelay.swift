import Foundation

/// A non-blocking, event-driven bidirectional relay for the conduit datapath. A small fixed
/// pool of `kqueue` worker threads multiplexes *many* client↔conduit pairs each, so hundreds
/// of concurrent connections are handled by ~a dozen threads instead of two-per-connection.
/// That removes the thread-per-connection explosion that blew up tail latency and
/// connection-churn under real serving load — while large reads keep bulk throughput.
///
/// Half-close is preserved (one direction EOF → `shutdown(peer, SHUT_WR)`, the other keeps
/// flowing), and backpressure is handled (a stalled write disables reads on the source until
/// the peer drains), so a slow consumer can't balloon memory.
///
/// **The** byte relay for the process: the published-port conduit fast path AND the
/// Docker-API socket proxy (via `VsockBridge`) both splice through here. There was a second
/// implementation (`SocketPump`, DispatchIO-based) doing the identical job; keeping both
/// meant fd ownership, half-close, backpressure and teardown ordering had to be solved twice,
/// and the 2026-08 audit found each solved wrongly in a different way. One mechanism per job.
public final class EventRelay: @unchecked Sendable {
    public static let shared = EventRelay()

    private let workers: [RelayWorker]
    private let rrLock = NSLock()
    private var rr = 0

    public init(workerCount: Int = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)) {
        // Keep only workers whose loop actually came up, so `relay` can never hand a
        // connection to a worker that will never service it.
        workers = (0..<workerCount).compactMap { _ in
            let w = RelayWorker()
            return w.start() ? w : nil
        }
        if workers.isEmpty { Log.error("event relay: no workers started — conduit relay is unavailable") }
    }

    /// Take ownership of `a` and `b` and relay between them until both sides close; `onClose`
    /// fires once when both fds are closed. The fds are made non-blocking.
    public func relay(_ a: Int32, _ b: Int32, onClose: @escaping @Sendable () -> Void) {
        // Round-robin over the workers whose loop is still alive. A retired worker would
        // accept the pair and never register it — the connection would hang open forever.
        rrLock.lock()
        var picked: RelayWorker?
        for _ in 0..<max(workers.count, 1) {
            guard !workers.isEmpty else { break }
            let w = workers[rr % workers.count]; rr += 1
            if w.isAlive { picked = w; break }
        }
        rrLock.unlock()
        guard let w = picked else {
            Log.error("event relay: no live worker — dropping the connection")
            close(a); close(b); onClose(); return
        }
        w.add(a, b, onClose)
    }

    /// Close every relayed pair (engine stop). Without this, an established published-port
    /// connection keeps pumping into a VM that is going away and only unwinds when its fds
    /// finally error — which in the long-lived GUI process means live fds surviving into the
    /// next start. The worker threads themselves stay: this is a process-wide pool, they are
    /// parked in `kevent` costing nothing, and the next engine reuses them.
    public func stopAll() {
        for w in workers { w.dropAll() }
    }
}

// MARK: - one direction's state (src → dst)

private final class RelayDir {
    /// Bulk ceiling — the backpressure bound: at most this many bytes are in flight toward
    /// `dst` before the next read waits for the peer to drain.
    static let maxCap = 256 * 1024
    /// First allocation. Most connections never become bulk streams.
    static let initialCap = 32 * 1024

    let src: Int32
    let dst: Int32
    private(set) var cap = 0
    private(set) var buf: UnsafeMutableRawPointer?
    var pendOff = 0
    var pendLen = 0          // pending bytes [pendOff, pendLen) to write to dst
    var eof = false          // src reached EOF (and, since we only read when pendLen==0, drained)
    init(src: Int32, dst: Int32) { self.src = src; self.dst = dst }
    deinit { buf?.deallocate() }
    var finished: Bool { eof && pendLen == 0 }

    /// Allocate on first read, not at registration.
    ///
    /// This used to allocate 256 KiB per direction eagerly — 512 KiB per connection whether
    /// or not a single byte ever flowed. Acceptable for a handful of bulk conduits; ruinous
    /// for the Docker-API path this relay now also serves, whose connections are mostly
    /// long-lived and IDLE (`logs -f`, `exec -it`, a BuildKit `/session`): 256 of them would
    /// have cost ~128 MiB of untouched buffers. `SocketPump`, which that path used before,
    /// cost ~0 when idle, so migrating without this would have been a straight regression.
    func buffer() -> UnsafeMutableRawPointer {
        if let b = buf { return b }
        cap = Self.initialCap
        let b = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
        buf = b
        return b
    }

    /// A read that filled the buffer means bulk traffic — take the full size. Only ever at a
    /// safe point (nothing pending), so no in-flight bytes are lost.
    func growIfSaturated(_ n: Int) {
        guard pendLen == 0, n == cap, cap < Self.maxCap else { return }
        buf?.deallocate()
        cap = Self.maxCap
        buf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
    }

    /// Release the buffer once this direction is done, rather than holding it until the whole
    /// pair tears down (a half-closed direction can idle for a long time).
    func releaseBuffer() {
        guard pendLen == 0, let b = buf else { return }
        b.deallocate(); buf = nil; cap = 0
    }
}

private final class RelayConn {
    let a: Int32
    let b: Int32
    let ab: RelayDir   // a → b
    let ba: RelayDir   // b → a
    let onClose: @Sendable () -> Void
    init(a: Int32, b: Int32, onClose: @escaping @Sendable () -> Void) {
        self.a = a; self.b = b
        ab = RelayDir(src: a, dst: b)
        ba = RelayDir(src: b, dst: a)
        self.onClose = onClose
    }
}

// MARK: - worker: a kqueue loop owning many conns, single-threaded (no per-conn locks)

private final class RelayWorker: @unchecked Sendable {
    private var kq: Int32 = -1
    /// Cleared when the kevent loop exits. Without it a worker whose loop died stayed in the
    /// pool, so `relay()` kept round-robining into it: the pair was never registered, the wake
    /// byte went to a pipe nobody read, and the client hung forever with both fds open and no
    /// EOF or RST — 1/N of every published-port connection, silently.
    private let aliveLock = NSLock()
    private var alive = false
    private var pipeR: Int32 = -1
    private var pipeW: Int32 = -1
    private var conns: [Int32: RelayConn] = [:]   // fd → conn (both fds map to it); worker-thread only
    private let addLock = NSLock()
    private var incoming: [RelayConn] = []         // registrations from other threads
    private var dropAllRequested = false            // set by `dropAll`, serviced on the loop

    var isAlive: Bool { aliveLock.lock(); defer { aliveLock.unlock() }; return alive }

    @discardableResult
    func start() -> Bool {
        kq = kqueue()
        guard kq >= 0 else {
            Log.error("event relay: kqueue() failed (\(errno)) — this worker will not start")
            return false
        }
        var fds: [Int32] = [-1, -1]
        // Check the result: on failure the fds stayed 0 and the worker registered *stdin*
        // as its wakeup pipe, so every keystroke woke the relay and `dropAll` silently
        // wrote to fd 0.
        let ok = fds.withUnsafeMutableBufferPointer { pipe($0.baseAddress) } == 0
        guard ok else {
            Log.error("event relay: pipe() failed (\(errno)) — this worker will not start")
            close(kq); kq = -1
            return false
        }
        pipeR = fds[0]; pipeW = fds[1]
        // Both ends: `dropAll`/`add` write from arbitrary threads — including the main one
        // during teardown — and must never block if the loop is slow to drain.
        setNonBlocking(pipeR); setNonBlocking(pipeW)
        aliveLock.lock(); alive = true; aliveLock.unlock()
        Thread.detachNewThread { [self] in run() }
        return true
    }

    func add(_ a: Int32, _ b: Int32, _ onClose: @escaping @Sendable () -> Void) {
        let conn = RelayConn(a: a, b: b, onClose: onClose)
        addLock.lock(); incoming.append(conn); addLock.unlock()
        var byte: UInt8 = 1
        _ = write(pipeW, &byte, 1) // wake the loop
    }

    private func run() {
        setEvent(pipeR, EVFILT_READ, EV_ADD | EV_ENABLE)
        var events = Array<kevent>(repeating: kevent(), count: 512)
        while true {
            let n = kevent(kq, nil, 0, &events, 512, nil)
            if n < 0 { if errno == EINTR { continue }; break }
            if n == 0 { continue }
            for i in 0..<Int(n) {
                let ev = events[i]
                let fd = Int32(ev.ident)
                if fd == pipeR { drainPipe(); registerIncoming(); continue }
                guard let conn = conns[fd] else { continue }
                if Int32(ev.filter) == EVFILT_READ {
                    handleRead(conn, fd == conn.a ? conn.ab : conn.ba)
                } else if Int32(ev.filter) == EVFILT_WRITE {
                    handleWrite(conn, fd == conn.a ? conn.ba : conn.ab)
                }
            }
        }
        // The loop can only exit on an unrecoverable kevent error. Retire the worker and
        // release every pair it owns, so its connections fail fast instead of hanging and
        // `relay()` stops handing it new ones.
        Log.error("event relay: worker loop exited (\(errno)) — retiring it and dropping "
                  + "\(conns.count / 2) connection(s)")
        aliveLock.lock(); alive = false; aliveLock.unlock()
        while let conn = conns.values.first { teardown(conn) }
        close(kq); kq = -1
        close(pipeR); close(pipeW); pipeR = -1; pipeW = -1
    }

    private func drainPipe() {
        var tmp = [UInt8](repeating: 0, count: 256)
        while read(pipeR, &tmp, tmp.count) > 0 {}
    }

    /// Ask the loop to close every pair it owns. Runs on the loop (not the caller) so the
    /// `conns` map stays single-threaded, like every other mutation here.
    func dropAll() {
        // Take the not-yet-registered pairs here rather than leaving them for the loop, so
        // the drop applies only to what existed at this instant. Otherwise a pair added by
        // the NEXT engine, between this call and the loop servicing it, would be killed by
        // the previous engine's stop. They aren't in the kqueue yet, so closing them off the
        // loop thread is safe.
        addLock.lock()
        dropAllRequested = true
        let orphans = incoming; incoming.removeAll()
        addLock.unlock()
        for c in orphans { close(c.a); close(c.b); c.onClose() }
        var byte: UInt8 = 1
        _ = write(pipeW, &byte, 1) // wake the loop
    }

    private func registerIncoming() {
        addLock.lock()
        let batch = incoming; incoming.removeAll()
        let drop = dropAllRequested; dropAllRequested = false
        addLock.unlock()
        // `teardown` clears both fd keys, so this drains the map.
        if drop { while let conn = conns.values.first { teardown(conn) } }
        for conn in batch {
            setNonBlocking(conn.a); setNonBlocking(conn.b)
            conns[conn.a] = conn; conns[conn.b] = conn
            setEvent(conn.a, EVFILT_READ, EV_ADD | EV_ENABLE)
            setEvent(conn.b, EVFILT_READ, EV_ADD | EV_ENABLE)
        }
    }

    // src readable: drain it (read→write repeatedly) until EAGAIN or a partial write applies
    // backpressure. Draining per event keeps bulk throughput (few epoll/kqueue dispatches).
    private func handleRead(_ conn: RelayConn, _ dir: RelayDir) {
        if dir.pendLen > 0 { return } // currently flushing (read should be disabled)
        while true {
            let buf = dir.buffer()   // allocated on first use, not at registration
            let n = read(dir.src, buf, dir.cap)
            if n > 0 {
                let w = write(dir.dst, buf, n)
                if w == n { dir.growIfSaturated(n); continue } // fully written — keep draining
                dir.pendOff = w > 0 ? w : 0
                dir.pendLen = n
                setEvent(dir.src, EVFILT_READ, EV_DISABLE)
                setEvent(dir.dst, EVFILT_WRITE, EV_ADD | EV_ENABLE)
                return
            } else if n == 0 {
                dir.eof = true
                shutdown(dir.dst, SHUT_WR)
                setEvent(dir.src, EVFILT_READ, EV_DISABLE)
                dir.releaseBuffer()   // this direction is done; don't hold 32-256 KiB idle
                if conn.ab.finished && conn.ba.finished { teardown(conn) }
                return
            } else {
                if errno == EAGAIN || errno == EINTR { return }
                teardown(conn)
                return
            }
        }
    }

    // dst writable: flush the pending buffer; when drained, re-enable reads on src.
    private func handleWrite(_ conn: RelayConn, _ dir: RelayDir) {
        guard let buf = dir.buf else { return }   // nothing buffered
        while dir.pendOff < dir.pendLen {
            let w = write(dir.dst, buf.advanced(by: dir.pendOff), dir.pendLen - dir.pendOff)
            if w > 0 { dir.pendOff += w }
            else if w < 0 && (errno == EAGAIN || errno == EINTR) { return }
            else { teardown(conn); return }
        }
        dir.pendOff = 0; dir.pendLen = 0
        setEvent(dir.dst, EVFILT_WRITE, EV_DISABLE)
        if dir.eof { dir.releaseBuffer() } else { setEvent(dir.src, EVFILT_READ, EV_ENABLE) }
    }

    private func teardown(_ conn: RelayConn) {
        conns[conn.a] = nil; conns[conn.b] = nil
        close(conn.a); close(conn.b) // closing the fds removes their kevents
        conn.onClose()
    }

    private func setEvent(_ fd: Int32, _ filter: Int32, _ flags: Int32) {
        var kev = kevent()
        kev.ident = UInt(fd)
        kev.filter = Int16(truncatingIfNeeded: filter)
        kev.flags = UInt16(truncatingIfNeeded: flags)
        kev.fflags = 0; kev.data = 0; kev.udata = nil
        _ = kevent(kq, &kev, 1, nil, 0, nil)
    }

    private func setNonBlocking(_ fd: Int32) {
        let fl = fcntl(fd, F_GETFL, 0)
        if fl >= 0 { _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK) }
    }
}
