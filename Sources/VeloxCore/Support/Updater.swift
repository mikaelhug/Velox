import Foundation

/// Checks GitHub Releases for a newer Velox build and (optionally) downloads it.
/// This is the single code path a future UI "Update" button must call too.
public enum Updater {
    private struct Release {
        let tag: String
        let htmlURL: String
        let assets: [(name: String, url: String)]
    }

    /// Structured result for the GUI "Check for Updates" button.
    public struct UpdateCheckResult: Sendable {
        public let currentVersion: String
        public let latestVersion: String?
        public let isUpdateAvailable: Bool
        public let releaseURL: String?
        public let message: String
    }

    /// Async wrapper around the same release-check logic the CLI uses, returning a
    /// structured result instead of printing. The UI "Update" button calls this —
    /// do not fork the logic (CLAUDE.md §3).
    public static func checkForUpdate() async -> UpdateCheckResult {
        let current = Versions.velox
        let repo = Versions.githubRepo
        guard repo.contains("/"),
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return UpdateCheckResult(currentVersion: current, latestVersion: nil,
                                     isUpdateAvailable: false, releaseURL: nil,
                                     message: "Update repository is not configured.")
        }
        let release: Release? = await withCheckedContinuation { cont in
            DispatchQueue.global().async { cont.resume(returning: fetchLatest(url)) }
        }
        guard let release else {
            return UpdateCheckResult(currentVersion: current, latestVersion: nil,
                                     isUpdateAvailable: false, releaseURL: nil,
                                     message: "No published release found, or GitHub is unreachable.")
        }
        let latest = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
        let available = compareSemver(latest, current) > 0
        return UpdateCheckResult(
            currentVersion: current,
            latestVersion: latest,
            isUpdateAvailable: available,
            releaseURL: release.htmlURL.isEmpty ? nil : release.htmlURL,
            message: available ? "Velox \(latest) is available." : "Velox is up to date (\(current)).")
    }

    /// Check the configured GitHub repo for a newer release.
    public static func check(apply: Bool) {
        let repo = Versions.githubRepo
        guard repo.contains("/"), !repo.hasPrefix("/"), !repo.hasSuffix("/") else {
            Log.error("update: VELOX_GITHUB_REPO is not configured in versions.env")
            return
        }
        print("Checking \(repo) for updates (current v\(Versions.velox))…")

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest"),
              let release = fetchLatest(url) else {
            print("No published release found, or the repo is unreachable.")
            return
        }

        let latest = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
        guard compareSemver(latest, Versions.velox) > 0 else {
            print("Velox is up to date (v\(Versions.velox)).")
            return
        }

        print("Update available: v\(latest)  (you have v\(Versions.velox))")
        print("  \(release.htmlURL)")
        if apply {
            applyUpdate(release)
        } else {
            print("Run `velox update --apply` to download and install it.")
        }
    }

    private static func fetchLatest(_ url: URL) -> Release? {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("velox-updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let sem = DispatchSemaphore(value: 0)
        var release: Release?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { sem.signal() }
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let assets = (json["assets"] as? [[String: Any]] ?? []).compactMap { a -> (String, String)? in
                guard let n = a["name"] as? String,
                      let u = a["browser_download_url"] as? String else { return nil }
                return (n, u)
            }
            release = Release(tag: tag,
                              htmlURL: json["html_url"] as? String ?? "",
                              assets: assets.map { (name: $0.0, url: $0.1) })
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        return release
    }

    /// GUI "Update" entry point: check the configured repo and, if a newer release
    /// exists, download + self-replace. Same code path as `velox update --apply`
    /// (CLAUDE.md §3). Blocking — call off the main thread.
    public static func applyLatestUpdate() {
        let repo = Versions.githubRepo
        guard repo.contains("/"),
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest"),
              let release = fetchLatest(url) else {
            Log.error("update: no release found or repo unreachable"); return
        }
        let latest = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
        guard compareSemver(latest, Versions.velox) > 0 else {
            print("Velox is up to date (v\(Versions.velox))."); return
        }
        applyUpdate(release)
    }

    /// Download the new release's macOS `.zip`, replace the installed `Velox.app` in
    /// place, and relaunch. Falls back to revealing the download in Finder if the app
    /// can't be replaced automatically (e.g. it lives somewhere read-only).
    private static func applyUpdate(_ release: Release) {
        // The .zip is programmatically unpackable; the .dmg is the human download.
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") })
                ?? release.assets.first(where: { $0.name.hasSuffix(".dmg") }),
              let assetURL = URL(string: asset.url) else {
            Log.error("update: release \(release.tag) has no macOS asset"); return
        }
        let fm = FileManager.default
        let dir = Paths.root.appendingPathComponent("updates/\(release.tag)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(asset.name)

        print("Downloading \(asset.name)…")
        let sem = DispatchSemaphore(value: 0); var saved = false
        URLSession.shared.downloadTask(with: assetURL) { tmp, _, _ in
            defer { sem.signal() }
            guard let tmp else { return }
            try? fm.removeItem(at: dest)
            saved = (try? fm.moveItem(at: tmp, to: dest)) != nil
        }.resume()
        _ = sem.wait(timeout: .now() + 600)
        guard saved else { Log.error("update: download failed"); return }
        print("Saved \(dest.lastPathComponent).")

        // Only a .zip can be applied in place; a .dmg is revealed for manual install.
        guard asset.name.hasSuffix(".zip") else { reveal(dest); return }
        guard let target = runningAppBundle() else {
            print("Could not locate the installed Velox.app — open \(dest.path) to install."); reveal(dest); return
        }
        // Unpack beside the target (same volume → atomic replace works), then swap.
        let staging = target.deletingLastPathComponent().appendingPathComponent(".velox-update-\(release.tag)")
        try? fm.removeItem(at: staging)
        guard run(["/usr/bin/ditto", "-x", "-k", dest.path, staging.path]) == 0,
              let newApp = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }) else {
            Log.error("update: could not unpack \(asset.name)"); try? fm.removeItem(at: staging); reveal(dest); return
        }
        do {
            _ = try fm.replaceItemAt(target, withItemAt: newApp)
            try? fm.removeItem(at: staging)
            // Re-register the new bundle with LaunchServices so its icon + Info.plist
            // changes take effect immediately, rather than from a stale icon cache.
            let lsregister = "/System/Library/Frameworks/CoreServices.framework"
                + "/Frameworks/LaunchServices.framework/Support/lsregister"
            _ = run([lsregister, "-f", target.path])
            print("Updated \(target.lastPathComponent) → \(release.tag). Relaunching…")
            let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-n", target.path]; try? open.run()
            exit(0)
        } catch {
            Log.error("update: could not replace \(target.path): \(error.localizedDescription)")
            print("Open \(dest.path) to install the update manually.")
            try? fm.removeItem(at: staging); reveal(dest)
        }
    }

    /// The enclosing `.app` of the running executable (GUI: Velox.app; a CLI shipped
    /// inside the bundle: walk up to the `.app`). nil if not running from a bundle.
    private static func runningAppBundle() -> URL? {
        if Bundle.main.bundleURL.pathExtension == "app" { return Bundle.main.bundleURL }
        var url = Bundle.main.executableURL ?? Bundle.main.bundleURL
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" { return url }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    private static func reveal(_ url: URL) { _ = run(["/usr/bin/open", "-R", url.path]) }

    @discardableResult
    private static func run(_ argv: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    /// Returns >0 if a>b, <0 if a<b, 0 if equal (dotted-integer semver).
    private static func compareSemver(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
