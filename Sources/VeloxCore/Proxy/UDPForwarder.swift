import Foundation

/// Maintains a `127.0.0.1:<port>` **UDP** listener on the Mac for each published
/// container UDP port (the datagram sibling of `PortForwarder`).
///
/// UDP is connectionless, so it can't reuse the TCP stream pump. Instead, per client
/// flow (keyed by source address+port) the host opens one VSOCK connection to the
/// guest reverse-relay with the header `"udp <port>\n"`, then tunnels each datagram
/// length-prefixed (`[u16 BE len][payload]`) in both directions. The guest dials the
/// published UDP port inside the guest (docker-proxy on 127.0.0.1:port, exactly like
/// the TCP path). Flows idle for `idleSeconds` are reclaimed.
///
/// Guest→host relaying for ALL flows is multiplexed on ONE lazy kqueue thread
/// (`RelayLoop`) instead of a thread per flow, so a source-port flood can't grow
/// threads; host→guest writes are non-blocking (a backed-up guest costs dropped
/// datagrams — UDP is lossy — never a stalled queue).
public final class UDPForwarder: @unchecked Sendable {
    private struct FlowKey: Hashable { let addr: UInt32; let port: UInt16 }

    /// Per-flow state. All mutable access is serialized on `queue` (the relay loop
    /// only holds the immutable fd/client copies handed over at registration), so the
    /// unchecked Sendable conformance is sound.
    private final class Flow: @unchecked Sendable {
        var vsockFd: Int32 = -1          // set once the VSOCK connection is ready
        var ready = false
        var registered = false           // guest→host side handed to the relay loop
        var token: UInt64 = 0            // relay-loop registration identity
        var pending: [[UInt8]] = []      // datagrams buffered during async connect
        var lastActive = Date()
        var client = sockaddr_in()
    }

    /// Mutated only on `queue`; captured by relay-loop completions that hop back here.
    private final class Listener: @unchecked Sendable {
        let fd: Int32
        let source: DispatchSourceRead
        var flows: [FlowKey: Flow] = [:]
        init(fd: Int32, source: DispatchSourceRead) { self.fd = fd; self.source = source }
    }

    private let manager: VMManager
    /// Source of loopback sockets for privileged (<1024) UDP ports (nil ⇒ skipped).
    private let privilegedBinder: PrivilegedPortBinder?
    private let queue = DispatchQueue(label: "dev.velox.udpfwd")
    private let relay = RelayLoop()
    private var listeners: [UInt16: Listener] = [:]
    /// Privileged ports already logged as "helper not ready" (warn-once; all on `queue`).
    private var warnedPrivileged: Set<UInt16> = []
    private let idleSeconds: TimeInterval
    private var reaper: DispatchSourceTimer?
    private let maxPending = 32
    /// Cap on concurrent client flows per published UDP port. Each flow holds a VSOCK
    /// connection (an fd on both sides), so without a ceiling a source-port flood to a
    /// published UDP port could exhaust descriptors. UDP is lossy — over the cap, new
    /// flows are dropped. 256 distinct live clients per port is well beyond real use.
    private let maxFlows = 256

    public init(manager: VMManager, idleSeconds: TimeInterval = 60, privilegedBinder: PrivilegedPortBinder? = nil) {
        self.manager = manager
        self.idleSeconds = idleSeconds
        self.privilegedBinder = privilegedBinder
    }

    /// Reconcile open UDP listeners against the desired set of published ports.
    public func reconcile(_ wanted: Set<UInt16>) {
        queue.async {
            let current = Set(self.listeners.keys)
            for port in wanted.subtracting(current) { self.open(port) }
            for port in current.subtracting(wanted) { self.closeListener(port) }
            self.updateReaper()
        }
    }

    public func stopAll() {
        queue.async {
            for port in Array(self.listeners.keys) { self.closeListener(port) }
            self.reaper?.cancel(); self.reaper = nil
        }
    }

    // MARK: - private (all on `queue` unless noted)

