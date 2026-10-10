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
///
/// On macOS 27 the idle action is a **nap** instead of the balloon (`Mode`): the front end
/// stops the VM and keeps the Docker socket listening, and the next client boots it again
/// (`EngineNap.swift`). A nap is stricter about "idle", because it ends everything in the VM.
public final class ResourceSaver: @unchecked Sendable {
    /// What the saver does once the engine has been idle long enough.
    public enum Mode: String, Sendable {
        /// Inflate the memory balloon to a floor; the VM keeps running.
        case balloon
        /// Stop the VM, keep the Docker socket; the next client wakes it (~0.45 s cold boot).
        case nap
    }

    /// The mode for this OS release.
    ///
    /// **macOS 27: the balloon returns nothing.** Virtualization.framework backs guest RAM with
    /// shared-memory regions (64 × 128 MiB, `SM=SHM` in vmmap), and an inflated
    /// `VZVirtioTraditionalMemoryBalloonDevice` frees none of it on the host: measured 7 GiB
    /// ballooned (`nr_balloon_pages` 1,835,008) with the VM process unchanged at 3.7 GB RSS and
    /// 0 reclaimable, across deflate/re-inflate cycles, compaction, minutes of hold and a
    /// simulated memory-pressure notification. On macOS 26.6 the same code took idle RSS
    /// 734 → 373 MB. So on 27 the saver naps instead — which returns all of it.
    /// `VELOX_RESOURCE_SAVER_MODE=balloon|nap` overrides, to re-test either on any release.
    public static var modeForThisOS: Mode {
        if let raw = ProcessInfo.processInfo.environment["VELOX_RESOURCE_SAVER_MODE"],
           let mode = Mode(rawValue: raw) { return mode }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 ? .nap : .balloon
    }

    /// A container dockerd would START when it boots, although it is not running now. A nap
    /// ends in a fresh dockerd, so napping with one of these would resurrect it on wake — a
    /// container the user stopped with `docker stop` coming back by itself.
    ///
    /// Mirrors moby's `RestartManager.ShouldRestart`: `always` restarts regardless of a manual
    /// stop; `on-failure` restarts a non-zero exit (a fresh daemon starts its retry count at 0).
    /// `unless-stopped` does not restart a container that is stopped — it was stopped by hand,
    /// or its restart manager would still be running it.
    public static func dockerdWouldRestart(policy: String?, exitCode: Int?) -> Bool {
        switch policy {
        case "always": return true
        case "on-failure": return (exitCode ?? 0) != 0
        default: return false
        }
    }

    /// Container states that hold live processes in the VM. A paused container is frozen in
    /// guest RAM and would be killed by a nap; `restarting` is a restart policy at work.
    public static func isActive(state: String) -> Bool {
        !["exited", "created", "dead"].contains(state)
    }

    private let manager: VMManager
    private let docker: any DockerClientProtocol
    private let fullMemoryBytes: UInt64
    private let floorBytes: UInt64
    private let idleThreshold: TimeInterval
    private let queue = DispatchQueue(label: "dev.velox.resourcesaver")

    private let mode: Mode
    private let activity: ActivityCounter?
    private var task: Task<Void, Never>?
    private var coalescer: Coalescer?
    private var idleTimer: DispatchSourceTimer?
    private var saving = false
    // Nap mode only (all on `queue`): the last container verdict, whether Docker-API work is in
    // flight, and whether the nap already fired (it fires once — the front end then stops us).
    private var lastRunning = -1
    private var apiBusy = false
    private var napFired = false
    private var napCheck: Task<Void, Never>?
    /// Bumped by everything that breaks the quiet; a confirmation commits only if it is unchanged.
    private var napGen: UInt64 = 0
    /// True while `confirmNap` runs. Its own requests flip the activity counter too, and must
    /// not count as activity — or every confirmation would cancel itself.
    private var confirming = false
    private let vetoLogged = Locked<Set<String>>([])

