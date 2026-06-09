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
/// here as a warm pool. When a published-port client connects, we pop a warm conduit, write
/// the target `"<port>\n"` (byte-identical to the vsock reverse header), and splice the two
/// with `SocketPump`. The data then rides VZNAT (~95 serving / ~17 ingress) instead of the
/// ~6 Gbit/s vsock relay, and the conduit's TCP handshake was pre-paid off the hot path —
/// so per-connection setup never touches the VM serial queue. If the pool is empty the caller
/// falls back to the vsock reverse relay, so this is strictly a fast path, never required.
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
    private var pumps: [UUID: BulkPump] = [:]
    private let pumpLock = NSLock()
    private let endpoints: PublishedEndpoints?

    public init(gateway: GatewayInfo, endpoints: PublishedEndpoints? = nil) {
        self.bindIP = gateway.gatewayIP
        self.guestIP = gateway.guestIP
        self.endpoints = endpoints
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
        guard bound == 0, listen(fd, 128) == 0 else {
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
        }
    }

    /// Parked-conduit count (diagnostics / tests). Synchronous read on `queue`.
    public var readyCount: Int { queue.sync { ready.count } }

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
            // Watch the parked conduit: a readable event before assignment is EOF/error
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

    /// Try to forward `clientFd` to the guest's `port` over a warm conduit. Returns true if a
    /// conduit was used (this object now owns `clientFd` + the conduit); false if the pool is
    /// empty or the popped conduit was stale (caller keeps `clientFd` for the vsock fallback).
    public func tryForward(clientFd: Int32, port: UInt16) -> Bool {
        queue.sync {
            guard let p = ready.popLast() else { return false }
            p.source.cancel() // stop monitoring; we own the fd now
            // In-band assignment. Prefer the container endpoint (guest dials it directly,
            // skipping docker-proxy); fall back to the bare port (guest → docker-proxy).
            let target = endpoints?.endpoint(for: port) ?? "\(port)"
            guard Self.writeAll(p.fd, Array("\(target)\n".utf8)) else {
                close(p.fd) // stale (e.g. conntrack-evicted) — let the caller fall back
                return false
            }
            startPump(clientFd, p.fd)
            return true
        }
    }

    private func startPump(_ a: Int32, _ b: Int32) {
        let id = UUID()
        let pump = BulkPump(fdA: a, fdB: b) { [weak self] in
            guard let self else { return }
            self.pumpLock.lock(); self.pumps[id] = nil; self.pumpLock.unlock()
        }
        pumpLock.lock(); pumps[id] = pump; pumpLock.unlock()
        pump.start()
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