    private func open(_ port: UInt16) {
        let fd: Int32
        if port < 1024 {
            // Privileged UDP port: bound by the root helper (loopback, <1024).
            guard let pfd = privilegedBinder?.boundListener(port: port, proto: .udp) else {
                if warnedPrivileged.insert(port).inserted {
                    Log.warn("udp-forward: 127.0.0.1:\(port)/udp needs the privileged helper — not authorized yet")
                }
                return
            }
            fd = pfd
        } else {
            let s = socket(AF_INET, SOCK_DGRAM, 0)
            guard s >= 0 else { return }
            var yes: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                Log.warn("udp-forward: could not bind 127.0.0.1:\(port)/udp (errno \(errno))")
                Darwin.close(s); return
            }
            fd = s
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readDatagrams(port) }
        source.setCancelHandler { Darwin.close(fd) }
        let listener = Listener(fd: fd, source: source)
        listeners[port] = listener
        warnedPrivileged.remove(port)
        source.resume()
        Log.info("udp-forward: localhost:\(port)/udp → guest:\(port)/udp")
    }

    private func closeListener(_ port: UInt16) {
        warnedPrivileged.remove(port)
        guard let listener = listeners.removeValue(forKey: port) else { return }
        // Every flow must be deregistered from the relay loop BEFORE the shared UDP fd
        // closes: a sendto on a closed (kernel-reused) fd number could misdirect
        // datagrams into an unrelated socket. teardown() completes per flow once the
        // loop confirms; the last completion cancels the source (whose cancel handler
        // closes the fd). No flows ⇒ close immediately.
        let flows = listener.flows
        listener.flows = [:]
        guard !flows.isEmpty else {
            listener.source.cancel()
            Log.info("udp-forward: closed localhost:\(port)/udp")
            return
        }
        let remaining = Countdown(flows.count) {
            listener.source.cancel()
            Log.info("udp-forward: closed localhost:\(port)/udp")
        }
        for (_, flow) in flows { teardown(flow) { remaining.hit() } }
    }

    /// Drain all pending datagrams on a port's UDP socket, demultiplex by client.
    private func readDatagrams(_ port: UInt16) {
        guard let listener = listeners[port] else { return }
        var buf = [UInt8](repeating: 0, count: 65535)
        while true {
            var from = sockaddr_in()
            var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(listener.fd, &buf, buf.count, 0, sa, &flen)
                }
            }
            if n <= 0 { break }
            let datagram = Array(buf[0..<n])
            let key = FlowKey(addr: from.sin_addr.s_addr, port: from.sin_port)
            if let flow = listener.flows[key] {
                flow.lastActive = Date()
                if flow.ready {
                    if !Self.writeFrame(flow.vsockFd, datagram) {
                        // Mid-frame stall or hard error — the tunnel stream is desynced;
                        // kill the flow (the client's next datagram opens a fresh one).
                        reclaim(port: port, key: key)
                    }
                } else if flow.pending.count < maxPending { flow.pending.append(datagram) }
            } else if listener.flows.count >= maxFlows {
                continue // over the per-port flow cap — drop (UDP is lossy); bounds fds
            } else {
                let flow = Flow()
                flow.client = from
                flow.pending.append(datagram)
                listener.flows[key] = flow
                connect(flow, port: port, key: key)
            }
        }
    }

    /// Open the per-flow VSOCK connection (async), flush buffered datagrams, then hand
    /// the guest→host direction to the shared relay loop.
    private func connect(_ flow: Flow, port: UInt16, key: FlowKey) {
        manager.connectToGuestPort(VsockPort.reverse) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                // Flow may have been reclaimed while connecting.
                guard let listener = self.listeners[port], listener.flows[key] === flow else {
                    if case .success(let fd) = result { Darwin.close(fd) }
                    return
                }
                switch result {
                case .failure(let error):
                    Log.error("udp-forward: vsock connect failed: \(error.localizedDescription)")
                    listener.flows[key] = nil
                case .success(let vsockFd):
                    let header = Array("udp \(port)\n".utf8)
                    guard FDIO.writeAll(vsockFd, header) else { Darwin.close(vsockFd); listener.flows[key] = nil; return }
                    // Non-blocking from here on: reads run on the relay loop, and writes
                    // must never block the shared queue (writeFrame drops when full).
                    let fl = fcntl(vsockFd, F_GETFL, 0)
                    _ = fcntl(vsockFd, F_SETFL, fl | O_NONBLOCK)
                    flow.vsockFd = vsockFd
                    flow.ready = true
                    var desynced = false
                    for dg in flow.pending where !desynced { desynced = !Self.writeFrame(vsockFd, dg) }
                    flow.pending.removeAll()
                    if desynced {
                        Darwin.close(vsockFd)
                        flow.vsockFd = -1; flow.ready = false
                        listener.flows[key] = nil
                        return
                    }
                    flow.token = self.relay.add(
                        fd: vsockFd, listenerFd: listener.fd, client: flow.client,
                        touch: { [weak self] in self?.touch(port: port, key: key) },
                        onEOF: { [weak self] in
                            guard let self else { return }
                            self.queue.async { self.reclaim(port: port, key: key) }
                        })
                    flow.registered = true
                }
            }
        }
    }

    private func touch(port: UInt16, key: FlowKey) {
        queue.async { self.listeners[port]?.flows[key]?.lastActive = Date() }
    }

    /// Close + remove a single flow (idempotent).
    private func reclaim(port: UInt16, key: FlowKey) {
        guard let flow = listeners[port]?.flows.removeValue(forKey: key) else { return }
        teardown(flow)
    }

    /// Release a flow's VSOCK fd. A loop-registered fd is closed only AFTER the relay
    /// loop confirms deregistration — closing first would let the kernel reuse the fd
    /// number while the loop still maps it, aliasing an unrelated descriptor. `then`
    /// fires on `queue` once the fd is actually closed (immediately when unregistered).
    private func teardown(_ flow: Flow, then: (@Sendable () -> Void)? = nil) {
        let fd = flow.vsockFd
        flow.vsockFd = -1
        flow.ready = false
        if fd >= 0 && flow.registered {
            flow.registered = false
            relay.drop(fd: fd, token: flow.token) { [weak self] in
                guard let self else { Darwin.close(fd); then?(); return }
                self.queue.async { Darwin.close(fd); then?() }
            }
        } else {
            if fd >= 0 { Darwin.close(fd) }
            then?()
        }
    }

    /// Keep the idle-flow reaper in sync with the listener set: run a 30s inactivity
    /// sweep while any UDP port is published, and stop it once none are (so the timer
    /// doesn't keep firing on an empty listener set after the last port closes). UDP
    /// has no connection close to ride, so this sweep is the only timer — never a poll.
    private func updateReaper() {
        if listeners.isEmpty {
            reaper?.cancel()
            reaper = nil
            return
        }
        guard reaper == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.sweep() }
        reaper = timer
        timer.resume()
    }

    private func sweep() {
        let cutoff = Date().addingTimeInterval(-idleSeconds)
        for (_, listener) in listeners {
            for (key, flow) in listener.flows where flow.lastActive < cutoff {
                listener.flows[key] = nil
                teardown(flow)
            }
        }
    }

    // MARK: - host→guest framing (non-blocking fd; called on `queue`)

    /// Write `[u16 BE len][payload]` for one datagram to the NON-blocking vsock fd.
    /// A frame that can't start (EAGAIN with nothing written) is dropped whole — UDP
    /// is lossy, and dropping beats blocking the shared queue on a backed-up guest.
    /// A frame that has started MUST finish or the length-prefixed stream desyncs:
    /// poll for writability (bounded, ~1s) and keep going; on timeout or hard error
    /// return false so the caller kills the flow.
    private static func writeFrame(_ fd: Int32, _ payload: [UInt8]) -> Bool {
        var frame = [UInt8]()
        frame.reserveCapacity(payload.count + 2)
        frame.append(UInt8((payload.count >> 8) & 0xff))
        frame.append(UInt8(payload.count & 0xff))
        frame.append(contentsOf: payload)
        return frame.withUnsafeBytes { raw in
            var off = 0
            var waits = 0
            while off < frame.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), frame.count - off)
                if n > 0 { off += n; continue }
                if n < 0 && errno == EINTR { continue }
                guard n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else { return false }
                if off == 0 { return true }      // nothing sent — drop this datagram whole
                waits += 1
                guard waits <= 10 else { return false }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&pfd, 1, 100)
            }
            return true
        }
    }

    /// `n` completions (all on `queue`) then one `done` — used to defer a listener
    /// close until the relay loop has forgotten every flow.
    private final class Countdown: @unchecked Sendable {
        private var n: Int
        private let done: @Sendable () -> Void
        init(_ n: Int, done: @escaping @Sendable () -> Void) { self.n = n; self.done = done }
        func hit() { n -= 1; if n == 0 { done() } }
    }
}

