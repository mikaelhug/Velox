import SwiftUI
import VeloxCore

/// Stable window identifiers used with `openWindow`.
enum WindowID {
    static let dashboard = "dashboard"
    static let settings = "settings"
    static let logs = "logs"
}

/// The Velox desktop app: a menu-bar engine controller plus a dashboard window
/// and a settings window. The engine runs in-process, so this single app both
/// hosts the VM and renders its Docker resources.
/// The single place the engine is stopped on the way out. ⌘Q, "Quit" from the Dock menu,
/// the menu-bar panel's Quit button and a logout-initiated terminate all arrive here — they
/// used to kill the process outright, so the guest's filesystems were never flushed. The
/// terminate is deferred until the flush + power-off finishes.
///
/// That stop runs **off the main actor** and its reply is delivered on the **run loop**, so
/// the guest still gets flushed when the UI is busy, and `NSApp.terminate` is safe to call
/// from anywhere — including inside a Task. See `replyOnMainRunLoop` for why that matters.
@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    /// Set once the app's engine exists; nil during early launch. Strong on purpose —
    /// a nil here silently skips the guest flush this whole class exists to guarantee,
    /// and the controller lives for the process anyway.
    static var engine: EngineController?
    /// Set alongside `engine`. Remote hosts own `ssh` child processes and unix sockets in
    /// `~/.velox/hosts/`; both must go when the app does, or the children are orphaned and
    /// their stale sockets block the next connect.
    static var remotes: RemoteHostController?
    private var stopping = false
    private var replied = false
    private var watchdog: Timer?
    /// Signalled when the engine shutdown finishes. Lets a *second* terminate request wait
    /// for the shutdown already in flight instead of having to choose between cancelling it
    /// and killing the guest. Nonisolated: the completion fires on a background queue.
    private nonisolated let shutdownDone = DispatchSemaphore(value: 0)

    /// Backstop only. The stop itself is bounded (`VMManager.stopGracefully` gives the guest
    /// flush 60 s) and runs off the main actor, so this should never fire.
    private static let stopDeadline: TimeInterval = 90

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cheap, synchronous, and independent of the VM shutdown below — do it first so it
        // happens even on the `.terminateNow` paths.
        MainActor.assumeIsolated { Self.remotes?.disconnectAll() }
        guard let engine = Self.engine else { return .terminateNow }
        // A second request — an impatient ⌘Q, or a logout/restart arriving while a ⌘Q
        // shutdown is still in flight (the guest `sync()` alone gets up to 60 s). Neither
        // simple answer is right: `.terminateNow` kills the guest mid-flush and tears the
        // ext4 image, `.terminateCancel` aborts the user's entire logout. So wait for the
        // shutdown already running and then answer truthfully. Blocking the main thread here
        // is safe *because* that shutdown is deliberately main-actor-independent — see
        // `EngineController.shutdownForTerminate`. Bounded, so a logout can't be held up
        // indefinitely, and it doubles as the escape hatch if the reply was already spent.
        if stopping {
            if shutdownDone.wait(timeout: .now() + Self.stopDeadline) == .timedOut {
                Log.warn("engine stop did not finish in \(Int(Self.stopDeadline))s — terminating anyway")
            }
            shutdownDone.signal()   // keep the gate open for any further request
            return .terminateNow
        }
        stopping = true
        engine.shutdownForTerminate {
            self.shutdownDone.signal()
            self.replyOnMainRunLoop()
        }
        armWatchdog()
        return .terminateLater
    }

    /// Answer AppKit's deferred terminate exactly once — the stop path and the
    /// watchdog both route through here, and a second reply is a hard AppKit error.
    private func reply() {
        guard !replied else { return }
        replied = true
        watchdog?.invalidate()
        watchdog = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Answer the deferred terminate from the **run loop**, not the main queue.
    ///
    /// This is the crux of the quit path. While AppKit waits out a `.terminateLater` it
    /// spins a nested run loop, and libdispatch refuses to re-enter the main-queue drain
    /// from inside one — so anything scheduled with `DispatchQueue.main` or an unstructured
    /// `Task` may never run, and the reply never arrives (the app then hangs with no way out
    /// but Force Quit). A `CFRunLoopPerformBlock` in the modes that nested loop actually
    /// runs always lands. Keeping the reply on this route is what makes the terminate safe
    /// no matter where `NSApp.terminate` was called from.
    nonisolated private func replyOnMainRunLoop() {
        RunLoop.main.perform(inModes: [.common, .default, .modalPanel]) {
            MainActor.assumeIsolated { self.reply() }
        }
    }

    /// Last-resort deadline, in case the stop never reports back at all. A run-loop timer
    /// for the same reason `replyOnMainRunLoop` exists — a dispatch-based one would not fire.
    private func armWatchdog() {
        let timer = Timer(timeInterval: Self.stopDeadline, repeats: false) { _ in
            MainActor.assumeIsolated {
                Log.warn("engine stop did not finish in \(Int(Self.stopDeadline))s — terminating anyway")
                self.reply()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        watchdog = timer
    }
}

@main
struct VeloxApp: App {
    @State private var engine = EngineController()
    /// Remote Docker hosts. Deliberately a *sibling* of `engine`, not a member: a remote
    /// host has no VM, no data disk and no instance lock, and folding it into the engine
    /// controller would blur exactly the line that keeps this feature cheap.
    @State private var remotes = RemoteHostController()
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var appDelegate

    init() {
        // Ignore SIGPIPE: writing to a socket whose peer has closed must surface as
        // an EPIPE error, not terminate the process. Essential for the proxy/relay/
        // watcher — the same disposition the `velox` CLI sets at startup. Without it
        // a BuildKit build (devcontainers `up`) half-closes its hijacked `/session`
        // stream and the next proxy write kills the whole GUI app.
        signal(SIGPIPE, SIG_IGN)
        MainActor.assumeIsolated {
            AppTerminationDelegate.engine = engine
            AppTerminationDelegate.remotes = remotes
        }
    }

    var body: some Scene {
        // Read engine state in `body` (not only inside the MenuBarExtra label
        // closure) so SwiftUI registers these as dependencies of the App and
        // rebuilds the menu-bar icon when they change. MenuBarExtra does NOT
        // reliably observe @Observable reads that happen lazily inside its label
        // closure, so the Resource Saver moon never appeared without this.
        let menuSymbol = engine.state.menuBarSymbol
        let saverActive = engine.isResourceSaving && engine.state.isRunning
        let runningCount = engine.state.isRunning
            ? (engine.resources?.containers.filter(\.isRunning).count ?? 0) : 0
        let updateAvailable = engine.availableUpdate?.isUpdateAvailable == true

        Window("Velox", id: WindowID.dashboard) {
            RootView()
                .environment(engine)
                .environment(remotes)
                .sheet(isPresented: Binding(
                    get: { engine.needsOnboarding },
                    set: { if !$0 { engine.completeOnboarding() } }
                )) {
                    OnboardingView()
                        .environment(engine)
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 920, height: 560)

        MenuBarExtra {
            MenuBarContentView()
                .environment(engine)
        } label: {
            // Same `Image(systemName:)` the old `systemImage:` form used (so it sizes
            // and tints identically to the original menu-bar icon), with a moon badge
            // knocked in only while Resource Saver is idling the VM, and the running-
            // container count beside it (only when non-zero).
            MenuBarLabel(symbol: menuSymbol, saving: saverActive, count: runningCount,
                         updateAvailable: updateAvailable)
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: WindowID.settings) {
            SettingsView()
                .environment(engine)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 720, height: 560)
        .defaultLaunchBehavior(.suppressed)
        .windowToolbarStyle(.unified)

        // One free-floating logs window per container (keyed by the target). Opened
        // from the Containers list's "View Logs"; multiple can be open at once.
        WindowGroup(id: WindowID.logs, for: LogWindowTarget.self) { $target in
            if let target {
                LogWindowHost(target: target)
                    .environment(engine)
                    .environment(remotes)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 560)
    }
}
