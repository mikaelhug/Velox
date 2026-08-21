import Foundation

/// Keeps the installed guest (`~/.velox/{kernel,root.img}`) in sync with the copy bundled inside
/// `Velox.app`. `GuestImage.locate()` prefers the *installed* copy (so the dev `make-guest.sh`
/// workflow and an env override work), which means that without this, an app update would ship a
/// new host + a new bundled guest yet keep booting the *old* installed guest forever — the engine
/// would be pinned to a stale `~/.velox` copy.
///
/// So on launch we stamp the installed guest with the app version that wrote it, and whenever the
/// running app version differs (a fresh install or an update), we replace `kernel` + `root.img`
/// from the bundle. The user's `data.img` (images/volumes) is never touched.
///
/// No-op when there's no bundled guest (a dev CLI build, where `Bundle.main` has no guest) or when
/// the installed guest already matches the running version — so `make-guest.sh`, which writes the
/// same stamp, is left in place during development.
public enum GuestInstall {
    /// `~/.velox/guest.version` — the Velox version whose guest is currently installed.
    private static var stampURL: URL { Paths.root.appendingPathComponent("guest.version") }

    /// Identity of the guest a bundle carries: its version plus each artifact's size and
    /// modification time. Cheap (no hashing of an 80 MiB rootfs) and enough to notice a
    /// rebuild — the same size+mtime basis the sleep sidecar uses.
    public static func stamp(version: String, kernel: URL, root: URL) -> String {
        func part(_ url: URL) -> String {
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "?" }
            let size = (a[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size)@\(mtime)"
        }
        return "\(version)|\(part(kernel))|\(part(root))"
    }

    public static func refreshFromBundleIfNeeded() {
        let fm = FileManager.default
        // Only a packaged .app carries a bundled guest; a dev build has none → nothing to sync.
        guard let bundledKernel = bundled("kernel"), let bundledRoot = bundled("root.img") else { return }

        // Stamp on the bundle's CONTENT, not just the version string. Stamping on version
        // alone meant a guest rebuilt under the same VELOX_VERSION was never installed:
        // ~/.velox kept the older kernel/rootfs and the VM silently booted it, while the
        // app bundle carried the new one. That is invisible (the versions match) and costs
        // a debugging cycle every time — and it would strand users on a stale guest if a
        // release ever re-cut the same version.
        let installedStamp = (try? String(contentsOf: stampURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleStamp = stamp(version: Versions.velox, kernel: bundledKernel, root: bundledRoot)
        let haveBoth = fm.fileExists(atPath: Paths.kernel.path) && fm.fileExists(atPath: Paths.rootDisk.path)
        if haveBoth, installedStamp == bundleStamp { return } // already current

        do {
            try Paths.ensureRoot()
            try replace(bundledKernel, into: Paths.kernel)
            try replace(bundledRoot, into: Paths.rootDisk)
            try bundleStamp.write(to: stampURL, atomically: true, encoding: .utf8)
            Log.info("guest install: refreshed ~/.velox kernel+root.img from the app bundle (v\(Versions.velox))")
        } catch {
            // Non-fatal: GuestImage.resolve() still falls back to the in-bundle copy directly.
            Log.warn("guest install: could not refresh installed guest from bundle: \(error)")
        }
    }

    /// True when a guest image is available to boot — already installed under `~/.velox`, or
    /// bundled in the app (it's installed from the bundle by `refreshFromBundleIfNeeded()`). For a
    /// shipped `.app` this is always true; only a source build with neither returns false. Used by
    /// onboarding so a packaged app never tells the user to build the guest themselves.
    public static var guestAvailable: Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: Paths.kernel.path) && fm.fileExists(atPath: Paths.rootDisk.path) { return true }
        return bundled("kernel") != nil && bundled("root.img") != nil
    }

    /// Copy `src` over `dst` via a temp file + rename, so a crash mid-copy never leaves a
    /// truncated kernel/rootfs in place (the rename is atomic on the same filesystem).
    private static func replace(_ src: URL, into dst: URL) throws {
        let fm = FileManager.default
        let tmp = dst.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: src, to: tmp)
        // `rename(2)` replaces the destination atomically — no unlink first. The old
        // remove-then-move left a window with NO kernel/rootfs on disk at all if the move
        // then failed, which is exactly the crash the temp file was meant to prevent.
        guard rename(tmp.path, dst.path) == 0 else {
            let err = errno
            try? fm.removeItem(at: tmp)
            throw VeloxError.socketSetupFailed("rename(\(dst.lastPathComponent))", err)
        }
    }

    /// The guest artifact bundled in `Velox.app/Contents/Resources/<name>`, or nil for a dev
    /// build. Mirrors `GuestImage.locate`'s bundle lookup: the GUI runs from `Contents/MacOS`
    /// (Resources is `resourceURL`); the CLI runs from `Contents/Resources/bin` (one dir up).
    private static func bundled(_ name: String) -> URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent(name),
           fm.fileExists(atPath: res.path) { return res }
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let up = execDir.deletingLastPathComponent().appendingPathComponent(name)
            if fm.fileExists(atPath: up.path) { return up }
        }
        return nil
    }
}