// MARK: - the shared guest→host relay loop

/// One kqueue thread (started lazily on the first flow) multiplexing every flow's
/// guest→host stream: parses the `[u16 BE len][payload]` framing incrementally across
/// partial reads and `sendto`s each complete datagram back to the originating client.
/// Registration/deregistration arrives over a wakeup pipe (the same pattern as
/// `EventRelay`'s RelayWorker). The loop NEVER closes fds — the forwarder queue owns
/// every close, and only after this loop confirms deregistration, so a kernel-reused
/// fd number can never alias another flow.
private final class RelayLoop: @unchecked Sendable {
    struct Registration {
        let fd: Int32
        let token: UInt64
        let listenerFd: Int32
        let client: sockaddr_in
        let touch: @Sendable () -> Void
        let onEOF: @Sendable () -> Void
    }

    /// Loop-thread only.
    private final class Entry {
        let reg: Registration
        var hdr = [UInt8](repeating: 0, count: 2)
        var payload = [UInt8](repeating: 0, count: 65535)
        var got = 0                    // bytes of the current header/payload read so far
        var need = 0                   // payload length (valid once the header completed)
        var inHeader = true
        var lastTouch = Date.distantPast
        init(_ reg: Registration) { self.reg = reg }
    }

    private enum Command {
        case add(Registration)
        case drop(fd: Int32, token: UInt64, done: @Sendable () -> Void)
    }

