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
/// Used only for the published-port conduit path. The Docker-API proxy keeps `SocketPump`.
public final class EventRelay: @unchecked Sendable {
    public static let shared = EventRelay()

    private let workers: [RelayWorker]
    private let rrLock = NSLock()
    private var rr = 0

    public init(workerCount: Int = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)) {
        workers = (0..<workerCount).map { _ in RelayWorker() }
        for w in workers { w.start() }
    }

    /// Take ownership of `a` and `b` and relay between them until both sides close; `onClose`
    /// fires once when both fds are closed. The fds are made non-blocking.
    public func relay(_ a: Int32, _ b: Int32, onClose: @escaping @Sendable () -> Void) {
        rrLock.lock(); let w = workers[rr % workers.count]; rr += 1; rrLock.unlock()
        w.add(a, b, onClose)
    }
}

// MARK: - one direction's state (src → dst)

private final class RelayDir {
    let src: Int32
    let dst: Int32
    let cap = 256 * 1024
    let buf: UnsafeMutableRawPointer
    var pendOff = 0
    var pendLen = 0          // pending bytes [pendOff, pendLen) to write to dst
    var eof = false          // src reached EOF (and, since we only read when pendLen==0, drained)
    init(src: Int32, dst: Int32) {
        self.src = src; self.dst = dst
        buf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
    }
    deinit { buf.deallocate() }
    var finished: Bool { eof && pendLen == 0 }
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
    private let kq = kqueue()
    private var pipeR: Int32 = -1
    private var pipeW: Int32 = -1
    private var conns: [Int32: RelayConn] = [:]   // fd → conn (both fds map to it); worker-thread only
    private let addLock = NSLock()
    private var incoming: [RelayConn] = []         // registrations from other threads

    func start() {
        var fds: [Int32] = [0, 0]
        _ = fds.withUnsafeMutableBufferPointer { pipe($0.baseAddress) }
        pipeR = fds[0]; pipeW = fds[1]
        setNonBlocking(pipeR)
        Thread.detachNewThread { [self] in run() }
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
    }

    private func drainPipe() {
        var tmp = [UInt8](repeating: 0, count: 256)
        while read(pipeR, &tmp, tmp.count) > 0 {}
    }

    private func registerIncoming() {
        addLock.lock(); let batch = incoming; incoming.removeAll(); addLock.unlock()
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
            let n = read(dir.src, dir.buf, dir.cap)
            if n > 0 {
                let w = write(dir.dst, dir.buf, n)
                if w == n { continue } // fully written — keep draining the source
                dir.pendOff = w > 0 ? w : 0
                dir.pendLen = n
                setEvent(dir.src, EVFILT_READ, EV_DISABLE)
                setEvent(dir.dst, EVFILT_WRITE, EV_ADD | EV_ENABLE)
                return
            } else if n == 0 {
                dir.eof = true
                shutdown(dir.dst, SHUT_WR)
                setEvent(dir.src, EVFILT_READ, EV_DISABLE)
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
        while dir.pendOff < dir.pendLen {
            let w = write(dir.dst, dir.buf.advanced(by: dir.pendOff), dir.pendLen - dir.pendOff)
            if w > 0 { dir.pendOff += w }
            else if w < 0 && (errno == EAGAIN || errno == EINTR) { return }
            else { teardown(conn); return }
        }
        dir.pendOff = 0; dir.pendLen = 0
        setEvent(dir.dst, EVFILT_WRITE, EV_DISABLE)
        setEvent(dir.src, EVFILT_READ, EV_ENABLE)
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
