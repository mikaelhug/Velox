import AppKit
import SwiftUI
import VeloxCore

/// Which daemon a row action should terminate at.
///
/// The local engine is reached through the `velox` docker context; a remote host is
/// reached through the unix socket its `SSHTunnel` forwards, which the docker CLI accepts
/// directly as `-H unix://…`. That one substitution is why volume export/import, `docker
/// load` and quick-run work against a remote host with no separate implementation.
enum DockerTarget: Equatable {
    case local
    case remote(id: String, socket: URL, user: String, hostname: String, port: Int)

    /// The CLI arguments that point `docker` at this daemon.
    var dockerArguments: [String] {
        switch self {
        case .local:
            return ["--context", "velox"]
        case .remote(_, let socket, _, _, _):
            return ["-H", "unix://\(socket.path)"]
        }
    }

    /// Host part of a published port's URL. A remote container's port is published on the
    /// server's own interface, not on this Mac.
    var portHost: String {
        switch self {
        case .local:                         return "localhost"
        // Bracketed when it is an IPv6 literal, or the address's own colons collide with
        // the URL's port separator.
        case .remote(_, _, _, let host, _):  return RemoteHost.urlHost(host)
        }
    }

    var isRemote: Bool { self != .local }

    /// Title for a destructive confirmation, naming the machine when it isn't this Mac.
    /// Prune dialogs are byte-identical across engines, so the title is the only thing that
    /// can say which one is about to lose data.
    func pruneTitle(_ action: String) -> String {
        switch self {
        case .local:                         return "\(action)?"
        case .remote(_, _, _, let host, _):  return "\(action) on \(host)?"
        }
    }

    /// Wrap a `docker` subcommand (already quoted for one shell) into a command the user can
    /// paste, aimed at THIS daemon.
    ///
    /// The remote form is an `ssh` command rather than `-H unix://<tunnel socket>`: that
    /// socket only exists while Velox is running and holding the SSH child, so a command
    /// built around it dies the moment the user quits. Same reasoning as `openShell`.
    ///
    /// **And it quotes a second time.** ssh joins its remote-command arguments with spaces
    /// and hands the result to the shell on the server, which re-parses it — so a body
    /// quoted once arrives unquoted. Without this, a container carrying
    /// `-e 'FOO=$(...)'` in its inspect data executes that substitution **on the server**
    /// the moment the user pastes the copied command. Container metadata comes from the
    /// daemon, which is exactly the machine we do not trust.
    func pasteableCommand(_ subcommand: String) -> String {
        switch self {
        case .local:
            return "docker --context velox \(subcommand)"
        case .remote(_, _, let user, let hostname, let port):
            // The second quoting level lives in `sshCommand`, so it cannot be forgotten here.
            return SSHTunnel.sshCommand(running: "docker \(subcommand)",
                                        user: user, hostname: hostname, port: port)
        }
    }

    /// `RemoteHost.id` when this is a remote target — used to key a logs window back to
    /// the session that can serve it.
    var remoteID: String? {
        if case .remote(let id, _, _, _, _) = self { return id }
        return nil
    }
}

