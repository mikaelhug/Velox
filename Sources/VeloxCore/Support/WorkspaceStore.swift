import Foundation

/// The persisted workspace list plus which one is active. Serialized to
/// `~/.velox/workspaces.json`.
public struct WorkspaceManifest: Codable, Sendable, Equatable {
    /// Schema version, for future migrations.
    public var version: Int
    /// Bumped on every write. Lets a writer notice it is working from a stale snapshot and
    /// re-apply instead of clobbering (see `WorkspaceStore.mutate`).
    public var revision: Int
    public var activeID: String
    public var workspaces: [Workspace]

    public static let currentVersion = 1

    public init(version: Int = WorkspaceManifest.currentVersion, revision: Int = 0,
                activeID: String, workspaces: [Workspace]) {
        self.version = version
        self.revision = revision
        self.activeID = activeID
        self.workspaces = workspaces
    }

    public func workspace(id: String) -> Workspace? { workspaces.first { $0.id == id } }

    public func workspace(named name: String) -> Workspace? {
        let target = Workspace.normalized(name)
        return workspaces.first { Workspace.normalized($0.name) == target }
    }

    /// The active workspace, or — when `activeID` names an entry that isn't in the list —
    /// the Default one, else the first.
    ///
    /// This fallback is deliberately **read-only**: it does not rewrite `activeID`. A
    /// dangling pointer is usually a manifest the user can still repair (or a drive they can
    /// reconnect), and silently rewriting it throws that away. Note the fallback covers a
    /// missing *entry* only — a workspace whose entry exists but whose disk file is gone is
    /// a hard failure at boot, never a quiet switch to someone else's data.
    /// Deliberately silent: this is a computed property that SwiftUI re-evaluates on every
    /// render (`needsRestart`, the Overview caption, Settings all read it), so logging here
    /// floods stderr at render frequency the moment `activeID` dangles. The one-time warning
    /// lives in `WorkspaceStore.loadExisting`, where a dangling pointer is discovered.
    public var active: Workspace {
        workspace(id: activeID)
            ?? workspace(id: Workspace.defaultID)
            ?? workspaces[0]
    }

    /// True when `activeID` names an entry that isn't in the list (so `active` is falling
    /// back). Surfaced by the UI as a banner rather than inferred by comparing ids.
    public var activeIsFallback: Bool { workspace(id: activeID) == nil }
}

/// Reads and writes the workspace manifest.
///
/// Two properties matter more than anything else here:
///
/// * **A corrupt manifest throws; it is never silently replaced.** `VeloxConfig.load()`
///   collapses "absent" and "corrupt" into `.default`, which is survivable for preferences
///   and catastrophic for this file: synthesizing a fresh manifest would hide every real
///   workspace behind an empty "Default" and boot the legacy disk in its place.
/// * **Every mutation is a read-modify-write under an exclusive `flock`.** The GUI is a
///   long-lived process holding an in-memory copy while `velox workspace new` can run beside
///   it; a whole-file write from a stale snapshot would drop the other side's workspace from
///   the list while its `data.img` stayed on disk, invisible to every UI.
public enum WorkspaceStore {

    // MARK: - Load

    /// Load the manifest, migrating a pre-Workspaces install on first run.
    ///
    /// Throws if the manifest exists but can't be decoded, or if migration is needed but
    /// `config.json` can't be trusted (see `migrate`).
    public static func load() throws -> WorkspaceManifest {
        if let manifest = try loadExisting() { return manifest }
        // First run: migrate under the lock, and look again inside it. Two processes can
        // reach this at once (the app autostarting while `velox workspace ls` runs), and
        // without the re-check both would synthesize a Default and the second would overwrite
        // the first — harmless today, since they'd agree, but only by luck.
        try Paths.ensureRoot()
        let lock = try FileLock(at: Paths.workspaceLock)
        defer { lock.release() }
        if let manifest = try loadExisting() { return manifest }
        let migrated = try migrate()
        try writeDurably(migrated)
        Log.info("workspaces: created \(Paths.workspaceManifest.lastPathComponent) with "
                 + "\"\(migrated.active.name)\" → \(migrated.active.dataDiskURL.path)")
        return migrated
    }

