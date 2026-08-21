import Foundation

/// Maintains a `<publishHostIP>:<port>` **UDP** listener on the Mac for each published
/// container UDP port (the datagram sibling of `PortForwarder`, and it binds the same
/// configured host address — all interfaces by default).
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
/// A client's address exactly as `recvfrom` reported it, with the length it reported.
/// A POD C struct on purpose: it is copied to the relay thread for every registration, and
/// modelling it as an enum or with `Data` would put retain/release traffic on that hot path.
/// Shared by `UDPForwarder` and its `RelayLoop`, hence file scope.
private struct ClientAddr {
    var storage = sockaddr_storage()
    var len: socklen_t = 0
}

public final class UDPForwarder: @unchecked Sendable {
    /// A client identity that is unambiguous across BOTH address families.
    ///
    /// Built from explicit fields, never by hashing `sockaddr_storage` bytes: `sin6_flowinfo`
    /// legitimately varies between datagrams from the same peer and the struct's tail padding
    /// is uninitialised, either of which would split one client into many flows — each holding
    /// a VSOCK fd on both sides — until the per-port flow cap started dropping traffic.
    /// `scope` keeps two link-local peers on different interfaces apart, and `listenerFd`
    /// keeps a v4 and a v6 client that happen to share a port from colliding.
    private struct FlowKey: Hashable {
        let listenerFd: Int32     // which socket it arrived on (v4 or v6 twin)
        let v6: Bool
        let addr: [UInt8]         // 4 bytes for v4, 16 for v6
        let port: UInt16
        let scope: UInt32         // sin6_scope_id; 0 for v4
    }

