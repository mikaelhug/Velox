import Foundation
import Virtualization
import VeloxCore

// Velox CLI entry point.

/// Holds the CLI-binding teardown closure and the engine runtime so they can be
/// shared across the VM's @Sendable stop/signal handlers (the runtime is created
/// only once the VM has started).
private final class Teardown: @unchecked Sendable {
    var run: () -> Void = {}
    var runtime: EngineRuntime?
    var saver: ResourceSaver?
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
    if ForwardingGuard.forwardingEnabled() == false {
        print("warning: net.inet.ip.forwarding is OFF (a VPN client likely disabled "
              + "it) — containers have no internet until a running engine restores it, "
              + "or: sudo sysctl -w net.inet.ip.forwarding=1")
    }
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
        let dataDisk = prefs.dataDiskURL
        // A relocated data disk that's gone (drive unplugged / deleted) must fail loudly, not be
        // silently recreated empty. A missing disk at the DEFAULT location is a legit first run.
        if prefs.dataDirectory != nil && !FileManager.default.fileExists(atPath: dataDisk.path) {
            throw VeloxError.dataDiskMissing(dataDisk)
        }
        try Storage.ensureDataDisk(at: dataDisk, sizeGiB: prefs.resources.diskGiB)
        // After an app update, refresh the installed guest from the (newer) bundled copy so we
        // never boot a stale ~/.velox kernel/rootfs against a new host.
        GuestInstall.refreshFromBundleIfNeeded()

        let image = try GuestImage.resolve().advertising(shares: prefs.shareURLs)
        let config = try VMConfiguration.build(
            image: image, dataDisk: dataDisk,
            resources: prefs.resources, extraShares: prefs.shareURLs,
            nestedVirtualization: prefs.nestedVirtualization)
        Log.info("booting guest: kernel=\(image.kernelURL.lastPathComponent) "
                 + "root=\(image.rootDiskURL.lastPathComponent) "
                 + "cmdline=\"\(image.kernelCommandLine)\"")

        let manager = VMManager()
        let teardown = Teardown()
        manager.onStop { error in
            teardown.run()
            teardown.runtime?.stop()
            teardown.saver?.stop()
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
                teardown.runtime?.stop()
                teardown.saver?.stop()
                manager.stopGracefully { exit(0) }
            }
            source.resume()
            signalSources.append(source)
        }
        _ = signalSources // keep alive

        manager.start(configuration: config) { result in
            switch result {
            case .success:
                // All the engine plumbing (Docker socket proxy, port forwarders, events
                // watcher, named access, clock sync, conduit pool) is shared with the
                // GUI via EngineRuntime — one wiring, no CLI/GUI drift.
                let runtime = EngineRuntime(manager: manager)
                do {
                    try runtime.start()
                    teardown.runtime = runtime
                    teardown.run = CLIBinding.apply(bind, socketPath: Paths.dockerSocket.path)
                    // Resource Saver stays outside EngineRuntime (the GUI re-arms its
                    // own on settings changes) but rides the runtime's Docker client.
                    if prefs.resourceSaverEnabled {
                        let saver = ResourceSaver(
                            manager: manager, docker: runtime.docker,
                            fullMemoryBytes: prefs.resources.memoryBytes,
                            floorBytes: prefs.resourceSaverFloorBytes,
                            idleMinutes: prefs.resourceSaverMinutes)
                        saver.start() // reclaim RAM while idle
                        teardown.saver = saver
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