    /// Nap mode: the engine has been idle for the whole threshold — nothing running, nothing
    /// connected, no Docker events, and no stopped container dockerd would restart. The front
    /// end performs the nap (it owns the engine lifecycle). Fires at most once per saver.
    public var onNap: (@Sendable () -> Void)?

    /// Fired whenever saver mode toggles — `true` when the balloon is inflated to
    /// reclaim idle RAM, `false` when full memory is restored. Invoked on an
    /// internal queue, so hop to your own actor inside. The GUI uses it to badge
    /// the menu-bar icon with a moon while idle.
    public var onStateChange: (@Sendable (Bool) -> Void)?

    /// - Parameters:
    ///   - fullMemoryBytes: the configured (boot) memory size to restore on exit.
    ///   - floorBytes: the memory ceiling to hold while saving.
    ///   - idleMinutes: minutes with zero running containers before saving kicks in.
    ///   - mode: `.balloon` or `.nap` — normally `ResourceSaver.modeForThisOS`.
    ///   - activity: in-flight Docker-API work (`EngineRuntime.activity`); nap mode never
    ///     counts down while it is busy.
    public init(manager: VMManager, docker: any DockerClientProtocol,
                fullMemoryBytes: UInt64, floorBytes: UInt64, idleMinutes: Int,
                mode: Mode = .balloon, activity: ActivityCounter? = nil) {
        self.manager = manager
        self.docker = docker
        self.fullMemoryBytes = fullMemoryBytes
        self.floorBytes = min(floorBytes, fullMemoryBytes)
        self.idleThreshold = TimeInterval(max(0, idleMinutes) * 60)
        self.mode = mode
        self.activity = activity
    }

    private let seqLock = NSLock()
    private var evaluateSeq: UInt64 = 0
    private var committedSeq: UInt64 = 0

