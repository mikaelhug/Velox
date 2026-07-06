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

    private func send(_ method: String, _ path: String, body: Data? = nil, readTimeout: Int32? = nil) async throws -> Data {
        let fd = try await openConnection()
        if let readTimeout {
            // Bound the wait so a wedged dockerd (accepts the VSOCK connection but never
            // replies) can't park this ioQueue thread + the awaiting Task forever. Only
            // the read-only reconcile calls pass this — never actions like `stop`, which
            // legitimately block until the container actually stops.
            var tv = timeval(tv_sec: Int(readTimeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            DockerClient.ioQueue.async {
                defer { close(fd) }
                do { cont.resume(returning: try HTTPCodec.perform(fd: fd, method: method, path: path, body: body)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private nonisolated func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw DockerError.decoding("\(error)") }
    }

    // MARK: - Lists

    public func containers() async throws -> [ContainerSummary] {
        try decode([ContainerSummary].self, from: await send("GET", Self.path("/containers/json?all=1"), readTimeout: 30))
    }

    public func images() async throws -> [ImageSummary] {
        // `manifests=true` (API 1.47) attaches per-platform manifest descriptors,
        // which is how we surface each image's architecture from the containerd store.
        try decode([ImageSummary].self, from: await send("GET", Self.path("/images/json?manifests=true"), readTimeout: 30))
    }

    public func volumes() async throws -> [Volume] {
        let volumes = try decode(VolumeListResponse.self, from: await send("GET", Self.path("/volumes"), readTimeout: 30)).volumes
        guard !volumes.isEmpty else { return [] }

        guard let usage = try? decode(VolumeListResponse.self,
                                      from: await send("GET", Self.path("/system/df?type=volume"), readTimeout: 30))
        else { return volumes }

        let sizesByName = Dictionary(usage.volumes.compactMap { volume -> (String, Int64)? in
            guard let size = volume.size else { return nil }
            return (volume.name, size)
        }, uniquingKeysWith: { first, _ in first })

        return volumes.map { volume in
            guard let size = sizesByName[volume.name] else { return volume }
            return Volume(name: volume.name,
                          driver: volume.driver,
                          mountpoint: volume.mountpoint,
                          createdAt: volume.createdAt,
                          size: size,
                          labels: volume.labels)
        }
    }

    public func networks() async throws -> [NetworkSummary] {
        let summaries = try decode([NetworkSummary].self, from: await send("GET", Self.path("/networks"), readTimeout: 30))
        guard !summaries.isEmpty else { return [] }
        // The summary list omits each network's attached-container list, so inspect each.
        // Do it **bounded-parallel** rather than 1+N serial: the per-network round-trips
        // overlap on the VSOCK path (the actor releases at each `await`), so a host with
        // many compose-project networks reconciles in a few batches, not N deep. Results
        // are slotted by index so the list order stays stable across refreshes.
        let maxConcurrent = min(summaries.count, 6)
        var results = [NetworkSummary?](repeating: nil, count: summaries.count)
        try await withThrowingTaskGroup(of: (Int, NetworkSummary?).self) { group in
            var next = 0
            func submit() {
                guard next < summaries.count else { return }
                let idx = next
                let id = summaries[idx].id
                next += 1
                group.addTask {
                    do {
                        let data = try await self.send("GET", Self.path("/networks/\(id.urlEncoded)"), readTimeout: 30)
                        return (idx, try self.decode(NetworkSummary.self, from: data))
                    } catch DockerError.http(status: 404, message: _) {
                        return (idx, nil) // disappeared between list and inspect
                    }
                }
            }
            for _ in 0..<maxConcurrent { submit() }
            while let (idx, ns) = try await group.next() {
                results[idx] = ns
                submit()
            }
        }
        return results.compactMap { $0 }
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
    public func pauseContainer(_ id: String) async throws {
        _ = try await send("POST", Self.path("/containers/\(id)/pause"))
    }
    public func inspectContainer(_ id: String) async throws -> ContainerInspect {
        try decode(ContainerInspect.self,
                   from: await send("GET", Self.path("/containers/\(id)/json"), readTimeout: 30))
    }
    public func pruneContainers() async throws -> UInt64 {
        Self.spaceReclaimed(try await send("POST", Self.path("/containers/prune")))
    }
    public func pruneBuildCache() async throws -> UInt64 {
        Self.spaceReclaimed(try await send("POST", Self.path("/build/prune")))
    }
    public func systemDiskUsage() async throws -> DiskUsage {
        // Volume sizing makes this endpoint slow on big stores — generous timeout.
        try decode(DiskUsage.self,
                   from: await send("GET", Self.path("/system/df"), readTimeout: 60))
    }
    public func unpauseContainer(_ id: String) async throws {
        _ = try await send("POST", Self.path("/containers/\(id)/unpause"))
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
        // `all=true` (docker volume prune -a): since API 1.42 the default prunes only
        // ANONYMOUS volumes — named unused volumes (what the size estimate counts and
        // what users mean by "unused") silently survive and the button looks broken
        // (measured: VolumesDeleted:[] with 1.8 GB of named unused volumes present).
        // Our UI gates this behind an off-by-default toggle + confirmation, and the
        // Reclaim flow prunes stopped containers FIRST, releasing the references that
        // otherwise make volumes un-prunable — so deliver what the dialog promises.
        let filters = "{\"all\":[\"true\"]}"
        return Self.spaceReclaimed(
            try await send("POST", Self.path("/volumes/prune?filters=\(filters.urlEncoded)")))
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
            let conn = StreamConnection()
            continuation.onTermination = { _ in conn.cancel() }
            manager.connectToGuestPort(VsockPort.docker) { result in
                switch result {
                case .failure(let error):
                    continuation.finish(throwing: error)
                case .success(let fd):
                    conn.attach(fd)
                    DockerClient.ioQueue.async {
                        defer { conn.closeFD() }
                        var acc = Data()
                        do {
                            try HTTPCodec.performStreaming(fd: fd, method: "POST", path: path,
                                                           isCancelled: { conn.isCancelled }) { bytes in
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
        // Only the freshest sample matters, so drop backlog if a consumer (a paused
        // table) falls behind — a slow UI can't grow an unbounded queue of stale samples.
        makeStream(method: "GET", path: Self.path("/containers/\(id)/stats?stream=1"),
                   bufferingPolicy: .bufferingNewest(2)) { bytes, acc, yield in
            acc.append(bytes)
            for line in acc.takeLines() {
                if let raw = try? JSONDecoder().decode(RawStats.self, from: line) { yield(raw.sample()) }
            }
        }
    }

    public nonisolated func logs(container id: String, tail: Int, since: Double?) -> AsyncStream<LogFrame> {
        let tailParam = tail > 0 ? "\(tail)" : "all"
        // Fixed C-locale format (period decimal) — dockerd parses `<sec>.<frac>`.
        let sinceParam = since.map { "&since=\(String(format: "%.6f", $0))" } ?? ""
        let path = Self.path("/containers/\(id)/logs?follow=1&stdout=1&stderr=1&tail=\(tailParam)\(sinceParam)")
        let parser = LogFrameParser()
        return makeStream(method: "GET", path: path) { bytes, acc, yield in
            acc.append(bytes)
            parser.parse(&acc, yield: yield)
        }
    }

    /// Generic streaming helper: open a VSOCK connection, run the blocking HTTP
    /// stream on `ioQueue`, and feed body bytes through `parse`, which yields
    /// decoded items into the AsyncStream. Cancellation shuts the fd down via
    /// `StreamConnection` so a reader blocked in `read()` unwinds promptly.
    private nonisolated func makeStream<T: Sendable>(
        method: String,
        path: String,
        bufferingPolicy: AsyncStream<T>.Continuation.BufferingPolicy = .unbounded,
        parse: @escaping @Sendable (Data, inout Data, (T) -> Void) -> Void
    ) -> AsyncStream<T> {
        let manager = self.manager
        return AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let conn = StreamConnection()
            continuation.onTermination = { _ in conn.cancel() }
            manager.connectToGuestPort(VsockPort.docker) { result in
                switch result {
                case .failure:
                    continuation.finish()
                case .success(let fd):
                    conn.attach(fd)
                    DockerClient.ioQueue.async {
                        defer { conn.closeFD(); continuation.finish() }
                        var acc = Data()
                        try? HTTPCodec.performStreaming(fd: fd, method: method, path: path,
                                                        isCancelled: { conn.isCancelled }) { bytes in
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

/// Owns the fd of a streaming vsock connection and makes cancellation *interrupt* a
/// blocked read instead of only flipping a flag the reader checks between reads.
///
/// The streaming readers (`HTTPCodec.streamChunked`/`streamRaw`) block in `read()`
/// inside `SocketChannel.fill()`; they only re-check `isCancelled` *between* reads. So
/// on an idle stream (a quiet `logs -f`, an `events()` stream with no Docker activity)
/// a parked reader would never notice a flag flip — leaking the dup'd vsock fd and its
/// `ioQueue` thread until bytes arrive. `cancel()` therefore `shutdown()`s the fd,
/// which forces the blocked `read()` to return so the reader unwinds through its
/// `defer { conn.close() }`. `close()` closes exactly once and nulls the fd, so a
/// cancel racing with normal teardown is a harmless no-op (no double-close / fd reuse).
final class StreamConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32?
    private var cancelled = false

    /// Cheap between-reads check passed to `performStreaming` (fast path).
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Register the fd once connected; if cancellation already fired, shut it down now.
    func attach(_ newFd: Int32) {
        lock.lock(); defer { lock.unlock() }
        fd = newFd
        if cancelled { shutdown(newFd, SHUT_RDWR) }
    }

    /// Interrupt a blocked read by shutting the connection down.
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let fd { shutdown(fd, SHUT_RDWR) }
    }

    /// Close the fd exactly once; a later `cancel()` then sees no fd and does nothing.
    func closeFD() {
        lock.lock(); defer { lock.unlock() }
        if let fd { Darwin.close(fd); self.fd = nil }
    }
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
