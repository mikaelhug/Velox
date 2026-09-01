import Foundation

/// The persisted list of remote Docker hosts (`~/.velox/hosts.json`).
public struct RemoteHostManifest: Codable, Sendable, Equatable {
    public var version: Int
    /// Bumped on every write, so a caller holding a stale snapshot can tell.
    public var revision: Int
    public var hosts: [RemoteHost]

    public static let currentVersion = 1

    public init(version: Int = RemoteHostManifest.currentVersion,
                revision: Int = 0,
                hosts: [RemoteHost] = []) {
        self.version = version
        self.revision = revision
        self.hosts = hosts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        hosts = try c.decodeIfPresent([RemoteHost].self, forKey: .hosts) ?? []
    }

    public func host(id: String) -> RemoteHost? { hosts.first { $0.id == id } }
}

/// Reads and writes `hosts.json`, with the same discipline as `WorkspaceStore`: every
/// mutation is a read-modify-write under an exclusive `FileLock`, the copy handed to the
/// mutation is re-read from disk, and the result is written durably (tmp → fsync →
/// `rename(2)` → directory fsync).
///
/// Two deliberate differences from `WorkspaceStore`:
///
/// - **An empty list is legal.** There is always at least one workspace; there is very
///   often no remote host at all, and "no hosts yet" is not a fault.
/// - **A missing file is not corruption**, but an unparseable one is — and it throws,
///   rather than quietly presenting an empty list that would look exactly like "you
///   never configured anything" while a real host list sat unreadable on disk.
public enum RemoteHostStore {

    // MARK: - Load

    /// The manifest as it is on disk. A missing file yields an empty manifest; an
    /// unreadable one throws.
    public static func load() throws -> RemoteHostManifest {
        guard FileManager.default.fileExists(atPath: Paths.remoteHostManifest.path) else {
            return RemoteHostManifest()
        }
        let data: Data
        do { data = try Data(contentsOf: Paths.remoteHostManifest) }
        catch { throw VeloxError.remoteHostManifestUnreadable(error.localizedDescription) }
        do { return try decoder.decode(RemoteHostManifest.self, from: data) }
        catch { throw VeloxError.remoteHostManifestUnreadable(error.localizedDescription) }
    }

