import Foundation

/// A tiny loopback DNS responder for direct (named) container access. macOS routes
/// `*.velox.local` here via `/etc/resolver/velox.local` (`nameserver 127.0.0.1` + `port`),
/// installed once by the porthelper grant. We answer `A` queries for `<name>.velox.local` with the
/// container's real IP (from `NameRegistry`); the host route + the guest firewall allow then carry
/// the traffic straight to the container — any protocol, no proxy. Unknown name → NXDOMAIN; AAAA →
/// empty NOERROR (so the stub resolver falls back to A). Binds loopback only: no privilege, no
/// entitlement. The wire-format mirrors the guest's `answer_dns` (guest/vinit/src/main.rs:433).
///
/// Served over **UDP *and* TCP**, on the same port. TCP is not optional: RFC 7766 makes it
/// mandatory for a DNS server, and macOS's mDNSResponder does fall back to it — measured, a
/// single name (`hug-caddy-1.velox.local`) resolved over UDP for every other container while
/// mDNSResponder queried that one over TCP, got nothing back from a UDP-only responder, and
/// reported NXDOMAIN indefinitely. Flushing the cache did not help and the responder answered
/// the identical query correctly over UDP the whole time, which made it look like a container
/// fault. The guest's DNS proxy already served both (`handle_dns_tcp`); the host did not.
public final class NameDNSResponder: @unchecked Sendable {
    /// The suffix the resolver file routes to us (matches `NamedAccess.domain`).
    public static let domainSuffix = "." + NamedAccess.domain

    private let port: UInt16
    private let registry: NameRegistry
    private let queue = DispatchQueue(label: "dev.velox.dns")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var tcpFd: Int32 = -1
    private var tcpSource: DispatchSourceRead?
    /// Concurrent TCP handlers in flight. `:53`-equivalent is reachable by any local process, so
    /// a connection flood must not be able to spawn unbounded work.
    private let tcpInFlight = Locked(0)
    private static let maxTCPInFlight = 16
    /// The port actually bound (the kernel's choice when `port == 0`). Valid after `start()`;
    /// `EngineRuntime` publishes it to `/etc/resolver/<domain>` through the porthelper.
    public private(set) var boundPort: UInt16 = 0

    public init(port: UInt16 = NamedAccess.dnsPort, registry: NameRegistry) {
        self.port = port; self.registry = registry
    }

