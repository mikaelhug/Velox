import Foundation

// Codable models for the Docker Engine API responses the dashboards render.
// Field names follow Docker's PascalCase JSON via explicit CodingKeys, mapped to
// idiomatic Swift property names. All are `Sendable` so they cross the actor /
// main-actor boundary freely.

// MARK: - Containers

public struct ContainerSummary: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let names: [String]
    public let image: String
    public let state: String          // running | exited | paused | created | restarting | dead
    public let status: String         // "Up 3 minutes", "Exited (0) 2 hours ago"
    public let ports: [PortMapping]
    public let labels: [String: String]
    /// The container's IP(s) across its attached networks (`NetworkSettings.Networks[*].
    /// IPAddress`), non-empty only. Used by the conduit pool to dial the container directly
    /// (bypassing docker-proxy). See `directIP`.
    public let networkIPs: [String]

    /// Bind/volume mounts as the list endpoint reports them — shown in the
    /// Containers inspector (no extra inspect round-trip needed).
    public let mounts: [MountPoint]

    enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image"
        case state = "State", status = "Status", ports = "Ports"
        case labels = "Labels", networkSettings = "NetworkSettings", mounts = "Mounts"
    }

    private struct NetworkSettings: Decodable {
        let networks: [String: Endpoint]?
        struct Endpoint: Decodable {
            let ipAddress: String?
            enum CodingKeys: String, CodingKey { case ipAddress = "IPAddress" }
        }
        enum CodingKeys: String, CodingKey { case networks = "Networks" }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // Docker prefixes names with "/"; strip it for display.
        names = (try c.decodeIfPresent([String].self, forKey: .names) ?? [])
            .map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? "<none>"
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        ports = try c.decodeIfPresent([PortMapping].self, forKey: .ports) ?? []
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        let ns = try c.decodeIfPresent(NetworkSettings.self, forKey: .networkSettings)
        networkIPs = (ns?.networks?.values.compactMap { $0.ipAddress } ?? [])
            .filter { !$0.isEmpty }
        mounts = try c.decodeIfPresent([MountPoint].self, forKey: .mounts) ?? []
    }

    /// Memberwise init for mock fixtures and tests.
    public init(id: String, names: [String], image: String,
                state: String, status: String, ports: [PortMapping] = [],
                labels: [String: String] = [:], networkIPs: [String] = [],
                mounts: [MountPoint] = []) {
        self.id = id; self.names = names; self.image = image
        self.state = state; self.status = status; self.ports = ports
        self.labels = labels; self.networkIPs = networkIPs; self.mounts = mounts
    }

    /// The container's IP for direct-dial — only when unambiguous (exactly one attached
    /// network). With multiple networks the list endpoint can't tie a published port to a
    /// specific IP, so we return nil and the conduit falls back to docker-proxy (correct).
    public var directIP: String? { networkIPs.count == 1 ? networkIPs.first : nil }

    public var displayName: String { names.first ?? String(id.prefix(12)) }
    public var shortID: String { String(id.prefix(12)) }
    public var isRunning: Bool { state == "running" }
    public var isPaused: Bool { state == "paused" }

    /// Only ports actually published to the host (a `-p` / compose `ports:` host
    /// binding). Excludes Dockerfile `EXPOSE`-only ports — Docker reports those
    /// with no `publicPort`, and they aren't reachable from the host, so they
    /// shouldn't show up as if they were forwarded. Deduplicated (Docker lists the
    /// IPv4 and IPv6 binding of the same publish separately).
    public var publishedPortLabels: [String] { publishedBindings.map(\.label) }

    /// The deduplicated published bindings themselves — for UI affordances that need
    /// the host port (clickable `localhost:<port>` links), not just the label.
    public var publishedBindings: [PortMapping] {
        var seen = Set<String>()
        return ports.filter { $0.publicPort != nil }
            .filter { seen.insert($0.label).inserted }
    }

    /// The direct named-access hostname (`<name>.velox.local` → the container's real
    /// IP, any protocol, no `-p`) — present only when the engine can actually serve
    /// it: container running, with an unambiguous single-network IP (mirrors the
    /// `NameRegistry` rule in DockerEventsWatcher).
    public var namedAccessDomain: String? {
        guard isRunning, directIP != nil else { return nil }
        return "\(displayName.lowercased()).\(NamedAccess.domain)"
    }

    /// Compose project this container belongs to, if any (the standard
    /// `com.docker.compose.project` label set by `docker compose`).
    public var composeProject: String? {
        let p = labels["com.docker.compose.project"]
        return (p?.isEmpty == false) ? p : nil
    }
}

/// One mount from the container list endpoint (`Mounts`): a named volume or a
/// host bind, with where it lands in the container.
public struct MountPoint: Decodable, Sendable, Hashable {
    public let type: String        // "volume" | "bind" | "tmpfs"
    public let source: String      // volume name's host path, or the bind source
    public let destination: String // path inside the container

