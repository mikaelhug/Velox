import Foundation

/// A Docker client that follows the embedded engine across idle stops (Resource Saver) instead of
/// being tied to one boot's connection. Every call first asks `resolve` for the engine's live
/// client, then runs on it. What `resolve` does while the engine is idle is the caller's policy:
///
/// - **Resume** — the dashboards' client while idle. Their lists stay on screen, frozen, and a
///   real action (start, remove, inspect, open a log) boots the engine before it runs.
/// - **Wait** — log windows. A window left open across an idle stop must neither resume the engine
///   (it would never stay idle) nor give up; it parks until the engine is live again, whoever
///   resumes it.
///
/// `resolve` returning nil means the engine is gone for good (stopped, failed): calls throw
/// `Unavailable` and streams finish. The type adds no state of its own, so it is a plain
/// `Sendable` — and it is the one implementation of this forwarding (CLAUDE.md §10).
public final class EngineDockerClient: DockerClientProtocol, Sendable {
    private let resolve: @Sendable () async -> (any DockerClientProtocol)?

    public init(resolve: @escaping @Sendable () async -> (any DockerClientProtocol)?) {
        self.resolve = resolve
    }

    public struct Unavailable: LocalizedError {
        public var errorDescription: String? { "The Velox engine is not running." }
    }

    private func live() async throws -> any DockerClientProtocol {
        guard let client = await resolve() else { throw Unavailable() }
        return client
    }

    // Lists
    public func containers() async throws -> [ContainerSummary] { try await live().containers() }
    public func images() async throws -> [ImageSummary] { try await live().images() }
    public func volumes() async throws -> [Volume] { try await live().volumes() }
    public func networks() async throws -> [NetworkSummary] { try await live().networks() }

    // Container actions
    public func startContainer(_ id: String) async throws { try await live().startContainer(id) }
    public func stopContainer(_ id: String) async throws { try await live().stopContainer(id) }
    public func restartContainer(_ id: String) async throws { try await live().restartContainer(id) }
    public func pauseContainer(_ id: String) async throws { try await live().pauseContainer(id) }
    public func unpauseContainer(_ id: String) async throws { try await live().unpauseContainer(id) }
    public func removeContainer(_ id: String, force: Bool) async throws {
        try await live().removeContainer(id, force: force)
    }
    public func inspectContainer(_ id: String) async throws -> ContainerInspect {
        try await live().inspectContainer(id)
    }
    public func pruneContainers() async throws -> UInt64 { try await live().pruneContainers() }
    public func pruneBuildCache() async throws -> UInt64 { try await live().pruneBuildCache() }
    public func systemDiskUsage() async throws -> DiskUsage { try await live().systemDiskUsage() }
    public func systemInfo() async throws -> SystemInfo { try await live().systemInfo() }

    // Image and volume actions
    public func removeImage(_ id: String, force: Bool) async throws {
        try await live().removeImage(id, force: force)
    }
    public func pruneImages(all: Bool) async throws -> UInt64 { try await live().pruneImages(all: all) }
    public func removeVolume(_ name: String, force: Bool) async throws {
        try await live().removeVolume(name, force: force)
    }
    public func pruneVolumes() async throws -> UInt64 { try await live().pruneVolumes() }

    // Streams: resolve when first consumed, then relay the live one.
    public func pullImage(_ reference: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in try await live().pullImage(reference) { continuation.yield(line) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func events() -> AsyncStream<DockerEvent> { relay { $0.events() } }
    public func stats(container id: String) -> AsyncStream<ContainerStatsSample> {
        relay { $0.stats(container: id) }
    }
    public func logs(container id: String, tail: Int, since: Double?) -> AsyncStream<LogFrame> {
        relay { $0.logs(container: id, tail: tail, since: since) }
    }

    private func relay<T: Sendable>(_ open: @escaping @Sendable (any DockerClientProtocol) -> AsyncStream<T>)
        -> AsyncStream<T> {
        AsyncStream { continuation in
            let task = Task {
                if let client = try? await live() {
                    for await item in open(client) { continuation.yield(item) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
