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

    public static func refreshFromBundleIfNeeded() {
        let fm = FileManager.default
        // Only a packaged .app carries a bundled guest; a dev build has none → nothing to sync.
        guard let bundledKernel = bundled("kernel"), let bundledRoot = bundled("root.img") else { return }

        let installedVersion = (try? String(contentsOf: stampURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let haveBoth = fm.fileExists(atPath: Paths.kernel.path) && fm.fileExists(atPath: Paths.rootDisk.path)
        if haveBoth, installedVersion == Versions.velox { return } // already current

        do {
            try Paths.ensureRoot()
            try replace(bundledKernel, into: Paths.kernel)
            try replace(bundledRoot, into: Paths.rootDisk)
            try Versions.velox.write(to: stampURL, atomically: true, encoding: .utf8)
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
        try? fm.removeItem(at: dst)
        try fm.moveItem(at: tmp, to: dst)
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
