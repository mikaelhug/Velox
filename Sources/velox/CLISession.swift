import Foundation
import Virtualization
import VeloxCore

/// One `velox start` engine: boots the VM, wires the shared `EngineRuntime` onto it, and —
/// when Resource Saver is in nap mode — stops the VM while idle and boots it again on the next
/// Docker client (`EngineNap.swift`). The GUI's `EngineController` does the same for the app.
///
/// All transitions run on `queue`, so a nap, a wake and a Ctrl-C can't interleave. The VM's own
/// callbacks and the signal handlers hop onto it.
final class CLISession: @unchecked Sendable {
    let manager = VMManager()

    private let prefs: VeloxConfig
    private let workspace: Workspace
    private let resources: VMConfiguration.Resources
    private let dataDisk: URL
    private let bind: BindMode
    private let queue = DispatchQueue(label: "dev.velox.cli.session")

    private enum Phase { case booting, running, napping, napped, stopping }
    private var phase = Phase.booting
    private var runtime: EngineRuntime?
    private var saver: ResourceSaver?
    private var unbind: () -> Void = {}
    private var gate: NapGate?

    init(prefs: VeloxConfig, workspace: Workspace, resources: VMConfiguration.Resources, dataDisk: URL,
         bind: BindMode) {
        self.prefs = prefs
        self.workspace = workspace
        self.resources = resources
        self.dataDisk = dataDisk
        self.bind = bind
    }

    /// Boot the VM and wire the engine onto it. `handoff` is a wake: adopt the Docker socket and
    /// the clients the nap parked. Configuration is rebuilt every time — `velox.epoch` on the
    /// kernel cmdline must be the boot's own wall clock, never the first boot's.
    func boot(handoff: NapGate.Handoff?) {
        let config: VZVirtualMachineConfiguration
        do {
            let image = try GuestImage.resolve().advertising(shares: prefs.shareURLs)
            config = try VMConfiguration.build(
                image: image, dataDisk: dataDisk,
                resources: resources, extraShares: prefs.shareURLs,
                nestedVirtualization: prefs.nestedVirtualization)
            if handoff == nil {
                Log.info("booting guest: kernel=\(image.kernelURL.lastPathComponent) "
                         + "root=\(image.rootDiskURL.lastPathComponent) "
                         + "cmdline=\"\(image.kernelCommandLine)\"")
            }
        } catch {
            Log.error("\(error)")
            Self.discard(handoff)
            exit(1)
        }
        let started = DispatchTime.now()
        manager.start(configuration: config) { [self] result in
            queue.async { [self] in
                switch result {
                case .success:
                    wire(handoff: handoff, started: started)
                case .failure(let error):
                    Self.logBootFailure(error)
                    Self.discard(handoff)
                    exit(1)
                }
            }
        }
    }

    /// On `queue`, once the VM runs.
    private func wire(handoff: NapGate.Handoff?, started: DispatchTime) {
        guard phase == .booting else {
            // Ctrl-C landed during the boot: the stop it queued powers the VM off; the clients a
            // wake was carrying have nowhere to go.
            Self.discard(handoff)
            return
        }
        if handoff == nil {
            // Stamp the first successful boot only now that there IS one — the flag is what turns
            // a later missing disk into a loud failure instead of a silent blank re-create.
            WorkspaceStore.recordBoot(id: workspace.id)
        }
        // All the engine plumbing (Docker socket proxy, port forwarders, events watcher, named
        // access, clock sync, conduit pool) is shared with the GUI via EngineRuntime.
        let runtime = EngineRuntime(manager: manager, publish: prefs.publishBind)
        do {
            try runtime.start(adopting: handoff)
            self.runtime = runtime
            if handoff == nil {
                unbind = CLIBinding.apply(bind, socketPath: Paths.dockerSocket.path)
            }
            startSaver(runtime)
        } catch {
            Log.error("docker socket proxy failed to start: \(error)")
        }
        phase = .running
        if handoff == nil {
            Log.info("guest started — console follows (Ctrl-C to stop).")
        } else {
            let ms = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            Log.info("resource saver: engine resumed in \(ms) ms")
        }
    }