    public func start() {
        // Coalesce so a healthcheck / compose storm collapses to one container-count
        // read instead of a full `containers()` fetch per event (CLAUDE.md §8).
        let coalescer = Coalescer { [weak self] in await self?.evaluate() }
        self.coalescer = coalescer
        if mode == .nap, let activity {
            activity.setOnChange { [weak self] busy in
                guard let saver = self else { return }
                saver.queue.async {
                    saver.apiBusy = busy
                    if !saver.confirming { saver.rearmNapCountdown() }
                }
            }
            let busy = activity.isBusy
            queue.async { self.apiBusy = busy }
        }
        task = Task { [weak self] in
            var backoff = ReconnectBackoff()
            while !Task.isCancelled {
                guard let self else { return }
                backoff.passBegan()
                await self.evaluate()                       // current state on (re)connect
                for await event in self.docker.events() {
                    if Task.isCancelled { return }
                    if event.type == nil || event.type == "container" { coalescer.trigger() }
                    // A nap waits for the engine to be QUIET, not just container-free: an image
                    // pull, a volume or network change, a build — any event restarts the wait.
                    if self.mode == .nap { self.queue.async { self.rearmNapCountdown() } }
                }
                if Task.isCancelled { return }
                try? await Task.sleep(for: backoff.delayAfterPass())   // back off, reconnect
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
        activity?.setOnChange(nil)
        queue.async {
            self.idleTimer?.cancel()
            self.idleTimer = nil
            self.napCheck?.cancel()
            self.napCheck = nil
            self.napFired = true   // a stopped saver never naps
            if self.saving { self.exitSaver() }
        }
    }

    /// Read the running-container count, then apply on `queue`.
    ///
    /// Serialized by `evaluateSeq`, not just by the coalescer: `Coalescer` clears its pending
    /// slot *before* running the action, and the on-(re)connect `evaluate()` runs from a
    /// different Task entirely, so two reads overlap whenever `containers()` takes longer than
    /// the coalescing delay — routine over VSOCK during a `compose up`. The `queue.async` hop
    /// then commits by *completion* order, so a stale `running: 0` could land last while a
    /// container is actually running, arm the idle countdown, and inflate the balloon out from
    /// under a live workload. Same hazard `DockerEventsWatcher` solves with `reconcileLock`.
    private func evaluate() async {
        let seq = nextEvaluateSeq()
        // nil = daemon not reachable; leave the current mode untouched.
        guard let containers = try? await docker.containers() else { return }
        // Nap mode counts paused/restarting containers too: they live in the VM.
        let running = mode == .nap
            ? containers.lazy.filter { Self.isActive(state: $0.state) }.count
            : containers.lazy.filter { $0.state == "running" }.count
        queue.async { [weak self] in
            guard let self, self.commitEvaluate(seq) else { return }   // a newer read won
            self.apply(running: running)
        }
    }

    /// Monotonic ticket for each `evaluate()` read. Synchronous helpers so the lock is never
    /// held across an `await`.
    private func nextEvaluateSeq() -> UInt64 {
        seqLock.lock(); defer { seqLock.unlock() }
        evaluateSeq &+= 1
        return evaluateSeq
    }

    /// True if `seq` is still the newest read to have been issued — i.e. this result is not
    /// stale. Also records it so an older in-flight read can't win later.
    private func commitEvaluate(_ seq: UInt64) -> Bool {
        seqLock.lock(); defer { seqLock.unlock() }
        guard seq > committedSeq else { return false }
        committedSeq = seq
        return true
    }

    // MARK: - private (all on `queue`)

    private func apply(running: Int) {
        if mode == .nap { lastRunning = running; rearmNapCountdown(); return }
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

    // MARK: - nap (all on `queue`)

    /// (Re)start the nap countdown from zero if the engine is idle right now, or cancel it if
    /// not. Every activity edge and every Docker event comes through here, so the countdown
    /// measures an unbroken quiet stretch.
    private func rearmNapCountdown() {
        guard mode == .nap, !napFired else { return }
        napGen &+= 1
        idleTimer?.cancel(); idleTimer = nil
        guard lastRunning == 0, !apiBusy else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + max(idleThreshold, 1))
        t.setEventHandler { [weak self] in
            guard let self, !self.napFired, !self.confirming else { return }
            self.idleTimer = nil
            self.confirming = true
            let gen = self.napGen
            self.napCheck = Task { await self.confirmNap(gen) }
        }
        t.resume()
        idleTimer = t
    }

    /// The countdown ran out: confirm from a fresh list (never a cached verdict) that nothing
    /// is active and nothing would be resurrected by a fresh dockerd, then nap — unless anything
    /// broke the quiet while this ran (`gen`). A veto or an unreachable daemon waits for the next
    /// event to re-arm; nothing retries on a timer.
    private func confirmNap(_ gen: UInt64) async {
        let verdict = await napVerdict()
        queue.async { [weak self] in
            guard let self else { return }
            self.confirming = false
            guard verdict, gen == self.napGen, !self.napFired,
                  self.lastRunning == 0, !self.apiBusy else { return }
            self.napFired = true
            Log.info("resource saver: idle for \(Int(self.idleThreshold / 60)) min — stopping the engine")
            self.onNap?()
        }
    }

    private func napVerdict() async -> Bool {
        guard let containers = try? await docker.containers(),
              !containers.contains(where: { Self.isActive(state: $0.state) }) else { return false }
        for c in containers {
            guard !Task.isCancelled, let info = try? await docker.inspectContainer(c.id) else { return false }
            let policy = info.hostConfig.restartPolicy?.name
            if Self.dockerdWouldRestart(policy: policy, exitCode: info.state?.exitCode) {
                if vetoLogged.withLock({ $0.insert(c.id).inserted }) {
                    Log.info("resource saver: engine kept running — \(c.displayName) has restart "
                             + "policy \(policy ?? "?") and would restart with the engine")
                }
                return false
            }
        }
        return true
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
