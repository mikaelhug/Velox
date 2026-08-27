import Foundation

/// One complete, isolated Docker engine state: its own containers, images, volumes,
/// networks and builder cache. Exactly one workspace is active at a time.
///
/// The whole feature rests on a single fact — all of that state already lives in one file.
/// `data.img` is a raw sparse ext4 image attached as `/dev/vdb` and mounted at
/// `/var/lib/docker`, so **a workspace *is* a `data.img`** and switching is just booting
/// against a different one. Nothing in the guest knows workspaces exist: `vinit` formats a
/// blank `/dev/vdb` on first boot and refuses to reformat a disk it doesn't recognise, so a
/// new workspace needs no guest change at all.
///
/// Everything else in `~/.velox` stays global and shared — kernel, `root.img`, the Docker
/// socket, the `velox` docker context, the porthelper, `/etc/resolver/velox.local`,
/// published-port bind address, file shares. In particular the socket path never changes, so
/// `docker` in a terminal transparently follows the active workspace.
public struct Workspace: Codable, Sendable, Equatable, Identifiable {
    /// The workspace migrated from a pre-Workspaces install. Reserved: it is the only one
    /// allowed to occupy the legacy `~/.velox/data.img` slot (see `dataDiskURL`).
    public static let defaultID = "default"
    public static let defaultName = "Default"

    /// Allowed data-disk sizes, in GiB. Defined once here because both front ends must agree:
    /// the Settings slider is bound to this range, and a SwiftUI `Slider` whose value sits
    /// outside its bounds is undefined — so a workspace created with `velox workspace new
    /// --size 512` would otherwise put the GUI in an invalid state. Every write clamps.
    public static let diskGiBRange = 8...256

    public static func clampDiskGiB(_ gib: Int) -> Int {
        min(max(gib, diskGiBRange.lowerBound), diskGiBRange.upperBound)
    }

    /// Stable identity. A UUID for everything created after migration, so a user-supplied
    /// name never reaches the filesystem — no sanitising, no path traversal, and renaming
    /// is free.
    public let id: String
    /// Display name. Unique case-insensitively; the CLI resolves names to ids with it.
    public var name: String
    /// Folder holding this workspace's `data.img`, when the user has relocated it (or when
    /// it was inherited from the pre-Workspaces `VeloxConfig.dataDirectory`). `nil` = the
    /// standard slot; resolve via `dataDiskURL`, never by hand.
    public var directory: String?
    /// Size of this workspace's data disk. Per-workspace on purpose: one workspace created
    /// at 64 GiB and another at 128 GiB can't share a global value, because `velox.disk`
    /// drives a `resize2fs` on every boot.
    public var diskGiB: Int
    public var created: Date
    public var lastUsed: Date
    /// When this workspace first booted successfully, or `nil` if it never has.
    ///
    /// This is the flag that makes "the disk is missing" answerable. Before Workspaces the
    /// question was decided by `VeloxConfig.dataDirectory != nil` — "did the user relocate
    /// it?" — which does not generalise: *every* non-default workspace has a resolved path,
    /// and a brand-new workspace's disk is *supposed* to be absent. Keying off that would
    /// either refuse to boot every new workspace or silently `mkfs` one whose external drive
    /// is unplugged. "Has it ever booted?" is the question that actually distinguishes the
    /// two: absent ⇒ create it; present-but-gone ⇒ fail loudly.
    public var firstBootedAt: Date?

