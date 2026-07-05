import Foundation

/// Errors from the in-process Docker HTTP exchange.
public enum DockerError: Error, CustomStringConvertible, Sendable {
    case transport(String)
    case http(status: Int, message: String)
    case decoding(String)

    public var description: String {
        switch self {
        case .transport(let m): return "connection error: \(m)"
        case .http(let s, let m): return "docker API error \(s): \(m)"
        case .decoding(let m): return "could not decode docker response: \(m)"
        }
    }
}

/// A minimal HTTP/1.1 client that speaks directly on a connected socket fd —
/// no URLSession, no third-party stack. Used over the in-process VSOCK fd to the
/// guest dockerd relay. All calls are blocking and meant to run off the main /
/// actor executor (see `DockerClient`).
public enum HTTPCodec {
    // MARK: Request building

    public static func request(method: String, path: String, body: Data? = nil) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: docker\r\n"
        head += "User-Agent: VeloxApp\r\n"
        head += "Accept: application/json\r\n"
        head += "Connection: close\r\n"
        if let body {
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }

    // MARK: Unary exchange

    /// Read a complete HTTP response off `fd` (status + decoded body), without
    /// judging the status code. Handles Content-Length, chunked, and read-to-EOF.
    public static func readResponse(fd: Int32) throws -> (status: Int, body: Data) {
        let channel = SocketChannel(fd: fd)
        let (status, headers) = try channel.readResponseHead()
        return (status, try channel.readFullBody(headers: headers))
    }

    /// Perform a request and read the full response. Throws `DockerError.http`
    /// for non-2xx. Blocking.
    static func perform(fd: Int32, method: String, path: String, body: Data? = nil) throws -> Data {
        try writeAll(fd, request(method: method, path: path, body: body))
        let (status, payload) = try readResponse(fd: fd)
        guard (200..<300).contains(status) else {
            let message = String(data: payload, encoding: .utf8).map(extractMessage) ?? ""
            throw DockerError.http(status: status, message: message)
        }
        return payload
    }

    /// Perform a streaming request: read the head, then deliver body bytes to
    /// `onBytes` as they arrive until EOF or `isCancelled()` becomes true.
    /// Handles both chunked transfer-encoding and raw (length-less) streams.
    static func performStreaming(fd: Int32, method: String, path: String,
                                 isCancelled: () -> Bool,
                                 onBytes: (Data) -> Void) throws {
        try writeAll(fd, request(method: method, path: path))
        let channel = SocketChannel(fd: fd)
        let (status, headers) = try channel.readResponseHead()
        guard (200..<300).contains(status) else {
            throw DockerError.http(status: status, message: "stream rejected")
        }
        let chunked = (headers["transfer-encoding"] ?? "").contains("chunked")
        if chunked {
            try channel.streamChunked(isCancelled: isCancelled, onBytes: onBytes)
        } else {
            try channel.streamRaw(isCancelled: isCancelled, onBytes: onBytes)
        }
    }

