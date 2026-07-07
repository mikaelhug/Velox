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

    // MARK: - Move

    /// Relocate `data.img` from `src` to `dst`, preserving sparseness. **The caller MUST have
    /// stopped the engine first** (the VM holds the file open + the guest must have flushed) —
    /// moving a live/torn image corrupts ext4.
    ///
    /// Stage a data-disk move: place the data at `dst` while LEAVING `src` intact, so the
    /// caller can persist the new location *before* the original is dropped — a crash in that
    /// gap then can't orphan the disk (config still points at a disk that exists). Same volume
    /// → an instant hard link (same inode, sparse preserved); different volume → a hole-aware
    /// copy so a mostly-empty 128 GiB disk copies its *used* bytes, fsync'd + atomically
    /// published. Any failure leaves `src` intact. Call `removeMovedSource` once persisted.
    public static func stageDataDiskMove(from src: URL, to dst: URL,
                                         progress: (@Sendable (Double) -> Void)? = nil) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            throw VeloxError.diskMove("Source data disk not found at \(src.path).")
        }
        guard !fm.fileExists(atPath: dst.path) else {
            throw VeloxError.diskMove("A data.img already exists in \(dst.deletingLastPathComponent().path).")
        }
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)

        if sameVolume(src, dst) {
            try fm.linkItem(at: src, to: dst)   // hard link: instant, same inode, keeps src
            progress?(1.0)
            return
        }
        try sparseCopyAcrossVolumes(src: src, dst: dst, progress: progress)
    }

    /// Drop the original disk after `stageDataDiskMove` and once the new location has been
    /// persisted. Best-effort: a leftover source only wastes space, it never loses data.
    public static func removeMovedSource(at src: URL) {
        try? FileManager.default.removeItem(at: src)
    }

    /// Whether `src` and `dst`'s parent folder live on the same volume (so a rename suffices).
    private static func sameVolume(_ src: URL, _ dst: URL) -> Bool {
        func volID(_ url: URL) -> (NSCopying & NSSecureCoding & NSObjectProtocol)? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        }
        guard let a = volID(src), let b = volID(dst.deletingLastPathComponent()) else { return false }
        return (a as AnyObject).isEqual(b)
    }

    /// Hole-aware copy to `dst.tmp` (only real data extents are read/written; the gaps stay
    /// holes), fsynced and atomically published. The source is left intact for the caller to
    /// remove. Throws leave the source untouched and clean up the partial destination.
    private static func sparseCopyAcrossVolumes(src: URL, dst: URL,
                                                progress: (@Sendable (Double) -> Void)?) throws {
        let fm = FileManager.default
        let tmp = dst.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)

        let srcFD = open(src.path, O_RDONLY)
        guard srcFD >= 0 else { throw VeloxError.diskMove("Couldn't open the data disk: \(errnoText()).") }
        defer { close(srcFD) }
        let dstFD = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard dstFD >= 0 else { throw VeloxError.diskMove("Couldn't create the destination: \(errnoText()).") }
        var dstOpen = true
        func closeDst() { if dstOpen { close(dstFD); dstOpen = false } }
        defer { closeDst() }

        let length = lseek(srcFD, 0, SEEK_END)
        guard length >= 0 else { throw VeloxError.diskMove("Couldn't size the data disk: \(errnoText()).") }
        // Progress against the *used* (allocated) bytes — the real work for a sparse image.
        let allocated = (try? src.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
            .totalFileAllocatedSize.map(Int64.init) ?? Int64(length)

        do {
            try copyDataExtents(srcFD: srcFD, dstFD: dstFD, length: length,
                                denom: Double(max(allocated, 1)), progress: progress)
            guard ftruncate(dstFD, length) == 0 else {
                throw VeloxError.diskMove("Couldn't finalize the destination size: \(errnoText()).")
            }
            guard fsync(dstFD) == 0 else {
                throw VeloxError.diskMove("Couldn't flush the destination: \(errnoText()).")
            }
            closeDst()
            fsyncDirectory(dst.deletingLastPathComponent())   // make the rename durable
        } catch {
            closeDst(); try? fm.removeItem(at: tmp)
            throw error
        }

        // Atomic publish on the destination volume; verify. The source is left intact — the
        // caller drops it (removeMovedSource) only after persisting the new location.
        do {
            try fm.moveItem(at: tmp, to: dst)
            let moved = Int64((try dst.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? -1)
            guard moved == Int64(length) else {
                throw VeloxError.diskMove("Moved disk failed verification (size mismatch).")
            }
        } catch {
            try? fm.removeItem(at: tmp); try? fm.removeItem(at: dst)
            throw error
        }
        progress?(1.0)
    }

    /// Walk `src`'s data extents via `SEEK_DATA`/`SEEK_HOLE`, copying each to the same offset in
    /// `dst` (gaps remain holes). Falls back to a full byte copy on a filesystem that can't report
    /// holes (the destination simply won't be sparse there — inherent).
    private static func copyDataExtents(srcFD: Int32, dstFD: Int32, length: off_t,
                                        denom: Double, progress: (@Sendable (Double) -> Void)?) throws {
        let chunk = 8 * 1024 * 1024
        var buf = [UInt8](repeating: 0, count: chunk)
        var copied: Int64 = 0
        var lastPct = -1
        func report() {
            let pct = Int((min(1.0, Double(copied) / denom) * 100).rounded(.down))
            if pct != lastPct { lastPct = pct; progress?(Double(pct) / 100) }
        }
        var off: off_t = 0
        while off < length {
            let dataStart = lseek(srcFD, off, SEEK_DATA)
            if dataStart == -1 {
                if errno == ENXIO { break }                       // only holes remain
                if (errno == EINVAL || errno == ENOTSUP) && off == 0 {
                    try fullCopy(srcFD: srcFD, dstFD: dstFD, length: length, progress: progress)
                    return
                }
                throw VeloxError.diskMove("Error scanning the data disk: \(errnoText()).")
            }
            var holeStart = lseek(srcFD, dataStart, SEEK_HOLE)
            if holeStart == -1 { holeStart = length }             // data runs to EOF
            try buf.withUnsafeMutableBytes { raw in
                let base = raw.baseAddress!
                var pos = dataStart
                while pos < holeStart {
                    let want = Int(min(off_t(chunk), holeStart - pos))
                    let got = try readFully(srcFD, base, want, at: pos)
                    // 0 inside a known data extent means the file was truncated under us — fail
                    // rather than spin (the source is never touched until a verified publish).
                    guard got > 0 else { throw VeloxError.diskMove("Unexpected end of data while copying the disk.") }
                    try writeFully(dstFD, base, got, at: pos)
                    pos += off_t(got); copied += Int64(got); report()
                }
            }
            off = holeStart
        }
    }

    /// Plain full-length copy (non-sparse fallback).
    private static func fullCopy(srcFD: Int32, dstFD: Int32, length: off_t,
                                 progress: (@Sendable (Double) -> Void)?) throws {
        let chunk = 8 * 1024 * 1024
        var buf = [UInt8](repeating: 0, count: chunk)
        let denom = Double(max(length, 1))
        var pos: off_t = 0
        var lastPct = -1
        try buf.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            while pos < length {
                let want = Int(min(off_t(chunk), length - pos))
                let got = try readFully(srcFD, base, want, at: pos)
                if got == 0 { break }
                try writeFully(dstFD, base, got, at: pos)
                pos += off_t(got)
                let pct = Int((Double(pos) / denom * 100).rounded(.down))
                if pct != lastPct { lastPct = pct; progress?(Double(pct) / 100) }
            }
        }
    }

    private static func readFully(_ fd: Int32, _ base: UnsafeMutableRawPointer, _ want: Int, at off: off_t) throws -> Int {
        var got = 0
        while got < want {
            let n = pread(fd, base + got, want - got, off + off_t(got))
            if n < 0 { if errno == EINTR { continue }; throw VeloxError.diskMove("Read error: \(errnoText()).") }
            if n == 0 { break }   // EOF (only legitimate at end of file)
            got += n
        }
        return got
    }

    private static func writeFully(_ fd: Int32, _ base: UnsafeRawPointer, _ count: Int, at off: off_t) throws {
        var done = 0
        while done < count {
            let n = pwrite(fd, base + done, count - done, off + off_t(done))
            if n < 0 { if errno == EINTR { continue }; throw VeloxError.diskMove("Write error: \(errnoText()).") }
            done += n
        }
    }

    private static func fsyncDirectory(_ dir: URL) {
        let fd = open(dir.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = fsync(fd)
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
}
