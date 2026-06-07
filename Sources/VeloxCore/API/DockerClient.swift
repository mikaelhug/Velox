import Foundation

/// Talks to the guest's `dockerd` over the Docker Engine HTTP API — but without
/// any external socket file, subprocess, or third-party HTTP stack.
///
/// Because the GUI process embeds the engine, the client opens an **in-process**
/// VSOCK connection straight to the guest (the same `VMManager.connectToGuestPort`
/// the proxy uses) and speaks HTTP/1.1 on that fd itself (see `HTTPCodec`). One
/// connection is used per request; streaming endpoints (logs/events/stats) hold
/// their connection open for the life of the stream. Blocking socket I/O runs on
/// a dedicated dispatch queue so it never stalls the actor or main thread.
public actor DockerClient: DockerClientProtocol {
    private nonisolated let manager: VMManager
    /// Docker Engine API version pinned in the request path (`/v1.47/…`).
    /// 1.47 is within every modern daemon's supported range (Docker 27 max,
    /// well above Docker 29's minimum), so it works without per-connection
    /// negotiation while still exposing the current endpoints we use.
    static let apiVersion = "v1.47"
    private static let ioQueue = DispatchQueue(label: "dev.velox.docker.io", attributes: .concurrent)

    public init(manager: VMManager) {
        self.manager = manager
    }

    private static func path(_ suffix: String) -> String { "/\(apiVersion)\(suffix)" }

    // MARK: - Unary exchange

    private func openConnection() async throws -> Int32 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            manager.connectToGuestPort(VsockPort.docker) { result in
                cont.resume(with: result)
            }
        }
    }

    private func send(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        let fd = try await openConnection()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            DockerClient.ioQueue.async {
                defer { close(fd) }
                do { cont.resume(returning: try HTTPCodec.perform(fd: fd, method: method, path: path, body: body)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw DockerError.decoding("\(error)") }
    }

    // MARK: - Lists

    public func containers() async throws -> [ContainerSummary] {
        try decode([ContainerSummary].self, from: await send("GET", Self.path("/containers/json?all=1")))
    }

    public func images() async throws -> [ImageSummary] {
        // `manifests=true` (API 1.47) attaches per-platform manifest descriptors,
        // which is how we surface each image's architecture from the containerd store.
        try decode([ImageSummary].self, from: await send("GET", Self.path("/images/json?manifests=true")))
    }

    public func volumes() async throws -> [Volume] {
        let volumes = try decode(VolumeListResponse.self, from: await send("GET", Self.path("/volumes"))).volumes
        guard !volumes.isEmpty else { return [] }

        guard let usage = try? decode(VolumeListResponse.self,
                                      from: await send("GET", Self.path("/system/df?type=volume")))
        else { return volumes }

        let sizesByName = Dictionary(uniqueKeysWithValues: usage.volumes.compactMap { volume -> (String, Int64)? in
            guard let size = volume.size else { return nil }
            return (volume.name, size)
        })

        return volumes.map { volume in
            guard let size = sizesByName[volume.name] else { return volume }
            return Volume(name: volume.name,
                          driver: volume.driver,
                          mountpoint: volume.mountpoint,
                          createdAt: volume.createdAt,
                          size: size)
        }
    }

    public func networks() async throws -> [NetworkSummary] {
        let summaries = try decode([NetworkSummary].self, from: await send("GET", Self.path("/networks")))
        var detailed: [NetworkSummary] = []
        detailed.reserveCapacity(summaries.count)

        for network in summaries {
            do {
                let data = try await send("GET", Self.path("/networks/\(network.id.urlEncoded)"))
                detailed.append(try decode(NetworkSummary.self, from: data))
            } catch DockerError.http(status: 404, message: _) {
                // Network disappeared between list and inspect; the next event-triggered
                // reconcile will see the settled state.
                continue
            }
        }

        return detailed
    }

    // MARK: - Container actions

    public func startContainer(_ id: String) async throws {
        _ = try await send("POST", Self.path("/containers/\(id)/start"))
    }
    public func stopContainer(_ id: String) async throws {
        _ = try await send("POST", Self.path("/containers/\(id)/stop"))
    }
    public func restartContainer(_ id: String) async throws {
        _ = try await send("POST", Self.path("/containers/\(id)/restart"))
    }
    public func removeContainer(_ id: String, force: Bool) async throws {
        _ = try await send("DELETE", Self.path("/containers/\(id)?force=\(force ? 1 : 0)&v=1"))
    }

    // MARK: - Image actions

    public func removeImage(_ id: String, force: Bool) async throws {
        _ = try await send("DELETE", Self.path("/images/\(id)?force=\(force ? 1 : 0)"))
    }
    public func pruneImages(all: Bool) async throws -> UInt64 {
        // dangling=false prunes *all* unused images, not just dangling layers.
        let filters = "{\"dangling\":[\"\(all ? "false" : "true")\"]}"
        let data = try await send("POST", Self.path("/images/prune?filters=\(filters.urlEncoded)"))
        return Self.spaceReclaimed(data)
    }

    // MARK: - Volume actions

    public func removeVolume(_ name: String, force: Bool) async throws {
        _ = try await send("DELETE", Self.path("/volumes/\(name)?force=\(force ? 1 : 0)"))
    }
    public func pruneVolumes() async throws -> UInt64 {
        Self.spaceReclaimed(try await send("POST", Self.path("/volumes/prune")))
    }

    private static func spaceReclaimed(_ data: Data) -> UInt64 {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0?["SpaceReclaimed"] as? UInt64 } ?? 0
    }

    // MARK: - Image pull (progress stream)

    public nonisolated func pullImage(_ reference: String) -> AsyncThrowingStream<String, Error> {
        let (image, tag) = Self.splitReference(reference)
        let path = Self.path("/images/create?fromImage=\(image.urlEncoded)&tag=\(tag.urlEncoded)")
        let manager = self.manager
        return AsyncThrowingStream { continuation in
            let cancelled = CancelFlag()
            continuation.onTermination = { _ in cancelled.cancel() }
            manager.connectToGuestPort(VsockPort.docker) { result in
                switch result {
                case .failure(let error):
                    continuation.finish(throwing: error)
                case .success(let fd):
                    DockerClient.ioQueue.async {
                        defer { close(fd) }
                        var acc = Data()
                        do {
                            try HTTPCodec.performStreaming(fd: fd, method: "POST", path: path,
                                                           isCancelled: { cancelled.isCancelled }) { bytes in
                                acc.append(bytes)
                                for line in acc.takeLines() {
                                    if let status = Self.progressLine(line) { continuation.yield(status) }
                                }
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }
        }
    }

    private static func progressLine(_ line: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if let err = obj["error"] as? String { return "error: \(err)" }
        let status = obj["status"] as? String ?? ""
        let progress = obj["progress"] as? String ?? ""
        let id = obj["id"] as? String
        let prefix = id.map { "\($0): " } ?? ""
        let text = progress.isEmpty ? status : "\(status) \(progress)"
        return text.isEmpty ? nil : prefix + text
    }

    // MARK: - Streams (events / stats / logs)

    public nonisolated func events() -> AsyncStream<DockerEvent> {
        makeStream(method: "GET", path: Self.path("/events")) { bytes, acc, yield in
            acc.append(bytes)
            for line in acc.takeLines() {
                if let event = try? JSONDecoder().decode(DockerEvent.self, from: line) { yield(event) }
            }
        }
    }

    public nonisolated func stats(container id: String) -> AsyncStream<ContainerStatsSample> {
        makeStream(method: "GET", path: Self.path("/containers/\(id)/stats?stream=1")) { bytes, acc, yield in
            acc.append(bytes)
            for line in acc.takeLines() {
                if let raw = try? JSONDecoder().decode(RawStats.self, from: line) { yield(raw.sample()) }
            }
        }
    }

    public nonisolated func logs(container id: String, tail: Int) -> AsyncStream<LogFrame> {
        let tailParam = tail > 0 ? "\(tail)" : "all"
        let path = Self.path("/containers/\(id)/logs?follow=1&stdout=1&stderr=1&tail=\(tailParam)")
        let parser = LogFrameParser()
        return makeStream(method: "GET", path: path) { bytes, acc, yield in
            acc.append(bytes)
            parser.parse(&acc, yield: yield)
        }
    }

    /// Generic streaming helper: open a VSOCK connection, run the blocking HTTP
    /// stream on `ioQueue`, and feed body bytes through `parse`, which yields
    /// decoded items into the AsyncStream. Cancellation propagates via `CancelFlag`.
    private nonisolated func makeStream<T: Sendable>(
        method: String,
        path: String,
        parse: @escaping @Sendable (Data, inout Data, (T) -> Void) -> Void
    ) -> AsyncStream<T> {
        let manager = self.manager
        return AsyncStream { continuation in
            let cancelled = CancelFlag()
            continuation.onTermination = { _ in cancelled.cancel() }
            manager.connectToGuestPort(VsockPort.docker) { result in
                switch result {
                case .failure:
                    continuation.finish()
                case .success(let fd):
                    DockerClient.ioQueue.async {
                        defer { close(fd); continuation.finish() }
                        var acc = Data()
                        try? HTTPCodec.performStreaming(fd: fd, method: method, path: path,
                                                        isCancelled: { cancelled.isCancelled }) { bytes in
                            parse(bytes, &acc) { item in continuation.yield(item) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Split "repo:tag" / "registry:port/repo" / "repo" into (image, tag).
    public static func splitReference(_ reference: String) -> (image: String, tag: String) {
        if let idx = reference.lastIndex(of: ":"),
           !reference[reference.index(after: idx)...].contains("/") {
            return (String(reference[..<idx]), String(reference[reference.index(after: idx)...]))
        }
        return (reference, "latest")
    }
}

/// Thread-safe cancellation flag shared between an AsyncStream and its blocking
/// reader task.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Parses Docker's multiplexed log stream (8-byte frame header + payload) into
/// `LogFrame`s, with a fallback to raw text for un-multiplexed (TTY) containers.
///
/// Stateful — one instance per log stream (the caller serializes `parse` calls). A
/// TTY stream has no frame headers, so once a non-multiplexed chunk is seen the
/// parser stays in raw mode for the rest of the stream; otherwise a later TTY chunk
/// that happened to start with byte 0/1/2 would be misread as a frame header.
public final class LogFrameParser: @unchecked Sendable {
    private var isTTY = false
    public init() {}

    public func parse(_ acc: inout Data, yield: (LogFrame) -> Void) {
        if isTTY {
            if !acc.isEmpty {
                yield(LogFrame(stream: .stdout, text: String(decoding: acc, as: UTF8.self)))
                acc.removeAll(keepingCapacity: true)
            }
            return
        }
        while acc.count >= 8 {
            let header = [UInt8](acc.prefix(8))
            let streamByte = header[0]
            // Non-multiplexed (TTY) stream: stream byte isn't 0/1/2 → switch to raw
            // mode for the rest of the stream and emit the buffer as text.
            guard streamByte <= 2 else {
                isTTY = true
                let text = String(decoding: acc, as: UTF8.self)
                acc.removeAll(keepingCapacity: true)
                if !text.isEmpty { yield(LogFrame(stream: .stdout, text: text)) }
                return
            }
            let size = (UInt32(header[4]) << 24) | (UInt32(header[5]) << 16)
                     | (UInt32(header[6]) << 8) | UInt32(header[7])
            guard acc.count >= 8 + Int(size) else { return } // wait for full frame
            let payload = acc.subdata(in: 8 ..< 8 + Int(size))
            acc.removeSubrange(0 ..< 8 + Int(size))
            let text = String(decoding: payload, as: UTF8.self)
            yield(LogFrame(stream: streamByte == 2 ? .stderr : .stdout, text: text))
        }
    }
}

private extension String {
    /// Percent-encode a query-parameter *value*: encode the characters that delimit a
    /// URL query (`& = + ;`) and anything not URL-safe, but leave registry/tag/filter
    /// punctuation (`. / : - _ ~` …) intact — so `ghcr.io/org/img:tag` and filter JSON
    /// aren't needlessly mangled (Docker decodes either way, but this is readable).
    var urlEncoded: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+;")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

private extension Data {
    /// Split off complete newline-terminated records, leaving any partial tail.
    mutating func takeLines() -> [Data] {
        var lines: [Data] = []
        while let idx = firstIndex(of: 0x0A) {
            let line = subdata(in: startIndex ..< idx)
            removeSubrange(startIndex ... idx)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}