    /// Pull a human-readable `message` out of Docker's `{"message": "..."}`.
    private static func extractMessage(_ body: String) -> String {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = obj["message"] as? String {
            return msg
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Low-level write

    /// Throwing wrapper over the shared `FDIO.writeAll` (the API layer reports transport
    /// failures as `DockerError`; the proxy layers use the Bool form directly).
    static func writeAll(_ fd: Int32, _ data: Data) throws {
        guard FDIO.writeAll(fd, data) else {
            throw DockerError.transport("write failed (errno \(errno))")
        }
    }
}

/// Buffered reader over a blocking socket fd. Supports line reads (for HTTP
/// headers and chunk sizes), fixed-length reads, and raw passthrough streaming.
final class SocketChannel {
    private let fd: Int32
    private var buffer = [UInt8]()
    private var head = 0          // first unconsumed byte; consuming advances this index
    private var eof = false       // (instead of front-shifting the whole buffer per read)

    init(fd: Int32) { self.fd = fd }

    /// Unconsumed bytes available.
    private var available: Int { buffer.count - head }

    /// Drop the already-consumed prefix — amortized: only shift when the dead prefix is
    /// sizeable, so steady streaming doesn't memmove the tail on every consume (the old
    /// `removeSubrange(0..<n)` was O(n) per read → O(n²) over a long log/stats stream).
    private func compact() {
        guard head > 0 else { return }
        if head == buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else if head >= 16 * 1024 || head > buffer.count / 2 {
            buffer.removeFirst(head)
        } else {
            return
        }
        head = 0
    }

    /// Read the status line + headers. Returns (status, lowercased headers).
    func readResponseHead() throws -> (Int, [String: String]) {
        guard let statusLine = try readLine() else {
            throw DockerError.transport("connection closed before response")
        }
        // "HTTP/1.1 200 OK"
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        let status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        var headers: [String: String] = [:]
        while let line = try readLine(), !line.isEmpty {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return (status, headers)
    }

    /// Read the whole body using Content-Length, chunked decoding, or read-to-EOF.
    func readFullBody(headers: [String: String]) throws -> Data {
        if (headers["transfer-encoding"] ?? "").contains("chunked") {
            var out = Data()
            try streamChunked(isCancelled: { false }) { out.append($0) }
            return out
        }
        if let lenStr = headers["content-length"], let len = Int(lenStr) {
            return try readExactly(len)
        }
        // No length: read until the peer closes (Connection: close).
        var out = Data()
        while let data = try readSome() { out.append(data) }
        return out
    }

    // MARK: Streaming

    func streamChunked(isCancelled: () -> Bool, onBytes: (Data) -> Void) throws {
        while !isCancelled() {
            guard let sizeLine = try readLine() else { return }
            // Chunk size is hex, optionally with ";ext".
            let hex = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw DockerError.transport("bad chunk size \"\(sizeLine)\"")
            }
            if size == 0 { _ = try readLine(); return } // trailer CRLF
            let chunk = try readExactly(size)
            _ = try readLine() // trailing CRLF after chunk data
            if !chunk.isEmpty { onBytes(chunk) }
        }
    }

    func streamRaw(isCancelled: () -> Bool, onBytes: (Data) -> Void) throws {
        // Flush anything already buffered (read alongside the headers), then stream.
        if available > 0 {
            onBytes(Data(buffer[head...])); head = buffer.count
        }
        while !isCancelled(), let data = try readSome() {
            onBytes(data)
        }
    }

    // MARK: Primitives

    private func fill() throws {
        compact() // reclaim the consumed prefix before growing the buffer
        var tmp = [UInt8](repeating: 0, count: 16 * 1024)
        let n = tmp.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n > 0 { buffer.append(contentsOf: tmp[0..<n]) }
        else if n == 0 { eof = true }
        else if errno == EINTR { return }
        else { throw DockerError.transport("read failed (errno \(errno))") }
    }

    private func readLine() throws -> String? {
        while true {
            if let nl = buffer[head...].firstIndex(of: 0x0A) { // absolute index into buffer
                var end = nl
                if end > head && buffer[end - 1] == 0x0D { end -= 1 } // drop \r
                let line = String(decoding: buffer[head..<end], as: UTF8.self)
                head = nl + 1
                return line
            }
            if eof {
                if available == 0 { return nil }
                let line = String(decoding: buffer[head...], as: UTF8.self)
                head = buffer.count
                return line
            }
            try fill()
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        while available < count {
            if eof {
                // Peer closed before the full Content-Length / chunk arrived. Surface a
                // transport error rather than silently returning a truncated body (which
                // would otherwise become a confusing JSON-decode failure downstream).
                throw DockerError.transport("unexpected EOF: got \(available) of \(count) bytes")
            }
            try fill()
        }
        let data = Data(buffer[head ..< head + count])
        head += count
        return data
    }

    /// Return some bytes (buffered or freshly read), or nil at EOF.
    private func readSome() throws -> Data? {
        if available == 0 {
            if eof { return nil }
            try fill()
            if available == 0 { return nil }
        }
        let data = Data(buffer[head...])
        head = buffer.count
        return data
    }
}
