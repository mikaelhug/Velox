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

    /// Wall-clock time the engine reached `.running`, for the Overview uptime
    /// readout. Cleared whenever the engine stops or fails.
    private(set) var startedAt: Date?

    /// True when guest artifacts or host virtualization support are missing, so
    /// the shell should present onboarding instead of arming Start.
    private(set) var needsOnboarding: Bool

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

    // Engine plumbing — created on `start`, torn down on stop.
    private let manager = VMManager()
    private var bridge: VsockBridge?
    private var proxy: DockerSocketProxy?
    private var forwarder: PortForwarder?
    private var udpForwarder: UDPForwarder?
    private var watcher: DockerEventsWatcher?
    private var clockSync: ClockSync?
    private var resourceSaver: ResourceSaver?
    /// Live ring buffer of the guest serial console (kernel + vinit + dockerd),
    /// surfaced by the Engine Logs view. Fed from the VM's console pipe.
    let engineLog = EngineLogStore()
    private var consolePipe: Pipe?
    /// Memory the running VM actually booted with — Resource Saver restores to
    /// this, not to an edited-but-unapplied value in `config`.
    private var bootedMemoryBytes: UInt64 = 0

    /// The Docker API client, valid only while the engine is running. Dashboards
    /// read this; it rides an in-process VSOCK connection to the guest (Phase 2).
    private(set) var docker: DockerClient?

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
        needsOnboarding = !EngineController.isReady
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
        Task.detached(priority: .userInitiated) {
            Updater.applyLatestUpdate()
            await MainActor.run { [weak self] in self?.updateInProgress = false }
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

    /// Re-evaluate readiness (e.g. after onboarding installs the guest image).
    func refreshReadiness() {
        needsOnboarding = !EngineController.isReady
    }

    /// Dismiss onboarding explicitly (user finished or chose to continue anyway).
    func completeOnboarding() {
        needsOnboarding = false
    }

    // MARK: - Lifecycle

    func start() async {
        guard state.isStopped || state.failureMessage != nil else { return }
        state = .starting
        do {
            let resources = config.resources
            let shareURLs = config.shareURLs
            try Paths.ensureRoot()
            try Storage.ensureDataDisk(at: Paths.dataDisk, sizeGiB: resources.diskGiB)
            let image = (try? GuestImage.resolve())?.advertising(shares: shareURLs)
                ?? GuestImage(kernelURL: Paths.kernel, rootDiskURL: Paths.rootDisk,
                              kernelCommandLine: GuestImage.defaultCommandLine)
            // Capture the guest serial console (kernel + vinit + dockerd) for the
            // Engine Logs view: hand the VM a pipe as its console write end and drain
            // the read end into the ring buffer. (The CLI keeps stdout.)
            let pipe = Pipe()
            consolePipe = pipe
            engineLog.attach(pipe.fileHandleForReading)
            let vmConfig = try VMConfiguration.build(
                image: image,
                dataDisk: Paths.dataDisk,
                resources: resources,
                extraShares: shareURLs,
                consoleOutput: pipe.fileHandleForWriting)

            // Unexpected guest exits / crashes route here too.
            manager.onStop { [weak self] error in
                Task { @MainActor in self?.handleGuestStopped(error) }
            }

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                manager.start(configuration: vmConfig) { result in
                    cont.resume(with: result)
                }
            }

            // Engine is up: expose the unix socket for the `docker` CLI (via the
            // `velox` context), and open the in-process Docker client for the dashboards.
            let bridge = VsockBridge(manager: manager)
            let proxy = DockerSocketProxy(
                socketPath: Paths.dockerSocket.path,
                guestPort: VsockPort.docker,
                bridge: bridge)
            try proxy.start()
            self.bridge = bridge
            self.proxy = proxy
            let docker = DockerClient(manager: manager)
            self.docker = docker
            appliedSignature = config.bootSignature
            bootedMemoryBytes = resources.memoryBytes

            // Reverse-forward published container ports to localhost (watch the
            // Docker API for -p ports, open 127.0.0.1 listeners, pipe over VSOCK).
            let forwarder = PortForwarder(bridge: bridge)
            let udpForwarder = UDPForwarder(manager: manager)
            let watcher = DockerEventsWatcher(docker: docker) { tcp, udp in
                forwarder.reconcile(tcp)
                udpForwarder.reconcile(udp)
            }
            watcher.start()
            self.forwarder = forwarder
            self.udpForwarder = udpForwarder
            self.watcher = watcher

            // Keep the guest clock aligned with the host (survives Mac sleep), and
            // arm Resource Saver to reclaim RAM while idle.
            let clockSync = ClockSync(manager: manager)
            clockSync.start()
            self.clockSync = clockSync
            startResourceSaver()
            // The VM has booted, but dockerd needs a few more seconds inside the
            // guest. Stay in `.starting` until it actually answers, so the
            // dashboards' first load succeeds (no transient "Connection reset by
            // peer" and no manual refresh).
            await waitForDockerReady(docker)
            startedAt = Date()
            state = .running
            Log.info("engine started in-process (GUI)")
            // First-run only: install terminal CLIs + the `velox` context and offer to
            // switch if needed. Backgrounded so it never delays the UI flipping to running.
            Task { await self.setUpTerminalAndContext() }
        } catch {
            cleanup()
            state = .failed(error.localizedDescription)
            Log.error("engine start failed: \(error.localizedDescription)")
        }
    }

    func stop() async {
        guard state.isRunning || state.isBusy else { return }
        state = .stopping
        proxy?.stop()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            manager.stopGracefully { cont.resume() }
        }
        // `handleGuestStopped` typically lands first via the delegate; this is a
        // backstop so the UI never sticks on "Stopping…".
        if state == .stopping { handleGuestStopped(nil) }
    }

    func restart() async {
        await stop()
        await start()
    }

    // MARK: - Internals

    private func handleGuestStopped(_ error: Error?) {
        cleanup()
        if let error {
            state = .failed(error.localizedDescription)
        } else {
            state = .stopped
        }
    }

    private func cleanup() {
        startedAt = nil
        watcher?.stop()
        watcher = nil
        forwarder?.stopAll()
        forwarder = nil
        udpForwarder?.stopAll()
        udpForwarder = nil
        proxy?.stop()
        proxy = nil
        bridge = nil
        docker = nil
        clockSync?.stop()
        clockSync = nil
        resourceSaver?.stop()
        resourceSaver = nil
        // Stop draining the (now-closing) console pipe; a restart attaches a fresh one.
        // Keep the buffered lines so the user can read why the engine stopped.
        engineLog.detach()
        consolePipe = nil
    }

    /// (Re)arm Resource Saver from the current config. Called on start and again
    /// whenever the user toggles it or changes the idle timer in Settings, so the
    /// change takes effect without an engine restart.
    private func startResourceSaver() {
        resourceSaver?.stop()
        resourceSaver = nil
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
        saver.start()
        resourceSaver = saver
    }

    /// Persist preferences and apply the live-tunable ones (Resource Saver) to a
    /// running engine. Settings calls this on change.
    func applyRuntimeConfig() {
        saveConfig()
        if state.isRunning { startResourceSaver() }
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

    /// Poll dockerd until it answers (it comes up a few seconds after the VM
    /// boots). Best-effort: returns after ~30s even if it never responds, so the
    /// UI doesn't hang on a broken guest.
    private func waitForDockerReady(_ docker: DockerClient) async {
        for _ in 0..<120 {
            if await docker.ping() { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        Log.warn("dockerd did not respond within 30s — continuing")
    }
}
