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

    /// The long-running operation that currently *owns* the engine — it drives the stop and
    /// restart itself, so `start()`/`stop()`/`restart()` must stay out of its way.
    ///
    /// One value rather than a flag per operation. The same "is something holding the
    /// engine?" ladder is hand-written in three places (the sidebar status bar, the
    /// engine-down pane, the menu-bar control), and with a boolean per operation each new
    /// one has to be threaded through all three — which is how they drift. Adding a case
    /// here updates every ladder at once.
    private(set) var engineOwner: EngineOwner?

    /// True while any operation owns the engine.
    var isEngineOwned: Bool { engineOwner != nil }

    /// True once the app has begun terminating.
    ///
    /// Deliberately separate from `state`. `beginTerminating()` only advances `state` when
    /// the engine is running or busy — but a workspace switch (or a disk move) sits in
    /// `.stopped` between its own `performStop` and `performStart`, so a ⌘Q landing in that
    /// window leaves `state` untouched, `performStart`'s entry guard passes, and the switch
    /// boots a VM the process is already killing. On a brand-new workspace that means a
    /// half-run `mkfs.ext4`: `is_ext4` then reports true while `disk_is_blank` reports false,
    /// so vinit refuses to format it *and* can't mount it, and the workspace is permanently
    /// unbootable. Checked at the top of `performStart` and after every `await` in an
    /// engine-owning operation.
    private(set) var isTerminating = false

    /// The data disk the running VM actually has open, set beside `instanceLock` and cleared
    /// in `cleanup()`.
    ///
    /// Workspace operations guard on **this**, never on "is it the active workspace?". The
    /// manifest's `activeID` is a separate mutable file that another process can move, and
    /// `InstanceLock` is per-user rather than per-disk, so neither answers "does a VM have
    /// this file open?". Getting that wrong means unlinking a disk out from under a live
    /// guest: on macOS the unlink succeeds, the VM keeps writing to an inode with no name,
    /// and every image, container and volume disappears when it stops.
    private(set) var attachedDiskURL: URL?

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
    ///
    /// Compared against the ACTIVE workspace's disk size, since that — not the mirrored
    /// global — is what the running VM booted with.
    var needsRestart: Bool {
        guard state.isRunning, let applied = appliedSignature else { return false }
        return applied != config.bootSignature(diskGiB: activeWorkspace?.diskGiB)
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

    /// The workspace list and which one is active. Re-read from disk on every start, so the
    /// CLI and this process can't diverge about which disk is booting.
    private(set) var workspaces: WorkspaceManifest?
    /// Set when the manifest can't be read (or a pre-Workspaces migration was refused).
    /// The engine won't start while this is non-nil — it's better to say so than to boot the
    /// wrong disk or format a blank one over a user's real data.
    private(set) var workspaceError: String?

    /// The active workspace, or nil if the manifest is unreadable.
    var activeWorkspace: Workspace? { workspaces?.active }

    /// Which workspace dialog is on screen. Owned here, like `paneUI`, so the sidebar can
    /// raise a prompt while `RootView` hosts it — see `WorkspacePanel`.
    let workspacePanel = WorkspacePanel()

    /// Workspaces in a stable display order. Creation order, so a switch never reshuffles
    /// the sidebar under the pointer.
    var sortedWorkspaces: [Workspace] {
        (workspaces?.workspaces ?? []).sorted { $0.created < $1.created }
    }

    /// What may be done to `workspace` right now, and why not.
    func capabilities(for workspace: Workspace) -> WorkspaceCapabilities {
        WorkspaceCapabilities(
            workspace: workspace,
            // The EFFECTIVE active id — with a dangling pointer, `active` falls back, and
            // the fallback workspace must be protected (and marked) as the active one.
            activeID: activeWorkspace?.id,
            workspaceCount: workspaces?.workspaces.count ?? 0,
            engineBusy: isEngineOwned,
            attachedDiskURL: attachedDiskURL)
    }

    // MARK: - Workspace actions (UI entry points)
    //
    // Thin wrappers that run the operation and route any failure into `workspacePanel`, so
    // every error reaches the user through one alert instead of each call site inventing its
    // own. They also keep the views free of `do/catch`.
    //
    // They all report through `fail`, which defers presentation: each of these is invoked
    // from inside the button of a prompt that was dismissed a moment earlier, and a second
    // alert raised while the first is still dismissing is simply dropped — losing exactly the
    // errors that matter most (a duplicate name, a delete the store refused).

    func performSwitch(to workspace: Workspace) async {
        do { try await switchWorkspace(to: workspace) }
        catch { workspacePanel.fail(Self.message(error)) }
    }

    func performCreate(name: String) {
        do { try createWorkspace(name: name) }
        catch { workspacePanel.fail(Self.message(error)) }
    }

    func performRename(_ workspace: Workspace, to name: String) {
        do { try renameWorkspace(workspace, to: name) }
        catch { workspacePanel.fail(Self.message(error)) }
    }

    func performDuplicate(_ workspace: Workspace, newName: String) async {
        do { _ = try await cloneWorkspace(workspace, newName: newName) }
        catch { workspacePanel.fail(Self.message(error)) }
    }

    func performDelete(_ workspace: Workspace) {
        do { try deleteWorkspace(workspace) }
        catch { workspacePanel.fail(Self.message(error)) }
    }

    func performMove(_ workspace: Workspace, to directory: URL) async {
        do { try await moveWorkspace(workspace, to: directory) }
        catch { workspacePanel.fail(Self.message(error)) }
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

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
        // Load (or, on the first run after upgrading, create) the workspace list. Must come
        // after the stored properties above are initialized.
        reloadWorkspaces()
        // Autostart the engine on app launch (unless onboarding is needed). Skipped
        // under SwiftUI previews so the canvas doesn't try to boot a VM.
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        if !needsOnboarding && !isPreview {
            Task { await self.start() }
        }
        if config.checkUpdatesOnStartup && !isPreview {
            Task { await self.checkForUpdates() }
        }
        // Refresh the workspace list whenever the app comes to the front. While the GUI is
        // open with the engine STOPPED, the engine lock is free, so `velox workspace
        // new/rename/rm` in a terminal succeeds — and nothing else would tell this process.
        // Activation is the moment the user cmd-tabs back to look at the sidebar, and it is
        // a push, not a poll (CLAUDE.md §8; same pattern as ClockSync's didWake).
        // `reloadWorkspaces` only publishes on a real change, so the common case is free.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadWorkspaces() }
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
        // Records whether the pre-relaunch shutdown actually confirmed. The fallback path
        // below must not "finish" a stop that never happened (see the guard there).
        let stopStalled = Locked(false)
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
                    stopStalled.value = true
                }
            })
            // Only reached if the update fell back (success calls exit(0)). `beforeRelaunch`
            // stopped the engine through the terminate path, which deliberately skips the UI
            // state machine — so finish it here, or the app is stuck in `.stopping` holding
            // the instance lock with `performStart` refusing to run.
            Task { @MainActor in
                guard let self else { return }
                self.updateInProgress = false
                // The update FELL BACK, so this process keeps running — and if the stop above
                // timed out, the VM is still alive on `data.img`. `handleGuestStopped` runs
                // `cleanup()`, which releases the instance lock: exactly the "second engine
                // attaches the same ext4 image" corruption `vmUnreachable` was added to
                // prevent in `performStop`. The update path reached the same state by a
                // different route, so it has to latch it the same way.
                guard !stopStalled.value else {
                    self.vmUnreachable = true
                    self.state = .failed("The engine did not shut down for the update and may "
                                         + "still be running. Quit and reopen Velox before "
                                         + "starting it again.")
                    return
                }
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
        guard !isTerminating else { return }
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
            // Re-read the manifest from disk on every start: `velox workspace use` may have
            // repointed it since this process loaded it, and booting the workspace the user
            // did *not* select is the one outcome worth failing to avoid.
            reloadWorkspaces()
            if let workspaceError {
                throw VeloxError.workspace(workspaceError)
            }
            guard let workspace = activeWorkspace else {
                throw VeloxError.workspace("No workspace is available.")
            }
            let resources = config.resources(diskGiB: workspace.diskGiB)
            let shareURLs = config.shareURLs
            try Paths.ensureRoot()
            // Refuse to boot if another engine (a `velox start` in a terminal) already
            // holds the lock — two engines on one data.img would corrupt it. Released in
            // cleanup(). Acquired before any disk/VM work so a conflict fails fast.
            instanceLock = try InstanceLock(at: Paths.engineLock)
            let dataDisk = workspace.dataDiskURL
            // A missing disk is a legitimate first-run create only for a workspace that has
            // never booted. Once one has, its disk going missing means the drive is unplugged
            // or the file is gone — fail loudly rather than silently format a fresh empty one
            // in its place, which would look exactly like total data loss.
            //
            // The old test for this was "did the user relocate the disk?", which does not
            // generalise: every non-default workspace has a resolved path, and a brand-new
            // workspace's disk is *supposed* to be absent. "Has it ever booted?" is the
            // question that actually separates the two.
            if workspace.firstBootedAt != nil,
               !FileManager.default.fileExists(atPath: dataDisk.path) {
                throw VeloxError.dataDiskMissing(dataDisk)
            }
            try Storage.ensureDataDisk(at: dataDisk, sizeGiB: resources.diskGiB)
            // Record what this VM actually attached. Workspace operations guard on this
            // rather than on the manifest's `activeID`, which another process can move.
            attachedDiskURL = dataDisk
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
            appliedSignature = config.bootSignature(diskGiB: workspace.diskGiB)
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
            // Stamp the first successful boot. From here on a missing disk for this
            // workspace is a fault to report, not a blank one to create.
            WorkspaceStore.recordBoot(id: workspace.id)
            reloadWorkspaces()
            Log.info("engine started in-process (GUI) — workspace “\(workspace.name)”")
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
        // prevent), and a workspace move or duplicate would go on to copy a live disk —
        // and a move unlinks the original afterwards. Surface it and leave the lock held.
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

    // Public lifecycle controls. While another operation owns the engine (a disk move, a
    // workspace switch or clone) these are no-ops: booting a VM mid-operation would attach a
    // data disk that's being copied or swapped out from under it (corruption). Those
    // operations drive the engine themselves via `performStart`/`performStop`.
    func start() async { guard !isEngineOwned else { return }; await performStart() }
    func stop() async { guard !isEngineOwned else { return }; await performStop() }
    func restart() async {
        guard !isEngineOwned else { return }
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
        // Latch FIRST, unconditionally. The guard below only fires when the engine is
        // running or busy — but an engine-owning operation (a workspace switch, a disk move)
        // sits in `.stopped` between its own stop and start, and a ⌘Q landing in that window
        // would slip past it: `startGeneration` would not be bumped, `performStart`'s entry
        // guard would pass, and the operation would boot a VM into a process that is already
        // exiting. On a brand-new workspace that interrupts `mkfs.ext4` and leaves a disk
        // vinit will neither format nor mount.
        isTerminating = true
        guard state.isRunning || state.isBusy else { return }
        startGeneration &+= 1
        state = .stopping
    }

    // MARK: - Workspaces
    //
    // A workspace is one complete Docker engine state, and all of it lives in one file —
    // `data.img`. So switching is just booting against a different one, and every operation
    // here is the same short sequence the data-disk move was hardened into: refuse if
    // anything else owns the engine, refuse if a VM might still hold the disk, stop and
    // *confirm* the stop, mutate, then restart.
    //
    // The one rule that must never bend: **never mutate a disk a VM has open.** Operations
    // on the ACTIVE workspace stop the engine first; operations on an inactive one need no
    // stop, because its disk isn't attached — but they still check `attachedDiskURL` rather
    // than trusting the manifest to say which that is.

    /// Re-read the manifest from disk. Cheap, and the reason the CLI and the GUI can't
    /// disagree about which workspace is booting.
    func reloadWorkspaces() {
        do {
            let loaded = try WorkspaceStore.load()
            // Only publish a real change. This is also called on every app activation, and
            // reassigning an identical manifest would invalidate every view observing it
            // each time the user cmd-tabs back to Velox.
            if workspaces != loaded { workspaces = loaded }
            workspaceError = nil
        } catch {
            workspaces = nil
            workspaceError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.error("workspaces: \(workspaceError ?? "")")
        }
    }

    /// Guard shared by every workspace operation.
    ///
    /// `vmUnreachable` is checked rather than inferred from `state`, because a stop that
    /// timed out leaves `.failed` — which reads as "not running" — while the guest is still
    /// journaling onto the disk.
    private func requireIdleEngine(_ what: String) throws {
        guard !isEngineOwned else {
            throw VeloxError.workspace("Velox is busy — wait for the current operation to "
                + "finish, then \(what) again.")
        }
        guard !isTerminating else {
            throw VeloxError.workspace("Velox is quitting.")
        }
        guard !vmUnreachable else {
            throw VeloxError.workspace("The engine may still be running and holding a data "
                + "disk. Quit and reopen Velox, then try again.")
        }
    }

    /// Refuse to touch a disk the running VM has open.
    ///
    /// Guarding on "is it the active workspace?" would not be enough: `activeID` lives in a
    /// file another process can rewrite, so it can disagree with what this VM actually
    /// attached. `attachedDiskURL` is what the VM was given.
    private func requireDetached(_ workspace: Workspace, _ what: String) throws {
        guard attachedDiskURL?.standardizedFileURL
                != workspace.dataDiskURL.standardizedFileURL else {
            throw VeloxError.workspace(
                "The engine currently has “\(workspace.name)” open. Stop it first, then "
                + "\(what).")
        }
    }

    /// Switch the engine to another workspace: stop, repoint the manifest, boot.
    ///
    /// VZ builds its block-device list when the VM configuration is built and
    /// `VZDiskImageStorageDeviceAttachment` is immutable, so there is no way to swap the
    /// disk under a live VM — and dockerd's data-root can't move under a live daemon either.
    /// A restart is the mechanism, not a shortcut; Velox boots in a couple of seconds, which
    /// is what makes this feel like switching rather than reinstalling.
    func switchWorkspace(to target: Workspace) async throws {
        try requireIdleEngine("switch")
        // The RAW id on purpose, unlike every other comparison: when the stored pointer
        // dangles, `active` falls back — and switching to the fallback workspace is then the
        // repair (activate rewrites `activeID` to a valid id). Comparing the effective id
        // would swallow that click as "already there" and leave the manifest broken.
        guard target.id != workspaces?.activeID else { return }

        let wasRunning = state.isRunning || state.isBusy
        engineOwner = .switchingWorkspace(name: target.name)
        defer { engineOwner = nil }

        // Flush and release the VZ file handle on the CURRENT workspace's disk. A stop that
        // doesn't confirm means the guest is still writing, so booting a second VM would put
        // two kernels on one ext4 image.
        // Land any debounced settings write first: a disk-size drag within 400 ms of
        // switching would otherwise persist AFTER the switch repoints everything — against
        // the wrong workspace, or not at all.
        flushPendingSave()

        if wasRunning, await performStop() == false {
            throw VeloxError.workspace("The engine did not shut down, so Velox can't switch "
                + "workspaces safely. Quit and reopen Velox, then try again.")
        }
        guard !isTerminating else { return }

        do {
            try WorkspaceStore.activate(id: target.id)
        } catch {
            // The stop released the engine lock, so another process had a window to delete
            // or rename the target. Every sibling operation restores the engine on failure;
            // a switch must too — the user clicked a row, not "stop my engine".
            if wasRunning { await performStart() }
            throw error
        }
        reloadWorkspaces()
        mirrorActiveWorkspaceIntoConfig()

        // Only once the switch is real. Selections are keyed by volume NAME and image
        // digest, both of which collide across workspaces — carried over, they silently
        // re-target identically-named objects in the new one, and the Volumes context menu
        // offers "Remove N Volumes" straight off the selection.
        paneUI.clearSelections()
        engineLog.mark("switching to workspace “\(target.name)”")
        if wasRunning { await performStart() }
    }

    /// Create an empty workspace. Doesn't touch the engine — a new disk is just a new file.
    @discardableResult
    func createWorkspace(name: String, diskGiB: Int? = nil) throws -> Workspace {
        try requireIdleEngine("create a workspace")
        let size = diskGiB ?? activeWorkspace?.diskGiB ?? config.diskGiB
        let workspace = try WorkspaceStore.create(name: name, diskGiB: size)
        reloadWorkspaces()
        return workspace
    }

    /// Duplicate a workspace, sharing its blocks until the copies diverge.
    ///
    /// Duplicating the ACTIVE workspace stops the engine first and restarts it after: an
    /// APFS clone of a mounted filesystem captures a torn journal that preen-`fsck` won't
    /// repair, which yields a workspace that looks real and can never mount.
    @discardableResult
    func cloneWorkspace(_ source: Workspace, newName: String) async throws -> Workspace {
        try requireIdleEngine("duplicate a workspace")
        let isActive = attachedDiskURL?.standardizedFileURL
            == source.dataDiskURL.standardizedFileURL
        let wasRunning = isActive && (state.isRunning || state.isBusy)

        engineOwner = .cloningWorkspace(name: source.name, progress: 0)
        defer { engineOwner = nil }

        if wasRunning, await performStop() == false {
            throw VeloxError.workspace("The engine did not shut down, so “\(source.name)” "
                + "can't be duplicated safely. Quit and reopen Velox, then try again.")
        }
        guard !isTerminating else {
            throw VeloxError.workspace("Velox is quitting.")
        }
        // Re-check now that the VM is down: the clone must not run against an open file.
        try requireDetached(source, "duplicate it")

        do {
            let id = source.id
            let copy = try await Task.detached(priority: .userInitiated) { [weak self] in
                try WorkspaceStore.clone(id: id, newName: newName) { frac in
                    Task { @MainActor in
                        guard let self, let owner = self.engineOwner else { return }
                        self.engineOwner = owner.advanced(to: frac)
                    }
                }
            }.value
            reloadWorkspaces()
            if wasRunning { await performStart() }
            return copy
        } catch {
            if wasRunning { await performStart() }   // nothing was mutated; restore as it was
            throw error
        }
    }

    /// Set the active workspace's disk size, debounced like the config write.
    ///
    /// Dragging the Settings slider fires on every integer tick, and each manifest write is a
    /// JSON encode plus an fsync of the directory. This rides the SAME debounce the config
    /// write already uses rather than adding a second timer — the trailing fire persists both.
    func setActiveWorkspaceDiskGiB(_ gib: Int) {
        guard let active = activeWorkspace, active.diskGiB != gib else { return }
        // Update the in-memory copy immediately so the slider tracks the drag…
        if var manifest = workspaces,
           let i = manifest.workspaces.firstIndex(where: { $0.id == active.id }) {
            manifest.workspaces[i].diskGiB = gib
            workspaces = manifest
        }
        // …and mirror it for a pre-workspaces binary, which also schedules the debounce.
        config.diskGiB = gib
        scheduleSave()
    }

    func renameWorkspace(_ workspace: Workspace, to newName: String) throws {
        try WorkspaceStore.rename(id: workspace.id, to: newName)
        reloadWorkspaces()
    }

    /// Delete a workspace and its disk, permanently.
    ///
    /// Refused on the active workspace and on the last one (`WorkspaceStore.delete` re-checks
    /// both under the manifest lock). Only `data.img` is unlinked — never a folder the user
    /// chose, which could be anything from `~/Documents` to a drive root.
    func deleteWorkspace(_ workspace: Workspace) throws {
        try requireIdleEngine("delete a workspace")
        try requireDetached(workspace, "delete it")
        try WorkspaceStore.delete(id: workspace.id)
        reloadWorkspaces()
    }

    /// Move a workspace's `data.img` to another folder or disk.
    ///
    /// Stops the engine when the workspace is the active one, stages the move
    /// sparse-preserving, repoints the manifest, and restarts. On any failure the original is
    /// left intact and the engine restarts where it was.
    func moveWorkspace(_ workspace: Workspace, to destinationDir: URL) async throws {
        try requireIdleEngine("move a workspace")
        let src = workspace.dataDiskURL
        let dst = destinationDir.standardizedFileURL.appendingPathComponent("data.img")
        guard dst != src.standardizedFileURL else {
            throw VeloxError.diskMove("“\(workspace.name)” is already in that folder.")
        }
        guard !FileManager.default.fileExists(atPath: dst.path) else {
            throw VeloxError.diskMove("A data.img already exists in \(destinationDir.path).")
        }
        // Free-space preflight — but ONLY for a real copy. A same-volume move is a hard link
        // (same inode), so it needs no space at all; checking anyway refused the common case
        // outright: a 60 GB-allocated data.img being reorganised on a drive with 40 GB free
        // was rejected with "not enough free space" for an operation that costs zero bytes.
        if !Storage.moveIsHardLink(from: src, to: dst) {
            let srcAllocated = (try? src.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize.map(Int64.init) ?? 0
            if let free = (try? destinationDir.resourceValues(
                    forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage,
               free > 0, srcAllocated > free {
                throw VeloxError.diskMove("Not enough free space at the destination "
                    + "(need \(Format.bytes(srcAllocated)), \(Format.bytes(free)) available).")
            }
        }

        let isActive = attachedDiskURL?.standardizedFileURL == src.standardizedFileURL
            || workspace.id == activeWorkspace?.id
        let wasRunning = isActive && (state.isRunning || state.isBusy)
        engineOwner = .movingDisk(name: workspace.name, progress: 0)
        defer { engineOwner = nil }

        // Flush + release the VZ file handle. If the engine won't stop, abort: copying a disk
        // the guest is still writing to yields a torn image, and the success path unlinks the
        // original — that's total data loss, not a degraded copy.
        if wasRunning, await performStop() == false {
            throw VeloxError.diskMove("The engine did not shut down, so the data disk can't be "
                + "moved safely. Quit and reopen Velox, then try again.")
        }
        guard !isTerminating else { return }
        try requireDetached(workspace, "move it")

        do {
            let id = workspace.id
            try await Task.detached(priority: .userInitiated) {
                // `relocate` stages the data at the destination, persists the new location,
                // and only then drops the original — so a crash anywhere in it leaves the
                // manifest pointing at a disk that exists.
                try WorkspaceStore.relocate(id: id, to: destinationDir) { [weak self] frac in
                    Task { @MainActor in
                        guard let self, let owner = self.engineOwner else { return }
                        self.engineOwner = owner.advanced(to: frac)
                    }
                }
            }.value
        } catch {
            if wasRunning { await performStart() }   // restore at the OLD location
            throw error
        }

        reloadWorkspaces()
        mirrorActiveWorkspaceIntoConfig()
        if wasRunning { await performStart() }
    }

    /// Copy the active workspace's disk location and size back into `config.json`.
    ///
    /// Redundant for this build — the manifest is the source of truth — and deliberately
    /// kept anyway, for a `velox` binary that predates workspaces (an app downgrade, or an
    /// older CLI still on `PATH`). Such a binary reads only `config.json`; without this
    /// mirror it would boot the *Default* workspace while the user believes they are on
    /// another one, and grow that disk to the wrong size. It also keeps the existing disk
    /// gauges and the `dataDiskMissing` guard correct with no changes.
    private func mirrorActiveWorkspaceIntoConfig() {
        guard let active = activeWorkspace else { return }
        let dir = active.dataDiskURL.deletingLastPathComponent().standardizedFileURL
        let mirrored = (dir == Paths.root.standardizedFileURL) ? nil : dir.path
        guard config.dataDirectory != mirrored || config.diskGiB != active.diskGiB else { return }
        config.dataDirectory = mirrored
        config.diskGiB = active.diskGiB
        saveConfig()
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
        // No VM holds a disk any more, so workspace operations are free to touch them.
        attachedDiskURL = nil
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
        scheduleSave()
    }

    /// Land the debounced write NOW. Called before a workspace switch, where "within the
    /// next 400 ms" means "after the world has changed underneath it".
    private func flushPendingSave() {
        guard let task = configSaveTask else { return }
        task.cancel()
        configSaveTask = nil
        saveConfig()
        if let active = activeWorkspace {
            try? WorkspaceStore.setDiskGiB(id: active.id, active.diskGiB)
        }
    }

    /// Trailing-debounced persistence for the slider-driven settings.
    ///
    /// One timer for both files. The workspace manifest picked up a slider of its own (disk
    /// size is per-workspace), and giving it a second debounce would mean two timers racing
    /// to write two files that have to agree — so the single trailing fire writes both.
    /// Explicit workspace mutations (create, rename, delete, switch) do NOT come through
    /// here; they persist immediately.
    private func scheduleSave() {
        configSaveTask?.cancel()
        configSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.saveConfig()
            if let active = self.activeWorkspace {
                try? WorkspaceStore.setDiskGiB(id: active.id, active.diskGiB)
            }
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
