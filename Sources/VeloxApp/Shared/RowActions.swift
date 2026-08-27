import AppKit
import VeloxCore

/// Row affordances that terminate in the user's world — browser, terminal,
/// clipboard — instead of in-app re-implementations.
///
/// (Named for what it does, not for `NSWorkspace`, which is merely how it does it. The old
/// name collided with the Workspaces feature — a workspace is an isolated engine state — and
/// two unrelated meanings of the same word in one module is one too many.)
///
/// (Named for what it does, not for `NSWorkspace`, which is merely how it does it. The old
/// name collided with the Workspaces feature — a workspace is an isolated engine state — and
/// two unrelated meanings of the same word in one module is one too many.) The lean answer to Docker
/// Desktop's embedded everything: a published port opens in the default browser, a
/// shell opens in the user's own Terminal (their fonts, their profile, their PATH),
/// and everything else is a copy away.
@MainActor
enum RowActions {
    /// Open a published port in the default browser (`http://localhost:<port>`).
    /// Plain http on purpose: TLS-fronted containers redirect themselves, and a
    /// non-HTTP port just produces a connection error tab — harmless and obvious.
    static func openPort(_ port: Int) {
        if let url = URL(string: "http://localhost:\(port)/") { NSWorkspace.shared.open(url) }
    }

    /// Open a named-access domain (`http://<name>.velox.local/`).
    static func openDomain(_ domain: String) {
        if let url = URL(string: "http://\(domain)/") { NSWorkspace.shared.open(url) }
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Open the user's Terminal with an interactive shell inside the container —
    /// `docker --context velox exec` in their own terminal, profile and PATH intact
    /// (the first-run setup put `docker` on PATH). bash when the image has it,
    /// else sh. No embedded PTY: delegating to the real terminal IS the feature.
    static func openShell(containerID: String) {
        let exec = "docker --context velox exec -it \(containerID) sh -c 'command -v bash >/dev/null && exec bash || exec sh'"
        let script = """
        tell application "Terminal"
            activate
            do script "\(exec)"
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    // MARK: - VS Code

    /// Whether anything handles the `vscode:` scheme (VS Code or a fork) — gates the
    /// menu item so it never dead-ends. Checked once.
    static let vsCodeAvailable: Bool = {
        guard let probe = URL(string: "vscode://") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }()

    /// Attach VS Code to a running container via the Dev Containers URI scheme
    /// (`vscode://vscode-remote/attached-container+<hex(name)>/`). Same one-line
    /// hand-off Docker Desktop and OrbStack use.
    static func openInVSCode(containerName: String) {
        let hex = containerName.utf8.map { String(format: "%02x", $0) }.joined()
        if let url = URL(string: "vscode://vscode-remote/attached-container+\(hex)/") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - docker CLI hand-offs (volume tar transfer, image load)

    /// The `docker` client Velox guarantees exists: the first-run symlink in
    /// `~/.velox/bin` (which points into the app bundle when installed). PATH isn't
    /// available to a GUI process, so resolve explicitly.
    private static var dockerCLI: URL? {
        let candidates = [
            Paths.root.appendingPathComponent("bin/docker"),
            Bundle.main.resourceURL?.appendingPathComponent("bin/docker"),
            URL(fileURLWithPath: "/usr/local/bin/docker"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Run the docker CLI against the velox context with optional stdin/stdout file
    /// redirection, off the main thread; completion (on main) gets nil on success or
    /// a short failure description. The lean transfer path: tar streams flow directly
    /// between the engine and the file — nothing buffers in the app.
    private static func runDocker(_ args: [String], stdin: URL? = nil, stdout: URL? = nil,
                                  completion: @escaping @MainActor (String?) -> Void) {
        guard let cli = dockerCLI else {
            completion("docker CLI not found — run the app once to install it"); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = cli
            p.arguments = ["--context", "velox"] + args
            let errPipe = Pipe()
            p.standardError = errPipe
            do {
                if let stdin { p.standardInput = try FileHandle(forReadingFrom: stdin) }
                if let stdout {
                    FileManager.default.createFile(atPath: stdout.path, contents: nil)
                    p.standardOutput = try FileHandle(forWritingTo: stdout)
                }
                try p.run()
                p.waitUntilExit()
                let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let failure = p.terminationStatus == 0
                    ? nil : (err.isEmpty ? "exit \(p.terminationStatus)" : err)
                Task { @MainActor in completion(failure) }
            } catch {
                Task { @MainActor in completion(error.localizedDescription) }
            }
        }
    }

    /// Export a volume's contents as a tar at `destination` (a `docker run … tar cf -`
    /// stream; alpine auto-pulls if missing).
    static func exportVolume(_ name: String, to destination: URL,
                             completion: @escaping @MainActor (String?) -> Void) {
        runDocker(["run", "--rm", "-v", "\(name):/v", "alpine", "tar", "cf", "-", "-C", "/v", "."],
                  stdout: destination, completion: completion)
    }

    /// Import a tar into a (new or existing) volume — create, then untar from stdin.
    static func importVolume(_ name: String, from tar: URL,
                             completion: @escaping @MainActor (String?) -> Void) {
        runDocker(["volume", "create", name]) { createError in
            if let createError { completion(createError); return }
            runDocker(["run", "--rm", "-i", "-v", "\(name):/v", "alpine", "tar", "xf", "-", "-C", "/v"],
                      stdin: tar, completion: completion)
        }
    }

    /// `docker load` an image tarball (the Images pane's drop target).
    static func loadImageTar(_ tar: URL, completion: @escaping @MainActor (String?) -> Void) {
        runDocker(["load", "-i", tar.path], completion: completion)
    }

    /// `docker run -d` an image with the minimal quick-run options (the Images pane's
    /// Run… dialog). Anything fancier belongs in the terminal.
    static func runImage(reference: String, name: String?, publishes: [String],
                         removeOnExit: Bool,
                         completion: @escaping @MainActor (String?) -> Void) {
        var args = ["run", "-d"]
        if removeOnExit { args.append("--rm") }
        if let name, !name.isEmpty { args += ["--name", name] }
        for p in publishes { args += ["-p", p] }
        args.append(reference)
        runDocker(args, completion: completion)
    }
}
