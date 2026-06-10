import Foundation

/// Reconstructs a best-effort `docker run` command from a container's inspect data —
/// the "Copy as docker run" affordance. Pure (no I/O) so the self-tests pin it.
///
/// Best-effort by nature: the inspect API can't distinguish image-provided env from
/// user-provided env (both are included, like every tool that offers this), and a
/// multi-element entrypoint has no exact CLI form (the first element becomes
/// `--entrypoint`, the rest prefix the command).
public enum DockerRunCommand {
    public static func build(from inspect: ContainerInspect) -> String {
        var parts = ["docker", "run", "-d"]
        let name = inspect.name.hasPrefix("/") ? String(inspect.name.dropFirst()) : inspect.name
        if !name.isEmpty { parts += ["--name", quote(name)] }

        // Ports, sorted by container port for deterministic output.
        if let bindings = inspect.hostConfig.portBindings {
            for (containerPort, hosts) in bindings.sorted(by: { $0.key < $1.key }) {
                let pieces = containerPort.split(separator: "/")
                let cport = pieces.first.map(String.init) ?? containerPort
                let proto = pieces.count > 1 ? String(pieces[1]) : "tcp"
                for h in hosts ?? [] {
                    guard let host = h.hostPort, !host.isEmpty else { continue }
                    parts += ["-p", proto == "tcp" ? "\(host):\(cport)" : "\(host):\(cport)/\(proto)"]
                }
            }
        }
        for bind in inspect.hostConfig.binds ?? [] { parts += ["-v", quote(bind)] }
        for env in inspect.config.env ?? [] { parts += ["-e", quote(env)] }
        if let restart = inspect.hostConfig.restartPolicy?.name, !restart.isEmpty, restart != "no" {
            parts += ["--restart", restart]
        }
        if let wd = inspect.config.workingDir, !wd.isEmpty { parts += ["-w", quote(wd)] }

        var command = inspect.config.cmd ?? []
        if let entry = inspect.config.entrypoint, let first = entry.first {
            parts += ["--entrypoint", quote(first)]
            command = Array(entry.dropFirst()) + command
        }
        parts.append(quote(inspect.config.image))
        parts += command.map(quote)
        return parts.joined(separator: " ")
    }

    /// Single-quote an argument when it contains anything a shell would interpret.
    public static func quote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:=@,")
        if !s.isEmpty && s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