    /// Decompose a `recvfrom` result into a key. Returns nil for a family we don't serve.
    private static func flowKey(_ sa: sockaddr_storage, _ listenerFd: Int32) -> FlowKey? {
        var s = sa
        switch Int32(s.ss_family) {
        case AF_INET:
            return withUnsafeBytes(of: &s) { raw -> FlowKey? in
                let a = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee
                var ip = a.sin_addr.s_addr
                let bytes = withUnsafeBytes(of: &ip) { Array($0) }
                return FlowKey(listenerFd: listenerFd, v6: false, addr: bytes,
                               port: UInt16(bigEndian: a.sin_port), scope: 0)
            }
        case AF_INET6:
            return withUnsafeBytes(of: &s) { raw -> FlowKey? in
                let a = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self).pointee
                var ip = a.sin6_addr
                let bytes = withUnsafeBytes(of: &ip) { Array($0) }
                return FlowKey(listenerFd: listenerFd, v6: true, addr: bytes,
                               port: UInt16(bigEndian: a.sin6_port), scope: a.sin6_scope_id)
            }
        default:
            return nil
        }
    }

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
        var client = ClientAddr()
    }

    /// Mutated only on `queue`; captured by relay-loop completions that hop back here.
    private final class Listener: @unchecked Sendable {
        /// One entry per address family. TCP models this the same way
        /// (`PortForwarder.Listener.sources`); UDP additionally needs the fd itself, because
        /// unlike `accept` it both receives on and replies from the listening socket.
        let sockets: [(fd: Int32, source: DispatchSourceRead)]
        var flows: [FlowKey: Flow] = [:]
        /// What this listener was opened for, so a changed bind address rebinds.
        let spec: PublishedPort
        init(sockets: [(fd: Int32, source: DispatchSourceRead)], spec: PublishedPort) {
            self.sockets = sockets; self.spec = spec
        }
    }

    /// Reported when a published UDP port can't be served (true) or recovers (false), so the
    /// GUI badges it. TCP had this; UDP failures were a log line only, i.e. invisible.
    /// Note the store is keyed by port number alone, so a port published on both protocols
    /// shares one badge.
    public var onBindIssue: (@Sendable (UInt16, Bool) -> Void)?

    private let manager: VMManager
    /// Source of sockets for privileged (<1024) UDP ports (nil ⇒ skipped).
    private let privilegedBinder: PrivilegedPortBinder?
    /// Host address the listeners bind (default: all interfaces).
    private let publish: PublishBind
    private let queue = DispatchQueue(label: "dev.velox.udpfwd")
    private let relay = RelayLoop()
    private var listeners: [UInt16: Listener] = [:]
    /// Privileged ports already logged as "helper not ready" (warn-once; all on `queue`).
    private var warnedPrivileged: Set<UInt16> = []
    /// Privileged ports already warned about a specific `publishHostIP` (warn-once; on `queue`).
    private var warnedSpecificPrivileged: Set<UInt16> = []
    private let idleSeconds: TimeInterval
    private var reaper: DispatchSourceTimer?
    private let maxPending = 32
    /// Cap on concurrent client flows per published UDP port. Each flow holds a VSOCK
    /// connection (an fd on both sides), so without a ceiling a source-port flood to a
    /// published UDP port could exhaust descriptors. UDP is lossy — over the cap, new
    /// flows are dropped. 256 distinct live clients per port is well beyond real use.
    private let maxFlows = 256

    public init(manager: VMManager, idleSeconds: TimeInterval = 60,
                privilegedBinder: PrivilegedPortBinder? = nil,
                publish: PublishBind = .wildcard) {
        self.manager = manager
        self.idleSeconds = idleSeconds
        self.privilegedBinder = privilegedBinder
        self.publish = publish
    }

    /// Set by `stopAll()`. A reconcile that lands afterwards must be inert: the
    /// `PortHelperManager.reconciler` re-reconciles the latest port set from an unowned
    /// `Task` that awaits the one-time admin prompt, so it can arrive long after the engine
    /// stopped — and re-opening a listener then binds a host port on a dead runtime that
    /// nothing will ever close (libdispatch retains a resumed source), so the *next* start
    /// fails with EADDRINUSE for the rest of the process's life. On `queue`.
    private var stopped = false
    /// Bumped by every `reconcile`, so a scheduled bind retry from an older desired set
    /// bails instead of re-opening a port that has since been unpublished. On `queue`.
    private var reconcileGen = 0
    private static let maxBindAttempts = 5
    private static let bindRetryDelay: DispatchTimeInterval = .milliseconds(150)

    /// Reconcile open UDP listeners against the desired set of published ports.
    public func reconcile(_ wanted: Set<PublishedPort>) {
        queue.async {
            self.reconcileGen &+= 1
            self.reconcileOnQueue(wanted, gen: self.reconcileGen, attempt: 0)
        }
    }

    private func reconcileOnQueue(_ wanted: Set<PublishedPort>, gen: Int, attempt: Int) {
        guard !stopped, gen == reconcileGen else { return }
        // Close what's unwanted or rebound, then open what's unserved (see PortForwarder).
        for (port, listener) in listeners where !wanted.contains(listener.spec) {
            closeListener(port)
        }
        for spec in wanted where listeners[spec.port] == nil { open(spec) }
        updateReaper()
        retryUnbound(wanted, gen: gen, attempt: attempt)
    }

    /// Re-arm the reconcile when a wanted port failed to bind. Two reasons this is not
    /// optional:
    ///  • **Close-then-rebind.** `closeListener` only *cancels* the accept source; the cancel
    ///    handler that actually closes the fd is asynchronous, so re-binding the same port in
    ///    the same pass hits EADDRINUSE (SO_REUSEADDR does not permit an identical addr:port).
    ///    That is the normal path when a container is recreated from `-p 127.0.0.1:8080:80`
    ///    to `-p 8080:80` and both states land in one coalescer window.
    ///  • **Transient conflicts** — another process momentarily holding the port.
    /// Without a retry the failure is permanent: the published-port *set* is unchanged, so
    /// `DockerEventsWatcher.commit` never fires `onPorts` again and nothing ever revisits it.
    private func retryUnbound(_ wanted: Set<PublishedPort>, gen: Int, attempt: Int) {
        guard wanted.contains(where: { listeners[$0.port] == nil }),
              attempt < Self.maxBindAttempts else { return }
        queue.asyncAfter(deadline: .now() + Self.bindRetryDelay) { [weak self] in
            self?.reconcileOnQueue(wanted, gen: gen, attempt: attempt + 1)
        }
    }

    public func stopAll() {
        queue.async {
            self.stopped = true
            for port in Array(self.listeners.keys) { self.closeListener(port) }
            self.reaper?.cancel(); self.reaper = nil
            self.relay.stop()   // tear down the shared kqueue loop (thread + kq + wakeup pipe)
        }
    }

    // MARK: - private (all on `queue` unless noted)

    private func open(_ spec: PublishedPort) {
        let port = spec.port
        // An explicit per-container `-p 127.0.0.1:…` beats the global default.
        var publish = spec.bind(default: self.publish)
        // The helper binds loopback or all-interfaces only — a specific `publishHostIP`
        // can't be honoured below 1024, so degrade to host-only and say so (see PortForwarder).
        if port < 1024, !publish.isWildcard, !publish.isLoopback {
            if warnedSpecificPrivileged.insert(port).inserted {
                Log.warn("udp-forward: publishHostIP \(publish.label) can't be honoured for privileged "
                         + "port \(port)/udp — binding 127.0.0.1:\(port) (host-only).")
            }
            publish = .loopback
        }
        // IPv4 first — it is required; the v6 twin is best-effort (see below).
        let fd: Int32
        if port < 1024 {
            guard let pfd = privilegedBinder?.boundListener(port: port, proto: .udp,
                                                            ipv6: false, wildcard: publish.isWildcard) else {
                if warnedPrivileged.insert(port).inserted {
                    Log.warn("udp-forward: \(publish.label):\(port)/udp needs the privileged helper — not authorized yet")
                }
                onBindIssue?(port, true)
                return
            }
            fd = pfd
        } else {
            guard let s = Self.bindUDP(port: port, v4: publish.v4) else {
                Log.warn("udp-forward: could not bind \(publish.label):\(port)/udp (errno \(errno))")
                onBindIssue?(port, true)
                return
            }
            fd = s
        }
        var sockets = [(fd: fd, source: makeReadSource(fd: fd, port: port))]

        // The IPv6 twin (V6ONLY, so it never shadows the v4 socket). macOS resolves
        // `localhost` to `::1` FIRST, so without this a published UDP service is simply
        // unreachable via `localhost` — the exact failure `PublishBind` documents and that
        // TCP has always handled. Best-effort and warn-only: a v6 failure must still leave
        // the v4 listener registered, or `retryUnbound` spins and the port never opens.
        if let v6addr = publish.v6 {
            let v6fd: Int32?
            if port < 1024 {
                v6fd = privilegedBinder?.boundListener(port: port, proto: .udp,
                                                       ipv6: true, wildcard: publish.isWildcard)
            } else {
                v6fd = Self.bindUDP6(port: port, address: v6addr)
            }
            if let f = v6fd {
                sockets.append((fd: f, source: makeReadSource(fd: f, port: port)))
            } else {
                Log.warn("udp-forward: \(publish.label):\(port)/udp bound v4 only — no IPv6 twin "
                         + "(localhost may resolve to ::1 and fail)")
            }
        }

        let listener = Listener(sockets: sockets, spec: spec)
        listeners[port] = listener
        warnedPrivileged.remove(port)
        for s in sockets { s.source.resume() }
        onBindIssue?(port, false)   // serving now — clear any earlier badge
        Log.info("udp-forward: \(publish.label):\(port)/udp → guest:\(port)/udp"
                 + (sockets.count == 2 ? " (v4+v6)" : ""))
    }

    /// A non-blocking UDP socket bound to `v4`:`port`, or nil.
    private static func bindUDP(port: UInt16, v4: in_addr_t) -> Int32? {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = v4
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { let e = errno; Darwin.close(s); errno = e; return nil }
        return s
    }

    /// The V6ONLY twin, so it never shadows the v4 socket.
    private static func bindUDP6(port: UInt16, address: in6_addr) -> Int32? {
        let s = socket(AF_INET6, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = address
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0 else { let e = errno; Darwin.close(s); errno = e; return nil }
        return s
    }

    /// The read source for one listening socket. The fd is CAPTURED, not re-derived from
    /// `listeners[port]` — with two sockets per port there is no single "the" fd any more,
    /// and the handler must know which one the datagram arrived on so the reply goes back
    /// out of the same socket. (TCP does the same in `makeAcceptSource`.)
    private func makeReadSource(fd: Int32, port: UInt16) -> DispatchSourceRead {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readDatagrams(port: port, fd: fd) }
        source.setCancelHandler { Darwin.close(fd) }
        return source
    }

    private func closeListener(_ port: UInt16) {
        warnedPrivileged.remove(port)
        onBindIssue?(port, false) // unpublished → whatever issue it had is moot
        guard let listener = listeners.removeValue(forKey: port) else { return }
        // Every flow must be deregistered from the relay loop BEFORE the shared UDP fd
        // closes: a sendto on a closed (kernel-reused) fd number could misdirect
        // datagrams into an unrelated socket. teardown() completes per flow once the
        // loop confirms; the last completion cancels the source (whose cancel handler
        // closes the fd). No flows ⇒ close immediately.
        let flows = listener.flows
        listener.flows = [:]
        // The listener's own bind, not the default — a loopback-only port closes as such.
        // Captured by value: the completion below is @Sendable.
        let label = listener.spec.bind(default: publish).label
        // BOTH sockets' sources must stay behind the countdown: the fd-reuse hazard above
        // applies to whichever socket a flow replies on, so cancelling either early re-opens
        // it.
        let sources = listener.sockets.map(\.source)
        guard !flows.isEmpty else {
            for src in sources { src.cancel() }
            Log.info("udp-forward: closed \(label):\(port)/udp")
            return
        }
        let remaining = Countdown(flows.count) {
            for src in sources { src.cancel() }
            Log.info("udp-forward: closed \(label):\(port)/udp")
        }
        for (_, flow) in flows { teardown(flow) { remaining.hit() } }
    }

    /// Drain all pending datagrams on ONE of a port's UDP sockets (v4 or v6), demultiplex
    /// by client. `fd` is the socket the event fired on — replies must go back out of the
    /// same one, and it is part of the flow identity.
    private func readDatagrams(port: UInt16, fd: Int32) {
        guard let listener = listeners[port] else { return }
        var buf = [UInt8](repeating: 0, count: 65535)
        while true {
            var client = ClientAddr()
            client.len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &client.storage) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buf, buf.count, 0, sa, &client.len)
                }
            }
            // n == 0 is a legitimate ZERO-LENGTH datagram (keepalives and several
            // protocols send them), not EOF — UDP sockets have no EOF. Treating it as one
            // both discarded the datagram and exited the drain loop early.
            if n < 0 { break }
            let datagram = Array(buf[0..<n])
            guard let key = Self.flowKey(client.storage, fd) else { continue }
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
                flow.client = client
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
                        fd: vsockFd, listenerFd: key.listenerFd, client: flow.client,
                        touch: { [weak self] in self?.touch(port: port, key: key) },
                        onEOF: { [weak self] in
                            guard let self else { return }
                            self.queue.async { self.reclaim(port: port, key: key) }
                        })
                    guard flow.token != 0 else {
                        // The relay refused the registration (torn down, or its loop failed to
                        // start). Marking it registered anyway sent `teardown` down the
                        // `drop()` path, whose `done()` would never fire — so this fd was
                        // never closed and the listener's Countdown never completed.
                        Darwin.close(vsockFd)
                        flow.vsockFd = -1; flow.ready = false
                        listener.flows[key] = nil
                        return
                    }
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
        /// The socket the client's datagrams ARRIVED on — replies must leave by the same one
        /// (a v6 client's reply on the v4 socket fails EAFNOSUPPORT, and the `sendto` result
        /// is discarded, so it would be a silent one-way blackhole).
        let listenerFd: Int32
        let client: ClientAddr
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
        var deliverErrors = 0
        init(_ reg: Registration) { self.reg = reg }
    }

    private enum Command {
        case add(Registration)
        case drop(fd: Int32, token: UInt64, done: @Sendable () -> Void)
        case stop
    }

    private var kq: Int32 = -1               // created lazily in start(); -1 until a flow appears
    private var pipeR: Int32 = -1
    private var pipeW: Int32 = -1
    private let lock = NSLock()
    private var commands: [Command] = []     // guarded by `lock`
    private var started = false              // guarded by `lock`
    private var stopped = false              // guarded by `lock`
    private var nextToken: UInt64 = 1        // guarded by `lock`
    private var entries: [Int32: Entry] = [:]   // loop-thread only

    /// Register a flow's vsock fd (must already be non-blocking). Returns the token
    /// that `drop` needs (registration identity — fd numbers get reused).
    func add(fd: Int32, listenerFd: Int32, client: ClientAddr,
             touch: @escaping @Sendable () -> Void,
             onEOF: @escaping @Sendable () -> Void) -> UInt64 {
        lock.lock()
        if stopped { lock.unlock(); return 0 }   // loop torn down; caller's flow gets closed by the forwarder
        let token = nextToken
        nextToken += 1
        commands.append(.add(Registration(fd: fd, token: token, listenerFd: listenerFd,
                                          client: client, touch: touch, onEOF: onEOF)))
        let needStart = !started
        started = true
        lock.unlock()
        if needStart, !start() {
            // Roll back so `drop()` takes its `done()`-now path and the caller's fd is closed.
            lock.lock(); started = false; stopped = true; commands.removeAll(); lock.unlock()
            return 0
        }
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

    /// Tear down the loop thread and its own fds (kqueue + wakeup pipe). Idempotent, safe
    /// from the forwarder queue on engine stop. Flow/listener fds stay the forwarder's to
    /// close. A loop that never started (no UDP flow) opened nothing, so this is a no-op.
    func stop() {
        lock.lock()
        let running = started && !stopped
        stopped = true
        if running { commands.append(.stop) }
        lock.unlock()
        if running { wake() }
    }

    /// Returns false if the loop could not be created. The caller must then treat the loop as
    /// never-started: leaving `started == true` makes `drop()` queue a command nobody will
    /// service, so `done()` never fires, the flow's vsock fd is never closed, and the
    /// listener's `Countdown` never completes — a permanent fd leak per flow plus a listener
    /// socket that stays bound forever.
    private func start() -> Bool {
        kq = kqueue()
        guard kq >= 0 else {
            Log.error("udp relay: kqueue() failed (\(errno)) — UDP forwarding unavailable")
            return false
        }
        var fds: [Int32] = [-1, -1]
        // Unchecked, a failed pipe() left the fds at 0 and registered *stdin* as the wakeup
        // pipe (the same bug EventRelay documents).
        guard fds.withUnsafeMutableBufferPointer({ pipe($0.baseAddress) }) == 0 else {
            Log.error("udp relay: pipe() failed (\(errno)) — UDP forwarding unavailable")
            close(kq); kq = -1
            return false
        }
        pipeR = fds[0]; pipeW = fds[1]
        let fl = fcntl(pipeR, F_GETFL, 0)
        _ = fcntl(pipeR, F_SETFL, fl | O_NONBLOCK)
        Thread.detachNewThread { [self] in run() }
        return true
    }

    private func wake() {
        var byte: UInt8 = 1
        _ = write(pipeW, &byte, 1)
    }

    private func run() {
        setEvent(pipeR, EVFILT_READ, EV_ADD | EV_ENABLE)
        var events = Array<kevent>(repeating: kevent(), count: 128)
        loop: while true {
            let n = kevent(kq, nil, 0, &events, 128, nil)
            if n < 0 { if errno == EINTR { continue }; break }
            for i in 0..<Int(n) {
                let fd = Int32(events[i].ident)
                if fd == pipeR { drainPipe(); if runCommands() { break loop }; continue }
                guard let entry = entries[fd] else { continue }   // stale event — ignore
                handleReadable(fd, entry)
            }
        }
        // Teardown: close only the loop's OWN fds (kqueue + wakeup pipe). Flow/listener fds
        // are owned + closed by the forwarder queue, never here.
        if kq >= 0 { close(kq); kq = -1 }
        if pipeR >= 0 { close(pipeR); pipeR = -1 }
        if pipeW >= 0 { close(pipeW); pipeW = -1 }
        entries.removeAll()
    }

    private func drainPipe() {
        var tmp = [UInt8](repeating: 0, count: 256)
        while read(pipeR, &tmp, tmp.count) > 0 {}
    }

    /// Apply queued commands (loop thread). Returns true if a stop was requested, so `run()`
    /// exits and tears the loop down.
    private func runCommands() -> Bool {
        lock.lock()
        let batch = commands
        commands.removeAll()
        lock.unlock()
        var shouldStop = false
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
            case .stop:
                shouldStop = true
            }
        }
        return shouldStop
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
        var client = entry.reg.client.storage
        // The length `recvfrom` reported, never `sizeof(sockaddr_in)` — a v6 address with a
        // v4 length is EINVAL, and since the result is discarded that failure is invisible.
        let salen = entry.reg.client.len
        let need = entry.need
        let sent = entry.payload.withUnsafeBytes { raw in
            withUnsafePointer(to: &client) { cp in
                cp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(entry.reg.listenerFd, raw.baseAddress, need, 0, sa, salen)
                }
            }
        }
        // Don't swallow it entirely: a persistent reply failure is a one-way blackhole that
        // otherwise looks exactly like a silent application bug.
        if sent < 0, entry.deliverErrors == 0 {
            entry.deliverErrors += 1
            Log.warn("udp-forward: reply sendto failed (errno \(errno)) — client may see no response")
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
