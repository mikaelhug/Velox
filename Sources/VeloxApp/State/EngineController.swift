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

    init() {
        config = VeloxConfig.load()
        needsOnboarding = !EngineController.isReady
        // Autostart the engine on app launch (unless onboarding is needed). Skipped
        // under SwiftUI previews so the canvas doesn't try to boot a VM.
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        if !needsOnboarding && !isPreview {
            Task { await self.start() }
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
            let watcher = DockerEventsWatcher(docker: docker) { ports in
                forwarder.reconcile(ports)
            }
            watcher.start()
            self.forwarder = forwarder
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
            state = .running
            Log.info("engine started in-process (GUI)")
            // Register the `velox` docker context and, if it isn't already
            // active, offer (once) to switch to it. Fire-and-forget so it never
            // delays the UI flipping to running.
            Task { await self.maybeOfferContextSwitch() }
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
        watcher?.stop()
        watcher = nil
        forwarder?.stopAll()
        forwarder = nil
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

    /// Ensure the `velox` Docker context exists (so `docker --context velox` and a
    /// manual `docker context use velox` always work), then — if it isn't already
    /// the active context and we haven't asked before — raise the switch prompt.
    /// The `docker` shell-outs are blocking, so they run off the main actor.
    private func maybeOfferContextSwitch() async {
        let socket = Paths.dockerSocket.path
        let active = await Task.detached(priority: .utility) { () -> String? in
            guard CLIBinding.ensureContext(socketPath: socket) else { return nil }
            return CLIBinding.activeContext()
        }.value
        guard let active else { return }            // `docker` CLI not installed
        if active != "velox" && !config.contextPromptShown {
            showContextPrompt = true
        }
    }

    /// User accepted: make `velox` the active Docker context.
    func adoptVeloxContext() {
        showContextPrompt = false
        config.contextPromptShown = true
        saveConfig()
        Task.detached(priority: .utility) {
            if CLIBinding.useVeloxContext() {
                Log.info("active docker context switched to velox")
            } else {
                Log.warn("failed to switch docker context to velox")
            }
        }
    }

    /// User declined: don't switch, and don't ask again.
    func declineVeloxContext() {
        showContextPrompt = false
        config.contextPromptShown = true
        saveConfig()
    }

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
