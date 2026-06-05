import Foundation

/// Watches for changes to the set of published container ports and reports them.
///
/// **Push-based**, the way Docker Desktop / OrbStack do it: it consumes the Docker
/// `/events` stream and reconciles the instant a container is published — no
/// polling. Crucially it rides the *same* proven in-process client the GUI uses
/// (`DockerClient`, a single persistent VSOCK connection over `HTTPCodec`, straight
/// to the guest dockerd — bypassing the unix-socket proxy), so there is no
/// per-poll connection churn and a port is reachable in well under a second.
///
/// On every (re)connect it reconciles the full set, so a missed event or a daemon
/// restart self-heals — the event stream is the trigger, full reconciliation is the
/// source of truth (the informer pattern).
public final class DockerEventsWatcher: @unchecked Sendable {
    private let docker: any DockerClientProtocol
    private let onPorts: @Sendable (Set<UInt16>) -> Void
    private var task: Task<Void, Never>?
    private var last: Set<UInt16> = []

    public init(docker: any DockerClientProtocol, onPorts: @escaping @Sendable (Set<UInt16>) -> Void) {
        self.docker = docker
        self.onPorts = onPorts
    }

    public func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Catch the current state on (re)connect (also picks up restart-policy
                // containers that were already running).
                await self.reconcile()
                for await event in self.docker.events() {
                    if Task.isCancelled { return }
                    if event.type == nil || event.type == "container" {
                        await self.reconcile()
                    }
                }
                // Stream ended (daemon not up yet, or restarted). Back off, reconnect.
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Re-read the authoritative published-port set; report only on change. Runs
    /// serially inside the single watcher Task, so `last` needs no extra locking.
    private func reconcile() async {
        guard let containers = try? await docker.containers() else { return }
        var ports: Set<UInt16> = []
        for c in containers where c.state == "running" {
            for p in c.ports where p.type == "tcp" {
                if let pub = p.publicPort, pub > 0, pub <= 65_535 { ports.insert(UInt16(pub)) }
            }
        }
        if ports != last {
            last = ports
            onPorts(ports)
        }
    }
}
