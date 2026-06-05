import Foundation

/// How `velox start` wires the standard `docker` CLI to the engine.
public enum BindMode: String, Sendable {
    /// Default: ensure the `velox` Docker *context* exists, but leave the active
    /// context untouched. Use it with `docker context use velox` or `--context velox`.
    case none
    /// Also switch the active Docker context to `velox` (restored when the engine
    /// stops), so a plain `docker ps` targets Velox while it's running.
    case docker
}

/// Velox is just a standard Docker engine on a unix socket, so the native way to
/// reach it is a Docker **context** — exactly how Docker Desktop binds its own CLI
/// (the `desktop-linux` context). We create/maintain a `velox` context pointing at
/// the engine socket; switching to it is opt-in (`--bind docker`) so we never
/// hijack an existing Docker Desktop session.
public enum CLIBinding {
    /// Apply the binding and return a teardown closure to run on stop.
    public static func apply(_ mode: BindMode, socketPath: String) -> () -> Void {
        let host = "unix://\(socketPath)"
        guard let docker = dockerPath() else {
            Log.warn("`docker` CLI not found — install it (e.g. `brew install docker`) to use Velox from the terminal.")
            return {}
        }
        ensureVeloxContext(host: host)

        switch mode {
        case .none:
            Log.info("engine ready — run `docker context use velox` (or `export DOCKER_HOST=\(host)`) to point docker at Velox.")
            return {}
        case .docker:
            let previous = output([docker, "context", "show"]) ?? "default"
            _ = run([docker, "context", "use", "velox"])
            Log.info("`docker` now targets Velox (context 'velox'); restoring '\(previous)' on stop.")
            return {
                if previous != "velox" { _ = run([docker, "context", "use", previous]) }
            }
        }
    }

    /// Create (or update) the `velox` context pointing at the engine socket.
    private static func ensureVeloxContext(host: String) {
        guard let docker = dockerPath() else { return }
        if run([docker, "context", "create", "velox",
                "--docker", "host=\(host)", "--description", "Velox engine"]) != 0 {
            _ = run([docker, "context", "update", "velox", "--docker", "host=\(host)"])
        }
    }

    // MARK: - GUI helpers
    //
    // The CLI wires the context in `apply()`; the in-process GUI engine isn't a
    // `velox start`, so it calls these directly to register the context and offer
    // to make it active. All three are blocking (they shell out to `docker`) —
    // call them off the main thread.

    /// True if the `docker` CLI is installed (a prerequisite for any context op).
    public static var dockerCLIAvailable: Bool { dockerPath() != nil }

    /// Ensure the `velox` context exists, pointing at the engine socket. No-op
    /// (returns false) if the `docker` CLI isn't installed.
    @discardableResult
    public static func ensureContext(socketPath: String) -> Bool {
        guard dockerPath() != nil else { return false }
        ensureVeloxContext(host: "unix://\(socketPath)")
        return true
    }

    /// The active Docker context name (`docker context show`), or nil if the
    /// `docker` CLI isn't installed.
    public static func activeContext() -> String? {
        guard let docker = dockerPath() else { return nil }
        return output([docker, "context", "show"]) ?? "default"
    }

    /// Switch the active Docker context to `velox`. Returns true on success.
    @discardableResult
    public static func useVeloxContext() -> Bool {
        guard let docker = dockerPath() else { return false }
        return run([docker, "context", "use", "velox"]) == 0
    }

    // MARK: - Process helpers

    @discardableResult
    private static func run(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    private static func output(_ args: [String]) -> String? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    private static func which(_ cmd: String) -> String? { output(["which", cmd]) }

    /// Resolve a usable `docker` client even before the user's shell PATH is set up:
    /// the PATH first, then the rootless install (`~/.velox/bin/docker`), then the
    /// copy bundled inside `Velox.app`. This is what lets context registration work
    /// on a brand-new Mac (FirstRun symlinks the bundled client into ~/.velox/bin).
    public static func dockerPath() -> String? {
        if let p = which("docker") { return p }
        let fm = FileManager.default
        let installed = Paths.root.appendingPathComponent("bin/docker").path
        if fm.isExecutableFile(atPath: installed) { return installed }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("bin/docker").path,
           fm.isExecutableFile(atPath: res) { return res }
        if let exec = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("docker").path, fm.isExecutableFile(atPath: exec) { return exec }
        return nil
    }
}
