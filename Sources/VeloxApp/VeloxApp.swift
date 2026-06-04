import SwiftUI
import VeloxCore

/// Stable window identifiers used with `openWindow`.
enum WindowID {
    static let dashboard = "dashboard"
}

/// The Velox desktop app: a menu-bar engine controller plus a dashboard window
/// and a settings window. The engine runs in-process, so this single app both
/// hosts the VM and renders its Docker resources.
@main
struct VeloxApp: App {
    @State private var engine = EngineController()

    var body: some Scene {
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

        MenuBarExtra("Velox", systemImage: engine.state.menuBarSymbol) {
            MenuBarContentView()
                .environment(engine)
        }

        Settings {
            SettingsView()
                .environment(engine)
        }
    }
}
