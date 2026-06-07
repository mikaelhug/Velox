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
            Label {
                Text("Velox is \(engine.state.label.lowercased())")
            } icon: {
                Image(nsImage: statusIcon)
            }
            .labelStyle(.titleAndIcon)

            Divider()

            Button("Open Dashboard") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: WindowID.dashboard)
            }
            .keyboardShortcut("d")

            Button("Settings") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: WindowID.settings)
            }
            .keyboardShortcut(",")

            Divider()

            engineControl

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

    private var statusIcon: NSImage {
        Self.tintedSymbol(engine.state.menuBarSymbol, color: statusColor)
    }

    private var statusColor: NSColor {
        switch engine.state {
        case .running: return .systemGreen
        case .starting, .stopping: return .systemYellow
        case .failed: return .systemRed
        case .stopped: return .systemRed
        }
    }

    private static func tintedSymbol(_ name: String, color: NSColor) -> NSImage {
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        let configured = symbol.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) ?? symbol
        let image = NSImage(size: NSSize(width: 16, height: 16))

        image.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        configured.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()

        image.isTemplate = false
        return image
    }
}
