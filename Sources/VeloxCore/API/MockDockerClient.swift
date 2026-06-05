import Foundation

/// In-memory Docker client used by SwiftUI previews and unit tests, so the whole
/// UI renders (and animates sparklines/logs) with zero VM running.
public final class MockDockerClient: DockerClientProtocol, @unchecked Sendable {
    public init() {}

    // MARK: Fixtures

    public static let sampleContainers: [ContainerSummary] = [
        ContainerSummary(id: "a1b2c3d4e5f60000000000000000000000000000000000000000000000000000",
                         names: ["web"], image: "nginx:latest", state: "running",
                         status: "Up 12 minutes",
                         ports: [PortMapping(privatePort: 80, publicPort: 8080)]),
        ContainerSummary(id: "b2c3d4e5f6a70000000000000000000000000000000000000000000000000000",
                         names: ["api"], image: "ghcr.io/acme/api:2.3", state: "running",
                         status: "Up 3 hours",
                         ports: [PortMapping(privatePort: 3000, publicPort: 3000)]),
        ContainerSummary(id: "c3d4e5f6a7b80000000000000000000000000000000000000000000000000000",
                         names: ["cache"], image: "redis:7", state: "paused",
                         status: "Up 1 hour (Paused)",
                         ports: [PortMapping(privatePort: 6379)]),
        ContainerSummary(id: "d4e5f6a7b8c90000000000000000000000000000000000000000000000000000",
                         names: ["migrate"], image: "acme/migrate:latest", state: "exited",
                         status: "Exited (0) 5 minutes ago"),
    ]

    public static let sampleImages: [ImageSummary] = [
        ImageSummary(id: "sha256:aaaa111122223333444455556666777788889999aaaabbbbccccddddeeeeffff",
                     repoTags: ["nginx:latest"], created: 1_717_000_000, size: 187_000_000, architecture: "arm64"),
        ImageSummary(id: "sha256:bbbb111122223333444455556666777788889999aaaabbbbccccddddeeeeffff",
                     repoTags: ["redis:7"], created: 1_716_000_000, size: 138_000_000, architecture: "arm64"),
        ImageSummary(id: "sha256:cccc111122223333444455556666777788889999aaaabbbbccccddddeeeeffff",
                     repoTags: ["ghcr.io/acme/api:2.3"], created: 1_715_000_000, size: 92_000_000, architecture: "amd64"),
        ImageSummary(id: "sha256:dddd111122223333444455556666777788889999aaaabbbbccccddddeeeeffff",
                     repoTags: [], created: 1_714_000_000, size: 5_300_000, architecture: "multi"),
    ]

    public static let sampleVolumes: [Volume] = [
        Volume(name: "pgdata", mountpoint: "/var/lib/docker/volumes/pgdata/_data",
               createdAt: "2026-05-30T10:00:00Z", size: 412_000_000),
        Volume(name: "redis-cache", mountpoint: "/var/lib/docker/volumes/redis-cache/_data",
               createdAt: "2026-06-01T08:30:00Z", size: 24_000_000),
        Volume(name: "build-cache", driver: "local",
               mountpoint: "/var/lib/docker/volumes/build-cache/_data", size: nil),
    ]

    public static let sampleNetworks: [NetworkSummary] = [
        NetworkSummary(id: "f00d0000000000000000000000000000", name: "bridge", driver: "bridge",
                       subnets: ["172.17.0.0/16"],
                       attachedContainers: [AttachedContainer(id: "a1b2c3d4e5f6", name: "web", ipv4: "172.17.0.2/16")]),
        NetworkSummary(id: "f00d0000000000000000000000000001", name: "host", driver: "host"),
        NetworkSummary(id: "f00d0000000000000000000000000002", name: "none", driver: "null"),
        NetworkSummary(id: "f00d0000000000000000000000000003", name: "acme_default", driver: "bridge",
                       subnets: ["172.20.0.0/16"],
                       attachedContainers: [
                        AttachedContainer(id: "b2c3d4e5f6a7", name: "api", ipv4: "172.20.0.2/16"),
                        AttachedContainer(id: "c3d4e5f6a7b8", name: "cache", ipv4: "172.20.0.3/16"),
                       ]),
    ]

    // MARK: Lists

    public func containers() async throws -> [ContainerSummary] { Self.sampleContainers }
    public func images() async throws -> [ImageSummary] { Self.sampleImages }
    public func volumes() async throws -> [Volume] { Self.sampleVolumes }
    public func networks() async throws -> [NetworkSummary] { Self.sampleNetworks }

    // MARK: Actions (no-ops)

    public func startContainer(_ id: String) async throws {}
    public func stopContainer(_ id: String) async throws {}
    public func restartContainer(_ id: String) async throws {}
    public func removeContainer(_ id: String, force: Bool) async throws {}
    public func tagImage(_ id: String, repository: String, tag: String) async throws {}
    public func removeImage(_ id: String, force: Bool) async throws {}
    public func pruneImages(all: Bool) async throws -> UInt64 { 5_300_000 }
    public func removeVolume(_ name: String, force: Bool) async throws {}
    public func pruneVolumes() async throws -> UInt64 { 24_000_000 }

    // MARK: Streams

    public func pullImage(_ reference: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for step in ["Pulling from library/\(reference)", "Downloading", "Extracting", "Pull complete"] {
                    continuation.yield(step)
                    try? await Task.sleep(for: .milliseconds(250))
                }
                continuation.finish()
            }
        }
    }

    public func events() -> AsyncStream<DockerEvent> {
        AsyncStream { $0.finish() }
    }

    public func stats(container id: String) -> AsyncStream<ContainerStatsSample> {
        AsyncStream { continuation in
            Task {
                var t = 0.0
                while !Task.isCancelled {
                    let cpu = 20 + 18 * (1 + sin(t)) + 6 * (1 + sin(t * 3.3))
                    let mem = UInt64(120_000_000 + 40_000_000 * (1 + sin(t * 0.7)))
                    continuation.yield(ContainerStatsSample(cpuPercent: cpu, memoryBytes: mem,
                                                            memoryLimit: 512_000_000))
                    t += 0.4
                    try? await Task.sleep(for: .milliseconds(500))
                }
                continuation.finish()
            }
        }
    }

    public func logs(container id: String, tail: Int) -> AsyncStream<LogFrame> {
        AsyncStream { continuation in
            Task {
                let lines = [
                    LogFrame(stream: .stdout, text: "\u{1B}[32mINFO\u{1B}[0m server listening on :80\n"),
                    LogFrame(stream: .stdout, text: "\u{1B}[36mGET\u{1B}[0m /healthz 200 1ms\n"),
                    LogFrame(stream: .stderr, text: "\u{1B}[33mWARN\u{1B}[0m slow query (123ms)\n"),
                    LogFrame(stream: .stdout, text: "\u{1B}[36mGET\u{1B}[0m /api/users 200 8ms\n"),
                ]
                var i = 0
                while !Task.isCancelled {
                    continuation.yield(lines[i % lines.count])
                    i += 1
                    try? await Task.sleep(for: .milliseconds(700))
                }
                continuation.finish()
            }
        }
    }
}
