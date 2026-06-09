import Foundation

/// Thread-safe `hostPort → "containerIP:containerPort"` map, maintained host-side by
/// `DockerEventsWatcher` (it already lists containers on every reconcile). The conduit pool
/// reads it to assign a conduit the container endpoint directly — so the guest dials the
/// container, skipping docker-proxy's userspace copy. Empty/missing → the guest gets the bare
/// host port and dials 127.0.0.1:<port> (docker-proxy), which is always safe.
public final class PublishedEndpoints: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [UInt16: String] = [:]

    public init() {}

    public func update(_ m: [UInt16: String]) {
        lock.lock(); map = m; lock.unlock()
    }

    public func endpoint(for port: UInt16) -> String? {
        lock.lock(); defer { lock.unlock() }; return map[port]
    }
}

/// Host end of the VZNAT reverse-dial conduit pool. The guest dials a pool of TCP conduits
/// to `gatewayIP:ConduitPort.pool` over VZNAT (the fast guest→host direction); we park them
/// here as a warm pool. When a published-port client connects, we pop a warm conduit, write the
/// target (`<container-ip>:<port>` for direct-dial, else the bare `<port>` → docker-proxy), and
/// splice the two via the event-loop relay (`EventRelay`). The data then rides VZNAT
/// (~95 serving / ~17 ingress) instead of the ~6 Gbit/s vsock relay, and the conduit's TCP
/// handshake was pre-paid off the hot path — so per-connection setup never touches the VM serial
/// queue. If the pool is empty the caller falls back to the vsock reverse relay, so this is
/// strictly a fast path, never required.
public final class ConduitPool: @unchecked Sendable {
    /// A parked, idle conduit plus a read source that prunes it if it dies. The guest never
    /// writes to a conduit before the host assigns it, so *any* readable event on a parked
    /// conduit means EOF/error (e.g. VZNAT conntrack evicted it) → drop it from the pool.
    private final class Parked {
        let fd: Int32
        let source: DispatchSourceRead
        init(fd: Int32, source: DispatchSourceRead) { self.fd = fd; self.source = source }
    }

    private let bindIP: in_addr_t      // network byte order; the vmnet bridge (gateway) address
    private let guestIP: in_addr_t     // the only allowed conduit peer (network byte order)
    private let queue = DispatchQueue(label: "dev.velox.conduitpool")
    private var listenFd: Int32 = -1
    private var source: DispatchSourceRead?
    private var ready: [Parked] = []   // parked idle conduits (all access on `queue`)
    private var waiting: [(fd: Int32, port: UInt16, deadline: DispatchTime)] = [] // clients awaiting a conduit
    private var sweepArmed = false     // at most one pending timeout sweep (all access on `queue`)
    private var fallbackHandler: (@Sendable (Int32, UInt16) -> Void)?
    private let endpoints: PublishedEndpoints?
    // Churn circuit breaker. A flood of *non-keep-alive* connections (a new connection per request)
    // drains the pool faster than the guest can redial — each request would otherwise wait out the
    // timeout and force a conduit redial, which under sustained churn buries the guest in TIME_WAIT
    // sockets and collapses the whole published-port path. So when the pool stays *continuously*
    // empty longer than any keep-alive establishment burst lasts, we declare churn and bypass the
    // pool: connections go straight to the vsock relay (no wait), and with nothing consuming
    // conduits the guest stops redialing (no TIME_WAIT storm). It auto-recovers after a cooldown.
    private var emptySince: DispatchTime?        // start of the current continuously-empty streak
    private var lastEmptyAt: DispatchTime?       // last empty-on-submit (to detect a gap → restart)
    private var breakerOpenUntil: DispatchTime?  // while set & future, bypass the pool entirely
    private var breakerBypassSecs = 2.0          // current bypass duration; backs off under sustained churn
    private let breakerTripAfter: DispatchTimeInterval = .milliseconds(300) // > a keep-alive burst
    private let breakerBypassMax = 16.0          // cap on the backed-off bypass duration
    private let breakerGap: DispatchTimeInterval = .milliseconds(100)       // quiet gap restarts the streak
    /// How long a client waits for a fresh conduit (while the guest's adaptive pool grows to meet
    /// a burst) before dropping to the vsock relay. Long enough to absorb a persistent-connection
    /// burst (which then reuses its fast conduit for the rest of its life); the adaptive pool keeps
    /// the warm buffer deep under sustained load, so brief (non-keep-alive) connections seldom
    /// reach this wait once the pool has grown.
    private let waitTimeout: DispatchTimeInterval = .milliseconds(150)

