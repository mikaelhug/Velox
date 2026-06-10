import Foundation

/// Maintains a `127.0.0.1:<port>` TCP listener on the Mac for each published
/// container port, forwarding connections over VSOCK to the guest reverse-relay
/// (which dials the same port inside the guest, where dockerd published it).
public final class PortForwarder: @unchecked Sendable {
    private struct Listener {
        /// One accept source per bound socket: always 127.0.0.1, plus best-effort ::1
        /// (macOS resolves `localhost` to ::1 first, and a v4-only bind leaves that
        /// first connect to whoever else holds the v6 port — e.g. a dormant Docker
        /// Desktop wildcard listener). Each source's cancel handler closes its own fd.
        let sources: [DispatchSourceRead]
    }

    private let bridge: VsockBridge
    /// Source of loopback listeners for privileged (<1024) ports, which an
    /// unprivileged process can't bind itself (nil ⇒ such ports are skipped).
    private let privilegedBinder: PrivilegedPortBinder?
    /// Fast path: a warm VZNAT conduit pool. Attached once `GatewayProbe` resolves; until
    /// then (or when the pool is empty) `accept` falls back to the vsock reverse relay.
    private var conduitPool: ConduitPool?
    private let queue = DispatchQueue(label: "dev.velox.portfwd")
    private var listeners: [UInt16: Listener] = [:]
    /// Privileged ports we've already logged as "helper not ready", so a pending or
    /// declined prompt doesn't re-warn on every reconcile (all access is on `queue`).
    private var warnedPrivileged: Set<UInt16> = []

    public init(bridge: VsockBridge,
                privilegedBinder: PrivilegedPortBinder? = nil,
                conduitPool: ConduitPool? = nil) {
        self.bridge = bridge
        self.privilegedBinder = privilegedBinder
        self.conduitPool = conduitPool
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

    /// Reconcile open listeners against the desired set of published ports.
    public func reconcile(_ wanted: Set<UInt16>) {
        queue.async {
            let current = Set(self.listeners.keys)
            for port in wanted.subtracting(current) { self.open(port) }
            for port in current.subtracting(wanted) { self.closeListener(port) }
        }
    }

    public func stopAll() {
        queue.async { for port in Array(self.listeners.keys) { self.closeListener(port) } }
    }

    // MARK: - private (all on `queue`)

    private func open(_ port: UInt16) {
        let fd: Int32
        if port < 1024 {
            // Privileged port: an unprivileged bind(2) returns EACCES, so the
            // listening socket comes from the root helper (already listening).
            guard let pfd = privilegedBinder?.boundListener(port: port, proto: .tcp) else {
                if warnedPrivileged.insert(port).inserted {
                    Log.warn("port-forward: 127.0.0.1:\(port) needs the privileged helper — not authorized yet")
                }
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
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(s, 128) == 0 else {
                Log.warn("port-forward: could not bind 127.0.0.1:\(port) (errno \(errno))")
                Darwin.close(s)
                return
            }
            fd = s
        }
        var sources = [makeAcceptSource(fd: fd, port: port)]
        // Best-effort ::1 twin (unprivileged ports only — the helper hands out v4).
        // Failure (e.g. another process wildcard-bound the v6 port) is non-fatal: the
        // v4 listener still serves, exactly as before.
        if port >= 1024, let v6 = Self.bindV6Loopback(port) {
            sources.append(makeAcceptSource(fd: v6, port: port))
        }
        listeners[port] = Listener(sources: sources)
        warnedPrivileged.remove(port)
        Log.info("port-forward: localhost:\(port) → guest:\(port)"
                 + (sources.count == 2 ? " (v4+v6)" : ""))
    }

    /// Non-blocking accept source for a listening socket; owns + closes the fd on cancel.
    private func makeAcceptSource(fd: Int32, port: UInt16) -> DispatchSourceRead {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(on: fd, port: port) }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return source
    }

    /// A `[::1]:port` listener (V6ONLY so it never shadows the v4 one), or nil.
    private static func bindV6Loopback(_ port: UInt16) -> Int32? {
        let s = socket(AF_INET6, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_loopback
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
        guard let listener = listeners.removeValue(forKey: port) else { return }
        for source in listener.sources { source.cancel() }
        Log.info("port-forward: closed localhost:\(port)")
    }

    private func accept(on fd: Int32, port: UInt16) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 { break }
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