    /// The manifest as it is on disk, or nil when there isn't one yet.
    public static func loadExisting() throws -> WorkspaceManifest? {
        guard FileManager.default.fileExists(atPath: Paths.workspaceManifest.path) else {
            return nil
        }
        let data: Data
        do { data = try Data(contentsOf: Paths.workspaceManifest) }
        catch { throw VeloxError.workspaceManifestUnreadable(error.localizedDescription) }
        do {
            let manifest = try decoder.decode(WorkspaceManifest.self, from: data)
            guard !manifest.workspaces.isEmpty else {
                throw VeloxError.workspaceManifestUnreadable("it lists no workspaces")
            }
            if manifest.activeIsFallback {
                // Once per load, not in `active` itself — see the note there.
                Log.warn("workspace manifest: active id \(manifest.activeID) is not in the "
                         + "list — falling back to \(manifest.active.name) for this boot "
                         + "(the manifest is left untouched)")
            }
            return manifest
        } catch let error as VeloxError {
            throw error
        } catch {
            throw VeloxError.workspaceManifestUnreadable(error.localizedDescription)
        }
    }

    // MARK: - Migration

    /// Build the first manifest for an existing install.
    ///
    /// The existing `~/.velox/data.img` is **not** read, moved, copied or reformatted — the
    /// Default workspace simply points at wherever it already is. Migration is one file
    /// *created*, which is what makes "a user must never lose containers by installing an
    /// update" true by construction rather than by care.
    ///
    /// It refuses to run against a `config.json` that exists but won't decode. `load()`
    /// would hand back `.default` there, whose `dataDirectory` is nil — and writing that
    /// down would point Default at `~/.velox/data.img` for a user whose disk is on an
    /// external volume, create a blank one there, let vinit format it, and erase the pointer
    /// to the real disk from both files.
    static func migrate() throws -> WorkspaceManifest {
        let config: VeloxConfig?
        do { config = try VeloxConfig.loadStrict() }
        catch {
            throw VeloxError.workspace(
                "Velox can't read \(Paths.config.path) (\(error.localizedDescription)), so it "
                + "won't guess where your Docker data lives. Fix or remove that file and "
                + "start Velox again — your data disk is untouched.")
        }
        // Belt-and-braces: recover the two fields that decide where the data lives straight
        // from the raw JSON, so a decode problem in some unrelated key can't default them.
        let raw = VeloxConfig.rawDiskSettings()
        let dataDirectory = raw?.dataDirectory ?? config?.dataDirectory
        let diskGiB = raw?.diskGiB ?? config?.diskGiB
            ?? Int(VMConfiguration.Resources.default.diskGiB)

        let now = Date()
        var workspace = Workspace(
            id: Workspace.defaultID, name: Workspace.defaultName,
            directory: dataDirectory, diskGiB: diskGiB,
            created: now, lastUsed: now)
        // An existing disk means this workspace has demonstrably booted before, so a later
        // disappearance is a fault to report — not an invitation to create a fresh one.
        if workspace.diskExists {
            let created = (try? workspace.dataDiskURL.resourceValues(
                forKeys: [.creationDateKey]))?.creationDate
            workspace.created = created ?? now
            workspace.firstBootedAt = created ?? now
        }
        return WorkspaceManifest(activeID: workspace.id, workspaces: [workspace])
    }

    // MARK: - Mutation

    /// Apply `body` to the manifest under an exclusive cross-process lock, then persist it.
    ///
    /// The lock is held across the whole read-modify-write, and the copy `body` receives is
    /// **re-read from disk** rather than whatever the caller had in memory — that is the
    /// point. Returns the manifest as written.
    @discardableResult
    public static func mutate(
        _ body: (inout WorkspaceManifest) throws -> Void
    ) throws -> WorkspaceManifest {
        try Paths.ensureRoot()
        let lock = try FileLock(at: Paths.workspaceLock)
        defer { lock.release() }

        var manifest = try loadExisting() ?? migrate()
        try body(&manifest)
        try validate(manifest)
        manifest.revision &+= 1
        try backup()
        try writeDurably(manifest)
        return manifest
    }

