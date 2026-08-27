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
            if engine.availableUpdate?.isUpdateAvailable == true {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill").foregroundStyle(.tint)
                    Text(verbatim: "Velox \(engine.availableUpdate?.latestVersion ?? "update") available")
                        .font(.caption)
                    Spacer()
                    Button(engine.updateInProgress ? "Installing…" : "Install") {
                        engine.applyUpdate()
                    }
                    .controlSize(.small)
                    .disabled(engine.updateInProgress)
                }
            }
            if engine.state.isRunning, let store = engine.resources {
                let running = store.containers.filter(\.isRunning)
                Divider()
                if running.isEmpty {
                    Text("No running containers")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 24)
                } else {
                    // Compose projects group under a small header with a stop-project
                    // button; standalone containers list first. Up to 7 rows render
                    // inline; beyond that the full list scrolls in a fixed-height
                    // viewport (like the Wi-Fi menu) — every container stays reachable.
                    let standalone = running.filter { $0.composeProject == nil }
                    let projects = Dictionary(grouping: running.filter { $0.composeProject != nil },
                                              by: { $0.composeProject ?? "" })
                        .sorted { $0.key < $1.key }
                    let rows = VStack(alignment: .leading, spacing: 7) {
                        ForEach(standalone) { c in quickRow(c) }
                        ForEach(projects, id: \.key) { name, members in
                            HStack(spacing: 5) {
                                Image(systemName: "square.stack.3d.up.fill")
                                    .font(.caption2).foregroundStyle(.blue)
                                Text(name).font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Button { stop(members) } label: { Image(systemName: "stop.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .help("Stop project “\(name)”")
                            }
                            ForEach(members) { c in quickRow(c).padding(.leading, 10) }
                        }
                    }
                    let headerRows = projects.count
                    if running.count + headerRows <= Self.maxRows {
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
        // Compact fixed width: MenuBarExtra's window doesn't reliably honor a
        // fixedSize content hug (it proposes its own width), so size explicitly to
        // the footer row plus a little air. Long names/domains truncate in
        // the rows (230pt text cap) rather than widening the panel.
        .frame(width:270, alignment: .leading)
        .modifier(RetainStatsIfPresent(stats: engine.state.isRunning ? engine.stats : nil))
    }

    private func quickRow(_ c: ContainerSummary) -> some View {
        ContainerQuickRow(container: c) { stop([c]) }
    }

    /// Stop one or many containers concurrently (a project header stops its members).
    private func stop(_ containers: [ContainerSummary]) {
        guard let docker = engine.docker else { return }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for c in containers {
                    group.addTask { try? await docker.stopContainer(c.id) }
                }
            }
        }
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
        if engine.isEngineOwned {
            // A disk move, workspace switch or clone owns the engine and drives it itself.
            ProgressView().controlSize(.small)
        } else if engine.needsOnboarding {
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
            // `AppTerminationDelegate` flushes the guest and stops the engine for every
            // quit route; don't stop it here as well.
            Button("Quit") { NSApp.terminate(nil) }
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
            Circle().fill(container.isUnhealthy ? Color.orange : .green)
                .frame(width: 6, height: 6)
                .help(container.isUnhealthy ? "Healthcheck failing" : "Running")
            // Cap the text column so one long name/domain can't widen the whole
            // panel — it truncates in the middle instead (the click still works).
            VStack(alignment: .leading, spacing: 1) {
                Text(container.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    if let domain = container.namedAccessDomain {
                        Button {
                            RowActions.openDomain(domain)
                        } label: {
                            Text(domain).lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(.link)
                        .help("Open http://\(domain)/")
                    }
                    // Port links render as capsule chips so they read as their own
                    // buttons (localhost:<port>), not as a suffix of the domain link
                    // beside them. String-built titles on purpose: a literal with an
                    // Int interpolation becomes a LocalizedStringKey and locale number
                    // grouping turns port 3000 into "3 000".
                    let bindings = container.publishedBindings
                    ForEach(bindings.prefix(3), id: \.self) { p in
                        if let pub = p.publicPort {
                            Button {
                                RowActions.openPort(pub)
                            } label: {
                                Text(":" + String(pub))
                                    .font(.caption2.monospaced())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.link)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary.opacity(0.5), in: Capsule())
                            .help("Open http://localhost:" + String(pub) + "/")
                        }
                    }
                    if bindings.count > 3 {
                        Text("+" + String(bindings.count - 3))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 230, alignment: .leading)
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
        // Read the store's published aggregates (already summed, refreshed at ~1 Hz) rather
        // than re-reducing `latest` here — which would also re-render this line on every raw
        // per-container sample.
        // Verbatim: Int interpolation in a Text literal is locale-formatted.
        Text(verbatim: "\(Int(stats.totalCPU))% CPU · \(Format.bytes(stats.totalMemBytes)) RAM")
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
