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
@main
struct VeloxApp: App {
    @State private var engine = EngineController()

    init() {
        // Ignore SIGPIPE: writing to a socket whose peer has closed must surface as
        // an EPIPE error, not terminate the process. Essential for the proxy/relay/
        // watcher — the same disposition the `velox` CLI sets at startup. Without it
        // a BuildKit build (devcontainers `up`) half-closes its hijacked `/session`
        // stream and the next proxy write kills the whole GUI app.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        // Read engine state in `body` (not only inside the MenuBarExtra label
        // closure) so SwiftUI registers these as dependencies of the App and
        // rebuilds the menu-bar icon when they change. MenuBarExtra does NOT
        // reliably observe @Observable reads that happen lazily inside its label
        // closure, so the Resource Saver moon never appeared without this.
        let menuSymbol = engine.state.menuBarSymbol
        let saverActive = engine.isResourceSaving && engine.state.isRunning

        Window("Velox", id: WindowID.dashboard) {
            RootView()
                .environment(engine)
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
            // knocked in only while Resource Saver is idling the VM.
            MenuBarLabel(symbol: menuSymbol, saving: saverActive)
        }

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
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 560)
    }
}
