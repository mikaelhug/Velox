import Foundation

/// Manages the persistent data disk backing `/var/lib/docker` in the guest.
public enum Storage {
    /// Ensure the data disk at `url` exists and is at least `sizeGiB`.
    ///
    /// The disk is a **raw** image (a sparse file on APFS). The guest formats it ext4;
    /// VZ honours the guest's periodic `fstrim` by hole-punching the backing file, so
    /// blocks freed by deleted image layers return to the host (verified: a deleted
    /// 4 GiB file reclaims after a trim pass) — it doesn't grow forever.
    ///
    /// Raw, **not** Apple's ASIF sparse format: ASIF is copy-on-write, so every durable
    /// `fsync` also had to commit its allocation map, making commits ~15× slower (4.6 ms
    /// vs 0.3 ms) — and an unsynced ASIF map is unrecoverable, which silently reformatted
    /// the disk on every restart. Raw fsyncs only the dirty data page at a fixed offset,
    /// so it's fully durable *and* faster than Docker Desktop's `Docker.raw`. See
    /// `VMConfiguration` for the `.fsync` attachment.
    ///
    /// Growing only: raising `diskGiB` extends the file (the guest `resize2fs`-grows the
    /// ext4 on boot). Lowering is honoured guest-side (offline `resize2fs` via the
    /// `velox.disk` cmdline) while the sparse file stays at its high-water mark —
    /// harmless, since only blocks actually in use cost host space. The image is never
    /// shrunk here (that would truncate the guest filesystem and lose data).
    public static func ensureDataDisk(at url: URL, sizeGiB: UInt64) throws {
        let fm = FileManager.default
        let bytes = sizeGiB * 1024 * 1024 * 1024

        if fm.fileExists(atPath: url.path) {
            // A legacy ASIF image can't be attached as raw (the guest would read its
            // "shdw" container header as garbage). Its contents never persisted anyway
            // (ASIF + the old writeback mode reformatted on every boot), so recreate it
            // raw rather than hand the guest a corrupt disk to reformat on first boot.
            if isLegacyASIF(url) {
                Log.warn("replacing legacy ASIF data disk with a raw image (faster, durable commits)")
                try? fm.removeItem(at: url)
            } else {
                growDataDisk(at: url, toBytes: bytes)
                return
            }
        }
        try createRaw(at: url, bytes: bytes)
        Log.info("created \(sizeGiB) GiB raw data disk (sparse, TRIM-reclaimable): \(url.path)")
    }

    /// Create a blank sparse raw image: an empty file truncated to `bytes`. APFS keeps it
    /// sparse (only written blocks consume space); the guest formats it ext4.
    private static func createRaw(at url: URL, bytes: UInt64) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw VeloxError.socketSetupFailed("create data disk \(url.lastPathComponent)", errno)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: bytes)
    }

    /// Enlarge the raw image to `bytes` if it's currently smaller (the guest `resize2fs`
    /// expands the ext4 into it on boot). Safe to call on every start: a no-op when the
    /// image is already ≥ `bytes`. Never shrinks — that would truncate the filesystem.
    private static func growDataDisk(at url: URL, toBytes bytes: UInt64) {
        let current = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64) ?? 0
        guard bytes > current else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            Log.warn("could not open data disk to grow it")
            return
        }
        defer { try? handle.close() }
        do {
            try handle.truncate(atOffset: bytes)
            Log.info("grew data disk \(current >> 30) → \(bytes >> 30) GiB")
        } catch {
            Log.warn("failed to grow data disk: \(error.localizedDescription)")
        }
    }

    /// A legacy ASIF image starts with diskutil's `shdw` sparse-container magic. A raw
    /// image starts with the guest's ext4 (zeroed boot block), so this never false-positives.
    private static func isLegacyASIF(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        return (try? fh.read(upToCount: 4)) == Data("shdw".utf8)
    }
}