    public init(id: String, name: String, directory: String? = nil, diskGiB: Int,
                created: Date, lastUsed: Date, firstBootedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.directory = directory
        self.diskGiB = diskGiB
        self.created = created
        self.lastUsed = lastUsed
        self.firstBootedAt = firstBootedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        directory = try c.decodeIfPresent(String.self, forKey: .directory)
        diskGiB = Workspace.clampDiskGiB(
            try c.decodeIfPresent(Int.self, forKey: .diskGiB)
                ?? Int(VMConfiguration.Resources.default.diskGiB))
        let now = Date()
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? now
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed) ?? now
        firstBootedAt = try c.decodeIfPresent(Date.self, forKey: .firstBootedAt)
    }

    // MARK: - Derived

    /// Where this workspace's `data.img` actually lives. Pure — mirrors what
    /// `VeloxConfig.dataDiskURL` did for the single-disk world, and is now *the* resolver
    /// used by start, the CLI and the disk gauges.
    ///
    /// The `defaultID` branch is the one documented special case: the migrated workspace
    /// keeps the legacy `~/.velox/data.img` slot rather than being moved into
    /// `workspaces/<id>/`. Moving the most valuable file in the system during an upgrade is
    /// the one operation that should never run — and `docs/bench/run.sh` hardcodes that path
    /// besides.
    public var dataDiskURL: URL {
        if let directory {
            return URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("data.img")
        }
        if id == Self.defaultID { return Paths.dataDisk }
        return Paths.workspaces.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("data.img")
    }

    /// The folder holding `data.img`.
    public var directoryURL: URL { dataDiskURL.deletingLastPathComponent() }

    /// True when this workspace's disk sits in a folder Velox created and owns
    /// (`~/.velox/workspaces/<id>/`), as opposed to a folder the user picked.
    ///
    /// Deletion depends on this. A user-chosen `directory` comes from an `NSOpenPanel` that
    /// can choose *any* folder, so it is routinely `~/Documents` or a drive root — removing
    /// "the workspace's folder" there would delete far more than the workspace. Only an
    /// owned slot may have its folder removed.
    public var ownsDirectory: Bool {
        directory == nil && id != Self.defaultID
    }

    /// Host bytes this workspace actually occupies (allocated, not the sparse logical size).
    /// `nil` when the disk doesn't exist yet.
    ///
    /// Note this counts APFS copy-on-write *shared* blocks, so N clones each report the full
    /// figure while the host has lost almost nothing. Never present this as free space — pair
    /// it with the volume's real availability.
    public var allocatedBytes: Int64? {
        guard let v = try? dataDiskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
              let bytes = v.totalFileAllocatedSize else { return nil }
        return Int64(bytes)
    }

    public var diskExists: Bool {
        FileManager.default.fileExists(atPath: dataDiskURL.path)
    }

    /// Human-readable allocated size, or "—" when the disk doesn't exist yet.
    ///
    /// Lives here rather than in the GUI's `Format` so the CLI's `workspace ls` and the
    /// sidebar can't disagree about how big a workspace is — and `Format` is main-actor
    /// isolated, which the CLI is not.
    public var allocatedDescription: String {
        guard let bytes = allocatedBytes else { return "—" }
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowsNonnumericFormatting = false   // "0 bytes", not "Zero KB"
        return f.string(fromByteCount: bytes)
    }

    // MARK: - Names

    /// Names are compared case-insensitively (and whitespace-trimmed) for uniqueness, so
    /// "Staging" and "staging" can't both exist and confuse `velox workspace use`.
    public static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether a typed confirmation matches this workspace's name closely enough to arm a
    /// delete.
    ///
    /// Case- and whitespace-insensitive on purpose: the point of typing the name is to make
    /// someone stop and read *which* workspace they are about to destroy, not to test their
    /// typing. A rule that is too strict just trains people to copy-paste, which defeats it.
    public func deleteConfirmationMatches(_ typed: String) -> Bool {
        !Self.normalized(typed).isEmpty && Self.normalized(typed) == Self.normalized(name)
    }

    /// Validate a user-supplied display name. The name never touches the filesystem (the id
    /// does), so this only guards against names that are empty or unusable in the UI/CLI.
    public static func validate(name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VeloxError.workspace("A workspace needs a name.")
        }
        guard trimmed.count <= 64 else {
            throw VeloxError.workspace("That name is too long (64 characters max).")
        }
        guard !trimmed.contains(where: { $0.isNewline }) else {
            throw VeloxError.workspace("A workspace name can't contain line breaks.")
        }
        return trimmed
    }
}
