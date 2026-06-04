import Foundation

/// Which client CLIs to wire up to the Velox engine on `velox start`.
enum BindMode: String {
    case vlcmd   // user socket only; talk to it via the `vlcmd` wrapper
    case docker  // bind the standard `docker` CLI via a Docker context
    case both    // both of the above
}

/// Wires client CLIs to the engine socket. `docker` binding uses a Docker
/// *context* (no root, no /var/run conflict with Docker Desktop) — the same
/// approach Colima takes — and is reverted when the engine stops.
enum CLIBinding {
    /// Apply the binding and return a teardown closure to run on stop.
    static func apply(_ mode: BindMode, socketPath: String) -> () -> Void {
        switch mode {
        case .vlcmd:
            Log.info("engine ready — use `vlcmd` (e.g. `vlcmd ps`).  [bind: vlcmd]")
            return {}
        case .docker, .both:
            let teardown = bindDockerContext(socketPath: socketPath)
            if mode == .both {
                Log.info("engine ready — use `vlcmd` OR `docker` (both target Velox).  [bind: both]")
            }
            return teardown
        }
    }

    private static func bindDockerContext(socketPath: String) -> () -> Void {
        guard which("docker") != nil else {
            Log.warn("`docker` CLI not found — falling back to `vlcmd` only.")
            return {}
        }
        let host = "unix://\(socketPath)"
        let previous = output(["docker", "context", "show"]) ?? "default"

        if run(["docker", "context", "create", "velox",
                "--docker", "host=\(host)", "--description", "Velox engine"]) != 0 {
            _ = run(["docker", "context", "update", "velox", "--docker", "host=\(host)"])
        }
        _ = run(["docker", "context", "use", "velox"])
        Log.info("`docker` bound to Velox (context 'velox'); will restore '\(previous)' on stop.")

        return {
            if previous != "velox" {
                _ = run(["docker", "context", "use", previous])
            }
        }
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
}
