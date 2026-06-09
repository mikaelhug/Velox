import Foundation

/// User preferences persisted to `~/.velox/config.json`. This is the GUI's
/// source of truth for resource allocation and file sharing; the engine reads it
/// at boot. Decoding tolerates missing keys so older/newer files still load.
public struct VeloxConfig: Codable, Sendable, Equatable {
    public var cpuCount: Int
    public var memoryGiB: Int
    public var diskGiB: Int
    /// Guest swap size in GiB (0 = no swap).
    public var swapGiB: Int
    public var fileShares: [String]      // absolute host directory paths
    public var launchAtLogin: Bool
    /// Resource Saver: when no containers have been running for
    /// `resourceSaverMinutes`, reclaim guest RAM (inflate the balloon) until a
    /// container starts again. Mirrors Docker Desktop's Resource Saver.
    public var resourceSaverEnabled: Bool
    public var resourceSaverMinutes: Int
    /// "Don't ask again" opt-out for the docker-context switch suggestion. Default
    /// false, so the GUI re-suggests switching to `velox` on every launch while it
    /// isn't the active context — only this opt-out silences it. (Replaces the old
    /// `contextPromptShown`, which got stuck `true` after a single prompt and then
    /// suppressed the suggestion forever.)
    public var dontSuggestContext: Bool
    /// Check GitHub Releases for a newer Velox on app launch (default on).
    public var checkUpdatesOnStartup: Bool

    public init(cpuCount: Int, memoryGiB: Int, diskGiB: Int, swapGiB: Int, fileShares: [String],
                launchAtLogin: Bool,
                resourceSaverEnabled: Bool = true, resourceSaverMinutes: Int = 5,
                dontSuggestContext: Bool = false, checkUpdatesOnStartup: Bool = true) {
        self.cpuCount = cpuCount; self.memoryGiB = memoryGiB; self.diskGiB = diskGiB
        self.swapGiB = swapGiB
        self.fileShares = fileShares; self.launchAtLogin = launchAtLogin
        self.resourceSaverEnabled = resourceSaverEnabled
        self.resourceSaverMinutes = resourceSaverMinutes
        self.dontSuggestContext = dontSuggestContext
        self.checkUpdatesOnStartup = checkUpdatesOnStartup
    }

    public static var `default`: VeloxConfig {
        let r = VMConfiguration.Resources.default
        return VeloxConfig(
            cpuCount: r.cpuCount,
            memoryGiB: Int(r.memoryBytes / (1024 * 1024 * 1024)),
            diskGiB: Int(r.diskGiB),
            swapGiB: Int(r.swapMiB / 1024),
            fileShares: [],
            launchAtLogin: false,
            resourceSaverEnabled: true,
            resourceSaverMinutes: 5,
            dontSuggestContext: false,
            checkUpdatesOnStartup: true)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VeloxConfig.default
        cpuCount = try c.decodeIfPresent(Int.self, forKey: .cpuCount) ?? d.cpuCount
        memoryGiB = try c.decodeIfPresent(Int.self, forKey: .memoryGiB) ?? d.memoryGiB
        diskGiB = try c.decodeIfPresent(Int.self, forKey: .diskGiB) ?? d.diskGiB
        swapGiB = try c.decodeIfPresent(Int.self, forKey: .swapGiB) ?? d.swapGiB
        fileShares = try c.decodeIfPresent([String].self, forKey: .fileShares) ?? d.fileShares
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        resourceSaverEnabled = try c.decodeIfPresent(Bool.self, forKey: .resourceSaverEnabled) ?? d.resourceSaverEnabled
        resourceSaverMinutes = try c.decodeIfPresent(Int.self, forKey: .resourceSaverMinutes) ?? d.resourceSaverMinutes
        dontSuggestContext = try c.decodeIfPresent(Bool.self, forKey: .dontSuggestContext) ?? d.dontSuggestContext
        checkUpdatesOnStartup = try c.decodeIfPresent(Bool.self, forKey: .checkUpdatesOnStartup) ?? d.checkUpdatesOnStartup
    }

    // MARK: - Derived

    /// Resource allocation for `VMConfiguration.build`, clamped to sane bounds.
    public var resources: VMConfiguration.Resources {
        VMConfiguration.Resources(
            cpuCount: max(1, cpuCount),
            memoryBytes: UInt64(max(1, memoryGiB)) * 1024 * 1024 * 1024,
            diskGiB: UInt64(max(1, diskGiB)),
            swapMiB: UInt64(max(0, swapGiB)) * 1024)
    }

    public var shareURLs: [URL] {
        fileShares.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Floor of guest memory while in Resource Saver mode (bytes). We never
    /// balloon below this so dockerd/containerd stay responsive enough to notice
    /// the next container start. ¼ of configured RAM, clamped to [512 MiB, 1 GiB].
    public var resourceSaverFloorBytes: UInt64 {
        let quarter = (UInt64(max(1, memoryGiB)) * 1024 * 1024 * 1024) / 4
        return min(max(quarter, 512 * 1024 * 1024), 1024 * 1024 * 1024)
    }

    /// Fields that require an engine restart to take effect (resources + shares).
    /// Resource Saver settings apply live, so they are deliberately excluded.
    public var bootSignature: [String] {
        ["\(cpuCount)", "\(memoryGiB)", "\(diskGiB)", "\(swapGiB)"] + fileShares.sorted()
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
