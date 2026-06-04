import Foundation

/// Manages the persistent data disk backing `/var/lib/docker` in the guest.
enum Storage {
    /// Create a sparse raw disk image at `url` if it doesn't exist yet.
    /// Sparse means it only consumes real space as the guest writes to it.
    static func ensureDataDisk(at url: URL, sizeGiB: UInt64) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }

        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw VeloxError.socketSetupFailed("create data disk \(url.lastPathComponent)", errno)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: sizeGiB * 1024 * 1024 * 1024)
        Log.info("created \(sizeGiB) GiB data disk: \(url.path)")
    }
}
