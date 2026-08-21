import Foundation
import Observation
import Virtualization
import VeloxCore

/// The single owner of the embedded Velox engine inside the GUI process.
///
/// Wraps `VMManager` + `DockerSocketProxy` (the same objects the `velox` CLI
/// drives) and lifts their callback API into `async`/`@Observable` state the
/// SwiftUI views bind to. This is the in-process replacement for `velox start`:
/// the app *is* the engine host, so the menu bar can boot and stop the VM
/// directly, and every dashboard talks to the guest over the same VSOCK device.
@MainActor
@Observable
final class EngineController {
    /// Current engine lifecycle, driven onto the main actor from the VM queue.
    private(set) var state: EngineState = .stopped
    /// Monotonic lifecycle token. Bumped when a start begins and whenever the engine is
    /// torn down (stop / guest-stopped). `performStart` captures it and, after each of its
    /// `await`s, bails if it changed — so a guest that dies mid-boot can't be overwritten by
    /// the resuming start writing `.running` over a dead engine.
    private var startGeneration = 0

    /// True once the VM is alive and attached to `data.img` with nothing left managing it —
    /// a stop that timed out, or a start that failed after the guest was already running.
    /// `state` cannot express this: the engine lands in `.failed`, which reads as "not
    /// running" to every guard. Anything that touches the disk or the instance lock must
    /// consult this instead. Only a relaunch clears it.
    private(set) var vmUnreachable = false

    /// True while a data-disk relocation is in flight (stop → move → restart). Gates the UI so
    /// Start/Restart/Move can't interleave; `moveProgress` (0…1) drives the move sheet.
    private(set) var isRelocatingDisk = false
    private(set) var moveProgress: Double = 0

    /// Wall-clock time the engine reached `.running`, for the Overview uptime
    /// readout. Cleared whenever the engine stops or fails.
    private(set) var startedAt: Date?

    /// True when guest artifacts or host virtualization support are missing, so
    /// the shell should present onboarding instead of arming Start.
    private(set) var needsOnboarding: Bool

    /// True while Resource Saver has reclaimed idle RAM (the memory balloon is
    /// inflated). Drives the moon badge on the menu-bar icon; cleared the instant
    /// a container starts or the engine stops.
    private(set) var isResourceSaving = false

    /// Persisted user preferences (resources, file shares, etc.). Settings bind
    /// to this; `saveConfig()` writes it back to ~/.velox/config.json.
    var config: VeloxConfig

    /// Boot signature captured at the last successful `start`, used to tell when
    /// edited settings require a restart to take effect.
    private var appliedSignature: [String]?

    /// True when the running engine's resources/shares no longer match `config`.
    var needsRestart: Bool {
        guard state.isRunning, let applied = appliedSignature else { return false }
        return applied != config.bootSignature
    }

    // Engine plumbing — created on `start`, torn down on stop. All the wiring shared
    // with the CLI (proxy, forwarders, watcher, named access, clock sync, conduit
    // pool) lives in EngineRuntime; only GUI-specific pieces stay here.
    // `manager` and the live `runtime` are reachable WITHOUT the main actor on purpose:
    // app termination has to flush and power off the guest even when the main actor is
    // busy (see `shutdownForTerminate`). Both types are already thread-safe.
    private nonisolated let manager = VMManager()
    private nonisolated let runtimeBox = Locked<EngineRuntime?>(nil)
    private var runtime: EngineRuntime? {
        get { runtimeBox.value }
        set { runtimeBox.value = newValue }
    }
    private var resourceSaver: ResourceSaver?
    /// Single-instance guard: acquired before boot, released on stop. Prevents a
    /// concurrent `velox start` (or second app) from attaching the same data.img.
    private var instanceLock: InstanceLock?
    /// Held for the engine's lifetime to keep macOS App Nap from throttling the
    /// embedded VM while Velox is backgrounded (see `start()`).
    private var engineActivity: NSObjectProtocol?
    /// Trailing-debounces the config disk write so dragging a Settings slider doesn't
    /// JSON-encode + write the file on every integer tick.
    private var configSaveTask: Task<Void, Never>?
    /// Live ring buffer of the guest serial console (kernel + vinit + dockerd),
    /// surfaced by the Engine Logs view. Fed from the VM's console pipe.
    let engineLog = EngineLogStore()
    private var consolePipe: Pipe?
    /// Memory the running VM actually booted with — Resource Saver restores to
    /// this, not to an edited-but-unapplied value in `config`.
    private var bootedMemoryBytes: UInt64 = 0

