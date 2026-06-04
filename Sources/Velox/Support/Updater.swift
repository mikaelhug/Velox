import Foundation

/// Checks GitHub Releases for a newer Velox build and (optionally) downloads it.
/// This is the single code path a future UI "Update" button must call too.
enum Updater {
    private struct Release {
        let tag: String
        let htmlURL: String
        let assets: [(name: String, url: String)]
    }

    /// Check the configured GitHub repo for a newer release.
    static func check(apply: Bool) {
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
            download(release)
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

    /// Download the macOS/arm64 asset to ~/.velox/updates/<tag>/ for the
    /// bundled installer to apply. (Self-replacement lands with the first real
    /// release; the download path here is ready for it.)
    private static func download(_ release: Release) {
        guard let asset = release.assets.first(where: {
            $0.name.contains("arm64") || $0.name.contains("macos") || $0.name.hasSuffix(".tar.gz")
        }), let assetURL = URL(string: asset.url) else {
            Log.error("update: release \(release.tag) has no macOS arm64 asset")
            return
        }
        do {
            let dir = Paths.root.appendingPathComponent("updates/\(release.tag)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(asset.name)
            print("Downloading \(asset.name)…")

            let sem = DispatchSemaphore(value: 0)
            var saved = false
            URLSession.shared.downloadTask(with: assetURL) { tmp, _, _ in
                defer { sem.signal() }
                guard let tmp else { return }
                try? FileManager.default.removeItem(at: dest)
                saved = (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil
            }.resume()
            _ = sem.wait(timeout: .now() + 600)

            if saved {
                print("Saved: \(dest.path)")
                print("Extract and replace the running binary to finish the update.")
            } else {
                Log.error("update: download failed")
            }
        } catch {
            Log.error("update: \(error.localizedDescription)")
        }
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
