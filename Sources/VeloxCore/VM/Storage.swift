import Foundation

/// Manages the persistent data disk backing `/var/lib/docker` in the guest.
public enum Storage {
    /// Create the data disk at `url` if it doesn't exist yet. Prefers Apple's
    /// **ASIF** sparse format (macOS 15+): it returns space to the host when the
    /// guest TRIMs deleted image layers (vinit runs `fstrim` periodically), so the
    /// disk doesn't grow forever like the classic `Docker.raw`. Falls back to a
    /// raw sparse file if `diskutil`/ASIF is unavailable.
    public static func ensureDataDisk(at url: URL, sizeGiB: UInt64) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        let bytes = sizeGiB * 1024 * 1024 * 1024

        if createASIF(at: url, bytes: bytes) {
            Log.info("created \(sizeGiB) GiB ASIF data disk (sparse, TRIM-reclaimable): \(url.path)")
            return
        }

        // Fallback: a raw sparse file (still sparse on APFS, but ASIF reclaims better).
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw VeloxError.socketSetupFailed("create data disk \(url.lastPathComponent)", errno)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: bytes)
        Log.info("created \(sizeGiB) GiB raw data disk: \(url.path)")
    }

    /// Create a blank ASIF image (no host filesystem — raw blocks the guest formats
    /// ext4). Returns false if diskutil isn't there or the format isn't supported.
    private static func createASIF(at url: URL, bytes: UInt64) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["image", "create", "blank",
                       "--format", "ASIF", "--fs", "None",
                       "--size", "\(bytes)", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
    }
}
