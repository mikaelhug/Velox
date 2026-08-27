import SwiftUI

/// The dashboard window: a sidebar of resource views and a detail pane. The
/// detail adapts to engine state — when the VM is down, every dashboard shows a
/// single "start the engine" affordance instead of an empty table.
struct RootView: View {
    @Environment(EngineController.self) private var engine
    @State private var selection: SidebarItem? = .overview
    @State private var showPalette = false

    var body: some View {
        @Bindable var engine = engine
        return NavigationSplitView {
            List(selection: $selection) {
                row(.overview)
                Section("Resources") {
                    row(.containers)
                    row(.images)
                    row(.volumes)
                    row(.networks)
                }
                WorkspacesSection()
                Section("System") {
                    row(.engineLogs)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 160, max: 270)
            // The sidebar List is an AppKit table too: while the sidebar slides,
            // its rows are briefly wider than the shrinking clip and AppKit
            // flashes a horizontal scroller — same glitch the dashboards had.
            .suppressHorizontalScroller()
            .safeAreaInset(edge: .bottom) {
                EngineStatusBar()
                    .padding(10)
            }
        } detail: {
            detail(for: selection ?? .overview)
                .frame(minWidth: 560, minHeight: 360)
                // Rebuild the detail pane when the workspace changes. `OverviewModel`
                // captures the data-disk URL at init, so a pane that survived a switch
                // would keep gauging the OLD workspace's disk. A switch normally destroys
                // this view anyway (the engine leaves `.running`), but that is incidental,
                // and this makes it impossible rather than merely unlikely.
                .id(engine.workspaces?.activeID ?? "")
        }
        .toolbar(removing: .sidebarToggle)
        .navigationTitle(selection?.title ?? "Velox")
        // ⌘K command palette — type-to-find anything, act inline.
        .background(
            Button("") { if engine.state.isRunning { showPalette = true } }
                .keyboardShortcut("k")
                .hidden()
        )
        .sheet(isPresented: $showPalette) {
            CommandPalette(isPresented: $showPalette) { id in
                selection = .containers
                engine.paneUI.containerSelection = [id]
            }
            .environment(engine)
        }
        .alert("Switch Docker context to Velox?", isPresented: $engine.showContextPrompt) {
            Button("Switch") { engine.adoptVeloxContext() }
            Button("Not Now", role: .cancel) { engine.declineVeloxContext() }
        } message: {
            Text("Your active Docker context isn't `velox`, so `docker` commands won't reach Velox. Switch now? You can also change this any time in Settings → General.")
        }
    }

    /// One selectable sidebar row.
    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.systemImage).tag(item)
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .engineLogs:
            // Always available — also shows the boot log and why a start failed.
            EngineLogsView(store: engine.engineLog)
        case .overview, .containers, .images, .volumes, .networks:
            if engine.state.isRunning, let docker = engine.docker, let store = engine.resources,
               let stats = engine.stats {
                switch item {
                case .overview:   OverviewView(store: store, stats: stats,
                                               dataDiskURL: engine.activeWorkspace?.dataDiskURL
                                                   ?? engine.config.dataDiskURL)
                case .containers: ContainersView(docker: docker, store: store, stats: stats,
                                                 ui: engine.paneUI, issues: engine.portIssues)
                case .images:     ImagesView(docker: docker, store: store, ui: engine.paneUI)
                case .volumes:    VolumesView(docker: docker, store: store, ui: engine.paneUI)
                default:          NetworksView(docker: docker, store: store)
                }
            } else {
                EngineDownView(item: item)
            }
        }
    }
}

/// Compact engine status + Start/Stop control pinned to the sidebar bottom.
struct EngineStatusBar: View {
    @Environment(EngineController.self) private var engine

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(engine.state.tint)
                .frame(width: 8, height: 8)
                .shadow(color: engine.state.tint.opacity(0.6), radius: engine.state.isRunning ? 2.5 : 0)
            Text(engine.engineOwner?.label ?? engine.state.label)
                .font(.callout.weight(.medium))
            if engine.isEngineOwned || engine.state.isBusy {
                ProgressView().controlSize(.small)
            } else if engine.state.isRunning {
                Button("Stop") { Task { await engine.stop() } }
                    .controlSize(.small)
            } else {
                Button("Start") { Task { await engine.start() } }
                    .controlSize(.small)
                    .disabled(engine.needsOnboarding)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }
}

/// Shown in the detail pane whenever the engine isn't running.
struct EngineDownView: View {
    @Environment(EngineController.self) private var engine
    let item: SidebarItem

    var body: some View {
        ContentUnavailableView {
            Label(item.title, systemImage: item.systemImage)
        } description: {
            if let owner = engine.engineOwner {
                Text(owner.explanation)
            } else if let workspaceError = engine.workspaceError {
                Text(workspaceError)
            } else if let failure = engine.state.failureMessage {
                Text(failure)
            } else if engine.needsOnboarding {
                Text("Finish setup to boot the Velox engine.")
            } else {
                Text("The Velox engine is \(engine.state.label.lowercased()). Start it to see \(item.title.lowercased()).")
            }
        } actions: {
            if !engine.needsOnboarding && !engine.isEngineOwned && engine.workspaceError == nil {
                Button(engine.state.isBusy ? "Starting…" : "Start Engine") {
                    Task { await engine.start() }
                }
                .disabled(engine.state.isBusy)
            }
        }
    }
}

#if DEBUG
struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
            .environment(EngineController())
            .frame(width: 820, height: 480)
    }
}
#endif