    /// Move an unreadable `hosts.json` aside so the list can be used again, returning where
    /// it went. **User-initiated only** — never called automatically.
    ///
    /// `mutate` begins with `load()`, so a corrupt file fails every mutation *including the
    /// delete that would remove the offending entry*: the list is wedged with no way out of
    /// the GUI. That is the same trap `validate` is deliberately narrow to avoid, one level
    /// up.
    ///
    /// Safe here in a way it would NOT be for workspaces: `hosts.json` holds nothing but
    /// connection settings, all of which the user can retype, whereas a workspace manifest
    /// is the only record of where a `data.img` lives. `WorkspaceStore` keeps its fail-loud
    /// policy for exactly that reason. The bad file is preserved, not deleted, so a
    /// hand-repair is still possible afterwards.
    @discardableResult
    public static func quarantineCorruptManifest() throws -> URL {
        try Paths.ensureRoot()
        let lock = try FileLock(at: Paths.remoteHostLock, what: "remote host list")
        defer { lock.release() }

        // Re-read under the lock. The corruption verdict was reached earlier and elsewhere
        // (the sidebar banner), and the user may well have fixed the file by hand in the
        // meantime — moving a now-valid list aside and handing them an empty one would be a
        // worse outcome than the problem.
        if (try? load()) != nil {
            throw VeloxError.remoteHost(
                "The host list reads correctly now, so it was left alone. "
                + "Close and reopen this dialog to see it.")
        }
        let target = Paths.remoteHostManifest
        let stamp = Int(Date().timeIntervalSince1970)
        let quarantined = target.appendingPathExtension("corrupt-\(stamp)")
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return quarantined }
        try? fm.removeItem(at: quarantined)
        try fm.moveItem(at: target, to: quarantined)
        Log.warn("remote hosts: quarantined an unreadable manifest to \(quarantined.lastPathComponent)")
        return quarantined
    }

    // MARK: - Mutation

    /// Apply `body` to the manifest under an exclusive cross-process lock, then persist.
    /// The manifest `body` receives is re-read from disk inside the lock — that is the
    /// point, so the GUI and a second process can't drop each other's entries.
    @discardableResult
    public static func mutate(
        _ body: (inout RemoteHostManifest) throws -> Void
    ) throws -> RemoteHostManifest {
        try Paths.ensureRoot()
        let lock = try FileLock(at: Paths.remoteHostLock, what: "remote host list")
        defer { lock.release() }

        var manifest = try load()
        try body(&manifest)
        try validate(manifest)
        manifest.revision &+= 1
        try backup()
        try writeDurably(manifest)
        return manifest
    }

    /// Structural invariants that must hold for any manifest we write.
    ///
    /// Deliberately **only** uniqueness — not the per-field rules. Those are enforced where
    /// the user types a value (`create` / `rename`), because enforcing them here would wedge
    /// the store: a hand-edited or downgrade-written entry with a bad field would fail every
    /// future mutation, including the delete that would get rid of it. Uniqueness is
    /// different — it is about the list, and the list is what we are writing.
    public static func validate(_ manifest: RemoteHostManifest) throws {
        var seenIDs = Set<String>()
        var seenNames = Set<String>()
        for host in manifest.hosts {
            guard seenIDs.insert(host.id).inserted else {
                throw VeloxError.remoteHost("Duplicate host id \(host.id).")
            }
            let key = RemoteHost.normalized(host.name).lowercased()
            guard seenNames.insert(key).inserted else {
                throw VeloxError.remoteHost("A host named \"\(host.name)\" already exists.")
            }
        }
    }

    /// The per-field rules, applied to a host the user just described.
    public static func validateFields(of host: RemoteHost) throws {
        if let complaint = RemoteHost.validate(name: host.name) { throw VeloxError.remoteHost(complaint) }
        if let complaint = RemoteHost.validate(user: host.user) { throw VeloxError.remoteHost(complaint) }
        if let complaint = RemoteHost.validate(hostname: host.hostname) { throw VeloxError.remoteHost(complaint) }
        if let complaint = RemoteHost.validate(socketPath: host.socketPath) { throw VeloxError.remoteHost(complaint) }
    }

    // MARK: - Operations
    //
    // Like `WorkspaceStore`, none of these touch a running engine or tunnel — they edit
    // the list and nothing else. Connecting and disconnecting is the caller's business.

    @discardableResult
    public static func create(_ host: RemoteHost) throws -> RemoteHostManifest {
        try validateFields(of: host)
        return try mutate { $0.hosts.append(host) }
    }

    @discardableResult
    private static func update(id: String, _ edit: (inout RemoteHost) -> Void) throws -> RemoteHostManifest {
        try mutate { manifest in
            guard let index = manifest.hosts.firstIndex(where: { $0.id == id }) else {
                throw VeloxError.remoteHost("That host is no longer in the list.")
            }
            edit(&manifest.hosts[index])
        }
    }

    @discardableResult
    public static func rename(id: String, to name: String) throws -> RemoteHostManifest {
        let trimmed = RemoteHost.normalized(name)
        if let complaint = RemoteHost.validate(name: trimmed) { throw VeloxError.remoteHost(complaint) }
        return try update(id: id) { $0.name = trimmed }
    }

    @discardableResult
    public static func delete(id: String) throws -> RemoteHostManifest {
        try mutate { manifest in
            guard manifest.host(id: id) != nil else {
                throw VeloxError.remoteHost("That host is no longer in the list.")
            }
            manifest.hosts.removeAll { $0.id == id }
        }
    }


    // MARK: - Persistence

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func backup() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.remoteHostManifest.path) else { return }
        let bak = Paths.remoteHostManifest.appendingPathExtension("bak")
        try? fm.removeItem(at: bak)
        try? fm.copyItem(at: Paths.remoteHostManifest, to: bak)
    }

    /// Temp file → fsync → `rename(2)` → fsync the directory, matching
    /// `WorkspaceStore.writeDurably`. Public so `velox-selftest` can plant edge-case
    /// manifests directly.
    public static func writeDurably(_ manifest: RemoteHostManifest) throws {
        try Paths.ensureRoot()
        let target = Paths.remoteHostManifest
        let tmp = target.appendingPathExtension("tmp")
        let data = try encoder.encode(manifest)
        try? FileManager.default.removeItem(at: tmp)
        try data.write(to: tmp)
        if let handle = try? FileHandle(forWritingTo: tmp) {
            try? handle.synchronize()
            try? handle.close()
        }
        guard Darwin.rename(tmp.path, target.path) == 0 else {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw VeloxError.socketSetupFailed("rename(\(target.lastPathComponent))", err)
        }
        Storage.fsyncDirectory(target.deletingLastPathComponent())
    }
}
