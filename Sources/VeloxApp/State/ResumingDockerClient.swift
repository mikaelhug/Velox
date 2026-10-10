import Foundation
import VeloxCore

/// The dashboard's Docker client while the engine is idle (stopped by Resource Saver).
///
/// The dashboards keep showing the last lists they had — their store is frozen, so nothing
/// refreshes on its own and merely looking at Velox never resumes the engine. A real request
/// from the user (start a container, remove an image, open a log, inspect one) comes through
/// here instead: it resumes the engine first, then runs on the live client the resume created.
/// The dashboards are already written against `any DockerClientProtocol` (CLAUDE.md §12), so
/// this needs no changes to them.
final class ResumingDockerClient: DockerClientProtocol, @unchecked Sendable {
    /// Resume the engine and return its live client, or nil if it could not be resumed.
    private let resume: @Sendable () async -> (any DockerClientProtocol)?

    init(resume: @escaping @Sendable () async -> (any DockerClientProtocol)?) {
        self.resume = resume
    }

    struct NotResumed: LocalizedError {
        var errorDescription: String? { "The Velox engine could not be resumed." }
    }

    private func live() async throws -> any DockerClientProtocol {
        guard let client = await resume() else { throw NotResumed() }
        return client
    }

    // Lists
    func containers() async throws -> [ContainerSummary] { try await live().containers() }
    func images() async throws -> [ImageSummary] { try await live().images() }
    func volumes() async throws -> [Volume] { try await live().volumes() }
    func networks() async throws -> [NetworkSummary] { try await live().networks() }

    // Container actions
    func startContainer(_ id: String) async throws { try await live().startContainer(id) }
    func stopContainer(_ id: String) async throws { try await live().stopContainer(id) }
    func restartContainer(_ id: String) async throws { try await live().restartContainer(id) }
    func pauseContainer(_ id: String) async throws { try await live().pauseContainer(id) }
    func unpauseContainer(_ id: String) async throws { try await live().unpauseContainer(id) }
    func removeContainer(_ id: String, force: Bool) async throws {
        try await live().removeContainer(id, force: force)
    }
    func inspectContainer(_ id: String) async throws -> ContainerInspect {
        try await live().inspectContainer(id)
    }
    func pruneContainers() async throws -> UInt64 { try await live().pruneContainers() }
    func pruneBuildCache() async throws -> UInt64 { try await live().pruneBuildCache() }
    func systemDiskUsage() async throws -> DiskUsage { try await live().systemDiskUsage() }
    func systemInfo() async throws -> SystemInfo { try await live().systemInfo() }

    // Image and volume actions
    func removeImage(_ id: String, force: Bool) async throws { try await live().removeImage(id, force: force) }
    func pruneImages(all: Bool) async throws -> UInt64 { try await live().pruneImages(all: all) }
    func removeVolume(_ name: String, force: Bool) async throws {
        try await live().removeVolume(name, force: force)
    }
    func pruneVolumes() async throws -> UInt64 { try await live().pruneVolumes() }

    // Streams: resume when the stream is first consumed, then relay the live one.
    func pullImage(_ reference: String) -> AsyncThrowingStream<String, Error> {
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
    func events() -> AsyncStream<DockerEvent> { relay { $0.events() } }
    func stats(container id: String) -> AsyncStream<ContainerStatsSample> { relay { $0.stats(container: id) } }
    func logs(container id: String, tail: Int, since: Double?) -> AsyncStream<LogFrame> {
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