    private let kq = kqueue()
    private var pipeR: Int32 = -1
    private var pipeW: Int32 = -1
    private let lock = NSLock()
    private var commands: [Command] = []     // guarded by `lock`
    private var started = false              // guarded by `lock`
    private var nextToken: UInt64 = 1        // guarded by `lock`
    private var entries: [Int32: Entry] = [:]   // loop-thread only

    /// Register a flow's vsock fd (must already be non-blocking). Returns the token
    /// that `drop` needs (registration identity — fd numbers get reused).
    func add(fd: Int32, listenerFd: Int32, client: sockaddr_in,
             touch: @escaping @Sendable () -> Void,
             onEOF: @escaping @Sendable () -> Void) -> UInt64 {
        lock.lock()
        let token = nextToken
        nextToken += 1
        commands.append(.add(Registration(fd: fd, token: token, listenerFd: listenerFd,
                                          client: client, touch: touch, onEOF: onEOF)))
        let needStart = !started
        started = true
        lock.unlock()
        if needStart { start() }
        wake()
        return token
    }

    /// Deregister; `done` fires (from the loop thread) once the fd is guaranteed out of
    /// the loop's map — only then may the owner close it. Always fires, even when the
    /// entry is already gone (EOF beat the drop).
    func drop(fd: Int32, token: UInt64, done: @escaping @Sendable () -> Void) {
        lock.lock()
        let running = started
        if running { commands.append(.drop(fd: fd, token: token, done: done)) }
        lock.unlock()
        if running { wake() } else { done() }
    }

    private func start() {
        var fds: [Int32] = [0, 0]
        _ = fds.withUnsafeMutableBufferPointer { pipe($0.baseAddress) }
        pipeR = fds[0]; pipeW = fds[1]
        let fl = fcntl(pipeR, F_GETFL, 0)
        _ = fcntl(pipeR, F_SETFL, fl | O_NONBLOCK)
        Thread.detachNewThread { [self] in run() }
    }

