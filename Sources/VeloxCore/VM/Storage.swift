import Foundation

/// Manages the persistent data disk backing `/var/lib/docker` in the guest.
public enum Storage {
    /// Ensure the data disk at `url` exists and is at least `sizeGiB`. Prefers
    /// Apple's **ASIF** sparse format (macOS 15+): it returns space to the host when
    /// the guest TRIMs deleted image layers (vinit runs `fstrim` periodically), so the
    /// disk doesn't grow forever like the classic `Docker.raw`. Falls back to a raw
    /// sparse file if `diskutil`/ASIF is unavailable.
    ///
    /// If the user **raised** `diskGiB`, the image is **grown** to the new size here;
    /// the guest (vinit) then `resize2fs`-grows the ext4 into it on boot. The image is
    /// only ever grown — shrinking the *image* would truncate the guest ext4 and lose
    /// data. **Lowering** `diskGiB` is honoured by the guest instead: vinit shrinks the
    /// *filesystem* (offline e2fsck + resize2fs, driven by `velox.disk` on the cmdline)
    /// so `df` reflects the smaller size, while the sparse ASIF stays at its high-water
    /// mark — harmless, since it only consumes host space for blocks actually in use.
    public static func ensureDataDisk(at url: URL, sizeGiB: UInt64) throws {
        let fm = FileManager.default
        let bytes = sizeGiB * 1024 * 1024 * 1024

        guard fm.fileExists(atPath: url.path) else {
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
            return
        }

        growDataDisk(at: url, toBytes: bytes)
    }

    /// Enlarge the data-disk image to `bytes` if it's currently smaller. ASIF images
    /// resize via `diskutil`; the raw fallback grows by extending the sparse file.
    /// Safe to call on every start: a no-op when the disk is already ≥ `bytes`.
    private static func growDataDisk(at url: URL, toBytes bytes: UInt64) {
        if let current = asifTotalBytes(at: url) {                 // ASIF image
            guard bytes > current else { return }                  // already ≥ target; never shrink
            if runDiskutil(["image", "resize", "--size", "\(bytes)", url.path]) {
                Log.info("grew data disk \(current >> 30) → \(bytes >> 30) GiB "
                       + "(guest resize2fs expands the filesystem on boot)")
            } else {
                Log.warn("failed to grow ASIF data disk to \(bytes >> 30) GiB")
            }
            return
        }
        // Raw sparse-file fallback: extend the file.
        let current = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64) ?? 0
        guard bytes > current else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            Log.warn("could not open data disk to grow it")
            return
        }
        defer { try? handle.close() }
        do {
            try handle.truncate(atOffset: bytes)
            Log.info("grew raw data disk \(current >> 30) → \(bytes >> 30) GiB")
        } catch {
            Log.warn("failed to grow raw data disk: \(error.localizedDescription)")
        }
    }

    /// The logical (block-device) size of an ASIF image, via `diskutil image info`.
    /// Returns nil if `url` isn't a diskutil-recognised image (e.g. the raw fallback).
    private static func asifTotalBytes(at url: URL) -> UInt64? {
        let pipe = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["image", "info", "--plist", url.path]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let sizeInfo = dict["Size Info"] as? [String: Any],
              let total = sizeInfo["Total Bytes"] as? Int, total > 0 else { return nil }
        return UInt64(total)
    }

    /// Create a blank ASIF image (no host filesystem — raw blocks the guest formats
    /// ext4). Returns false if diskutil isn't there or the format isn't supported.
    private static func createASIF(at url: URL, bytes: UInt64) -> Bool {
        runDiskutil(["image", "create", "blank", "--format", "ASIF", "--fs", "None",
                     "--size", "\(bytes)", url.path])
            && FileManager.default.fileExists(atPath: url.path)
    }

    private static func runDiskutil(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }
}
