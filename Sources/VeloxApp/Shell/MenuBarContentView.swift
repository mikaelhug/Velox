import AppKit
import SwiftUI
import VeloxCore

/// The menu-bar quick panel (`.window` style): engine status + control, the running
/// containers with their launchpads (ports, domain, stop), a live CPU/MEM line, and
/// shortcuts into the dashboard. Most day-to-day interactions are a glance-and-click
/// here that never opens the dashboard. The panel's body is evaluated only while it's
/// open and the stats streams are retained only then — closed, it costs nothing.
struct MenuBarContentView: View {
    @Environment(EngineController.self) private var engine
    @Environment(\.openWindow) private var openWindow

    private static let maxRows = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if engine.state.isRunning, let store = engine.resources {
                let running = store.containers.filter(\.isRunning)
                Divider()
                if running.isEmpty {
                    Text("No running containers")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 2)
                } else {
                    // Up to 7 rows render inline; beyond that the full list scrolls in
                    // a fixed-height viewport (like the Wi-Fi menu) — every container
                    // stays reachable, the panel never grows past the screen.
                    let rows = VStack(alignment: .leading, spacing: 7) {
                        ForEach(running) { c in
                            ContainerQuickRow(container: c) {
                                Task { try? await engine.docker?.stopContainer(c.id) }
                            }
                        }
                    }
                    if running.count <= Self.maxRows {
                        rows
                    } else {
                        ScrollView { rows }.frame(height: 280)
                    }
                    if let stats = engine.stats { UsageLine(stats: stats) }
                }
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 300)
        .modifier(RetainStatsIfPresent(stats: engine.state.isRunning ? engine.stats : nil))
    }

    // MARK: header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Label { Text(statusText).font(.callout.weight(.medium)) }
                icon: { Image(nsImage: statusIcon) }
                .labelStyle(.titleAndIcon)
            Spacer()
            engineControl
        }
    }

    @ViewBuilder
    private var engineControl: some View {
        if engine.needsOnboarding {
            Button("Finish Setup…") { openDashboard() }.controlSize(.small)
        } else if engine.state.isRunning {
            Button("Stop") { Task { await engine.stop() } }.controlSize(.small)
        } else if engine.state.isBusy {
            ProgressView().controlSize(.small)
        } else {
            Button("Start") { Task { await engine.start() } }.controlSize(.small)
        }
    }

    private var footer: some View {
        HStack {
            Button("Dashboard") { openDashboard() }.keyboardShortcut("d")
            Button("Settings") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: WindowID.settings)
            }
            .keyboardShortcut(",")
            Spacer()
            Button("Quit") {
                Task { await engine.stop(); NSApp.terminate(nil) }
            }
            .keyboardShortcut("q")
        }
        .controlSize(.small)
    }

    private func openDashboard() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: WindowID.dashboard)
    }

    /// Status line. While Resource Saver is reclaiming idle RAM, say so — it
    /// matches the moon badge on the menu-bar icon.
    private var statusText: String {
        if engine.state.isRunning && engine.isResourceSaving { return "Velox is idle" }
        return "Velox is \(engine.state.label.lowercased())"
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

/// One running container in the panel: name + its launchpads (domain, ports) and a
/// stop button. The same affordances as the dashboard row, panel-sized.
private struct ContainerQuickRow: View {
    let container: ContainerSummary
    let stop: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(.green).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.displayName)
                    .font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 8) {
                    if let domain = container.namedAccessDomain {
                        Button(domain) { WorkspaceActions.openDomain(domain) }
                            .buttonStyle(.plain).font(.caption2).foregroundStyle(.link)
                            .help("Open http://\(domain)/")
                    }
                    // String-built titles on purpose: a literal with an Int interpolation
                    // becomes a LocalizedStringKey, and locale number formatting turns
                    // port 3000 into "3 000". Ports are never locale-formatted.
                    let bindings = container.publishedBindings
                    ForEach(bindings.prefix(3), id: \.self) { p in
                        if let pub = p.publicPort {
                            let title = ":" + String(pub)
                            Button(title) { WorkspaceActions.openPort(pub) }
                                .buttonStyle(.plain).font(.caption2.monospaced())
                                .foregroundStyle(.link)
                                .help("Open http://localhost:" + String(pub) + "/")
                        }
                    }
                    if bindings.count > 3 {
                        Text("+" + String(bindings.count - 3))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            Button(action: stop) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Stop \(container.displayName)")
        }
    }
}

/// Aggregate live CPU/MEM across the running containers (the streams the panel
/// retains while open).
private struct UsageLine: View {
    let stats: StatsStore

    var body: some View {
        let samples = stats.latest.values
        let cpu = samples.reduce(0.0) { $0 + $1.cpuPercent }
        let mem = samples.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        // Verbatim: Int interpolation in a Text literal is locale-formatted.
        Text(verbatim: "\(Int(cpu))% CPU · \(Format.bytes(mem)) RAM")
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
    }
}

/// `.retainingStats` needs a concrete store; the engine only has one while running.
private struct RetainStatsIfPresent: ViewModifier {
    let stats: StatsStore?
    func body(content: Content) -> some View {
        if let stats { content.retainingStats(stats) } else { content }
    }
}