    public init(gateway: GatewayInfo, endpoints: PublishedEndpoints? = nil) {
        self.bindIP = gateway.gatewayIP
        self.guestIP = gateway.guestIP
        self.endpoints = endpoints
    }

    /// The vsock reverse-relay fallback, used when no conduit is available in time. Set by the
    /// PortForwarder when it attaches the pool.
    public func setFallback(_ handler: @escaping @Sendable (Int32, UInt16) -> Void) {
        queue.async { self.fallbackHandler = handler }
    }

    public func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VeloxError.socketSetupFailed("socket()", errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = ConduitPort.pool.bigEndian
        addr.sin_addr.s_addr = bindIP // already network byte order
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 256) == 0 else { // deep backlog: the pool can redial a burst of conduits at once
            let e = errno; close(fd)
            throw VeloxError.socketSetupFailed("conduit pool bind/listen", e)
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        listenFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptConduits() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        Log.info("conduit pool: listening on \(Self.ipString(bindIP)):\(ConduitPort.pool) — VZNAT reverse-dial")
    }

    public func stop() {
        queue.async {
            self.source?.cancel(); self.source = nil
            for p in self.ready { p.source.cancel(); close(p.fd) }
            self.ready.removeAll()
            for w in self.waiting { close(w.fd) }
            self.waiting.removeAll()
        }
    }

    // MARK: - accept (on `queue`)

