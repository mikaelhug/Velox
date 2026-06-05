import Foundation

/// First-run setup so a freshly downloaded `Velox.app` gives the user a working
/// `docker` (and `velox`) command in the terminal — rootless, no admin, no
/// `/usr/local/bin`. We symlink the bundled CLIs into `~/.velox/bin` and add that
/// directory to the shell `PATH`. Idempotent and reversible (a single marked block).
public enum FirstRun {
    public struct Result: Sendable {
        public let linkedTools: Bool
        public let updatedPATH: Bool
        public let binDir: String
        public let message: String
    }

    /// The rootless bin dir the CLIs are installed into (kept on the user's PATH).
    public static var binDir: URL { Paths.root.appendingPathComponent("bin", isDirectory: true) }

    /// True if `~/.velox/bin` is already on the current process's PATH.
    public static var onPATH: Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init).contains(binDir.path)
    }

    /// Symlink the bundled `velox` + `docker` into `~/.velox/bin` (symlinks, so a
    /// later app update is picked up automatically), and — when `updateShellProfile`
    /// is set — add that dir to PATH in the user's zsh profile. Safe on every launch.
    @discardableResult
    public static func installCLITools(updateShellProfile: Bool) -> Result {
        let fm = FileManager.default
        guard let bundledBin = bundledBinDir,
              fm.fileExists(atPath: bundledBin.appendingPathComponent("velox").path) else {
            return Result(linkedTools: false, updatedPATH: false, binDir: binDir.path,
                          message: "Bundled CLIs not found (running from a dev build, not Velox.app).")
        }
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        var linked = true
        for tool in ["velox", "docker"] {
            let link = binDir.appendingPathComponent(tool)
            let src = bundledBin.appendingPathComponent(tool)
            try? fm.removeItem(at: link)
            do { try fm.createSymbolicLink(at: link, withDestinationURL: src) } catch { linked = false }
        }
        let pathUpdated = updateShellProfile ? ensurePATH() : false
        return Result(linkedTools: linked, updatedPATH: pathUpdated, binDir: binDir.path,
                      message: linked
                        ? "Installed `docker` and `velox` into \(binDir.path)."
                        : "Could not link the CLIs into \(binDir.path).")
    }

    /// Where the CLIs live inside the running bundle: `Velox.app/Contents/Resources/bin`.
    private static var bundledBinDir: URL? {
        if let res = Bundle.main.resourceURL {
            let bin = res.appendingPathComponent("bin")
            if FileManager.default.fileExists(atPath: bin.path) { return bin }
        }
        // CLI invoked from inside the bundle: it's already in .../Resources/bin.
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent(),
           FileManager.default.fileExists(atPath: execDir.appendingPathComponent("docker").path) {
            return execDir
        }
        return nil
    }

    private static let marker = "# >>> velox PATH >>>"
    private static let markerEnd = "# <<< velox PATH <<<"

    /// Append a marked PATH block to the user's zsh profiles if not already present.
    /// Returns true if any file was modified. Remove the block to opt out.
    private static func ensurePATH() -> Bool {
        let block = "\n\(marker)\nexport PATH=\"$HOME/.velox/bin:$PATH\"\n\(markerEnd)\n"
        let home = FileManager.default.homeDirectoryForCurrentUser
        var wrote = false
        for name in [".zshrc", ".zprofile"] {        // interactive + login zsh (macOS default)
            let rc = home.appendingPathComponent(name)
            let existing = (try? String(contentsOf: rc, encoding: .utf8)) ?? ""
            if existing.contains(marker) { continue }
            if (try? (existing + block).write(to: rc, atomically: true, encoding: .utf8)) != nil { wrote = true }
        }
        return wrote
    }
}
