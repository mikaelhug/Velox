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
    /// Folder holding the active workspace's data disk, or `nil` for `~/.velox`.
    ///
    /// **No longer the source of truth** — `Workspace.dataDiskURL` is, via the manifest in
    /// `~/.velox/workspaces.json`. This is kept as a *mirror* of the active workspace,
    /// rewritten on every switch, for exactly one reason: a `velox` binary that predates
    /// workspaces (an app downgrade, or an older CLI still on `PATH`) reads only this file.
    /// Without the mirror it would boot the Default workspace while the user believes they
    /// are on another one. Migration seeds the Default workspace from it.
    ///
    /// Deliberately NOT in `bootSignature` — a relocation restarts the engine itself.
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
    ///
    /// `diskGiB` is per-workspace (a workspace created at 64 GiB and one at 128 GiB can't
    /// share a global value — `velox.disk` drives a `resize2fs` on every boot), so callers
    /// that know the active workspace pass its size in. The parameterless form keeps using
    /// `config.diskGiB`, which is maintained as a mirror of the active workspace for the
    /// benefit of an older `velox` binary that predates workspaces.
    public func resources(diskGiB overrideGiB: Int? = nil) -> VMConfiguration.Resources {
        VMConfiguration.Resources(
            cpuCount: max(1, cpuCount),
            memoryBytes: UInt64(max(1, memoryGiB)) * 1024 * 1024 * 1024,
            diskGiB: UInt64(max(1, overrideGiB ?? diskGiB)),
            swapMiB: UInt64(max(0, swapGiB)) * 1024)
    }

    /// Resource allocation using the mirrored global `diskGiB`.
    public var resources: VMConfiguration.Resources { resources() }

    public var shareURLs: [URL] {
        fileShares.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Where the mirrored `dataDirectory` points. Prefer `Workspace.dataDiskURL`: this
    /// resolves the *mirror*, so it is only correct for the active workspace and only
    /// between switches. Retained because it is what a pre-workspaces binary would compute,
    /// and the self-test pins that equivalence.
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
    /// The active workspace's disk size is passed in, because that — not the mirrored
    /// global — is what the running VM booted with.
    ///
    /// The active workspace's *identity* is deliberately absent, for the same reason
    /// `dataDirectory` is: a switch restarts the engine itself, so including it would light
    /// up the "restart to apply" banner during every switch.
    public func bootSignature(diskGiB overrideGiB: Int? = nil) -> [String] {
        ["\(cpuCount)", "\(memoryGiB)", "\(overrideGiB ?? diskGiB)", "\(swapGiB)",
         "\(nestedVirtualization)", publishHostIP]
            + fileShares.sorted()
    }

    public var bootSignature: [String] { bootSignature() }

    // MARK: - Persistence

    public static func load() -> VeloxConfig {
        guard let data = try? Data(contentsOf: Paths.config),
              let config = try? JSONDecoder().decode(VeloxConfig.self, from: data) else {
            return .default
        }
        return config
    }

    /// Like `load()`, but tells "no file yet" apart from "the file is corrupt".
    ///
    /// `load()` collapses both into `.default`, which silently sets `dataDirectory` to nil —
    /// i.e. "the data disk is at ~/.velox/data.img". That is survivable while it's only a
    /// runtime guess, but **workspace migration writes it down**: a user whose disk lives on
    /// an external volume would get a Default workspace pointing at a path that doesn't
    /// exist, `ensureDataDisk` would create a blank one there, vinit would format it, and
    /// the pointer to the real disk would be gone from both files. Migration must therefore
    /// refuse on a corrupt config rather than guess. Returns nil when the file is absent
    /// (a genuine first run); throws when it exists but can't be decoded.
    public static func loadStrict() throws -> VeloxConfig? {
        guard FileManager.default.fileExists(atPath: Paths.config.path) else { return nil }
        let data = try Data(contentsOf: Paths.config)
        return try JSONDecoder().decode(VeloxConfig.self, from: data)
    }

    /// `dataDirectory` and `diskGiB` lifted straight out of the raw JSON, bypassing the
    /// `Codable` model entirely. Belt-and-braces for migration: if some *other* key in
    /// `config.json` ever fails to decode, the two fields that decide where the user's data
    /// lives are still recovered instead of silently becoming defaults.
    public static func rawDiskSettings() -> (dataDirectory: String?, diskGiB: Int?)? {
        guard let data = try? Data(contentsOf: Paths.config),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (object["dataDirectory"] as? String, object["diskGiB"] as? Int)
    }

    public func save() throws {
        try Paths.ensureRoot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Paths.config, options: .atomic)
    }
}
