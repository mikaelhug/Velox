import Foundation

/// Maintains a `<publishHostIP>:<port>` TCP listener on the Mac for each published
/// container port, forwarding connections over VSOCK to the guest reverse-relay
/// (which dials the same port inside the guest, where dockerd published it).
///
/// The bind address defaults to `0.0.0.0` (Docker's own default — published ports are
/// reachable from other machines); `VeloxConfig.publishHostIP` can pin it to
/// `127.0.0.1` for host-only. See `PublishBind`.
public final class PortForwarder: @unchecked Sendable {
    private struct Listener {
        /// One accept source per bound socket: the configured v4 address, plus a
        /// best-effort v6 twin (macOS resolves `localhost` to ::1 first, and a v4-only
        /// bind leaves that first connect to whoever else holds the v6 port — e.g. a
        /// dormant Docker Desktop wildcard listener). Each source's cancel handler
        /// closes its own fd.
        let sources: [DispatchSourceRead]
        /// What this listener was opened for. Held so a reconcile can tell "same port,
        /// different bind address" (a container recreated with/without an explicit
        /// loopback `HostIp`) from "unchanged", and rebuild only in the former case.
        let spec: PublishedPort
    }

    private let bridge: VsockBridge
    /// Source of listeners for privileged (<1024) ports, which an unprivileged
    /// process can't bind itself (nil ⇒ such ports are skipped).
    private let privilegedBinder: PrivilegedPortBinder?
    /// Host address the listeners bind (default: all interfaces).
    private let publish: PublishBind
    /// Fast path: a warm VZNAT conduit pool. Attached once `GatewayProbe` resolves; until
    /// then (or when the pool is empty) `accept` falls back to the vsock reverse relay.
    private var conduitPool: ConduitPool?
    private let queue = DispatchQueue(label: "dev.velox.portfwd")
    private var listeners: [UInt16: Listener] = [:]
    /// Privileged ports we've already logged as "helper not ready", so a pending or
    /// declined prompt doesn't re-warn on every reconcile (all access is on `queue`).
    private var warnedPrivileged: Set<UInt16> = []
    /// Privileged ports already warned about a specific `publishHostIP` the helper can't
    /// bind (warn-once; all access is on `queue`).
    private var warnedSpecificPrivileged: Set<UInt16> = []
    /// Fired when a published port can't get its localhost listener (true) or the
    /// condition clears (false) — the GUI badges the port instead of burying the
    /// only signal in a log line. Set before `reconcile` is first called.
    public var onBindIssue: (@Sendable (UInt16, Bool) -> Void)?

    public init(bridge: VsockBridge,
                privilegedBinder: PrivilegedPortBinder? = nil,
                conduitPool: ConduitPool? = nil,
                publish: PublishBind = .wildcard) {
        self.bridge = bridge
        self.privilegedBinder = privilegedBinder
        self.conduitPool = conduitPool
        self.publish = publish
    }

