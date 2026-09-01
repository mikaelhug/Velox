import Foundation

/// The one shared "persist a small JSON manifest under `~/.velox`, durably" helper.
///
/// `WorkspaceStore` and `RemoteHostStore` had byte-identical copies of the encoder, the
/// decoder, `backup()` and `writeDurably()` — differing only in which `Paths` constant they
/// named. That is the duplication CLAUDE.md §10 exists to prevent, and the same shape as the
/// four copies of an EINTR-retrying `writeAll` that `82a7044` folded into `FDIO.writeAll`
/// "so the retry semantics can't drift apart". The durability sequence here is subtle enough
/// that two copies would eventually disagree about it.
///
/// What stays with each store: its manifest type, its `Paths` constant, its lock, its
/// validation rules, and what a missing or unreadable file means — those genuinely differ
/// (a workspace manifest always has at least one entry and fails loud; an absent host list
/// is normal and empty).
enum JSONManifest {
    /// Pretty-printed and key-sorted so a hand-edit produces a small, readable diff, with
    /// ISO-8601 dates so the file stays portable.
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Keep the last good copy alongside the live one. Cheap insurance: these files are the
    /// only record of where a relocated workspace's disk lives, and of how to reach a
    /// configured server.
    static func backup(_ target: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return }
        let bak = target.appendingPathExtension("bak")
        try? fm.removeItem(at: bak)
        try? fm.copyItem(at: target, to: bak)
    }

    /// Temp file → fsync → `rename(2)` → fsync the directory.
    ///
    /// `Data.write(.atomic)` gets the rename but **not** the directory fsync, so a crash can
    /// leave the directory entry unwritten even though the bytes are on disk — losing the
    /// only record of where a relocated workspace lives.
    static func writeDurably<T: Encodable>(_ value: T, to target: URL) throws {
        try Paths.ensureRoot()
        let tmp = target.appendingPathExtension("tmp")
        let data = try encoder.encode(value)
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
