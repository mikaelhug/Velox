import Foundation

/// User preferences persisted to `~/.velox/config.json`. This is the GUI's
/// source of truth for resource allocation and file sharing; the engine reads it
/// at boot. Decoding tolerates missing keys so older/newer files still load.
public struct VeloxConfig: Codable, Sendable, Equatable {
    public enum UpdateBehavior: String, Codable, Sendable, CaseIterable {
        case manual    // never check automatically
        case notify    // check and notify (default)
        case automatic // download + install when available
    }

    public var cpuCount: Int
    public var memoryGiB: Int
    public var diskGiB: Int
    public var fileShares: [String]      // absolute host directory paths
    public var launchAtLogin: Bool
    public var updateBehavior: UpdateBehavior
    public var defaultTerminal: String   // app name used for "Open in Terminal"

    public init(cpuCount: Int, memoryGiB: Int, diskGiB: Int, fileShares: [String],
                launchAtLogin: Bool, updateBehavior: UpdateBehavior, defaultTerminal: String) {
        self.cpuCount = cpuCount; self.memoryGiB = memoryGiB; self.diskGiB = diskGiB
        self.fileShares = fileShares; self.launchAtLogin = launchAtLogin
        self.updateBehavior = updateBehavior; self.defaultTerminal = defaultTerminal
    }

    public static var `default`: VeloxConfig {
        let r = VMConfiguration.Resources.default
        return VeloxConfig(
            cpuCount: r.cpuCount,
            memoryGiB: Int(r.memoryBytes / (1024 * 1024 * 1024)),
            diskGiB: Int(r.diskGiB),
            fileShares: [],
            launchAtLogin: false,
            updateBehavior: .notify,
            defaultTerminal: "Terminal")
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VeloxConfig.default
        cpuCount = try c.decodeIfPresent(Int.self, forKey: .cpuCount) ?? d.cpuCount
        memoryGiB = try c.decodeIfPresent(Int.self, forKey: .memoryGiB) ?? d.memoryGiB
        diskGiB = try c.decodeIfPresent(Int.self, forKey: .diskGiB) ?? d.diskGiB
        fileShares = try c.decodeIfPresent([String].self, forKey: .fileShares) ?? d.fileShares
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        updateBehavior = try c.decodeIfPresent(UpdateBehavior.self, forKey: .updateBehavior) ?? d.updateBehavior
        defaultTerminal = try c.decodeIfPresent(String.self, forKey: .defaultTerminal) ?? d.defaultTerminal
    }

    // MARK: - Derived

    /// Resource allocation for `VMConfiguration.build`, clamped to sane bounds.
    public var resources: VMConfiguration.Resources {
        VMConfiguration.Resources(
            cpuCount: max(1, cpuCount),
            memoryBytes: UInt64(max(1, memoryGiB)) * 1024 * 1024 * 1024,
            diskGiB: UInt64(max(1, diskGiB)))
    }

    public var shareURLs: [URL] {
        fileShares.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Fields that require an engine restart to take effect (resources + shares).
    public var bootSignature: [String] {
        ["\(cpuCount)", "\(memoryGiB)", "\(diskGiB)"] + fileShares.sorted()
    }

    // MARK: - Persistence

    public static func load() -> VeloxConfig {
        guard let data = try? Data(contentsOf: Paths.config),
              let config = try? JSONDecoder().decode(VeloxConfig.self, from: data) else {
            return .default
        }
        return config
    }

    public func save() throws {
        try Paths.ensureRoot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Paths.config, options: .atomic)
    }
}
