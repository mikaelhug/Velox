import Foundation
import Virtualization

// Velox CLI entry point.

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
      velox start [--bind vlcmd|docker|both]
                      Boot the Linux guest engine (serial console on this terminal)
      velox status    Show host/environment info
      velox version   Show Velox and component versions
      velox update    Check GitHub for a newer Velox (--apply to install)
      velox help      Show this help

    --bind chooses which client CLIs target Velox (default: vlcmd):
      vlcmd   use the `vlcmd` wrapper          docker  bind the `docker` CLI (context)
      both    either `vlcmd` or `docker` works

    Talk to the engine with `vlcmd` (the Docker CLI for Velox):
      vlcmd ps -a            vlcmd run --rm hello-world

    Environment overrides:
      VELOX_KERNEL    path to guest kernel    (default ~/.velox/kernel)
      VELOX_INITRD    path to guest initrd    (default ~/.velox/initrd.img)
      VELOX_CMDLINE   kernel command line     (default "console=hvc0")
    """)
}

func runVersion() {
    print("Velox        v\(Versions.velox)")
    print("Kernel (OS)  \(Versions.kernelImage)")
    print("containerd   \(Versions.containerdImage)")
    print("Docker       \(Versions.dockerImage)")
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
        try Paths.ensureRoot()
        try Storage.ensureDataDisk(at: Paths.dataDisk, sizeGiB: 16)
        let image = try GuestImage.resolve()
        let config = try VMConfiguration.build(image: image, dataDisk: Paths.dataDisk)
        Log.info("booting guest: kernel=\(image.kernelURL.lastPathComponent) "
                 + "initrd=\(image.initrdURL?.lastPathComponent ?? "none") "
                 + "cmdline=\"\(image.kernelCommandLine)\"")

        let manager = VMManager()
        let bridge = VsockBridge(manager: manager)
        let proxy = DockerSocketProxy(
            socketPath: Paths.dockerSocket.path,
            guestPort: VsockPort.docker,
            bridge: bridge)
        let forwarder = PortForwarder(bridge: bridge)
        let watcher = DockerEventsWatcher(socketPath: Paths.dockerSocket.path) { ports in
            forwarder.reconcile(ports)
        }
        var unbindCLI: () -> Void = {}
        manager.onStop { error in
            unbindCLI()
            watcher.stop()
            forwarder.stopAll()
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
                unbindCLI()
                watcher.stop()
                forwarder.stopAll()
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
                    unbindCLI = CLIBinding.apply(bind, socketPath: Paths.dockerSocket.path)
                    watcher.start() // dynamic -p port forwarding
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
    return .vlcmd
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
