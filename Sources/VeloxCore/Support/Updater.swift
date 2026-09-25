import CryptoKit
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
            // The CLI process runs no engine of its own, so there is nothing to stop between
            // staging and the swap.
            if let staged = stage(release), install(staged) {
                relaunch(staged)
                exit(0)
            }
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
        // Synchronized by the semaphore (the closure signals; we read only after wait()).
        nonisolated(unsafe) var release: Release?
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

    /// GUI "Update" entry point, step 1 of 3: check the configured repo and, if a newer
    /// release exists, download, verify and unpack it beside the installed app — without
    /// touching the running app or its engine. Same code path as `velox update --apply`
    /// (CLAUDE.md §3). Blocking — call off the main thread. The GUI then stops its engine
    /// the normal way, `install`s, and `relaunch`es; see `EngineController.applyUpdate`.
    public static func stageLatestUpdate() -> StagedUpdate? {
        let repo = Versions.githubRepo
        guard repo.contains("/"),
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest"),
              let release = fetchLatest(url) else {
            Log.error("update: no release found or repo unreachable"); return nil
        }
        let latest = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
        guard compareSemver(latest, Versions.velox) > 0 else {
            print("Velox is up to date (v\(Versions.velox))."); return nil
        }
        return stage(release)
    }

    /// A verified, unpacked build waiting beside the installed app for `install`.
    public struct StagedUpdate: Sendable {
        public let tag: String
        /// The downloaded archive — revealed in Finder whenever the automatic path gives up.
        let archive: URL
        /// `.velox-update-<tag>` beside the app: same volume, so the swap is a rename.
        let staging: URL
        let newApp: URL
        /// The installed `Velox.app` this process is running from.
        let target: URL
    }

    /// Safe to use as a single path component? `tag` and `asset.name` arrive in the release
    /// JSON, which is read *before* any signature check, and both are used to build paths
    /// (`updates/<tag>/<name>`, `.velox-update-<tag>` beside the app) that are then created,
    /// extracted into, and `removeItem`'d. A `/` or `..` escapes the intended directory.
    private static func safePathComponent(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 128 && !s.hasPrefix(".")
            && s.allSatisfy { $0.isLetter || $0.isNumber || "._-+".contains($0) }
    }

    /// Download the new release's macOS `.zip`, verify it, and unpack it beside the installed
    /// `Velox.app`. Returns nil — revealing the download in Finder where a manual install is
    /// still possible — if any gate refuses or the app can't be replaced automatically (e.g.
    /// it lives somewhere read-only).
    private static func stage(_ release: Release) -> StagedUpdate? {
        // The macOS release asset is the programmatically-unpackable .zip (build-app.sh
        // ships no .dmg — see the release workflow).
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let assetURL = URL(string: asset.url) else {
            Log.error("update: release \(release.tag) has no macOS .zip asset"); return nil
        }
        guard safePathComponent(release.tag), safePathComponent(asset.name) else {
            Log.error("update: refusing release \(release.tag) — tag or asset name is not a "
                      + "safe path component"); return nil
        }
        let fm = FileManager.default
        let dir = Paths.root.appendingPathComponent("updates/\(release.tag)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(asset.name)

        print("Downloading \(asset.name)…")
        let sem = DispatchSemaphore(value: 0)
        // Synchronized by the semaphore (the closure signals; we read only after wait()).
        nonisolated(unsafe) var saved = false
        URLSession.shared.downloadTask(with: assetURL) { tmp, _, _ in
            defer { sem.signal() }
            guard let tmp else { return }
            try? FileManager.default.removeItem(at: dest)
            saved = (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil
        }.resume()
        _ = sem.wait(timeout: .now() + 600)
        guard saved else { Log.error("update: download failed"); return nil }
        print("Saved \(dest.lastPathComponent).")

        // Integrity gate: the CI signs each release .zip with Ed25519 (release-sign.swift);
        // the matching public key is baked into this build (versions.env → Versions.swift).
        // No/invalid signature ⇒ never auto-install — reveal the download for a manual call.
        guard verifyReleaseSignature(of: dest, assetName: asset.name, in: release) else {
            reveal(dest); return nil
        }
        guard let target = runningAppBundle() else {
            print("Could not locate the installed Velox.app — open \(dest.path) to install."); reveal(dest); return nil
        }
        // Preflight the install location BEFORE unpacking or stopping the engine: a
        // read-only volume, SIP-protected path, or /Applications without admin can't be
        // written, and there's no point tearing the running engine down for a swap that
        // will fail. Reveal the download for a manual install instead.
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            Log.error("update: \(target.deletingLastPathComponent().path) is not writable — open \(dest.path) to install manually.")
            print("Open \(dest.path) to install the update manually."); reveal(dest); return nil
        }
        // Unpack beside the target: same volume, so the swap in `install` is an atomic rename.
        let staging = target.deletingLastPathComponent().appendingPathComponent(".velox-update-\(release.tag)")
        try? fm.removeItem(at: staging)
        guard run(["/usr/bin/ditto", "-x", "-k", dest.path, staging.path]) == 0,
              let newApp = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }) else {
            Log.error("update: could not unpack \(asset.name)"); try? fm.removeItem(at: staging); reveal(dest); return nil
        }
        // Version binding. The Ed25519 signature covers the zip BYTES, while the version we
        // compared against came from the unsigned `tag_name`. Anyone able to control the
        // /releases/latest response (repo compromise, or a TLS-intercepting proxy with a
        // trusted root) could therefore advertise a high tag pointing at an older, genuinely
        // signed build and downgrade us onto a known-vulnerable version. Read the version out
        // of the STAGED bundle — which the signature does cover — and require a real upgrade.
        let stagedVersion = (NSDictionary(contentsOf: newApp
            .appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"]
            as? String) ?? ""
        guard compareSemver(stagedVersion, Versions.velox) > 0 else {
            Log.error("update: staged bundle reports v\(stagedVersion.isEmpty ? "?" : stagedVersion)"
                      + ", which is not newer than v\(Versions.velox) — refusing "
                      + "(advertised \(release.tag)). Possible downgrade or replay.")
            try? fm.removeItem(at: staging); reveal(dest); return nil
        }
        return StagedUpdate(tag: release.tag, archive: dest, staging: staging,
                            newApp: newApp, target: target)
    }

    /// Step 2: swap the staged build in for the installed one. Returns false — having logged
    /// the reason and revealed the download — if it could not; the installed app is then
    /// untouched. Call only once nothing needs the old bundle any more: the GUI stops its
    /// engine first.
    public static func install(_ update: StagedUpdate) -> Bool {
        let fm = FileManager.default
        do {
            _ = try fm.replaceItemAt(update.target, withItemAt: update.newApp)
            try? fm.removeItem(at: update.staging)
        } catch {
            Log.error("update: could not replace \(update.target.path): \(error.localizedDescription)")
            print("Open \(update.archive.path) to install the update manually.")
            discard(update); reveal(update.archive)
            return false
        }
        // Re-register the new bundle with LaunchServices so its icon + Info.plist
        // changes take effect immediately, rather than from a stale icon cache.
        let lsregister = "/System/Library/Frameworks/CoreServices.framework"
            + "/Frameworks/LaunchServices.framework/Support/lsregister"
        _ = run([lsregister, "-f", update.target.path])
        print("Updated \(update.target.lastPathComponent) → \(update.tag).")
        return true
    }

    /// Step 3: start the freshly installed build. The caller quits right after.
    public static func relaunch(_ update: StagedUpdate) {
        print("Relaunching…")
        let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", update.target.path]
        do { try open.run() } catch {
            // The swap already succeeded — don't die silently with nothing relaunched.
            Log.error("update: relaunch failed (\(error.localizedDescription)) — open \(update.target.path) manually")
            reveal(update.target)
        }
    }

    /// Drop a staged build that will not be installed.
    public static func discard(_ update: StagedUpdate) {
        try? FileManager.default.removeItem(at: update.staging)
    }

    // MARK: Release signature verification

    /// Verify the downloaded release archive against its Ed25519 `.sig` asset.
    /// - A build without a baked-in public key (dev builds) skips the check with a log line.
    /// - A keyed build REFUSES to auto-install when the sig asset is missing or invalid;
    ///   the caller reveals the download so the user can decide manually.
    private static func verifyReleaseSignature(of file: URL, assetName: String, in release: Release) -> Bool {
        let pubB64 = Versions.releasePubkey
        guard !pubB64.isEmpty else {
            // A dev build (compiled without VELOX_RELEASE_PUBKEY) has nothing to verify against.
            // A RELEASE build with no key is a build misconfiguration — fail CLOSED rather than
            // auto-install an unverified archive; the caller reveals the download instead.
            #if DEBUG
            Log.warn("update: dev build has no release public key — skipping signature verification")
            return true
            #else
            Log.error("update: release build is missing its public key — refusing to auto-install "
                      + "(rebuild with VELOX_RELEASE_PUBKEY set in versions.env)")
            return false
            #endif
        }
        guard let sigAsset = release.assets.first(where: { $0.name == assetName + ".sig" }),
              let sigURL = URL(string: sigAsset.url) else {
            Log.error("update: release \(release.tag) has no \(assetName).sig — refusing to auto-install")
            return false
        }
        guard let sigText = fetchData(sigURL).flatMap({ String(data: $0, encoding: .utf8) }),
              let data = try? Data(contentsOf: file),
              ed25519Verify(data: data,
                            signatureB64: sigText.trimmingCharacters(in: .whitespacesAndNewlines),
                            publicKeyB64: pubB64) else {
            Log.error("update: Ed25519 signature check FAILED for \(assetName) — refusing to install")
            return false
        }
        print("Signature verified (\(sigAsset.name)).")
        return true
    }

    /// Raw Ed25519 verify over base64 key + signature. `package` so the selftest can
    /// round-trip it without exporting it as public API.
    package static func ed25519Verify(data: Data, signatureB64: String, publicKeyB64: String) -> Bool {
        guard let sig = Data(base64Encoded: signatureB64),
              let raw = Data(base64Encoded: publicKeyB64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    /// Small synchronous GET (release `.sig` assets are ~90 bytes).
    private static func fetchData(_ url: URL) -> Data? {
        var request = URLRequest(url: url)
        request.setValue("velox-updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let sem = DispatchSemaphore(value: 0)
        // Synchronized by the semaphore (the closure signals; we read only after wait()).
        nonisolated(unsafe) var body: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { sem.signal() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            body = data
        }.resume()
        _ = sem.wait(timeout: .now() + 60)
        return body
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
    /// `package` (not private) so the selftest can exercise the ordering.
    package static func compareSemver(_ a: String, _ b: String) -> Int {
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