    /// Invariants that must hold for any manifest we write.
    public static func validate(_ manifest: WorkspaceManifest) throws {
        guard !manifest.workspaces.isEmpty else {
            throw VeloxError.workspace("There must always be at least one workspace.")
        }
        // A dangling `activeID` is tolerated, not fatal: the read side deliberately falls
        // back (see `WorkspaceManifest.active`) and preserves the pointer so a restored
        // manifest entry can reclaim it. Throwing here would freeze EVERY mutation while the
        // pointer dangles — create and rename would fail with a baffling error, and
        // `recordBoot`'s try? would go silently dead — leaving "switch" as the only working
        // verb without ever saying so. The load path already warns once.
        if manifest.workspace(id: manifest.activeID) == nil {
            Log.warn("workspace manifest: keeping dangling active id \(manifest.activeID) "
                     + "through a write (effective active: \(manifest.active.name))")
        }
        var seenIDs = Set<String>(), seenNames = Set<String>()
        for w in manifest.workspaces {
            guard seenIDs.insert(w.id).inserted else {
                throw VeloxError.workspace("Duplicate workspace id \(w.id).")
            }
            guard seenNames.insert(Workspace.normalized(w.name)).inserted else {
                throw VeloxError.workspace("A workspace named “\(w.name)” already exists.")
            }
        }
        try validateDiskPaths(manifest.workspaces)
    }

    /// No two workspaces may resolve to the same `data.img`.
    ///
    /// Without this, relocating a workspace into `~/.velox` lands its disk on the Default
    /// workspace's reserved slot whenever Default has never booted (`stageDataDiskMove`'s
    /// only guard is that the destination doesn't already exist). Two entries would then
    /// share one file, and deleting either would destroy the other. Compared by resolved
    /// path *and*, when both files exist, by `(st_dev, st_ino)` — so a hard link or a
    /// symlinked folder can't sneak two names onto one inode either.
    ///
    /// Public so `velox-selftest` can exercise it directly, like
    /// `NamedAccessRouter.installedRoutes()`.
    public static func validateDiskPaths(_ workspaces: [Workspace]) throws {
        var byPath: [String: String] = [:]      // standardized path → workspace name
        var byInode: [String: String] = [:]     // "dev:ino" → workspace name

        for w in workspaces {
            let url = w.dataDiskURL
            // The legacy slot belongs to the migrated workspace alone.
            if Self.comparablePath(url) == Self.comparablePath(Paths.dataDisk),
               w.id != Workspace.defaultID {
                throw VeloxError.workspace(
                    "“\(w.name)” can't live in \(Paths.root.path) — that folder holds the "
                    + "Default workspace's disk. Pick another folder.")
            }
            let path = Self.comparablePath(url)
            if let other = byPath[path] {
                throw VeloxError.workspace(
                    "“\(w.name)” and “\(other)” would share the same disk at \(path).")
            }
            byPath[path] = w.name

            var st = stat()
            if stat(path, &st) == 0 {
                let key = "\(st.st_dev):\(st.st_ino)"
                if let other = byInode[key] {
                    throw VeloxError.workspace(
                        "“\(w.name)” and “\(other)” point at the same disk file.")
                }
                byInode[key] = w.name
            }
        }
    }

