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
        // compose/buildx are CLI plugins, not PATH tools, but we still keep a symlink to
        // each in ~/.velox/bin as a stable indirection target (and it makes the hyphenated
        // `docker-compose` / `docker-buildx` invocations resolve on PATH too). The plugin
        // form (`docker compose`) is wired up separately by installCLIPlugins().
        for tool in ["velox", "docker", "docker-compose", "docker-buildx"] {
            let link = binDir.appendingPathComponent(tool)
            let src = bundledBin.appendingPathComponent(tool)
            try? fm.removeItem(at: link)
            do { try fm.createSymbolicLink(at: link, withDestinationURL: src) } catch { linked = false }
        }
        let linkedPlugins = installCLIPlugins()
        let pathUpdated = updateShellProfile ? ensurePATH() : false
        var message = linked
            ? "Installed `docker` and `velox` into \(binDir.path)."
            : "Could not link the CLIs into \(binDir.path)."
        if !linkedPlugins.isEmpty {
            message += " Linked the \(linkedPlugins.joined(separator: " + ")) plugin(s) into ~/.docker/cli-plugins."
        }
        return Result(linkedTools: linked, updatedPATH: pathUpdated, binDir: binDir.path, message: message)
    }

    /// Docker discovers CLI plugins under `~/.docker/cli-plugins` (and a few system dirs) —
    /// NOT on `$PATH` — so `docker compose` / `docker buildx` only work if a `docker-compose`
    /// / `docker-buildx` binary lives there. We link the bundled plugins in, but ONLY when the
    /// subcommand doesn't already resolve, so a user's existing compose/buildx (Docker Desktop,
    /// Homebrew, …) is never shadowed. The link targets the stable `~/.velox/bin/<name>`
    /// indirection (refreshed each launch above), so it survives app updates/moves. Returns the
    /// subcommands that were newly linked (empty when everything was already present).
    @discardableResult
    private static func installCLIPlugins() -> [String] {
        let fm = FileManager.default
        let docker = CLIBinding.dockerPath()
        let pluginDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".docker/cli-plugins", isDirectory: true)
        var linked: [String] = []
        for (name, subcommand) in [("docker-compose", "compose"), ("docker-buildx", "buildx")] {
            // Don't shadow a compose/buildx the user's docker already resolves (any source).
            if let docker, pluginResolves(docker: docker, subcommand: subcommand) { continue }
            let target = binDir.appendingPathComponent(name)          // ~/.velox/bin/<name> → bundle
            guard fm.isReadableFile(atPath: target.path) else { continue }   // not bundled (dev build)
            let link = pluginDir.appendingPathComponent(name)
            // Leave any real file / valid symlink already there; only fill an empty slot or
            // replace a dangling symlink — never delete a user's plugin binary.
            if fm.fileExists(atPath: link.path) { continue }          // follows symlinks → false if dangling
            try? fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: link)                              // clears a dangling symlink, if any
            if (try? fm.createSymbolicLink(at: link, withDestinationURL: target)) != nil {
                linked.append(subcommand)
            }
        }
        return linked
    }

    /// Whether `<docker> <subcommand> version` succeeds — i.e. the CLI plugin is already
    /// installed and discoverable. Local (prints the plugin's own version), needs no engine.
    private static func pluginResolves(docker: String, subcommand: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: docker)
        p.arguments = [subcommand, "version"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
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
            let exists = FileManager.default.fileExists(atPath: rc.path)
            // Read as bytes, not as a UTF-8 String. A profile containing any non-UTF-8 byte
            // (latin-1 accents are common) decoded to nil, `?? ""` turned that into an empty
            // file, and the atomic write below then REPLACED the user's entire profile with
            // just our block. If we can't read an existing file, leave it completely alone.
            guard let data = exists ? try? Data(contentsOf: rc) : Data() else { continue }
            if data.range(of: Data(marker.utf8)) != nil { continue }
            // Append in place rather than writing a new file: `write(atomically:)` swaps the
            // inode, which silently detaches a symlinked `~/.zshrc` (dotfiles repos) — the
            // user keeps editing the repo copy while zsh reads our orphan.
            if exists, let fh = try? FileHandle(forWritingTo: rc) {
                defer { try? fh.close() }
                guard (try? fh.seekToEnd()) != nil,
                      (try? fh.write(contentsOf: Data(block.utf8))) != nil else { continue }
                wrote = true
            } else if !exists,
                      (try? Data(block.utf8).write(to: rc, options: .withoutOverwriting)) != nil {
                wrote = true
            }
        }
        return wrote
    }
}
