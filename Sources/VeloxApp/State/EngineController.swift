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

    /// The Docker API client, valid only while the engine is running. Dashboards
    /// read this; it rides an in-process VSOCK connection to the guest (Phase 2).
    private(set) var docker: DockerClient?

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
            let image = Self.guestImageAdvertisingShares(shareURLs)
            let vmConfig = try VMConfiguration.build(
                image: image,
                dataDisk: Paths.dataDisk,
                resources: resources,
                extraShares: shareURLs)

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
            // The VM has booted, but dockerd needs a few more seconds inside the
            // guest. Stay in `.starting` until it actually answers, so the
            // dashboards' first load succeeds (no transient "Connection reset by
            // peer" and no manual refresh).
            await waitForDockerReady(docker)
            state = .running
            Log.info("engine started in-process (GUI)")
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
        proxy?.stop()
        proxy = nil
        bridge = nil
        docker = nil
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

    /// Resolve the guest image and append `velox.shares=<base64>` to the kernel
    /// command line so the guest's on-boot mounter knows which VirtioFS tags to
    /// mount where (the host attaches the matching devices in `VMConfiguration`).
    private static func guestImageAdvertisingShares(_ shares: [URL]) -> GuestImage {
        // `resolve()` succeeds whenever onboarding passed; fall back defensively.
        let base = (try? GuestImage.resolve())
            ?? GuestImage(kernelURL: Paths.kernel, rootDiskURL: Paths.rootDisk,
                          kernelCommandLine: GuestImage.defaultCommandLine)
        let adverts = VMConfiguration.shareAdvertisement(for: shares)
        guard !adverts.isEmpty else { return base }
        let payload = adverts.map { "\($0.tag)\t\($0.path)" }.joined(separator: "\n")
        let encoded = Data(payload.utf8).base64EncodedString()
        return GuestImage(kernelURL: base.kernelURL, rootDiskURL: base.rootDiskURL,
                          kernelCommandLine: base.kernelCommandLine + " velox.shares=\(encoded)")
    }
}
