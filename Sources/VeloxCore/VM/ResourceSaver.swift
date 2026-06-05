import Foundation

/// Docker Desktop-style **Resource Saver**: when no containers have been running
/// for a configured idle period, reclaim guest RAM by inflating the virtio memory
/// balloon down to a floor; restore full memory as soon as a container starts
/// again. The VM keeps running throughout (an idle guest already uses ~no CPU),
/// so dockerd stays responsive and exit is automatic.
///
/// Polls the Docker API for the running-container count. Polling (rather than the
/// event stream) matches `DockerEventsWatcher` and is robust to the daemon coming
/// and going; the poll interval is short relative to the minutes-scale threshold.
public final class ResourceSaver: @unchecked Sendable {
    private let manager: VMManager
    private let socketPath: String
    private let fullMemoryBytes: UInt64
    private let floorBytes: UInt64
    private let idleThreshold: TimeInterval
    private let queue = DispatchQueue(label: "dev.velox.resourcesaver")
    private static let pollInterval: TimeInterval = 10

    private var timer: DispatchSourceTimer?
    private var zeroRunningSince: Date?
    private var saving = false

    /// - Parameters:
    ///   - fullMemoryBytes: the configured (boot) memory size to restore on exit.
    ///   - floorBytes: the memory ceiling to hold while saving.
    ///   - idleMinutes: minutes with zero running containers before saving kicks in.
    public init(manager: VMManager, socketPath: String,
                fullMemoryBytes: UInt64, floorBytes: UInt64, idleMinutes: Int) {
        self.manager = manager
        self.socketPath = socketPath
        self.fullMemoryBytes = fullMemoryBytes
        self.floorBytes = min(floorBytes, fullMemoryBytes)
        self.idleThreshold = TimeInterval(max(0, idleMinutes) * 60)
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    /// Stop polling and, if currently saving, restore full memory so a later
    /// engine restart (or a different saver config) starts from a clean ceiling.
    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            if self.saving { self.exitSaver() }
        }
    }

    // MARK: - private (all on `queue`)

    private func poll() {
        // nil = daemon not reachable; leave the current mode untouched.
        guard let running = DockerAPI.runningContainerCount(socketPath: socketPath) else { return }
        if running > 0 {
            zeroRunningSince = nil
            if saving { exitSaver() }
            return
        }
        if zeroRunningSince == nil { zeroRunningSince = Date() }
        if !saving, let since = zeroRunningSince,
           Date().timeIntervalSince(since) >= idleThreshold {
            enterSaver()
        }
    }

    private func enterSaver() {
        saving = true
        manager.setMemoryTarget(floorBytes)
        Log.info("resource saver: idle — reclaiming memory to \(floorBytes / (1024 * 1024)) MiB")
    }

    private func exitSaver() {
        saving = false
        manager.setMemoryTarget(fullMemoryBytes)
        Log.info("resource saver: container started — restoring full memory")
    }
}