    /// Canonical form of a disk path for collision comparison, with symlinks resolved in
    /// every component that exists.
    ///
    /// Not `resolvingSymlinksInPath()` alone: measured, that resolves NOTHING when the final
    /// component doesn't exist — and a disk that hasn't been created yet is exactly the case
    /// this guards, because the `(st_dev, st_ino)` cross-check in `validateDiskPaths` can
    /// only see files that exist. Two never-booted workspaces reaching one folder through a
    /// symlink would otherwise pass validation and collide at first boot. So: walk up to the
    /// deepest ancestor that exists, resolve that, and re-append the rest.
    static func comparablePath(_ url: URL) -> String {
        var dir = url.standardizedFileURL.deletingLastPathComponent()
        var tail = [url.lastPathComponent]
        while !FileManager.default.fileExists(atPath: dir.path), dir.path != "/" {
            tail.append(dir.lastPathComponent)
            dir = dir.deletingLastPathComponent()
        }
        var resolved = dir.resolvingSymlinksInPath()
        for component in tail.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }

    // MARK: - Operations
    //
    // Manifest + disk only. **None of these stop or start the engine** — that is the
    // caller's job, and the reason is the one invariant this feature can't get wrong: a
    // disk must never be mutated while a VM holds it. `EngineController` wraps the ones
    // that touch the active workspace in its stop/start latch; the CLI refuses outright
    // while an engine is running. Keeping the lifecycle out of here is what lets the GUI
    // and the CLI share one implementation instead of growing two.

    /// Create a new, empty workspace. Its disk is a blank sparse file; the guest formats it
    /// on first boot.
    @discardableResult
    public static func create(name: String, diskGiB: Int,
                              directory: URL? = nil) throws -> Workspace {
        let clean = try Workspace.validate(name: name)
        let now = Date()
        let workspace = Workspace(
            id: UUID().uuidString.lowercased(), name: clean,
            directory: directory?.standardizedFileURL.path,
            diskGiB: Workspace.clampDiskGiB(diskGiB),
            created: now, lastUsed: now)
        try mutate { manifest in
            manifest.workspaces.append(workspace)
        }
        do {
            try Storage.createWorkspaceDisk(at: workspace.dataDiskURL,
                                            sizeGiB: UInt64(workspace.diskGiB))
        } catch {
            // Roll the entry back so a failed create can't leave a workspace that points at
            // nothing — the user would see it in the list and be unable to use or remove it.
            _ = try? mutate { $0.workspaces.removeAll { $0.id == workspace.id } }
            throw error
        }
        return workspace
    }

    /// Duplicate an existing workspace, sharing its blocks until the two diverge.
    ///
    /// The source must be **stopped and cleanly unmounted** — verified here rather than
    /// trusted, because a clone of a live disk produces a workspace that looks real and
    /// isn't (see `Storage.dataDiskIsClean`).
    @discardableResult
    public static func clone(id: String, newName: String, directory: URL? = nil,
                             progress: (@Sendable (Double) -> Void)? = nil) throws -> Workspace {
        let clean = try Workspace.validate(name: newName)
        guard let source = try load().workspace(id: id) else {
            throw VeloxError.workspace("That workspace no longer exists.")
        }
        guard source.diskExists else {
            throw VeloxError.workspace(
                "“\(source.name)” has no data disk yet — start it once before duplicating it.")
        }
        // A filesystem that has recorded errors shouldn't be propagated into a second
        // workspace. Note this does NOT detect a *live* disk — see `dataDiskIsClean`. The
        // caller is responsible for the engine being stopped: the app checks what the VM
        // actually attached, and the CLI refuses while the engine lock is held.
        guard Storage.dataDiskIsClean(at: source.dataDiskURL) else {
            throw VeloxError.workspace(
                "“\(source.name)” has filesystem errors recorded, so a copy of it could be "
                + "unusable. Start it once to let the filesystem recover, stop it, then "
                + "duplicate it.")
        }
        let now = Date()
        // `firstBootedAt` is set HERE, in the same write that inserts the entry — not after
        // the copy. The clone carries the source's filesystem, so it counts as already
        // booted, and that flag is what makes a later missing disk fail loudly instead of
        // being silently re-created blank. Setting it in a follow-up write meant a crash
        // between the two left the entry unprotected. Recording it before the copy can only
        // err toward "fail loudly", which is the safe direction.
        let workspace = Workspace(
            id: UUID().uuidString.lowercased(), name: clean,
            directory: directory?.standardizedFileURL.path, diskGiB: source.diskGiB,
            created: now, lastUsed: now, firstBootedAt: source.firstBootedAt ?? now)
        try mutate { manifest in
            manifest.workspaces.append(workspace)
        }
        do {
            try Storage.cloneDataDisk(from: source.dataDiskURL, to: workspace.dataDiskURL,
                                      progress: progress)
        } catch {
            _ = try? mutate { $0.workspaces.removeAll { $0.id == workspace.id } }
            throw error
        }
        return workspace
    }

