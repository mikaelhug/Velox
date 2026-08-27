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
      velox start [--bind none|docker] [--workspace <name>]
                      Boot the Linux guest engine (serial console on this terminal)
      velox status    Show host/environment info
      velox workspace Manage workspaces (see below)
      velox version   Show Velox and component versions
      velox update    Check GitHub for a newer Velox (--apply to install)
      velox help      Show this help

    Workspaces — each one is a complete, isolated engine state (its own containers,
    images, volumes, networks and build cache). Exactly one is active at a time:
      velox workspace ls                     List workspaces (* marks the active one)
      velox workspace info [<name>]          Show one workspace in detail
      velox workspace new <name> [--size N]  Create an empty workspace (N in GB)
      velox workspace clone <name> <new>     Duplicate one (instant on APFS, no extra space)
      velox workspace use <name>             Make it active (takes effect on next start)
      velox workspace rename <old> <new>     Rename one
      velox workspace rm <name>              Delete one and its data, permanently
    Everything except container data is shared: the docker socket path never changes,
    so `docker` follows the active workspace with no reconfiguration.

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
      VELOX_HOME      state directory            (default ~/.velox)
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

func runStart(bind: BindMode, workspaceName: String?) -> Never {
    do {
        // The CLI honors the same ~/.velox/config.json the GUI writes, so
        // resources, swap, and file shares are consistent across both front ends.
        let prefs = VeloxConfig.load()
        try Paths.ensureRoot()
        // Refuse to boot a second engine (the app or another `velox start`): two would
        // attach the same data.img read-write and corrupt it. Held for the whole process.
        try InstanceLock.acquireForProcess(at: Paths.engineLock)

        // `--workspace` sets the active one persistently rather than booting it just for
        // this run: a one-shot would leave the GUI's sidebar showing a different workspace
        // than the one actually running, which is worse than an explicit switch.
        if let workspaceName {
            guard let target = try WorkspaceStore.load().workspace(named: workspaceName) else {
                throw VeloxError.workspace("No workspace named “\(workspaceName)”. "
                    + "Run `velox workspace ls` to see them.")
            }
            try WorkspaceStore.activate(id: target.id)
        }
        let manifest = try WorkspaceStore.load()
        let workspace = manifest.active
        let resources = prefs.resources(diskGiB: workspace.diskGiB)
        let dataDisk = workspace.dataDiskURL
        // A disk that's gone (drive unplugged / deleted) must fail loudly, not be silently
        // recreated empty. A missing disk for a workspace that has NEVER booted is a legit
        // first run — that distinction, not "did the user relocate it", is what tells a
        // brand-new workspace apart from a broken one.
        if workspace.firstBootedAt != nil,
           !FileManager.default.fileExists(atPath: dataDisk.path) {
            throw VeloxError.dataDiskMissing(dataDisk)
        }
        try Storage.ensureDataDisk(at: dataDisk, sizeGiB: resources.diskGiB)
        WorkspaceStore.recordBoot(id: workspace.id)
        Log.info("workspace: \(workspace.name) (\(dataDisk.path))")
        // After an app update, refresh the installed guest from the (newer) bundled copy so we
        // never boot a stale ~/.velox kernel/rootfs against a new host.
        GuestInstall.refreshFromBundleIfNeeded()

        let image = try GuestImage.resolve().advertising(shares: prefs.shareURLs)
        let config = try VMConfiguration.build(
            image: image, dataDisk: dataDisk,
            resources: resources, extraShares: prefs.shareURLs,
            nestedVirtualization: prefs.nestedVirtualization)
        Log.info("booting guest: kernel=\(image.kernelURL.lastPathComponent) "
                 + "root=\(image.rootDiskURL.lastPathComponent) "
                 + "cmdline=\"\(image.kernelCommandLine)\"")

        let manager = VMManager()
        let teardown = Teardown()

        // Drop the host plumbing — same order as the GUI's `EngineController.teardown()`:
        // stop accepting docker CLI connections and remove the host routes BEFORE flushing
        // the guest. `waitForTeardown: true` is not optional here: the named-access routes
        // are installed out-of-process by the porthelper, and this process calls `exit`
        // moments later, so an async removal would simply never run and the routes would be
        // left pointing at a dead VM. Bounded (3 s per porthelper round-trip).
        let stopPlumbing: @Sendable () -> Void = {
            teardown.run()
            teardown.runtime?.stop(waitForTeardown: true)
            teardown.saver?.stop()
        }
        manager.onStop { error in
            stopPlumbing()
            exit(error == nil ? 0 : 1)
        }

        // Graceful shutdown on Ctrl-C / SIGTERM: request an ACPI power-off so
        // the guest unmounts and flushes the data disk before exiting.
        var signalSources: [DispatchSourceSignal] = []
        let interrupted = Locked(false)
        // SIGHUP and SIGQUIT too: the engine is normally attached to a terminal, so closing
        // the window (SIGHUP) used to take the default action — killing the process with no
        // guest flush and no host-route cleanup.
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                // Second Ctrl-C escalates. The disposition is SIG_IGN, so without this the
                // terminal is dead to the user for the whole flush window (up to 60 s) with
                // no way out but `kill -9` — and each extra signal would only queue another
                // graceful stop.
                if interrupted.value {
                    Log.warn("second signal — exiting now; the guest may not be flushed")
                    exit(1)
                }
                interrupted.value = true
                Log.info("signal \(sig) — flushing and stopping guest…")
                stopPlumbing()
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
                let runtime = EngineRuntime(manager: manager, publish: prefs.publishBind)
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

// MARK: - Workspaces

/// Whether an engine (the app, or another `velox start`) currently holds the instance lock.
///
/// Probed by taking the lock and immediately releasing it — the same `flock` the engine
/// itself uses, so the answer is authoritative at the instant it is asked.
func engineIsRunning() -> Bool {
    let fd = open(Paths.engineLock.path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
    flock(fd, LOCK_UN)
    return false
}

/// Refuse a mutating workspace command while an engine is running.
///
/// Not merely conservative. There is no `velox stop` — a `velox start` process *is* the
/// engine and is stopped with a signal — so this process cannot restart a running one to
/// apply a switch. And the GUI holds the workspace list in memory, so a write landing
/// underneath it would be overwritten by its next save. (Correctness against genuinely
/// concurrent writers comes from the manifest lock inside `WorkspaceStore`; this is the
/// friendlier refusal that keeps users out of that situation in the first place.)
func requireStoppedEngine(_ action: String) throws {
    guard !engineIsRunning() else {
        throw VeloxError.workspace(
            "Velox is running, so it can't \(action) right now. Stop the engine first "
            + "(quit the Velox app, or press Ctrl-C in the terminal running `velox start`).")
    }
}

func workspaceNamed(_ name: String, in manifest: WorkspaceManifest) throws -> Workspace {
    guard let w = manifest.workspace(named: name) else {
        throw VeloxError.workspace("No workspace named “\(name)”. "
            + "Run `velox workspace ls` to see them.")
    }
    return w
}

func runWorkspace(_ args: [String]) -> Never {
    do {
        let manifest = try WorkspaceStore.load()
        switch args.first {
        case "ls", "list", .none:
            // Allocated (not apparent) size: the images are sparse, and on APFS a clone
            // shares its blocks, so this is what the workspace actually occupies today.
            let width = max(4, manifest.workspaces.map(\.name.count).max() ?? 4)
            print("  \("NAME".padding(toLength: width, withPad: " ", startingAt: 0))  "
                  + "\("SIZE".padding(toLength: 9, withPad: " ", startingAt: 0))  MAX   LOCATION")
            for w in manifest.workspaces.sorted(by: { $0.created < $1.created }) {
                let marker = w.id == manifest.activeID ? "*" : " "
                let name = w.name.padding(toLength: width, withPad: " ", startingAt: 0)
                let size = w.allocatedDescription.padding(toLength: 9, withPad: " ", startingAt: 0)
                let max = "\(w.diskGiB)G".padding(toLength: 5, withPad: " ", startingAt: 0)
                let dir = (w.dataDiskURL.deletingLastPathComponent().path as NSString)
                    .abbreviatingWithTildeInPath
                print("\(marker) \(name)  \(size)  \(max) \(dir)")
            }

        case "info":
            let w = args.count > 1 ? try workspaceNamed(args[1], in: manifest) : manifest.active
            print("Name        \(w.name)")
            print("Active      \(w.id == manifest.activeID ? "yes" : "no")")
            print("Disk        \(w.dataDiskURL.path)")
            print("Used        \(w.allocatedDescription) of \(w.diskGiB) GB max")
            print("Created     \(w.created.formatted())")
            print("Last used   \(w.lastUsed.formatted())")
            print("First boot  \(w.firstBootedAt?.formatted() ?? "never started")")
            if w.diskExists && !Storage.dataDiskIsClean(at: w.dataDiskURL) {
                print("State       not cleanly shut down — start it once before duplicating")
            }

        case "new", "create":
            guard args.count > 1 else { throw VeloxError.workspace("Usage: velox workspace new <name> [--size N]") }
            try requireStoppedEngine("create a workspace")
            var size = manifest.active.diskGiB
            if let i = args.firstIndex(of: "--size"), i + 1 < args.count,
               let n = Int(args[i + 1]) { size = n }
            let created = try WorkspaceStore.create(name: args[1], diskGiB: size)
            print("Created workspace “\(created.name)” (\(size) GB max) at "
                  + "\(created.dataDiskURL.path)")
            print("Run `velox workspace use \(created.name)` to switch to it.")

        case "clone", "duplicate":
            guard args.count > 2 else { throw VeloxError.workspace("Usage: velox workspace clone <name> <new-name>") }
            try requireStoppedEngine("duplicate a workspace")
            let source = try workspaceNamed(args[1], in: manifest)
            let copy = try WorkspaceStore.clone(id: source.id, newName: args[2])
            print("Duplicated “\(source.name)” → “\(copy.name)” at \(copy.dataDiskURL.path)")

        case "use", "switch":
            guard args.count > 1 else { throw VeloxError.workspace("Usage: velox workspace use <name>") }
            try requireStoppedEngine("switch workspaces")
            let target = try workspaceNamed(args[1], in: manifest)
            try WorkspaceStore.activate(id: target.id)
            print("Active workspace is now “\(target.name)”. Start Velox to use it.")

        case "rename":
            guard args.count > 2 else { throw VeloxError.workspace("Usage: velox workspace rename <old> <new>") }
            let target = try workspaceNamed(args[1], in: manifest)
            try WorkspaceStore.rename(id: target.id, to: args[2])
            print("Renamed “\(target.name)” → “\(args[2])”")

        case "rm", "remove", "delete":
            guard args.count > 1 else { throw VeloxError.workspace("Usage: velox workspace rm <name>") }
            try requireStoppedEngine("delete a workspace")
            let target = try workspaceNamed(args[1], in: manifest)
            // Check what would refuse the delete BEFORE asking the user to type the name.
            // `WorkspaceStore.delete` re-checks both under the manifest lock; this is only so
            // nobody is made to confirm a deletion that was never going to happen.
            guard manifest.workspaces.count > 1 else {
                throw VeloxError.workspace(
                    "“\(target.name)” is the only workspace — Velox needs at least one.")
            }
            guard manifest.activeID != target.id else {
                throw VeloxError.workspace("“\(target.name)” is the active workspace. "
                    + "Switch to another one first: velox workspace use <other>")
            }
            // Deleting a workspace destroys its containers, images and volumes with no way
            // back, so make the user type the name rather than accept a bare `-f`.
            print("This permanently deletes “\(target.name)” and everything in it "
                  + "(\(target.allocatedDescription) at \(target.dataDiskURL.path)).")
            print("Type the workspace name to confirm: ", terminator: "")
            let typed = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard Workspace.normalized(typed) == Workspace.normalized(target.name) else {
                print("Not deleted.")
                exit(1)
            }
            try WorkspaceStore.delete(id: target.id)
            print("Deleted “\(target.name)”.")

        default:
            Log.error("unknown workspace command: \(args[0])")
            printUsage()
            exit(2)
        }
        exit(0)
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

/// `--workspace <name>` for `velox start`.
func parseWorkspace(_ args: [String]) -> String? {
    guard let i = args.firstIndex(of: "--workspace"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// Ignore SIGPIPE: writing to a socket whose peer has closed must surface as an
// EPIPE error, not terminate the process. Essential for the proxy/relay/watcher.
signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "start":
    runStart(bind: parseBind(arguments), workspaceName: parseWorkspace(arguments))
case "status":
    runStatus()
case "workspace", "workspaces", "ws":
    runWorkspace(Array(arguments.dropFirst()))
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
