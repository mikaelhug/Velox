import Foundation
import Virtualization
import VeloxCore

// Velox CLI entry point.

/// Holds the CLI-binding teardown closure so it can be shared across the VM's
/// @Sendable stop/signal handlers (the closure itself isn't Sendable).
private final class Teardown: @unchecked Sendable {
    var run: () -> Void = {}
}

private func hostArch() -> String {
    #if arch(arm64)
    return "arm64"
    #else
    return "x86_64"
    #endif
}

func printUsage() {
    print("""
    Velox \(Versions.velox) — lightweight Docker engine host for macOS

    Usage:
      velox start [--bind none|docker]
                      Boot the Linux guest engine (serial console on this terminal)
      velox status    Show host/environment info
      velox version   Show Velox and component versions
      velox update    Check GitHub for a newer Velox (--apply to install)
      velox help      Show this help

    Velox is a standard Docker engine on a unix socket. Reach it with the plain
    `docker` CLI via the `velox` Docker context (created on start):
      docker context use velox     # then: docker ps / docker run …
      docker --context velox ps    # one-off, without switching
    Or set an env var:  export DOCKER_HOST=unix://~/.velox/docker.sock
    Prefer your own command? Alias it:  alias vdocker='docker --context velox'

    --bind controls the active Docker context on start (default: none):
      none    just create/update the `velox` context; don't change the active one
      docker  switch the active context to `velox` (restored when the engine stops)

    Environment overrides:
      VELOX_KERNEL    path to guest kernel       (default ~/.velox/kernel)
      VELOX_ROOT      path to erofs root image   (default ~/.velox/root.img)
      VELOX_CMDLINE   kernel command line        (default "console=hvc0")
    """)
}

func runVersion() {
    print("Velox        v\(Versions.velox)")
    print("Kernel (OS)  \(Versions.kernelVersion)")
    print("Docker       \(Versions.dockerVersion)")
}

func runStatus() {
    print("Velox \(Versions.velox)")
    print("Host: \(ProcessInfo.processInfo.operatingSystemVersionString) (\(hostArch()))")
    print("State dir: \(Paths.root.path)")
    let config = VZVirtualMachineConfiguration()
    _ = config // proves Virtualization.framework links
    print("Virtualization.framework: linked")
    #if !arch(arm64)
    print("warning: Velox targets Apple Silicon (arm64) first.")
    #endif
}