    /// Attach the VZNAT conduit pool once `GatewayProbe` has resolved (the probe is async, so
    /// the forwarder is usually constructed before the pool exists). Future connections take
    /// the fast path; in-flight ones are unaffected. The pool gets the vsock relay as its
    /// last-resort fallback (used only when no conduit is available in time).
    public func attachConduitPool(_ pool: ConduitPool) {
        pool.setFallback { [bridge] clientFd, port in
            bridge.bridge(localFd: clientFd, toGuestPort: VsockPort.reverse, header: "\(port)\n")
        }
        queue.async { self.conduitPool = pool }
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
    /// Last desired set, so a network change can re-bind without waiting for a docker event.
    private var lastWanted: Set<PublishedPort> = []
    /// Accept sources currently paused for fd exhaustion (see `pauseForFDExhaustion`).
    private var throttled: Set<ObjectIdentifier> = []
    private static let maxBindAttempts = 5
    private static let bindRetryDelay: DispatchTimeInterval = .milliseconds(150)

    /// Reconcile open listeners against the desired set of published ports.
    public func reconcile(_ wanted: Set<PublishedPort>) {
        queue.async {
            self.reconcileGen &+= 1
            self.reconcileOnQueue(wanted, gen: self.reconcileGen, attempt: 0)
        }
    }

    private func reconcileOnQueue(_ wanted: Set<PublishedPort>, gen: Int, attempt: Int) {
        guard !stopped, gen == reconcileGen else { return }
        lastWanted = wanted
        // Close anything no longer wanted *or* whose bind address changed, then open
        // whatever is left unserved — so a port that flips between loopback-only and
        // the default rebinds instead of silently keeping its old address.
        for (port, listener) in listeners where !wanted.contains(listener.spec) {
            closeListener(port)
        }
        for spec in wanted where listeners[spec.port] == nil { open(spec) }
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

    /// Re-bind listeners pinned to a SPECIFIC host address (a non-default `publishHostIP`).
    /// That socket keeps existing after a Wi-Fi switch or DHCP renewal moves the address, but
    /// silently stops receiving, and nothing else re-triggers a reconcile because the
    /// published-port set is unchanged. Wildcard and loopback binds are unaffected by an
    /// address change, so they're left alone.
    public func rebindPinnedAddresses() {
        queue.async {
            guard !self.stopped else { return }
            var changed = false
            for (port, listener) in self.listeners {
                let bind = listener.spec.bind(default: self.publish)
                guard !bind.isWildcard, !bind.isLoopback else { continue }
                self.closeListener(port); changed = true
            }
            guard changed else { return }
            self.reconcileGen &+= 1
            self.reconcileOnQueue(self.lastWanted, gen: self.reconcileGen, attempt: 0)
        }
    }

    /// Pause an accept source that hit EMFILE/ENFILE. The source is level-triggered and the
    /// connection stays queued, so simply returning re-fires it immediately and spins the
    /// queue at 100% CPU — exactly when the process can least afford it.
    private func pauseForFDExhaustion(_ source: DispatchSourceRead, port: UInt16) {
        let id = ObjectIdentifier(source)
        guard throttled.insert(id).inserted else { return }
        Log.warn("port-forward: out of file descriptors accepting on port \(port) — "
                 + "pausing that listener briefly")
        source.suspend()
        queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            // Resume UNCONDITIONALLY (see DockerSocketProxy for the full reasoning): a
            // suspended source never runs its cancel handler, so `closeListener`'s cancel
            // would leak the listening fd if the forwarder went away inside this window, and
            // releasing a suspended source traps in libdispatch.
            self?.throttled.remove(id)
            source.resume()
        }
    }

    public func stopAll() {
        queue.async {
            self.stopped = true
            for port in Array(self.listeners.keys) { self.closeListener(port) }
        }
        // Barrier. `EngineRuntime.stop()` shuts the producers down and only then drains the
        // shared relay; with a bare `queue.async` that ordering was aspirational — an accept
        // still queued here could hand a pair to `EventRelay` after the drain and survive the
        // stop. Bounded: this queue can be mid-`boundListener`, a porthelper round-trip, and
        // `stop()` is reachable from the main actor.
        queue.settle("port-forward")
    }

    // MARK: - private (all on `queue`)

    private func open(_ spec: PublishedPort) {
        let port = spec.port
        // An explicit per-container `-p 127.0.0.1:…` always wins over the global default:
        // enabling Docker-compatible publishing must never widen a service the user
        // deliberately pinned to loopback (a database, an admin port).
        var publish = spec.bind(default: self.publish)
        // The root helper's protocol offers loopback or all-interfaces — not an arbitrary
        // address — so a specific `publishHostIP` cannot be honoured below 1024. Say so
        // loudly and degrade to host-only: binding loopback while logging the requested
        // address would be exactly the silent fallback that hid the original bug.
        if port < 1024, !publish.isWildcard, !publish.isLoopback {
            if warnedSpecificPrivileged.insert(port).inserted {
                Log.warn("port-forward: publishHostIP \(publish.label) can't be honoured for privileged "
                         + "port \(port) — the root helper binds loopback or all interfaces only. "
                         + "Binding 127.0.0.1:\(port) (host-only); use 0.0.0.0 to publish it off-box.")
            }
            publish = .loopback
        }
        // With SO_REUSEADDR a wildcard bind SUCCEEDS even when another process already
        // holds `127.0.0.1:<port>` — and that more-specific socket keeps winning loopback
        // traffic (verified). Left undetected the conflict would go silent: the LAN works
        // while `localhost` quietly reaches the other app. On loopback binds it stays a
        // hard bind failure, as before. Either way the GUI gets its badge.
        let shadowed = publish.isWildcard && loopbackHeld(port, type: SOCK_STREAM)
        let fd: Int32
        if port < 1024 {
            // Privileged port: an unprivileged bind(2) returns EACCES, so the
            // listening socket comes from the root helper (already listening).
            guard let pfd = privilegedBinder?.boundListener(port: port, proto: .tcp,
                                                            ipv6: false, wildcard: publish.isWildcard) else {
                if warnedPrivileged.insert(port).inserted {
                    Log.warn("port-forward: \(publish.label):\(port) needs the privileged helper — not authorized yet")
                }
                onBindIssue?(port, true)
                return
            }
            fd = pfd
        } else {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { return }
            var yes: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = publish.v4
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(s, 128) == 0 else {
                Log.warn("port-forward: could not bind \(publish.label):\(port) (errno \(errno))")
                Darwin.close(s)
                onBindIssue?(port, true)
                return
            }
            fd = s
        }
        var sources = [makeAcceptSource(fd: fd, port: port)]
        // Best-effort v6 twin. macOS resolves `localhost` to ::1 first, so a v4-only
        // listener yields the baffling "connection refused on localhost, works on
        // 127.0.0.1" — most acute for the privileged reverse-proxy ports (:80/:443) the
        // helper exists to serve. Privileged ports get the twin from the helper (it binds
        // v4 and v6); the rest bind it directly. Skipped entirely for a specific v4
        // address (no meaningful twin). Failure is non-fatal (v4 still serves) — e.g. an
        // old helper predating the v6 verb, or another process holding the port.
        if let v6addr = publish.v6 {
            let v6fd: Int32? = port < 1024
                ? privilegedBinder?.boundListener(port: port, proto: .tcp,
                                                  ipv6: true, wildcard: publish.isWildcard)
                : Self.bindV6(port, v6addr)
            if let v6fd {
                sources.append(makeAcceptSource(fd: v6fd, port: port))
            } else {
                Log.warn("port-forward: [\(publish.isWildcard ? "::" : "::1")]:\(port) unavailable "
                         + "(old helper, or held by another process?) — `localhost` may resolve "
                         + "there first; use 127.0.0.1:\(port)")
            }
        }
        listeners[port] = Listener(sources: sources, spec: spec)
        warnedPrivileged.remove(port)
        if shadowed {
            Log.warn("port-forward: \(publish.label):\(port) is bound, but another process already holds "
                     + "127.0.0.1:\(port) — it keeps winning `localhost` traffic; this port serves "
                     + "other interfaces only")
        }
        onBindIssue?(port, shadowed)
        Log.info("port-forward: \(publish.label):\(port) → guest:\(port)"
                 + (sources.count == 2 ? " (v4+v6)" : ""))
    }

    /// True when another process already holds `127.0.0.1:<port>`. `SO_REUSEADDR` does not
    /// permit two sockets on the identical addr:port pair, so a probe bind returns
    /// `EADDRINUSE` — the detection a wildcard bind would otherwise lose.
    private func loopbackHeld(_ port: UInt16, type: Int32) -> Bool {
        let s = socket(AF_INET, type, 0)
        guard s >= 0 else { return false }
        defer { Darwin.close(s) }
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
        if bound != 0 && errno == EADDRINUSE { return true }
        // A port below 1024 fails the probe bind with EACCES, not EADDRINUSE, so this check
        // was dead for exactly the ports that matter (:80/:443 via the privileged helper).
        // Fall back to *connecting*: if anything accepts on 127.0.0.1:<port>, it's held.
        if bound != 0 && errno == EACCES && type == SOCK_STREAM {
            // Memoized: this fallback *connects* to whatever is listening, and it is reached
            // once per `open()` — so a `retryUnbound` burst on `-p 22:22` with Remote Login on
            // knocked on sshd up to five times in a second, each one logging "Did not receive
            // identification string". It answers a UI badge, so a slightly stale answer is
            // fine; a probe storm against someone else's daemon is not.
            if let memo = shadowProbe[port], memo.expires > DispatchTime.now() { return memo.held }
            let held = Self.loopbackAccepts(port)
            shadowProbe[port] = (DispatchTime.now() + Self.shadowProbeTTL, held)
            return held
        }
        return false
    }

    /// Cache for the connect-probe below, so a bind-retry burst probes a third-party daemon
    /// once rather than once per attempt. On `queue`.
    private var shadowProbe: [UInt16: (expires: DispatchTime, held: Bool)] = [:]
    private static let shadowProbeTTL = DispatchTimeInterval.seconds(30)

    /// True if something is accepting TCP connections on `127.0.0.1:port`. Unprivileged and
    /// works for privileged ports, unlike a probe bind.
    private static func loopbackAccepts(_ port: UInt16) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { Darwin.close(s) }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        return ok
    }