    enum CodingKeys: String, CodingKey {
        case type = "Type", source = "Source", destination = "Destination"
    }

    public init(type: String, source: String, destination: String) {
        self.type = type; self.source = source; self.destination = destination
    }
}

public struct PortMapping: Codable, Sendable, Hashable {
    public let ip: String?
    public let privatePort: Int
    public let publicPort: Int?
    public let type: String

    enum CodingKeys: String, CodingKey {
        case ip = "IP", privatePort = "PrivatePort", publicPort = "PublicPort", type = "Type"
    }

    public init(ip: String? = nil, privatePort: Int, publicPort: Int? = nil, type: String = "tcp") {
        self.ip = ip; self.privatePort = privatePort; self.publicPort = publicPort; self.type = type
    }

    /// "8080:80/tcp" when published, else "80/tcp".
    public var label: String {
        if let publicPort { return "\(publicPort):\(privatePort)/\(type)" }
        return "\(privatePort)/\(type)"
    }
}

// MARK: - Images

public struct ImageSummary: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let repoTags: [String]
    public let created: Int
    public let size: Int64
    /// Platform of the image's manifest(s), e.g. "arm64" / "amd64", or "multi"
    /// when several distinct architectures are present. Nil when the daemon
    /// doesn't report manifest platforms. Sourced from `?manifests=true`.
    public let architecture: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id", repoTags = "RepoTags", created = "Created", size = "Size"
        case manifests = "Manifests"
    }

    /// A single entry of the containerd-store `Manifests` array — just enough to
    /// pull the platform architecture out of the OCI descriptor.
    private struct Manifest: Decodable {
        let kind: String?
        let descriptor: Descriptor?
        let imageData: ImageData?
        enum CodingKeys: String, CodingKey {
            case kind = "Kind", descriptor = "Descriptor", imageData = "ImageData"
        }
        struct Descriptor: Decodable { let platform: Platform? }
        struct ImageData: Decodable {
            let platform: Platform?
            enum CodingKeys: String, CodingKey { case platform = "Platform" }
        }
        struct Platform: Decodable { let architecture: String? }

        /// Architecture for image-kind manifests with a real platform.
        var arch: String? {
            guard (kind ?? "image") == "image" else { return nil }
            let a = (descriptor?.platform ?? imageData?.platform)?.architecture
            guard let a, !a.isEmpty, a != "unknown" else { return nil }
            return a
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repoTags = try c.decodeIfPresent([String].self, forKey: .repoTags) ?? []
        created = try c.decodeIfPresent(Int.self, forKey: .created) ?? 0
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        let manifests = (try? c.decodeIfPresent([Manifest].self, forKey: .manifests)) ?? nil
        let archs = Set((manifests ?? []).compactMap(\.arch))
        architecture = archs.count > 1 ? "multi" : archs.first
    }

    public init(id: String, repoTags: [String], created: Int, size: Int64, architecture: String? = nil) {
        self.id = id; self.repoTags = repoTags; self.created = created; self.size = size
        self.architecture = architecture
    }

    /// Image ID without the "sha256:" prefix, truncated.
    public var shortID: String {
        let raw = id.hasPrefix("sha256:") ? String(id.dropFirst(7)) : id
        return String(raw.prefix(12))
    }

    /// First repo:tag split, falling back to <none>.
    public var repository: String { primaryTag.repository }
    public var tag: String { primaryTag.tag }

    private var primaryTag: (repository: String, tag: String) {
        guard let first = repoTags.first, first != "<none>:<none>",
              let idx = first.lastIndex(of: ":") else {
            return ("<none>", "<none>")
        }
        return (String(first[..<idx]), String(first[first.index(after: idx)...]))
    }
}

// MARK: - Volumes

public struct VolumeListResponse: Decodable, Sendable {
    public let volumes: [Volume]
    enum CodingKeys: String, CodingKey { case volumes = "Volumes" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumes = try c.decodeIfPresent([Volume].self, forKey: .volumes) ?? []
    }
    public init(volumes: [Volume]) { self.volumes = volumes }
}

public struct Volume: Decodable, Sendable, Identifiable, Hashable {
    public let name: String
    public let driver: String
    public let mountpoint: String
    public let createdAt: String?
    public let size: Int64?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name = "Name", driver = "Driver", mountpoint = "Mountpoint"
        case createdAt = "CreatedAt", usageData = "UsageData"
    }
    enum UsageKeys: String, CodingKey { case size = "Size" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        driver = try c.decodeIfPresent(String.self, forKey: .driver) ?? "local"
        mountpoint = try c.decodeIfPresent(String.self, forKey: .mountpoint) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        if let usage = try? c.nestedContainer(keyedBy: UsageKeys.self, forKey: .usageData) {
            let s = try usage.decodeIfPresent(Int64.self, forKey: .size) ?? -1
            size = s >= 0 ? s : nil
        } else {
            size = nil
        }
    }

    public init(name: String, driver: String = "local", mountpoint: String,
                createdAt: String? = nil, size: Int64? = nil) {
        self.name = name; self.driver = driver; self.mountpoint = mountpoint
        self.createdAt = createdAt; self.size = size
    }
}