/// Row affordances that terminate in the user's world — browser, terminal, clipboard —
/// instead of in-app re-implementations. The lean answer to Docker Desktop's embedded
/// everything: a published port opens in the default browser, a shell opens in the user's
/// own Terminal (their fonts, their profile, their PATH), and everything else is a copy away.
///
/// (Named for what it does, not for `NSWorkspace`, which is merely how it does it. The old
/// name collided with the Workspaces feature — a workspace is an isolated engine state — and
/// two unrelated meanings of the same word in one module is one too many.)
@MainActor
enum RowActions {
    /// Open a published port in the default browser (`http://localhost:<port>`).
    /// Plain http on purpose: TLS-fronted containers redirect themselves, and a
    /// non-HTTP port just produces a connection error tab — harmless and obvious.
    static func openPort(_ port: Int, target: DockerTarget = .local) {
        if let url = URL(string: "http://\(target.portHost):\(port)/") { NSWorkspace.shared.open(url) }
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
    static func openShell(containerID: String, target: DockerTarget = .local) {
        switch target {
        case .local:
            // Quoted for the same reason as the remote branch: the id comes from the
            // daemon, not from us.
            let script = "command -v bash >/dev/null && exec bash || exec sh"
            runInTerminal("docker --context velox exec -it "
                          + "\(SSHTunnel.shellQuoted(containerID)) sh -c \(SSHTunnel.shellQuoted(script))")
        case .remote(_, _, let user, let hostname, let port):
            // Deliberately a fresh `ssh -t` rather than `docker -H unix://<our socket>`:
            // the Terminal window then outlives Velox. Routing it through the app's own
            // tunnel would kill the user's shell the moment they quit Velox.
            // The command itself is built in `SSHTunnel` — its quoting is subtle enough to
            // deserve tests, which only reach VeloxCore.
            runInTerminal(SSHTunnel.terminalShellCommand(containerID: containerID, user: user,
                                                         hostname: hostname, port: port))
        }
    }

    /// Open a plain interactive SSH session to a remote host in Terminal.
    static func openSSH(user: String, hostname: String, port: Int) {
        runInTerminal(SSHTunnel.terminalLoginCommand(user: user, hostname: hostname, port: port))
    }

    /// Hand a command to the user's own Terminal — their fonts, profile and PATH intact.
    /// No embedded PTY: delegating to the real terminal IS the feature.
    private static func runInTerminal(_ command: String) {
        // The command is interpolated into an AppleScript string literal, so a quote or
        // backslash in it would break out of that literal. Every caller builds the command
        // from validated fields, but escape anyway rather than rely on that staying true.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let errors = Pipe()
        p.standardError = errors
        do { try p.run() } catch {
            Log.warn("terminal hand-off: couldn't run osascript: \(error.localizedDescription)")
            return
        }
        // Report a refusal rather than silently doing nothing. osascript fails to compile if
        // the command ever contains a newline, which validation now prevents — but a silent
        // dead button is the worst way to find out that changed.
        DispatchQueue.global(qos: .utility).async {
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                              as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                Log.warn("terminal hand-off failed (osascript \(p.terminationStatus)): \(text)")
            }
        }
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
    private static func runDocker(_ args: [String], target: DockerTarget = .local,
                                  stdin: URL? = nil, stdout: URL? = nil,
                                  completion: @escaping @MainActor (String?) -> Void) {
        guard let cli = dockerCLI else {
            completion("docker CLI not found — run the app once to install it"); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = cli
            p.arguments = target.dockerArguments + args
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
    static func exportVolume(_ name: String, to destination: URL, target: DockerTarget = .local,
                             completion: @escaping @MainActor (String?) -> Void) {
        runDocker(["run", "--rm", "-v", "\(name):/v", "alpine", "tar", "cf", "-", "-C", "/v", "."],
                  target: target, stdout: destination, completion: completion)
    }

    /// Import a tar into a (new or existing) volume — create, then untar from stdin.
    static func importVolume(_ name: String, from tar: URL, target: DockerTarget = .local,
                             completion: @escaping @MainActor (String?) -> Void) {
        runDocker(["volume", "create", name], target: target) { createError in
            if let createError { completion(createError); return }
            runDocker(["run", "--rm", "-i", "-v", "\(name):/v", "alpine", "tar", "xf", "-", "-C", "/v"],
                      target: target, stdin: tar, completion: completion)
        }
    }

    /// `docker load` an image tarball (the Images pane's drop target).
    static func loadImageTar(_ tar: URL, target: DockerTarget = .local,
                             completion: @escaping @MainActor (String?) -> Void) {
        runDocker(["load", "-i", tar.path], target: target, completion: completion)
    }

    /// `docker run -d` an image with the minimal quick-run options (the Images pane's
    /// Run… dialog). Anything fancier belongs in the terminal.
    static func runImage(reference: String, name: String?, publishes: [String],
                         removeOnExit: Bool, target: DockerTarget = .local,
                         completion: @escaping @MainActor (String?) -> Void) {
        var args = ["run", "-d"]
        if removeOnExit { args.append("--rm") }
        if let name, !name.isEmpty { args += ["--name", name] }
        for p in publishes { args += ["-p", p] }
        args.append(reference)
        runDocker(args, target: target, completion: completion)
    }
}

// MARK: - Environment

/// The daemon the current detail pane is showing, propagated through the view tree.
///
/// Row affordances live several view types deep (a port menu inside a row inside a table
/// inside the pane), and they are the only things that need to know which daemon they act
/// on. Threading a `DockerTarget` through every one of those initialisers would touch far
/// more code than it clarifies; the environment carries it to exactly the leaves that read
/// it. `RootView` sets it once on the detail pane.
private struct DockerTargetKey: EnvironmentKey {
    static let defaultValue = DockerTarget.local
}

extension EnvironmentValues {
    var dockerTarget: DockerTarget {
        get { self[DockerTargetKey.self] }
        set { self[DockerTargetKey.self] = newValue }
    }
}
