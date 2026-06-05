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
    private let onPorts: @Sendable (Set<UInt16>, Set<UInt16>) -> Void
    private var task: Task<Void, Never>?
    private var lastTCP: Set<UInt16> = []
    private var lastUDP: Set<UInt16> = []

    /// `onPorts` is called with the published (tcp, udp) port sets whenever either changes.
    public init(docker: any DockerClientProtocol, onPorts: @escaping @Sendable (Set<UInt16>, Set<UInt16>) -> Void) {
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
        var tcp: Set<UInt16> = []
        var udp: Set<UInt16> = []
        for c in containers where c.state == "running" {
            for p in c.ports {
                guard let pub = p.publicPort, pub > 0, pub <= 65_535 else { continue }
                switch p.type {
                case "tcp": tcp.insert(UInt16(pub))
                case "udp": udp.insert(UInt16(pub))
                default: break
                }
            }
        }
        if tcp != lastTCP || udp != lastUDP {
            lastTCP = tcp
            lastUDP = udp
            onPorts(tcp, udp)
        }
    }
}