func runStart(bind: BindMode) -> Never {
    do {
        // The CLI honors the same ~/.velox/config.json the GUI writes, so
        // resources, swap, and file shares are consistent across both front ends.
        let prefs = VeloxConfig.load()
        try Paths.ensureRoot()
        try Storage.ensureDataDisk(at: Paths.dataDisk, sizeGiB: prefs.resources.diskGiB)

        let image = try GuestImage.resolve().advertising(shares: prefs.shareURLs)
        let config = try VMConfiguration.build(
            image: image, dataDisk: Paths.dataDisk,
            resources: prefs.resources, extraShares: prefs.shareURLs)
        Log.info("booting guest: kernel=\(image.kernelURL.lastPathComponent) "
                 + "root=\(image.rootDiskURL.lastPathComponent) "
                 + "cmdline=\"\(image.kernelCommandLine)\"")

        let manager = VMManager()
        let bridge = VsockBridge(manager: manager)
        let proxy = DockerSocketProxy(
            socketPath: Paths.dockerSocket.path,
            guestPort: VsockPort.docker,
            bridge: bridge)
        // Inbound published ports: watch the Docker API and reverse-forward each
        // published port over VSOCK to the guest (which dials 127.0.0.1:<port>).
        // The watcher rides the same in-process VSOCK Docker client the GUI uses and
        // is push-based (the /events stream), so ports come up near-instantly.
        // Privileged ports (<1024) route through the root helper (installed on first
        // use, with one admin prompt), so e.g. a reverse proxy on :80 reaches the Mac.
        let portHelper = PortHelperManager()
        let forwarder = PortForwarder(bridge: bridge, privilegedBinder: portHelper)
        let udpForwarder = UDPForwarder(manager: manager, privilegedBinder: portHelper)
        let docker = DockerClient(manager: manager)
        // Direct-dial endpoint map: the watcher fills it, the conduit pool reads it.
        let endpoints = PublishedEndpoints()
        let watcher = DockerEventsWatcher(docker: docker, onPorts: portHelper.reconciler(
            tcp: { forwarder.reconcile($0) },
            udp: { udpForwarder.reconcile($0) }), endpoints: endpoints)
        let clockSync = ClockSync(manager: manager)
        let resourceSaver: ResourceSaver? = prefs.resourceSaverEnabled
            ? ResourceSaver(manager: manager, docker: docker,
                            fullMemoryBytes: prefs.resources.memoryBytes,
                            floorBytes: prefs.resourceSaverFloorBytes,
                            idleMinutes: prefs.resourceSaverMinutes)
            : nil
        let teardown = Teardown()
        manager.onStop { error in
            teardown.run()
            watcher.stop()
            forwarder.stopAll()
            udpForwarder.stopAll()
            clockSync.stop()
            resourceSaver?.stop()
            proxy.stop()
            exit(error == nil ? 0 : 1)
        }

        // Graceful shutdown on Ctrl-C / SIGTERM: request an ACPI power-off so
        // the guest unmounts and flushes the data disk before exiting.
        var signalSources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Log.info("signal \(sig) — flushing and stopping guest…")
                teardown.run()
                watcher.stop()
                forwarder.stopAll()
                clockSync.stop()
                resourceSaver?.stop()
                proxy.stop()
                manager.stopGracefully { exit(0) }
            }
            source.resume()
            signalSources.append(source)
        }
        _ = signalSources // keep alive

        manager.start(configuration: config) { result in
            switch result {
            case .success:
                do {
                    try proxy.start()
                    teardown.run = CLIBinding.apply(bind, socketPath: Paths.dockerSocket.path)
                    watcher.start() // dynamic -p port forwarding
                    clockSync.start() // keep guest clock aligned across host sleep
                    resourceSaver?.start() // reclaim RAM while idle
                    // Fast published-port datapath: learn the VZNAT gateway from the guest,
                    // then bind a warm conduit pool so published ports ride VZNAT (~95/~17)
                    // instead of the vsock relay. Best-effort; falls back to vsock on failure.
                    Task {
                        guard let info = await GatewayProbe.probe(manager: manager) else { return }
                        let pool = ConduitPool(gateway: info, endpoints: endpoints)
                        do { try pool.start(); forwarder.attachConduitPool(pool) }
                        catch { Log.warn("conduit pool failed to start: \(error); using vsock fallback") }
                    }
                } catch {
                    Log.error("docker socket proxy failed to start: \(error)")
                }
                Log.info("guest started — console follows (Ctrl-C to stop).")
            case .failure(let error):
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
                exit(1)
            }
        }

        dispatchMain() // park main thread; exits via onStop handler
    } catch {
        Log.error("\(error)")
        exit(1)
    }
}

// MARK: - Dispatch

func parseBind(_ args: [String]) -> BindMode {
    if let i = args.firstIndex(of: "--bind"), i + 1 < args.count,
       let mode = BindMode(rawValue: args[i + 1].lowercased()) {
        return mode
    }
    return .none
}

// Ignore SIGPIPE: writing to a socket whose peer has closed must surface as an
// EPIPE error, not terminate the process. Essential for the proxy/relay/watcher.
signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "start":
    runStart(bind: parseBind(arguments))
case "status":
    runStatus()
case "version", "--version", "-v":
    runVersion()
case "update":
    Updater.check(apply: arguments.contains("--apply"))
case "help", "-h", "--help":
    printUsage()
case .none:
    printUsage()
default:
    Log.error("unknown command: \(arguments[0])")
    printUsage()
    exit(2)
}