    public func start() throws {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { throw VeloxError.socketSetupFailed("dns socket()", errno) }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { close(s); throw VeloxError.socketSetupFailed("dns bind(127.0.0.1:\(port))", errno) }
        // Read back the port the kernel actually assigned — with `port == 0` (the default)
        // that is the whole point, and it is what gets published to /etc/resolver.
        var bound = sockaddr_in()
        var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &bound) { bp in
            bp.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &blen) == 0 }
        }
        guard gotName else { close(s); throw VeloxError.socketSetupFailed("dns getsockname", errno) }
        boundPort = UInt16(bigEndian: bound.sin_port)
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.handleOne() }
        src.setCancelHandler { close(s) }
        source = src
        src.resume()
        startTCP()
        Log.info("named-access DNS responder on 127.0.0.1:\(boundPort) (udp+tcp)")
    }

    /// Companion TCP listener on the same port. Best-effort: a failure here costs the TCP
    /// fallback, not named access as a whole, so it warns rather than throwing.
    private func startTCP() {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { Log.warn("named-access DNS: tcp socket() failed"); return }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = boundPort.bigEndian     // the port UDP actually got
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0, listen(s, 16) == 0 else {
            Log.warn("named-access DNS: tcp bind/listen on 127.0.0.1:\(boundPort) failed (errno \(errno))"
                     + " — resolvers that fall back to TCP will see NXDOMAIN")
            close(s); return
        }
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        tcpFd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptTCP() }
        src.setCancelHandler { close(s) }
        tcpSource = src
        src.resume()
    }

    private func acceptTCP() {
        while true {
            let c = accept(tcpFd, nil, nil)
            if c < 0 { return }                       // EWOULDBLOCK — drained
            let n = tcpInFlight.withLock { v -> Int in v += 1; return v }
            guard n <= Self.maxTCPInFlight else {
                tcpInFlight.withLock { $0 -= 1 }
                close(c); continue                    // shed load rather than spawn unbounded work
            }
            // Off `queue`: the reads below block (bounded by SO_RCVTIMEO) and this queue also
            // serves every UDP query.
            DispatchQueue.global().async { [weak self] in
                self?.serveTCP(c)
                self?.tcpInFlight.withLock { $0 -= 1 }
            }
        }
    }

    /// One TCP connection: `[2-byte length][message]`, repeated until EOF (RFC 7766 allows
    /// several queries per connection). Bounded by a receive timeout so a client that opens a
    /// connection and says nothing cannot pin a slot.
    private func serveTCP(_ c: Int32) {
        defer { close(c) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while true {
            var len = [UInt8](repeating: 0, count: 2)
            guard Self.readFull(c, &len, 2) else { return }
            let want = Int(len[0]) << 8 | Int(len[1])
            guard want >= 12, want <= 4096 else { return }   // 12 = header; cap the allocation
            var msg = [UInt8](repeating: 0, count: want)
            guard Self.readFull(c, &msg, want) else { return }
            let reply = Self.buildReply(msg, registry: registry)
            guard !reply.isEmpty, reply.count <= 0xFFFF else { return }
            var out: [UInt8] = [UInt8((reply.count >> 8) & 0xff), UInt8(reply.count & 0xff)]
            out += reply
            guard FDIO.writeAll(c, out) else { return }
        }
    }

    /// Read exactly `count` bytes, retrying short reads and EINTR. False on EOF/timeout/error.
    private static func readFull(_ fd: Int32, _ buf: inout [UInt8], _ count: Int) -> Bool {
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { p -> Int in
                read(fd, p.baseAddress!.advanced(by: got), count - got)
            }
            if n > 0 { got += n; continue }
            if n < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }

    public func stop() {
        queue.async {
            self.source?.cancel(); self.source = nil; self.fd = -1
            self.tcpSource?.cancel(); self.tcpSource = nil; self.tcpFd = -1
        }
    }

    private func handleOne() {
        var buf = [UInt8](repeating: 0, count: 512)
        var from = sockaddr_storage()
        var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = withUnsafeMutablePointer(to: &from) { fp in
            fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
        }
        guard n >= 12 else { return }
        let reply = Self.buildReply(Array(buf[0..<n]), registry: registry)
        guard !reply.isEmpty else { return }   // not a query we should answer
        _ = withUnsafePointer(to: &from) { fp in
            fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                reply.withUnsafeBytes { sendto(fd, $0.baseAddress, reply.count, 0, sa, fromLen) }
            }
        }
    }

    // MARK: wire-format (ported from the guest: parse_qname / build_a_reply / build_empty_reply)

    /// Nil when the header says this isn't a plain single-question query we should answer.
    /// Checked before anything else because answering a *response* creates a self-sustaining
    /// packet loop with any local process that can spoof our own source port, and because
    /// echoing a QDCOUNT we then truncate produces a malformed reply.
    ///   • QR (bit 7 of byte 2) must be 0 — a query, not a response.
    ///   • OPCODE (bits 3-6) must be 0 — a standard query, not NOTIFY/UPDATE.
    ///   • QDCOUNT must be exactly 1 — we only ever copy the first question.
    static func isAnswerableQuery(_ q: [UInt8]) -> Bool {
        guard q.count >= 12 else { return false }
        guard q[2] & 0x80 == 0, (q[2] >> 3) & 0x0F == 0 else { return false }
        return (UInt16(q[4]) << 8 | UInt16(q[5])) == 1
    }

    public static func buildReply(_ q: [UInt8], registry: NameRegistry) -> [UInt8] {
        guard isAnswerableQuery(q) else { return [] }   // not ours to answer — stay silent
        // QCLASS must be IN (1); a CH/HS question must not get an IN answer.
        guard let (name, qtype, qend) = parseQName(q), qclassIsIN(q, qend: qend),
              name.hasSuffix(domainSuffix) else { return nxdomain(q) }
        let bare = String(name.dropLast(domainSuffix.count))
        guard let ip = registry.address(for: bare) else { return nxdomain(q) }
        return qtype == 1 ? aReply(q, qend: qend, addr: ip) : emptyReply(q, qend: qend)
    }

    /// QCLASS sits in the two bytes just before `qend`.
    static func qclassIsIN(_ q: [UInt8], qend: Int) -> Bool {
        guard qend >= 2, qend <= q.count else { return false }
        return (UInt16(q[qend - 2]) << 8 | UInt16(q[qend - 1])) == 1
    }

    /// Extract the lowercased query name, qtype, and the offset just past the question.
    public static func parseQName(_ q: [UInt8]) -> (String, UInt16, Int)? {
        guard q.count >= 12 else { return nil }
        var pos = 12, name = ""
        while true {
            guard pos < q.count else { return nil }
            let len = Int(q[pos]); pos += 1
            if len == 0 { break }
            if len & 0xC0 != 0 { return nil }            // compression isn't valid in a question
            guard pos + len <= q.count else { return nil }
            if !name.isEmpty { name += "." }
            name += (String(bytes: q[pos..<pos + len], encoding: .ascii) ?? "").lowercased()
            pos += len
        }
        guard pos + 4 <= q.count else { return nil }
        return (name, (UInt16(q[pos]) << 8) | UInt16(q[pos + 1]), pos + 4)
    }

    static func aReply(_ q: [UInt8], qend: Int, addr: in_addr_t) -> [UInt8] {
        var r = Array(q[0..<qend])
        r[2] = 0x84 | (q[2] & 0x01); r[3] = 0x80          // QR=1, AA=1, RD copied; RA=1, RCODE=0
        r[6] = 0; r[7] = 1; r[8] = 0; r[9] = 0; r[10] = 0; r[11] = 0   // ANCOUNT=1
        r += [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x04] // ptr, A, IN, TTL 2s, len 4
        var a = addr                                      // already network byte order
        withUnsafeBytes(of: &a) { r.append(contentsOf: $0) }
        return r
    }

    static func emptyReply(_ q: [UInt8], qend: Int) -> [UInt8] {
        var r = Array(q[0..<qend])
        r[2] = 0x84 | (q[2] & 0x01); r[3] = 0x80
        for i in 6...11 { r[i] = 0 }                      // ANCOUNT=NS=AR=0 (NOERROR)
        return r
    }

    /// Encode a dotted name into DNS wire format (length-prefixed labels, root terminator).
    static func encodeName(_ name: String) -> [UInt8] {
        var out: [UInt8] = []
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8.prefix(63))
            out.append(UInt8(bytes.count))
            out += bytes
        }
        out.append(0)
        return out
    }

    /// A minimal SOA for the zone, carrying **MINIMUM = 1 second**.
    ///
    /// This is the whole point of the record. Under RFC 2308 a resolver takes its *negative*
    /// cache TTL from the SOA in the authority section of an NXDOMAIN; with no SOA it falls
    /// back to its own default, and mDNSResponder's is both long and sticky. That produced a
    /// recurring, baffling failure: query `<name>.velox.local` while the container happens to
    /// be down (an engine restart, a `compose down`, a recreate), and the name stays dead for
    /// the rest of the cache period even though the responder answers it correctly the whole
    /// time — verifiable only by querying the responder directly. Positive answers already use
    /// a 2 s TTL for the mirror-image reason (container IPs change on recreate).
    static func soaAuthority(zone: String) -> [UInt8] {
        let mname = encodeName("ns." + zone)
        let rname = encodeName("hostmaster." + zone)
        var rec = encodeName(zone)
        rec += [0x00, 0x06, 0x00, 0x01]                   // TYPE=SOA, CLASS=IN
        rec += [0x00, 0x00, 0x00, 0x01]                   // TTL 1s (the record itself)
        let rdlen = mname.count + rname.count + 20
        rec += [UInt8((rdlen >> 8) & 0xff), UInt8(rdlen & 0xff)]
        rec += mname
        rec += rname
        rec += [0, 0, 0, 1]                               // SERIAL
        rec += [0, 0, 0, 60]                              // REFRESH
        rec += [0, 0, 0, 60]                              // RETRY
        rec += [0, 0, 0, 60]                              // EXPIRE
        rec += [0, 0, 0, 1]                               // MINIMUM — the negative-cache TTL
        return rec
    }

    static func nxdomain(_ q: [UInt8]) -> [UInt8] {
        guard q.count >= 12 else { return [] }   // r[2…11] below would be out of range
        let qend = parseQName(q).map { $0.2 } ?? min(q.count, 12)
        var r = Array(q[0..<qend])
        r[2] = 0x84 | (q[2] & 0x01); r[3] = 0x83          // RA=1, RCODE=3 (NXDOMAIN)
        r[6] = 0; r[7] = 0; r[8] = 0; r[9] = 1; r[10] = 0; r[11] = 0   // NSCOUNT=1 (the SOA)
        r += soaAuthority(zone: NamedAccess.domain)
        return r
    }
}