    /// Resource Saver stays outside EngineRuntime (the GUI re-arms its own on settings changes)
    /// but rides the runtime's Docker client and activity counter.
    private func startSaver(_ runtime: EngineRuntime) {
        guard prefs.resourceSaverEnabled else { return }
        let mode = ResourceSaver.modeForThisOS
        let saver = ResourceSaver(
            manager: manager, docker: runtime.docker,
            fullMemoryBytes: prefs.resources.memoryBytes,
            floorBytes: prefs.resourceSaverFloorBytes,
            idleMinutes: prefs.resourceSaverMinutes,
            mode: mode, activity: runtime.activity)
        if mode == .nap { saver.onNap = { [weak self] in self?.nap() } }
        saver.start()
        self.saver = saver
    }

    /// Idle stop (Resource Saver's `onNap`): release the Docker socket unless a request is in
    /// flight, then the shared `EngineNap.stop` sequence; the gate's first client calls `wake()`.
    private func nap() {
        queue.async { [self] in
            guard phase == .running, let runtime, runtime.releaseDockerSocketIfIdle() else {
                saver?.rearm()   // declined: count down again rather than never napping
                return
            }
            phase = .napping
            saver?.stop()
            saver = nil
            // `runtime` stays set until the outcome: a Ctrl-C meanwhile stops it, which closes the
            // released socket if the stop below hasn't claimed it yet.
            EngineNap.stop(runtime: runtime, manager: manager, deadline: 120,
                           onDemand: { [weak self] in self?.wake() }) { [self] outcome in
                queue.async { [self] in
                    switch outcome {
                    case .stopped(let gate):
                        guard phase == .napping else { gate.close(); return }   // Ctrl-C took over
                        self.runtime = nil
                        self.gate = gate
                        phase = .napped
                        gate.start()
                        Log.info("resource saver: engine stopped — resumes on the next Docker request")
                    case .cancelled:
                        return   // a stop overtook this one and owns the rest
                    case .stuck:
                        Log.error("resource saver: the engine did not stop — exiting")
                        _ = stopPlumbingLocked()
                        exit(1)
                    }
                }
            }
        }
    }

    private func wake() {
        queue.async { [self] in
            guard phase == .napped, let gate else { return }
            self.gate = nil
            phase = .booting
            boot(handoff: gate.handOff())
        }
    }

    /// Drop the host plumbing — same order as the GUI's `EngineController.teardown()`: stop
    /// accepting docker CLI connections and remove the host routes BEFORE flushing the guest.
    /// `waitForTeardown: true` is not optional: the named-access routes are installed
    /// out-of-process by the porthelper, and this process exits moments later, so an async
    /// removal would never run. From any thread except `queue`.
    ///
    /// Returns false when there is no VM to flush — the engine is stopped for idleness, and its
    /// guest was flushed and powered off then.
    @discardableResult
    func stopPlumbing() -> Bool {
        queue.sync { stopPlumbingLocked() }
    }

    /// `stopPlumbing` for code already on `queue`.
    private func stopPlumbingLocked() -> Bool {
        let vmMayRun = phase != .napped
        // Mid idle-stop, the socket is in flight inside `EngineNap.stop`, which would close it only
        // after the VM is down — and this process exits the moment that happens. Remove the path
        // now so `docker` isn't left facing a dead socket file.
        if phase == .napping { unlink(Paths.dockerSocket.path) }
        phase = .stopping
        gate?.close()
        gate = nil
        unbind()
        unbind = {}
        runtime?.stop(waitForTeardown: true)
        saver?.stop()
        return vmMayRun
    }

    private static func discard(_ handoff: NapGate.Handoff?) {
        NapGate.discard(handoff, socketPath: Paths.dockerSocket.path)
    }

    private static func logBootFailure(_ error: Error) {
        let ns = error as NSError
        Log.error("failed to start guest: \(error.localizedDescription)")
        Log.error("  domain=\(ns.domain) code=\(ns.code)")
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            Log.error("  underlying: \(underlying.domain) code=\(underlying.code) — "
                      + "\(underlying.localizedDescription)")
        }
        for (k, v) in ns.userInfo where k != NSUnderlyingErrorKey {
            Log.error("  userInfo[\(k)] = \(v)")
        }
    }
}
