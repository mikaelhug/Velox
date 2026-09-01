import Foundation

/// The surface the dashboards depend on. `DockerClient` implements it live over
/// VSOCK; `MockDockerClient` implements it with fixtures so SwiftUI previews and
/// tests run without a VM.
public protocol DockerClientProtocol: Sendable {
    // Lists
    func containers() async throws -> [ContainerSummary]
    func images() async throws -> [ImageSummary]
    func volumes() async throws -> [Volume]
    func networks() async throws -> [NetworkSummary]

    // Container actions
    func startContainer(_ id: String) async throws
    func stopContainer(_ id: String) async throws
    func restartContainer(_ id: String) async throws
    func pauseContainer(_ id: String) async throws
    func unpauseContainer(_ id: String) async throws
    func removeContainer(_ id: String, force: Bool) async throws
    func inspectContainer(_ id: String) async throws -> ContainerInspect
    func pruneContainers() async throws -> UInt64
    func pruneBuildCache() async throws -> UInt64
    func systemDiskUsage() async throws -> DiskUsage
    /// `GET /info` — the daemon's host: CPU count, RAM, OS, engine version.
    func systemInfo() async throws -> SystemInfo

    // Image actions
    func pullImage(_ reference: String) -> AsyncThrowingStream<String, Error>
    func removeImage(_ id: String, force: Bool) async throws
    func pruneImages(all: Bool) async throws -> UInt64

    // Volume actions
    func removeVolume(_ name: String, force: Bool) async throws
    func pruneVolumes() async throws -> UInt64

    // Streams
    func events() -> AsyncStream<DockerEvent>
    func stats(container id: String) -> AsyncStream<ContainerStatsSample>
    /// Follow a container's logs. `tail` bounds the initial backlog; `since` (a Unix
    /// timestamp, fractional seconds allowed) returns only logs newer than that moment
    /// — used to reattach after a restart without re-printing the persisted history.
    func logs(container id: String, tail: Int, since: Double?) -> AsyncStream<LogFrame>
}
