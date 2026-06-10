import Foundation

/// A tiny loopback DNS responder for direct (named) container access. macOS routes
/// `*.velox.local` here via `/etc/resolver/velox.local` (`nameserver 127.0.0.1` + `port`),
/// installed once by the porthelper grant. We answer `A` queries for `<name>.velox.local` with the
/// container's real IP (from `NameRegistry`); the host route + the guest firewall allow then carry
/// the traffic straight to the container — any protocol, no proxy. Unknown name → NXDOMAIN; AAAA →
/// empty NOERROR (so the stub resolver falls back to A). Binds loopback only: no privilege, no
/// entitlement. The wire-format mirrors the guest's `answer_dns` (guest/vinit/src/main.rs:433).
public final class NameDNSResponder: @unchecked Sendable {
    /// The suffix the resolver file routes to us (matches `NamedAccess.domain`).
    public static let domainSuffix = "." + NamedAccess.domain

    private let port: UInt16
    private let registry: NameRegistry
    private let queue = DispatchQueue(label: "dev.velox.dns")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

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
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.handleOne() }
        src.setCancelHandler { close(s) }
        source = src
        src.resume()
        Log.info("named-access DNS responder on 127.0.0.1:\(port)")
    }

    public func stop() {
        queue.async { self.source?.cancel(); self.source = nil; self.fd = -1 }
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
        _ = withUnsafePointer(to: &from) { fp in
            fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                reply.withUnsafeBytes { sendto(fd, $0.baseAddress, reply.count, 0, sa, fromLen) }
            }
        }
    }

    // MARK: wire-format (ported from the guest: parse_qname / build_a_reply / build_empty_reply)

    public static func buildReply(_ q: [UInt8], registry: NameRegistry) -> [UInt8] {
        guard let (name, qtype, qend) = parseQName(q), name.hasSuffix(domainSuffix) else { return nxdomain(q) }
        let bare = String(name.dropLast(domainSuffix.count))
        guard let ip = registry.address(for: bare) else { return nxdomain(q) }
        return qtype == 1 ? aReply(q, qend: qend, addr: ip) : emptyReply(q, qend: qend)
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

    static func nxdomain(_ q: [UInt8]) -> [UInt8] {
        let qend = parseQName(q).map { $0.2 } ?? min(q.count, 12)
        var r = Array(q[0..<qend])
        r[2] = 0x84 | (q[2] & 0x01); r[3] = 0x83          // RA=1, RCODE=3 (NXDOMAIN)
        r[6] = 0; r[7] = 0; r[8] = 0; r[9] = 0; r[10] = 0; r[11] = 0
        return r
    }
}