// MARK: - Networks

public struct NetworkSummary: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let driver: String
    public let scope: String
    public let subnets: [String]
    public let attachedContainers: [AttachedContainer]

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", driver = "Driver", scope = "Scope"
        case ipam = "IPAM", containers = "Containers"
    }
    enum IPAMKeys: String, CodingKey { case config = "Config" }
    struct IPAMConfig: Codable { let subnet: String?; enum CodingKeys: String, CodingKey { case subnet = "Subnet" } }
    struct ContainerEndpoint: Codable {
        let name: String?; let ipv4: String?
        enum CodingKeys: String, CodingKey { case name = "Name", ipv4 = "IPv4Address" }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        driver = try c.decodeIfPresent(String.self, forKey: .driver) ?? ""
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "local"
        if let ipam = try? c.nestedContainer(keyedBy: IPAMKeys.self, forKey: .ipam),
           let configs = try? ipam.decodeIfPresent([IPAMConfig].self, forKey: .config) {
            subnets = configs.compactMap { $0.subnet }
        } else {
            subnets = []
        }
        if let map = try? c.decodeIfPresent([String: ContainerEndpoint].self, forKey: .containers) {
            attachedContainers = map.map {
                AttachedContainer(id: $0.key, name: $0.value.name ?? String($0.key.prefix(12)),
                                  ipv4: $0.value.ipv4)
            }.sorted { $0.name < $1.name }
        } else {
            attachedContainers = []
        }
    }

    public init(id: String, name: String, driver: String, scope: String = "local",
                subnets: [String] = [], attachedContainers: [AttachedContainer] = []) {
        self.id = id; self.name = name; self.driver = driver; self.scope = scope
        self.subnets = subnets; self.attachedContainers = attachedContainers
    }
}

public struct AttachedContainer: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let ipv4: String?
    public init(id: String, name: String, ipv4: String?) {
        self.id = id; self.name = name; self.ipv4 = ipv4
    }
}

// MARK: - Events

public struct DockerEvent: Codable, Sendable {
    public let type: String?       // "container", "image", "network", "volume"
    public let action: String?     // "start", "stop", "die", "create", "destroy", "pull"
    enum CodingKeys: String, CodingKey { case type = "Type", action = "Action" }
}

// MARK: - Stats

/// A single sampled CPU/memory reading for a container, already reduced from the
/// raw Docker stats payload into percentages/bytes the UI can plot directly.
public struct ContainerStatsSample: Sendable, Hashable {
    public let cpuPercent: Double      // 0…(100 * cores)
    public let memoryBytes: UInt64
    public let memoryLimit: UInt64

    public init(cpuPercent: Double, memoryBytes: UInt64, memoryLimit: UInt64) {
        self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes; self.memoryLimit = memoryLimit
    }
}

/// Raw Docker stats JSON (subset) used to compute a `ContainerStatsSample`.
struct RawStats: Codable {
    struct CPU: Codable {
        struct Usage: Codable { let total_usage: UInt64; let percpu_usage: [UInt64]? }
        let cpu_usage: Usage
        let system_cpu_usage: UInt64?
        let online_cpus: Int?
    }
    struct Memory: Codable {
        let usage: UInt64?
        let limit: UInt64?
        let stats: [String: UInt64]?
    }
    let cpu_stats: CPU
    let precpu_stats: CPU
    let memory_stats: Memory

    /// Docker's documented CPU% formula.
    func sample() -> ContainerStatsSample {
        let cpuDelta = Double(cpu_stats.cpu_usage.total_usage) - Double(precpu_stats.cpu_usage.total_usage)
        let sysDelta = Double(cpu_stats.system_cpu_usage ?? 0) - Double(precpu_stats.system_cpu_usage ?? 0)
        let cores = Double(cpu_stats.online_cpus ?? cpu_stats.cpu_usage.percpu_usage?.count ?? 1)
        let cpuPercent = (sysDelta > 0 && cpuDelta > 0) ? (cpuDelta / sysDelta) * cores * 100 : 0
        // Subtract cache so memory usage matches `docker stats`.
        let cache = memory_stats.stats?["inactive_file"] ?? memory_stats.stats?["cache"] ?? 0
        let usage = (memory_stats.usage ?? 0) >= cache ? (memory_stats.usage ?? 0) - cache : (memory_stats.usage ?? 0)
        return ContainerStatsSample(cpuPercent: cpuPercent,
                                    memoryBytes: usage,
                                    memoryLimit: memory_stats.limit ?? 0)
    }
}

// MARK: - Log frames

public struct LogFrame: Sendable, Hashable {
    public enum Stream: Sendable { case stdout, stderr }
    public let stream: Stream
    public let text: String
    public init(stream: Stream, text: String) { self.stream = stream; self.text = text }
}