    /// The Docker API client, valid only while the engine is running. Dashboards
    /// read this; it rides an in-process VSOCK connection to the guest.
    private(set) var docker: DockerClient?

    /// Persistent, shared store of the dashboard resource lists (containers/images/
    /// volumes/networks). Owned here, above the navigation, so it survives pane
    /// switches — dashboards read already-loaded data instead of re-fetching on every
    /// switch. One events-driven informer feeds all of them (no per-view streams).
    private(set) var resources: DockerResourceStore?

    /// Shared owner of live container CPU/memory stats (one stream per running
    /// container, shared by the Containers table and the Overview; streams only while a
    /// stats view is on screen). Created with the engine, torn down on stop.
    private(set) var stats: StatsStore?

    /// Per-pane UI state (search/selection/expansion), lifted here so it survives
    /// pane switches (the dashboard views themselves are recreated per switch).
    let paneUI = PaneUIState()

    /// Crash notifications (opt-in) — fed by the resource store's die events.
    private let crashNotifier = CrashNotifier()

    /// Published ports that couldn't bind localhost — the Containers pane badges them.
    let portIssues = PortIssues()

    /// Set true when the engine is running and the `velox` Docker context exists
    /// but isn't the active one — the shell shows a one-time prompt offering to
    /// switch, so a plain `docker ps` in the terminal targets Velox.
    var showContextPrompt = false

    /// Result of the most recent update check (startup or manual), surfaced in
    /// Settings → General and the menu bar.
    var availableUpdate: Updater.UpdateCheckResult?
    var checkingForUpdate = false
    var updateInProgress = false

    init() {
        config = VeloxConfig.load()
        // Don't copy the bundled guest here — on update day that's a ~90 MB write
        // blocking app launch, and `start()` refreshes it anyway. Onboarding only
        // needs to know whether a guest is *available* (installed or bundled), which
        // `guestAvailable` answers without copying.
        needsOnboarding = !(VZVirtualMachine.isSupported && GuestInstall.guestAvailable)
        // Autostart the engine on app launch (unless onboarding is needed). Skipped
        // under SwiftUI previews so the canvas doesn't try to boot a VM.
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        if !needsOnboarding && !isPreview {
            Task { await self.start() }
        }
        if config.checkUpdatesOnStartup && !isPreview {
            Task { await self.checkForUpdates() }
        }
    }

    // MARK: - Updates

    /// Check GitHub Releases (VELOX_GITHUB_REPO) for a newer Velox; the result lands
    /// in `availableUpdate`, which Settings → General and the menu bar observe.
    func checkForUpdates() async {
        checkingForUpdate = true
        defer { checkingForUpdate = false }
        availableUpdate = await Updater.checkForUpdate()
    }

