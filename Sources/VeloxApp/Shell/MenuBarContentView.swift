import AppKit
import SwiftUI
import VeloxCore

/// The menu shown from the status-bar icon: engine status, start/stop, and
/// shortcuts into the dashboard and settings. Mirrors `velox start`/stop, but
/// in-process.
struct MenuBarContentView: View {
    @Environment(EngineController.self) private var engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Label("Velox \(Versions.velox) — \(engine.state.label)",
                  systemImage: engine.state.menuBarSymbol)
                .labelStyle(.titleAndIcon)

            if let failure = engine.state.failureMessage {
                Text(failure)
                    .font(.caption)
            }

            Divider()

            engineControl

            Button("Open Dashboard") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: WindowID.dashboard)
            }
            .keyboardShortcut("d")

            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit Velox") {
                Task {
                    await engine.stop()
                    NSApp.terminate(nil)
                }
            }
            .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private var engineControl: some View {
        if engine.needsOnboarding {
            Button("Finish Setup…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: WindowID.dashboard)
            }
        } else if engine.state.isRunning {
            Button("Stop Engine") { Task { await engine.stop() } }
        } else if engine.state.isBusy {
            Text(engine.state.label).foregroundStyle(.secondary)
        } else {
            Button("Start Engine") { Task { await engine.start() } }
        }
    }
}