    private func wake() {
        var byte: UInt8 = 1
        _ = write(pipeW, &byte, 1)
    }

    private func run() {
        setEvent(pipeR, EVFILT_READ, EV_ADD | EV_ENABLE)
        var events = Array<kevent>(repeating: kevent(), count: 128)
        while true {
            let n = kevent(kq, nil, 0, &events, 128, nil)
            if n < 0 { if errno == EINTR { continue }; break }
            for i in 0..<Int(n) {
                let fd = Int32(events[i].ident)
                if fd == pipeR { drainPipe(); runCommands(); continue }
                guard let entry = entries[fd] else { continue }   // stale event — ignore
                handleReadable(fd, entry)
            }
        }
    }

    private func drainPipe() {
        var tmp = [UInt8](repeating: 0, count: 256)
        while read(pipeR, &tmp, tmp.count) > 0 {}
    }

    private func runCommands() {
        lock.lock()
        let batch = commands
        commands.removeAll()
        lock.unlock()
        for cmd in batch {
            switch cmd {
            case .add(let reg):
                entries[reg.fd] = Entry(reg)
                setEvent(reg.fd, EVFILT_READ, EV_ADD | EV_ENABLE)
            case .drop(let fd, let token, let done):
                if let e = entries[fd], e.reg.token == token {
                    entries[fd] = nil
                    setEvent(fd, EVFILT_READ, EV_DELETE)
                }
                done()
            }
        }
    }

    /// Drain the fd: advance the header/payload state machine across however many
    /// partial reads it takes, delivering each completed datagram, until EAGAIN.
    private func handleReadable(_ fd: Int32, _ entry: Entry) {
        while true {
            let n: Int
            if entry.inHeader {
                let got = entry.got
                n = entry.hdr.withUnsafeMutableBytes { raw in
                    read(fd, raw.baseAddress!.advanced(by: got), 2 - got)
                }
            } else {
                let got = entry.got
                let need = entry.need
                n = entry.payload.withUnsafeMutableBytes { raw in
                    read(fd, raw.baseAddress!.advanced(by: got), need - got)
                }
            }
            if n > 0 {
                entry.got += n
                if entry.inHeader {
                    if entry.got == 2 {
                        entry.need = Int(entry.hdr[0]) << 8 | Int(entry.hdr[1])
                        entry.got = 0
                        // A zero-length frame is a keepalive — stay in the header state.
                        if entry.need > 0 { entry.inHeader = false }
                    }
                } else if entry.got == entry.need {
                    deliver(entry)
                    entry.got = 0
                    entry.need = 0
                    entry.inHeader = true
                }
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            // EOF or hard error: forget the fd and hand the flow back for reclaim
            // (the forwarder tears down and closes — see the ownership note above).
            entries[fd] = nil
            setEvent(fd, EVFILT_READ, EV_DELETE)
            entry.reg.onEOF()
            return
        }
    }

    private func deliver(_ entry: Entry) {
        var client = entry.reg.client
        let need = entry.need
        _ = entry.payload.withUnsafeBytes { raw in
            withUnsafePointer(to: &client) { cp in
                cp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(entry.reg.listenerFd, raw.baseAddress, need, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        // Idle-tracking ping, throttled to ≤1 queue hop per second per flow so a
        // high-rate stream doesn't flood the forwarder queue with touch tasks.
        let now = Date()
        if now.timeIntervalSince(entry.lastTouch) >= 1 {
            entry.lastTouch = now
            entry.reg.touch()
        }
    }

    private func setEvent(_ fd: Int32, _ filter: Int32, _ flags: Int32) {
        var kev = kevent()
        kev.ident = UInt(fd)
        kev.filter = Int16(truncatingIfNeeded: filter)
        kev.flags = UInt16(truncatingIfNeeded: flags)
        kev.fflags = 0; kev.data = 0; kev.udata = nil
        _ = kevent(kq, &kev, 1, nil, 0, nil)
    }
}