    private func acceptConduits() {
        while true {
            var sa = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFd, $0, &len) }
            }
            if cfd < 0 { break } // EWOULDBLOCK (drained) or error
            // Only the guest may supply conduits. The pool listens on the VM-private bridge,
            // so this is defense-in-depth against any other local process on that subnet.
            guard sa.sin_addr.s_addr == guestIP else {
                Log.warn("conduit pool: rejecting conduit from \(Self.ipString(sa.sin_addr.s_addr))")
                close(cfd); continue
            }
            Self.setKeepalive(cfd)
            // A client is already waiting (a burst drained the pool) → assign this conduit to it
            // immediately instead of parking it.
            if !waiting.isEmpty {
                let w = waiting.removeFirst()
                assign(conduit: cfd, clientFd: w.fd, port: w.port)
                continue
            }
            // Otherwise park it. Watch for a readable event before assignment — that's EOF/error
            // (conntrack eviction / guest gone) → prune it so the pool can't accrue dead fds.
            let src = DispatchSource.makeReadSource(fileDescriptor: cfd, queue: queue)
            src.setEventHandler { [weak self] in self?.discardDead(cfd) }
            src.setCancelHandler { } // fd lifetime is managed explicitly (kept alive when popped)
            src.resume()
            ready.append(Parked(fd: cfd, source: src))
        }
    }

    /// A parked conduit became readable before assignment → it's dead. Remove + close it.
    private func discardDead(_ fd: Int32) {
        guard let idx = ready.firstIndex(where: { $0.fd == fd }) else { return }
        let p = ready.remove(at: idx)
        p.source.cancel()
        close(p.fd)
    }

    // MARK: - forward

    /// Forward `clientFd` to the guest's published `port`. Splices to a warm conduit immediately
    /// if one is parked; otherwise queues the client and waits briefly for the guest to grow the
    /// pool (a burst drains it), dropping to the vsock relay only if no conduit arrives within
    /// `waitTimeout`. Always takes ownership of `clientFd`.
    public func submit(clientFd: Int32, port: UInt16) {
        queue.async {
            let now = DispatchTime.now()
            // Breaker open (churn) → bypass the pool entirely; straight to vsock, no wait.
            if let until = self.breakerOpenUntil, now < until {
                self.fallbackHandler?(clientFd, port)
                return
            }
            if let p = self.ready.popLast() {
                p.source.cancel() // stop monitoring; we own the fd now
                self.emptySince = nil       // a spare conduit was waiting → pool is healthy
                self.breakerBypassSecs = 2.0 // real traffic served → reset the churn backoff
                self.assign(conduit: p.fd, clientFd: clientFd, port: port)
            } else {
                // Pool empty. Track how long it's been *continuously* empty-on-submit; a quiet gap
                // (or a served submit above) restarts the streak, so only sustained emptiness —
                // churn, not a keep-alive establishment burst — trips the breaker.
                if let last = self.lastEmptyAt, now > last + self.breakerGap { self.emptySince = now }
                else if self.emptySince == nil { self.emptySince = now }
                self.lastEmptyAt = now
                if let since = self.emptySince, now > since + self.breakerTripAfter {
                    self.breakerOpenUntil = now + .milliseconds(Int(self.breakerBypassSecs * 1000))
                    self.breakerBypassSecs = min(self.breakerBypassMax, self.breakerBypassSecs * 2) // back off if churn persists
                    self.emptySince = nil
                    self.fallbackHandler?(clientFd, port) // sustained churn → straight to vsock
                    return
                }
                // Queue the client and let one shared sweep enforce the timeout. A per-client
                // asyncAfter here would flood the serial queue under churn (thousands/s) and starve
                // the conduit-accept handler that refills the pool — so the pool would never recover.
                self.waiting.append((fd: clientFd, port: port, deadline: now + self.waitTimeout))
                self.armSweep()
            }
        }
    }

    /// Ensure exactly one pending timeout sweep is scheduled (idempotent). Armed only while clients
    /// wait, so there's no timer at idle — and never more than one in flight regardless of load.
    private func armSweep() {
        guard !sweepArmed else { return }
        sweepArmed = true
        queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in self?.sweep() }
    }

    /// Fall back any waiting clients past their deadline to the vsock relay; re-arm while any remain.
    private func sweep() {
        sweepArmed = false
        guard !waiting.isEmpty else { return }
        let now = DispatchTime.now()
        var still: [(fd: Int32, port: UInt16, deadline: DispatchTime)] = []
        for w in waiting {
            if w.deadline <= now { fallbackHandler?(w.fd, w.port) } else { still.append(w) }
        }
        waiting = still
        if !waiting.isEmpty { armSweep() }
    }

    /// Write the in-band target (container endpoint when known, else the bare port → docker-proxy)
    /// and splice `clientFd` ↔ `conduit` via the event-loop relay. Stale conduit → vsock fallback.
    private func assign(conduit: Int32, clientFd: Int32, port: UInt16) {
        let target = endpoints?.endpoint(for: port) ?? "\(port)"
        guard Self.writeAll(conduit, Array("\(target)\n".utf8)) else {
            close(conduit)
            fallbackHandler?(clientFd, port)
            return
        }
        // The event-loop relay multiplexes this pair onto its worker pool (no thread per
        // connection) and owns both fds until they close.
        EventRelay.shared.relay(clientFd, conduit) {}
    }

    // MARK: - helpers

    /// Short keepalive so a silently conntrack-evicted conduit surfaces as an error (→ the
    /// read source prunes it) within ~40s, instead of black-holing a future assignment.
    private static func setKeepalive(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
        var idle: Int32 = 25 // macOS: TCP_KEEPALIVE is the idle seconds before the first probe
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, socklen_t(MemoryLayout<Int32>.size))
        var intvl: Int32 = 5
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, socklen_t(MemoryLayout<Int32>.size))
        var cnt: Int32 = 3
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func writeAll(_ fd: Int32, _ buf: [UInt8]) -> Bool {
        var off = 0
        return buf.withUnsafeBytes { raw in
            while off < buf.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), buf.count - off)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }

    private static func ipString(_ be: in_addr_t) -> String {
        let h = UInt32(bigEndian: be)
        return "\((h >> 24) & 0xff).\((h >> 16) & 0xff).\((h >> 8) & 0xff).\(h & 0xff)"
    }
}