    public static func rename(id: String, to newName: String) throws {
        let clean = try Workspace.validate(name: newName)
        try mutate { manifest in
            guard let i = manifest.workspaces.firstIndex(where: { $0.id == id }) else {
                throw VeloxError.workspace("That workspace no longer exists.")
            }
            manifest.workspaces[i].name = clean
        }
    }

    /// Remove a workspace and its disk, permanently.
    ///
    /// Refuses on the active workspace and on the last remaining one. Both could be made to
    /// work — deleting the active one by switching first — but an implicit engine restart
    /// hidden inside a delete is the wrong place to put a surprise. "Switch away first" is
    /// one extra click.
    public static func delete(id: String) throws {
        let manifest = try load()
        guard let workspace = manifest.workspace(id: id) else {
            throw VeloxError.workspace("That workspace no longer exists.")
        }
        guard manifest.workspaces.count > 1 else {
            throw VeloxError.workspace(
                "“\(workspace.name)” is the only workspace — Velox needs at least one.")
        }
        // `active.id`, NOT the raw `activeID`: when the stored pointer dangles (a
        // hand-edited or restored manifest), `active` falls back to Default — and Default is
        // then the workspace that will actually boot. Comparing the raw id would let exactly
        // that workspace be deleted, disk and all, while it is the effective active one.
        guard manifest.active.id != id else {
            throw VeloxError.workspace(
                "“\(workspace.name)” is the active workspace. Switch to another one first.")
        }
        try mutate { m in
            // Re-check under the lock: another process may have switched to it since.
            guard m.active.id != id else {   // effective active — see the guard above
                throw VeloxError.workspace(
                    "“\(workspace.name)” has become the active workspace. Switch away first.")
            }
            guard m.workspaces.count > 1 else {
                throw VeloxError.workspace("Velox needs at least one workspace.")
            }
            m.workspaces.removeAll { $0.id == id }
        }
        // The entry is already gone, so a failure here can't be undone by throwing — the
        // workspace has vanished from the list either way. Report what actually happened,
        // naming the file the user now has to remove by hand, instead of a bare error that
        // leaves them wondering whether the delete worked.
        do {
            try Storage.deleteWorkspaceDisk(at: workspace.dataDiskURL,
                                            mayRemoveDirectory: workspace.ownsDirectory)
            Log.info("workspace: deleted “\(workspace.name)” (\(workspace.dataDiskURL.path))")
        } catch {
            Log.warn("workspace: removed “\(workspace.name)” from the list but its disk "
                     + "could not be deleted: \(error.localizedDescription)")
            throw VeloxError.workspace(
                "“\(workspace.name)” was removed, but its disk file couldn't be deleted. "
                + "Remove it by hand to reclaim the space:\n\(workspace.dataDiskURL.path)")
        }
    }

    /// Point the manifest at a different workspace. Persisting this is all a switch *is*;
    /// the engine restart around it belongs to the caller.
    public static func activate(id: String) throws {
        try mutate { manifest in
            guard let i = manifest.workspaces.firstIndex(where: { $0.id == id }) else {
                throw VeloxError.workspace("That workspace no longer exists.")
            }
            manifest.activeID = id
            manifest.workspaces[i].lastUsed = Date()
        }
    }