    /// Download the latest release and replace the running app in place, then
    /// relaunch. Runs off the main actor (it blocks on the download and exits the
    /// process on success); `updateInProgress` only clears if it falls back.
    func applyUpdate() {
        guard !updateInProgress else { return }
        updateInProgress = true
        // A GCD queue, not `Task.detached`: `applyLatestUpdate` blocks (download, then the
        // shutdown wait below), and blocking a Swift-concurrency cooperative thread — of
        // which there are only as many as there are cores — can starve every other task in
        // the process. GCD grows its pool instead.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Updater.applyLatestUpdate(beforeRelaunch: { [weak self] in
                // The updater is about to exit(0) to relaunch, which tears down this VM. Block
                // here until the guest has flushed (sync over the control channel) and the VM has
                // cleanly stopped, so the data disk isn't left torn (which would be
                // reformatted on next boot, losing all containers/images).
                //
                // Via the nonisolated teardown, never `await stop()`: this thread is blocked,
                // so a main-actor-bound stop that can't be scheduled would park it forever and
                // the relaunch would never happen. Bounded for the same reason.
                guard let self else { return }
                let sem = DispatchSemaphore(value: 0)
                self.shutdownForTerminate { sem.signal() }
                if sem.wait(timeout: .now() + Self.stopDeadline) == .timedOut {
                    Log.warn("engine did not stop before the update relaunch; continuing")
                }
            })
            // Only reached if the update fell back (success calls exit(0)). `beforeRelaunch`
            // stopped the engine through the terminate path, which deliberately skips the UI
            // state machine — so finish it here, or the app is stuck in `.stopping` holding
            // the instance lock with `performStart` refusing to run.
            Task { @MainActor in
                guard let self else { return }
                self.updateInProgress = false
                if self.state == .stopping { self.handleGuestStopped(nil) }
            }
        }
    }

    /// Persist preferences to disk.
    func saveConfig() {
        do { try config.save() }
        catch { Log.warn("failed to save config: \(error.localizedDescription)") }
    }

    /// Whether the engine can boot right now: host supports virtualization and
    /// the guest kernel has been installed under ~/.velox.
    static var isReady: Bool {
        VZVirtualMachine.isSupported
            && FileManager.default.fileExists(atPath: Paths.kernel.path)
            && FileManager.default.fileExists(atPath: Paths.rootDisk.path)
    }

    /// Re-evaluate readiness, installing the bundled guest first if it isn't in place yet.
    ///
    /// Deliberately does NOT clear `needsOnboarding`: the onboarding sheet is bound to that
    /// flag, so a successful re-check used to dismiss the wizard out from under the user —
    /// skipping the finish step, which is the only place `start()` is called. Setup then
    /// "completed" into a stopped engine with no explanation. Only `completeOnboarding()`
    /// dismisses. It can still re-raise the sheet if readiness was lost.
    /// The guest copy is off the main actor — it's up to ~90 MB.
    func refreshReadiness() async {
        await Task.detached(priority: .userInitiated) { GuestInstall.refreshFromBundleIfNeeded() }.value
        if !needsOnboarding, !EngineController.isReady { needsOnboarding = true }
    }

    /// Dismiss onboarding explicitly (user finished or chose to continue anyway).
    func completeOnboarding() {
        needsOnboarding = false
    }

    // MARK: - Lifecycle

    private func performStart() async {
        guard state.isStopped || state.failureMessage != nil else { return }
        // Refuse while an orphan VM may still hold the disk. `flock` is per-open-file-
        // description, so re-acquiring throws even inside this same process — and the catch
        // below calls `cleanup()`, which would release the lock the LIVE VM depends on and
        // let a second engine attach the same ext4 image.
        guard !vmUnreachable, instanceLock == nil else {
            state = .failed("A previous engine is still holding the data disk. Quit and "
                            + "reopen Velox.")
            return
        }
        state = .starting
        startGeneration &+= 1
        let gen = startGeneration
        // Tracks whether `manager.start` succeeded, so the catch knows whether there is a
        // live guest to stop. Inferring it from `state` is exactly what went wrong before.
        var vmStarted = false
        do {
            let resources = config.resources
            let shareURLs = config.shareURLs
            try Paths.ensureRoot()
            // Refuse to boot if another engine (a `velox start` in a terminal) already
            // holds the lock — two engines on one data.img would corrupt it. Released in
            // cleanup(). Acquired before any disk/VM work so a conflict fails fast.
            instanceLock = try InstanceLock(at: Paths.engineLock)
            let dataDisk = config.dataDiskURL
            // A missing disk is a legitimate first-run create only at the DEFAULT location. At a
            // user-chosen location it means the drive is unplugged / the file is gone — fail loudly
            // rather than silently format a fresh empty disk (which would look like total data loss).
            if config.dataDirectory != nil && !FileManager.default.fileExists(atPath: dataDisk.path) {
                throw VeloxError.dataDiskMissing(dataDisk)
            }
            try Storage.ensureDataDisk(at: dataDisk, sizeGiB: resources.diskGiB)
            // After an app update, refresh the installed guest from the (newer) bundled copy so we
            // never boot a stale ~/.velox kernel/rootfs against a new host.
            // Off the main actor: this copies the kernel (~10 MB) and rootfs (~80 MB) after
            // an app update, and doing it inline beach-balled the whole UI — menu bar,
            // dashboard, and the Engine Logs view that should be showing boot progress.
            await Task.detached(priority: .userInitiated) { GuestInstall.refreshFromBundleIfNeeded() }.value
            let image = (try? GuestImage.resolve())?.advertising(shares: shareURLs)
                ?? GuestImage(kernelURL: Paths.kernel, rootDiskURL: Paths.rootDisk,
                              kernelCommandLine: GuestImage.defaultCommandLine)
                    .advertising(shares: shareURLs) // else extra shares attach but never mount
            // Capture the guest serial console (kernel + vinit + dockerd) for the
            // Engine Logs view: hand the VM a pipe as its console write end and drain
            // the read end into the ring buffer. (The CLI keeps stdout.)
            let pipe = Pipe()
            consolePipe = pipe
            engineLog.attach(pipe.fileHandleForReading)
            let vmConfig = try VMConfiguration.build(
                image: image,
                dataDisk: dataDisk,
                resources: resources,
                extraShares: shareURLs,
                consoleOutput: pipe.fileHandleForWriting,
                nestedVirtualization: config.nestedVirtualization)

            // Unexpected guest exits / crashes route here too.
            manager.onStop { [weak self] error in
                Task { @MainActor in self?.handleGuestStopped(error) }
            }

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                manager.start(configuration: vmConfig) { result in
                    cont.resume(with: result)
                }
            }
            // From here on the guest is RUNNING and holding `data.img`, so any later failure
            // has to power it off rather than just drop the plumbing — see the catch below.
            vmStarted = true
            // Stopped/torn down while the VM was starting — don't wire plumbing onto a
            // dead or stopping VM (the teardown path bumped the generation).
            guard gen == startGeneration else { return }

            // Engine is up: all the shared plumbing (Docker socket proxy, port
            // forwarders, events watcher, named access, clock sync, conduit pool) is
            // wired by EngineRuntime — the same code path as the `velox` CLI.
            let runtime = EngineRuntime(manager: manager, publish: self.config.publishBind)
            runtime.setPortIssueHandler { [portIssues] port, blocked in
                Task { @MainActor in portIssues.set(port, blocked: blocked) }
            }
            try runtime.start()
            self.runtime = runtime
            self.docker = runtime.docker
            // Start the shared resource informer immediately so the dashboards have
            // data loaded before the user navigates to them (no per-pane re-fetch).
            let resourceStore = DockerResourceStore(docker: runtime.docker)
            crashNotifier.enabled = config.notifyOnCrash
            resourceStore.onContainerDied = { [crashNotifier] name, code in
                crashNotifier.containerDied(name: name, exitCode: code)
            }
            resourceStore.start()
            self.resources = resourceStore
            self.stats = StatsStore(docker: runtime.docker, resources: resourceStore)
            appliedSignature = config.bootSignature
            bootedMemoryBytes = resources.memoryBytes
            startResourceSaver()
            // The VM has booted, but dockerd needs a few more seconds inside the
            // guest. Stay in `.starting` until it actually answers — signaled by the
            // events watcher's first successful reconcile — so the dashboards' first
            // load succeeds (no transient "Connection reset by peer", no manual refresh).
            let ready = await waitForDockerReady(runtime)
            // Torn down while we waited for dockerd (e.g. the guest crashed during boot):
            // stay in whatever state cleanup() already set — never write `.running` over a
            // dead engine (which would leave the UI "Running" with no docker client).
            guard gen == startGeneration else { return }
            if !ready {
                // dockerd never answered. Reporting `.running` here leaves the engine bound
                // to a socket with nothing behind it and no way back — every docker command
                // fails and only an app restart recovers. Surface it instead.
                //
                // Stop the VM properly rather than just dropping the plumbing: it is still
                // running and attached to `data.img`, and an orphan there is what makes a
                // later Start or data-disk move act on a live disk. `.starting` is `isBusy`,
                // so `performStop` runs, and it latches `vmUnreachable` if it can't confirm.
                let stopped = await performStop()
                state = .failed(stopped
                    ? "The engine started but Docker never became ready. Try starting it again."
                    : "Docker never became ready and the engine did not shut down. Quit and "
                      + "reopen Velox.")
                return
            }
            // Keep macOS App Nap from throttling the embedded VM while Velox is
            // backgrounded (you're working in another app and the engine has real work
            // to do). A napped process has its threads — including the VM's vCPUs —
            // timer-throttled and pushed to efficiency cores, so a build/heavy container
            // crawls exactly when it shouldn't. Hold a user-initiated activity for the
            // engine's lifetime; `AllowingIdleSystemSleep` so the Mac can still sleep
            // when idle (the guest pauses and ClockSync re-syncs on wake).
            engineActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Velox container engine is running")
            startedAt = Date()
            state = .running
            Log.info("engine started in-process (GUI)")
            // First-run only: install terminal CLIs + the `velox` context and offer to
            // switch if needed. Backgrounded so it never delays the UI flipping to running.
            Task { await self.setUpTerminalAndContext() }
        } catch {
            // `runtime.start()` throws when the docker socket can't bind (a full or unwritable
            // ~/.velox, EMFILE) — by which point the guest is up and journaling the data disk.
            // `cleanup()` alone would release the instance lock under a live VM, letting a
            // second engine attach the same image, and would leave `.failed` looking "not
            // running" to the data-disk move. Power it off properly; `performStop` latches
            // `vmUnreachable` if it can't confirm.
            if vmStarted {
                let stopped = await performStop()
                state = .failed(stopped
                    ? error.localizedDescription
                    : error.localizedDescription + " The engine also did not shut down cleanly; "
                      + "quit and reopen Velox.")
            } else {
                cleanup()
                state = .failed(error.localizedDescription)
            }
            Log.error("engine start failed: \(error.localizedDescription)")
        }
    }

    /// Ceiling on a graceful VM stop before `performStop` gives up waiting. Above the
    /// 60 s guest-flush timeout in `VMManager.stopGracefully` plus the power-off, so this
    /// only fires on a genuine stall — never on a slow-but-working shutdown.
    private nonisolated static let stopDeadline: TimeInterval = 120

    /// **The** engine teardown: drop the host plumbing (docker socket, forwarders, host
    /// routes), then flush the guest and power the VM off. Both stop routes — the UI's
    /// `performStop` and app termination's `shutdownForTerminate` — go through here, so
    /// the sequence can't drift the way the CLI's and GUI's wiring once did (the reason
    /// `EngineRuntime` exists at all).
    ///
    /// Nonisolated on purpose: termination must be able to flush the guest even when the
    /// main actor is busy. Everything touched is thread-safe (`EngineRuntime.stop` is
    /// lock-guarded, `VMManager.stopGracefully` completes on the VM queue), and the
    /// blocking route removal stays off the main thread. `completion` fires on a
    /// background queue.
    private nonisolated func teardown(completion: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [manager, runtimeBox] in
            runtimeBox.value?.stop(waitForTeardown: true)
            manager.stopGracefully {
                // Off the VM queue: this completion runs on `dev.velox.vm`, and the stop
                // below blocks on synchronous porthelper round trips (up to 3 s per route).
                // Holding the VM queue there stalls every other VZ operation queued on it.
                DispatchQueue.global(qos: .userInitiated).async {
                    // A `performStart` that raced this teardown can have wired fresh plumbing
                    // in between (it publishes `runtime` only after `EngineRuntime.start()`).
                    // Stopping again is idempotent for the runtime we already stopped, and
                    // catches that one — so nothing outlives a teardown.
                    runtimeBox.value?.stop(waitForTeardown: true)
                    completion()
                }
            }
        }
    }

    /// Returns true once the VM is confirmed down. **False means the VM is still alive** —
    /// callers must not treat that as stopped.
    @discardableResult
    private func performStop() async -> Bool {
        guard state.isRunning || state.isBusy else { return true }
        startGeneration &+= 1   // invalidate any in-flight performStart
        state = .stopping
        let confirmed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = OnceResume(cont)
            teardown { once.fire(true) }
            // Bound it. `VMManager.attemptStop` parks the completion while the VM isn't
            // stoppable yet (`canStop == false` during the boot window) and only
            // `machine.start`'s completion re-invokes it — so a VZ start that never
            // completes strands this continuation and the UI sticks on "Stopping…"
            // forever. Generous: above the 60 s guest flush plus the VM's own power-off.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.stopDeadline) {
                if once.fire(false) {
                    Log.warn("VM stop did not complete in \(Int(Self.stopDeadline))s — "
                             + "abandoning the wait; the guest may still be running")
                }
            }
        }
        // Timed out: the VM is STILL ALIVE and still attached to data.img. Do not fall into
        // the normal path — `cleanup()` releases the instance lock, which would let a second
        // engine attach the same ext4 image (the corruption `InstanceLock` exists to
        // prevent), and `moveDataDisk` would go on to copy a live disk and unlink the
        // original. Surface it and leave the lock held.
        guard confirmed else {
            // The VM is still alive on `data.img` and nothing manages it any more. Latch it:
            // every disk-touching action must now refuse, and the instance lock must stay
            // held so no other engine can attach the same image.
            vmUnreachable = true
            state = .failed("The engine did not shut down and may still be running. Quit and "
                            + "reopen Velox before starting it again.")
            return false
        }
        // `handleGuestStopped` typically lands first via the delegate; this is a
        // backstop so the UI never sticks on "Stopping…".
        if state == .stopping { handleGuestStopped(nil) }
        return true
    }

    // Public lifecycle controls. While a data-disk relocation owns the engine
    // (`isRelocatingDisk`) these are no-ops: booting a VM mid-move would attach the data disk
    // that's being copied out from under it (corruption). The move drives the engine itself via
    // `performStart`/`performStop`.
    func start() async { guard !isRelocatingDisk else { return }; await performStart() }
    func stop() async { guard !isRelocatingDisk else { return }; await performStop() }
    func restart() async {
        guard !isRelocatingDisk else { return }
        // Never boot a second VM onto a disk the first one is still holding.
        guard await performStop() else { return }
        await performStart()
    }

    /// Flush and power off the guest for app termination — **without ever needing the main
    /// actor**.
    ///
    /// `applicationShouldTerminate` returns `.terminateLater` and AppKit then waits for a
    /// reply. If that wait depended on main-actor work, a busy (or wedged) UI would mean the
    /// guest never gets flushed — precisely the data-durability outcome the deferred
    /// terminate exists to protect, and how a quit could hang until Force Quit. So this
    /// route runs the shared `teardown()` sequence, which touches only thread-safe,
    /// callback-driven pieces. `completion` fires on a background queue.
    ///
    /// The UI state machine is deliberately not on the critical path — the process is
    /// exiting. It is only nudged best-effort, so an in-flight `performStart` can't wire
    /// fresh plumbing onto a VM we just powered off; if the main actor is stuck that hop
    /// never runs, but then `performStart` is stuck too and there is nothing to invalidate.
    nonisolated func shutdownForTerminate(completion: @escaping @Sendable () -> Void) {
        Task { @MainActor in self.beginTerminating() }
        teardown(completion: completion)
    }

    /// Best-effort UI bookkeeping for a terminate already under way (see above).
    private func beginTerminating() {
        guard state.isRunning || state.isBusy else { return }
        startGeneration &+= 1
        state = .stopping
    }

    /// Relocate `data.img` into `destinationDir`. Stops the engine first (so the image is flushed
    /// and its VZ file handle released), moves it sparse-preserving, repoints the config, and
    /// restarts if it was running. On any failure the original is left intact and the engine is
    /// restarted at the OLD location, then the error is rethrown. `moveProgress` tracks 0…1.
    func moveDataDisk(to destinationDir: URL) async throws {
        let src = config.dataDiskURL
        let dst = destinationDir.appendingPathComponent("data.img")
        guard dst.standardizedFileURL != src.standardizedFileURL else {
            throw VeloxError.diskMove("The data disk is already in that folder.")
        }
        guard !FileManager.default.fileExists(atPath: dst.path) else {
            throw VeloxError.diskMove("A data.img already exists in \(destinationDir.path).")
        }
        // Free-space preflight — but ONLY for a real copy. A same-volume move is a hard link
        // (same inode), so it needs no space at all; checking anyway refused the common case
        // outright: a 60 GB-allocated data.img being reorganised on a drive with 40 GB free
        // was rejected with "not enough free space" for an operation that costs zero bytes.
        if !Storage.moveIsHardLink(from: src, to: destinationDir.appendingPathComponent("data.img")) {
            let srcAllocated = (try? src.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize.map(Int64.init) ?? 0
            if let free = (try? destinationDir.resourceValues(
                    forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
               free > 0, srcAllocated > free {
                throw VeloxError.diskMove("Not enough free space at the destination "
                    + "(need \(Format.bytes(srcAllocated)), \(Format.bytes(free)) available).")
            }
        }

        // NOT inferred from `state`: a stop-timeout leaves `.failed` with a live VM, which
        // reads as "not running" here — the move would then copy a disk the guest is still
        // journaling and `removeMovedSource` would unlink the original.
        guard !vmUnreachable else {
            throw VeloxError.diskMove("The engine may still be running and holding the data "
                + "disk. Quit and reopen Velox, then try again.")
        }
        let wasRunning = state.isRunning || state.isBusy
        isRelocatingDisk = true; moveProgress = 0
        defer { isRelocatingDisk = false; moveProgress = 0 }
        // Flush + release the VZ file handle. If the engine won't stop, abort: copying a disk
        // the guest is still writing to yields a torn image, and the success path unlinks the
        // original — that's total data loss, not a degraded copy.
        if wasRunning, await performStop() == false {
            throw VeloxError.diskMove("The engine did not shut down, so the data disk can't be "
                + "moved safely. Quit and reopen Velox, then try again.")
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                try Storage.stageDataDiskMove(from: src, to: dst) { [weak self] frac in
                    Task { @MainActor in self?.moveProgress = frac }
                }
            }.value
        } catch {
            if wasRunning { await performStart() }   // restore at the OLD location; config unchanged
            throw error
        }

        // The data now exists at BOTH src and dst. Persist the new location FIRST — a crash
        // here leaves config→dst with the data present (src just a harmless leftover), never an
        // orphaned disk — THEN drop the original.
        config.dataDirectory = (destinationDir.standardizedFileURL == Paths.root.standardizedFileURL)
            ? nil : destinationDir.standardizedFileURL.path
        saveConfig()
        Storage.removeMovedSource(at: src)
        if wasRunning { await performStart() }
    }

    // MARK: - Internals

    private func handleGuestStopped(_ error: Error?) {
        startGeneration &+= 1   // invalidate any in-flight performStart
        cleanup()
        if let error {
            state = .failed(error.localizedDescription)
        } else {
            state = .stopped
        }
    }

    private func cleanup() {
        startedAt = nil
        if let engineActivity {
            ProcessInfo.processInfo.endActivity(engineActivity)
            self.engineActivity = nil
        }
        // Shared plumbing teardown (watcher, named access, forwarders, conduit pool,
        // clock sync, proxy) — idempotent; also removes host routes so none dangle.
        runtime?.stop()
        runtime = nil
        portIssues.clear()
        resources?.stop()
        resources = nil
        stats?.stop()
        stats = nil
        docker = nil
        resourceSaver?.stop()
        resourceSaver = nil
        isResourceSaving = false
        // Stop draining the (now-closing) console pipe; a restart attaches a fresh one.
        // Keep the buffered lines so the user can read why the engine stopped.
        engineLog.detach()
        consolePipe = nil
        // Release the single-instance lock last, so no other engine can grab the disk
        // until this one has fully torn its plumbing down.
        instanceLock?.release()
        instanceLock = nil
    }

    /// (Re)arm Resource Saver from the current config. Called on start and again
    /// whenever the user toggles it or changes the idle timer in Settings, so the
    /// change takes effect without an engine restart.
    private func startResourceSaver() {
        resourceSaver?.stop()
        resourceSaver = nil
        isResourceSaving = false
        guard config.resourceSaverEnabled, bootedMemoryBytes > 0, let docker else { return }
        // Floor at ¼ of the booted RAM, clamped to [512 MiB, 1 GiB], so dockerd
        // stays responsive enough to notice the next container start.
        let floor = min(max(bootedMemoryBytes / 4, 512 * 1024 * 1024), 1024 * 1024 * 1024)
        let saver = ResourceSaver(
            manager: manager,
            docker: docker,
            fullMemoryBytes: bootedMemoryBytes,
            floorBytes: floor,
            idleMinutes: config.resourceSaverMinutes)
        // Reflect saver mode in the menu-bar icon (moon badge). The callback fires
        // on the saver's internal queue; hop to the main actor for the @Observable.
        saver.onStateChange = { [weak self] saving in
            Task { @MainActor in self?.isResourceSaving = saving }
        }
        saver.start()
        resourceSaver = saver
    }

    /// Persist preferences and apply the live-tunable ones (Resource Saver) to a
    /// running engine. Settings calls this on change.
    func applyRuntimeConfig() {
        // Apply the live-tunable parts (Resource Saver, crash notifications) immediately,
        // but debounce the disk write: dragging a CPU/memory/disk slider fires this on
        // every integer tick, and each `saveConfig` is a synchronous JSON encode + write.
        crashNotifier.enabled = config.notifyOnCrash
        if state.isRunning { startResourceSaver() }
        configSaveTask?.cancel()
        configSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.saveConfig()
        }
    }

    /// First-run setup, on a background task (off the launch path): always (cheap)
    /// install the terminal CLIs, and ONCE create the `velox` context + offer to switch
    /// if it isn't active. After the first run we don't re-check every launch (that would
    /// shell out to `docker` for nothing) — the user switches any time from Settings.
    private func setUpTerminalAndContext() async {
        let socket = Paths.dockerSocket.path
        let handled = config.dontSuggestContext
        let active = await Task.detached(priority: .utility) { () -> String? in
            // Always, cheap + idempotent: make `docker` + `velox` usable from the terminal
            // (symlinks into ~/.velox/bin + a marked PATH block in the zsh profile).
            let setup = FirstRun.installCLITools(updateShellProfile: true)
            if setup.linkedTools { Log.info("first-run: \(setup.message)") }
            // Only on the first run: create the context + read the active one (a `docker`
            // shell-out). Skipped forever after, so launches stay quiet.
            guard !handled else { return nil }
            guard CLIBinding.ensureContext(socketPath: socket) else { return nil }
            return CLIBinding.activeContext()
        }.value
        guard !handled, let active else { return }
        config.dontSuggestContext = true; saveConfig()      // first-run handled — never auto-check again
        if active == "velox" {
            Log.info("docker context: velox already active")
        } else {
            Log.info("docker context: active=\(active) — offering to switch to velox")
            showContextPrompt = true
        }
    }

    /// Switch the active Docker context to `velox` — used by the first-run prompt and
    /// the Settings button. Ensures the context exists first.
    func switchToVeloxContext() {
        Task.detached(priority: .utility) {
            _ = CLIBinding.ensureContext(socketPath: Paths.dockerSocket.path)
            if CLIBinding.useVeloxContext() { Log.info("active docker context → velox") }
            else { Log.warn("failed to switch docker context to velox") }
        }
    }

    /// The active Docker context name, for display in Settings (nil if `docker` is absent).
    func activeDockerContext() async -> String? {
        await Task.detached(priority: .utility) { CLIBinding.activeContext() }.value
    }

    /// First-run prompt accepted → switch to the `velox` context.
    func adoptVeloxContext() { showContextPrompt = false; switchToVeloxContext() }

    /// First-run prompt dismissed. (The user can still switch later from Settings.)
    func declineVeloxContext() { showContextPrompt = false }

    /// Wait for dockerd to start answering before flipping to `.running`. The events
    /// watcher is already opening a persistent connection and reconciling, so its
    /// first success is the readiness signal — we don't poll `/_ping` (which would
    /// churn a fresh VSOCK connection every 250 ms; CLAUDE.md §8). Bounded so a
    /// broken guest can't hang the UI in `.starting`.
    @discardableResult
    private func waitForDockerReady(_ runtime: EngineRuntime) async -> Bool {
        if await runtime.waitUntilDockerReady(timeout: .seconds(30)) {
            Log.info("dockerd ready")
            return true
        }
        Log.warn("dockerd did not respond within 30s")
        return false
    }
}