    /// Non-blocking accept source for a listening socket; owns + closes the fd on cancel.
    private func makeAcceptSource(fd: Int32, port: UInt16) -> DispatchSourceRead {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // Strong capture of `source` is deliberate: dispatch releases both handlers when the
        // source is cancelled, so the cycle breaks exactly then.
        source.setEventHandler { [weak self] in self?.accept(on: fd, port: port, source: source) }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return source
    }

    /// A `[<addr>]:port` listener (V6ONLY so it never shadows the v4 one), or nil.
    private static func bindV6(_ port: UInt16, _ address: in6_addr) -> Int32? {
        let s = socket(AF_INET6, SOCK_STREAM, 0)
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
        guard bound == 0, listen(s, 128) == 0 else { Darwin.close(s); return nil }
        return s
    }

    private func closeListener(_ port: UInt16) {
        warnedPrivileged.remove(port)
        onBindIssue?(port, false) // unpublished → whatever issue it had is moot
        guard let listener = listeners.removeValue(forKey: port) else { return }
        for source in listener.sources { source.cancel() }
        // The listener's own bind, not the default — a loopback-only port closes as such.
        Log.info("port-forward: closed \(listener.spec.bind(default: publish).label):\(port)")
    }

    private func accept(on fd: Int32, port: UInt16, source: DispatchSourceRead) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EMFILE || errno == ENFILE { pauseForFDExhaustion(source, port: port) }
                break // EWOULDBLOCK (drained) or error
            }
            // No Nagle on the client leg: replies are written in protocol-sized pieces
            // (headers, then body) and a delayed-ACK hold-back here is pure added latency.
            // The guest/conduit leg sets its own NODELAY.
            var on: Int32 = 1
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            // When the conduit pool is up it owns the connection — it splices to a warm conduit,
            // briefly waits for the guest to grow the pool under a burst, and drops to the vsock
            // relay only as a timed last resort. Without a pool, use the vsock relay directly.
            if let pool = conduitPool {
                pool.submit(clientFd: client, port: port)
            } else {
                bridge.bridge(localFd: client, toGuestPort: VsockPort.reverse, header: "\(port)\n")
            }
        }
    }
}
