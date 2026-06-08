import Foundation

/// Docker Desktop-style **Resource Saver**: when no containers have been running
/// for a configured idle period, reclaim guest RAM by inflating the virtio memory
/// balloon down to a floor; restore full memory the instant a container starts
/// again. The VM keeps running throughout (an idle guest already uses ~no CPU), so
/// dockerd stays responsive and recovery is automatic.
///
/// **Event-driven**, not polled: it rides the Docker `/events` stream (the same
/// in-process VSOCK client the GUI uses) to learn the running-container count the
/// moment it changes. The only timer is the idle *countdown* — an inherent delay
/// (you must wait the threshold), armed when the count hits zero and cancelled the
/// instant a container starts — not a status poll.
public final class ResourceSaver: @unchecked Sendable {
    private let manager: VMManager
    private let docker: any DockerClientProtocol
    private let fullMemoryBytes: UInt64
    private let floorBytes: UInt64
    private let idleThreshold: TimeInterval
    private let queue = DispatchQueue(label: "dev.velox.resourcesaver")

    private var task: Task<Void, Never>?
    private var coalescer: Coalescer?
    private var idleTimer: DispatchSourceTimer?
    private var saving = false

    /// Fired whenever saver mode toggles — `true` when the balloon is inflated to
    /// reclaim idle RAM, `false` when full memory is restored. Invoked on an
    /// internal queue, so hop to your own actor inside. The GUI uses it to badge
    /// the menu-bar icon with a moon while idle.
    public var onStateChange: (@Sendable (Bool) -> Void)?

    /// - Parameters:
    ///   - fullMemoryBytes: the configured (boot) memory size to restore on exit.
    ///   - floorBytes: the memory ceiling to hold while saving.
    ///   - idleMinutes: minutes with zero running containers before saving kicks in.
    public init(manager: VMManager, docker: any DockerClientProtocol,
                fullMemoryBytes: UInt64, floorBytes: UInt64, idleMinutes: Int) {
        self.manager = manager
        self.docker = docker
        self.fullMemoryBytes = fullMemoryBytes
        self.floorBytes = min(floorBytes, fullMemoryBytes)
        self.idleThreshold = TimeInterval(max(0, idleMinutes) * 60)
    }

    public func start() {
        // Coalesce so a healthcheck / compose storm collapses to one container-count
        // read instead of a full `containers()` fetch per event (CLAUDE.md §8).
        let coalescer = Coalescer { [weak self] in await self?.evaluate() }
        self.coalescer = coalescer
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.evaluate()                       // current state on (re)connect
                for await event in self.docker.events() {
                    if Task.isCancelled { return }
                    if event.type == nil || event.type == "container" { coalescer.trigger() }
                }
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(1))      // back off, reconnect
            }
        }
    }

    /// Stop watching and, if currently saving, restore full memory so a later
    /// engine restart (or a different saver config) starts from a clean ceiling.
    public func stop() {
        coalescer?.cancel()
        coalescer = nil
        task?.cancel()
        task = nil
        queue.async {
            self.idleTimer?.cancel()
            self.idleTimer = nil
            if self.saving { self.exitSaver() }
        }
    }

    /// Read the running-container count, then apply on `queue`.
    private func evaluate() async {
        // nil = daemon not reachable; leave the current mode untouched.
        guard let containers = try? await docker.containers() else { return }
        let running = containers.lazy.filter { $0.state == "running" }.count
        queue.async { [weak self] in self?.apply(running: running) }
    }

    // MARK: - private (all on `queue`)

    private func apply(running: Int) {
        if running > 0 {
            idleTimer?.cancel(); idleTimer = nil
            if saving { exitSaver() }
            return
        }
        // Zero running: arm the idle countdown (a one-shot delay) if not already.
        guard !saving, idleTimer == nil else { return }
        if idleThreshold <= 0 { enterSaver(); return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + idleThreshold)
        t.setEventHandler { [weak self] in
            self?.idleTimer = nil
            self?.enterSaver()
        }
        t.resume()
        idleTimer = t
    }

    private func enterSaver() {
        guard !saving else { return }
        saving = true
        manager.setMemoryTarget(floorBytes)
        onStateChange?(true)
        Log.info("resource saver: idle — reclaiming memory to \(floorBytes / (1024 * 1024)) MiB")
    }

    private func exitSaver() {
        guard saving else { return }
        saving = false
        manager.setMemoryTarget(fullMemoryBytes)
        onStateChange?(false)
        Log.info("resource saver: container started — restoring full memory")
    }
}
