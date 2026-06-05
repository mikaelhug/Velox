import Foundation

/// Minimal Docker Engine API client over the unix socket. Used to discover
/// which host ports running containers publish, for reverse port-forwarding.
enum DockerAPI {
    /// Set of published TCP host ports across running containers, or nil if the
    /// daemon isn't reachable / response couldn't be parsed.
    static func publishedTCPPorts(socketPath: String) -> Set<UInt16>? {
        guard let body = httpGetBody(socketPath: socketPath, path: "/v1.47/containers/json"),
              let json = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]]
        else { return nil }

        var ports: Set<UInt16> = []
        for container in json {
            guard let portList = container["Ports"] as? [[String: Any]] else { continue }
            for p in portList {
                let type = (p["Type"] as? String) ?? "tcp"
                guard type == "tcp", let pub = p["PublicPort"] as? Int,
                      pub > 0, pub <= 65535 else { continue }
                ports.insert(UInt16(pub))
            }
        }
        return ports
    }

    /// Number of currently running containers, or nil if the daemon isn't
    /// reachable. `/containers/json` (without `all`) lists only running ones, so
    /// the array length is the count. Used by Resource Saver to decide when the
    /// engine is idle.
    static func runningContainerCount(socketPath: String) -> Int? {
        guard let body = httpGetBody(socketPath: socketPath, path: "/v1.47/containers/json"),
              let json = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]]
        else { return nil }
        return json.count
    }

    /// GET over the unix socket; returns the (de-chunked) response body.
    private static func httpGetBody(socketPath: String, path: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else { return nil }

        let request = "GET \(path) HTTP/1.1\r\nHost: velox\r\nConnection: close\r\n\r\n"
        guard writeAll(fd, Array(request.utf8)) else { return nil }

        var raw = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            raw.append(contentsOf: buffer[0..<n])
        }

        let crlf2 = Data("\r\n\r\n".utf8)
        guard let sep = raw.range(of: crlf2) else { return nil }
        let headerData = raw[raw.startIndex..<sep.lowerBound]
        let bodyData = Data(raw[sep.upperBound...])
        let headers = (String(data: headerData, encoding: .utf8) ?? "").lowercased()

        if headers.contains("transfer-encoding: chunked") {
            return dechunk(bodyData)
        }
        return bodyData
    }

    /// Decode HTTP/1.1 chunked transfer-encoding into the raw payload.
    private static func dechunk(_ data: Data) -> Data {
        var out = Data()
        let crlf = Data("\r\n".utf8)
        var i = data.startIndex
        while i < data.endIndex {
            guard let r = data.range(of: crlf, in: i..<data.endIndex) else { break }
            let sizeLine = String(data: data[i..<r.lowerBound], encoding: .utf8) ?? ""
            let hex = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
            guard let chunkSize = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16),
                  chunkSize > 0 else { break }
            let chunkStart = r.upperBound
            guard let chunkEnd = data.index(chunkStart, offsetBy: chunkSize, limitedBy: data.endIndex)
            else { break }
            out.append(data[chunkStart..<chunkEnd])
            // Skip the CRLF that terminates the chunk.
            i = data.index(chunkEnd, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        return bytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            while offset < bytes.count {
                let n = write(fd, base + offset, bytes.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}