    /// Record that a workspace booted successfully (see `Workspace.firstBootedAt`).
    public static func recordBoot(id: String) {
        _ = try? mutate { manifest in
            guard let i = manifest.workspaces.firstIndex(where: { $0.id == id }) else { return }
            let now = Date()
            if manifest.workspaces[i].firstBootedAt == nil {
                manifest.workspaces[i].firstBootedAt = now
            }
            manifest.workspaces[i].lastUsed = now
        }
    }

    public static func setDiskGiB(id: String, _ gib: Int) throws {
        try mutate { manifest in
            guard let i = manifest.workspaces.firstIndex(where: { $0.id == id }) else { return }
            manifest.workspaces[i].diskGiB = Workspace.clampDiskGiB(gib)
        }
    }

    /// Move a workspace's disk into `destinationDir` and repoint the manifest.
    ///
    /// Mirrors the ordering the data-disk move has been hardened into three times: stage the
    /// data at the destination while leaving the source intact, persist the new location,
    /// and only then drop the original. A crash anywhere in that sequence leaves the manifest
    /// pointing at a disk that exists.
    ///
    /// **The caller must have stopped the engine** if this workspace is the active one.
    public static func relocate(id: String, to destinationDir: URL,
                                progress: (@Sendable (Double) -> Void)? = nil) throws {
        guard let workspace = try load().workspace(id: id) else {
            throw VeloxError.workspace("That workspace no longer exists.")
        }
        let src = workspace.dataDiskURL
        let dst = destinationDir.standardizedFileURL.appendingPathComponent("data.img")
        guard dst != src.standardizedFileURL else {
            throw VeloxError.workspace("“\(workspace.name)” is already in that folder.")
        }
        // Reject a destination that would collide with another workspace *before* copying
        // anything, so the check can't be discovered halfway through a cross-volume copy.
        var probe = try load()
        if let i = probe.workspaces.firstIndex(where: { $0.id == id }) {
            probe.workspaces[i].directory = destinationDir.standardizedFileURL.path
            try validateDiskPaths(probe.workspaces)
        }
        guard !FileManager.default.fileExists(atPath: dst.path) else {
            throw VeloxError.workspace("A data.img already exists in \(destinationDir.path).")
        }

        if workspace.diskExists {
            try Storage.stageDataDiskMove(from: src, to: dst, progress: progress)
        }
        do {
            try mutate { manifest in
                guard let i = manifest.workspaces.firstIndex(where: { $0.id == id }) else {
                    throw VeloxError.workspace("That workspace no longer exists.")
                }
                manifest.workspaces[i].directory = destinationDir.standardizedFileURL.path
            }
        } catch {
            // The manifest still points at `src`; drop the staged copy so the two can't
            // drift apart. Nothing was removed from the source.
            if workspace.diskExists { try? FileManager.default.removeItem(at: dst) }
            throw error
        }
        if workspace.diskExists {
            Storage.removeMovedSource(at: src)
            // A now-empty owned slot is ours to tidy up.
            if workspace.ownsDirectory {
                try? Storage.deleteWorkspaceDisk(at: src, mayRemoveDirectory: true)
            }
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

    /// Keep the last good manifest alongside the live one. Cheap insurance: this file is the
    /// only thing that knows where a relocated workspace's disk is.
    private static func backup() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.workspaceManifest.path) else { return }
        let bak = Paths.workspaceManifest.appendingPathExtension("bak")
        try? fm.removeItem(at: bak)
        try? fm.copyItem(at: Paths.workspaceManifest, to: bak)
    }

    /// Temp file → fsync → `rename(2)` → fsync the directory. `Data.write(.atomic)` gets the
    /// rename but not the directory fsync, and losing this file loses the only record of
    /// where a relocated workspace lives.
    /// Public so `velox-selftest` can construct edge-case manifests (a dangling activeID)
    /// directly, the way `validateDiskPaths` is exercised.
    public static func writeDurably(_ manifest: WorkspaceManifest) throws {
        try Paths.ensureRoot()
        let target = Paths.workspaceManifest
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
