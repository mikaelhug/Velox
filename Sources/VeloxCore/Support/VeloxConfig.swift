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
    /// Post a macOS notification when a container exits with a non-zero code
    /// (opt-in; rides the existing events stream — nothing polls).
    public var notifyOnCrash: Bool
    /// Expose KVM inside the guest (VZ nested virtualization — M3+/macOS 15).
    /// Opt-in, default off: off means the VZ flag is never set and nothing changes.
    public var nestedVirtualization: Bool
    /// Host address published container ports bind on the Mac. Default `"0.0.0.0"` — all
    /// interfaces, matching Docker's own default, so `-p 8080:80` is reachable from other
    /// machines. Set `"127.0.0.1"` for host-only publishing (what Velox did before this
    /// setting existed), or a specific host address to pin one interface. Parsed by
    /// `PublishBind`; an unparseable value falls back to host-only.
    public var publishHostIP: String
    /// Folder holding the data disk (`data.img`), if the user relocated it off the default
    /// `~/.velox`. `nil` = default location. Set by Settings › Resources › Move…; resolve via
    /// `dataDiskURL`. Deliberately NOT in `bootSignature` — the move restarts the engine itself.
    public var dataDirectory: String?

    public init(cpuCount: Int, memoryGiB: Int, diskGiB: Int, swapGiB: Int, fileShares: [String],
                launchAtLogin: Bool,
                resourceSaverEnabled: Bool = true, resourceSaverMinutes: Int = 5,
                dontSuggestContext: Bool = false, checkUpdatesOnStartup: Bool = true,
                notifyOnCrash: Bool = false, nestedVirtualization: Bool = false,
                publishHostIP: String = "0.0.0.0",
                dataDirectory: String? = nil) {
        self.cpuCount = cpuCount; self.memoryGiB = memoryGiB; self.diskGiB = diskGiB
        self.swapGiB = swapGiB
        self.fileShares = fileShares; self.launchAtLogin = launchAtLogin
        self.resourceSaverEnabled = resourceSaverEnabled
        self.resourceSaverMinutes = resourceSaverMinutes
        self.dontSuggestContext = dontSuggestContext
        self.checkUpdatesOnStartup = checkUpdatesOnStartup
        self.notifyOnCrash = notifyOnCrash
        self.nestedVirtualization = nestedVirtualization
        self.publishHostIP = publishHostIP
        self.dataDirectory = dataDirectory
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
        notifyOnCrash = try c.decodeIfPresent(Bool.self, forKey: .notifyOnCrash) ?? d.notifyOnCrash
        nestedVirtualization = try c.decodeIfPresent(Bool.self, forKey: .nestedVirtualization)
            ?? d.nestedVirtualization
        publishHostIP = try c.decodeIfPresent(String.self, forKey: .publishHostIP) ?? d.publishHostIP
        dataDirectory = try c.decodeIfPresent(String.self, forKey: .dataDirectory) ?? d.dataDirectory
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

    /// Where `data.img` actually lives — the configured `dataDirectory`, or the default
    /// `~/.velox`. The single resolver used by start, the CLI, and the disk gauges.
    public var dataDiskURL: URL {
        let dir = dataDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Paths.root
        return dir.appendingPathComponent("data.img")
    }

    /// Floor of guest memory while in Resource Saver mode (bytes). We never
    /// balloon below this so dockerd/containerd stay responsive enough to notice
    /// the next container start. ¼ of configured RAM, clamped to [512 MiB, 1 GiB].
    public var resourceSaverFloorBytes: UInt64 {
        let quarter = (UInt64(max(1, memoryGiB)) * 1024 * 1024 * 1024) / 4
        return min(max(quarter, 512 * 1024 * 1024), 1024 * 1024 * 1024)
    }

    /// Host bind address for published ports, parsed and validated.
    public var publishBind: PublishBind { PublishBind.parse(publishHostIP) }

    /// Fields that require an engine restart to take effect (resources + shares).
    /// Resource Saver settings apply live, so they are deliberately excluded.
    /// `publishHostIP` is included: the forwarders bind it when they're constructed, so
    /// a change only lands once they're rebuilt.
    public var bootSignature: [String] {
        ["\(cpuCount)", "\(memoryGiB)", "\(diskGiB)", "\(swapGiB)", "\(nestedVirtualization)",
         publishHostIP]
            + fileShares.sorted()
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
