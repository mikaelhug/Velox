import SwiftUI
import VeloxCore

/// The dashboard window: a sidebar of resource views and a detail pane. The
/// detail adapts to engine state — when the VM is down, every dashboard shows a
/// single "start the engine" affordance instead of an empty table.
struct RootView: View {
    @Environment(EngineController.self) private var engine
    @Environment(RemoteHostController.self) private var remotes
    @State private var selection: SidebarItem? = .overview
    @State private var showPalette = false

    var body: some View {
        @Bindable var engine = engine
        return NavigationSplitView {
            // The selection binding refuses nil. Workspace rows are plain buttons inside the
            // list, and a click that lands on one would otherwise clear the navigation
            // selection as a side effect — bouncing the detail pane to Overview for an action
            // that was never about navigation.
            List(selection: Binding(get: { selection },
                                    set: { if let new = $0 { selection = new } })) {
                row(.overview)
                Section("Resources") {
                    row(.containers)
                    row(.images)
                    row(.volumes)
                    row(.networks)
                }
                HostsSection()
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
            // Every workspace dialog is hosted HERE, on the list, not on the section that
            // raises it: presentation modifiers attached to a `Section` are unreliable and
            // can silently never appear. See `WorkspacePanel`.
            .workspacePrompts(engine)
            .remoteHostPrompts(remotes)
            .safeAreaInset(edge: .bottom) {
                EngineStatusBar()
                    .padding(10)
            }
        } detail: {
            detail(for: selection ?? .overview)
                .frame(minWidth: 560, minHeight: 360)
                // Row affordances several view types deep (port links, the shell hand-off)
                // need to know which daemon they act on. See `EnvironmentValues.dockerTarget`.
                .environment(\.dockerTarget, dashboard?.target ?? .local)
                // Rebuild the detail pane when the workspace OR the host changes.
                // `OverviewModel` captures the data-disk URL at init, so a pane that
                // survived a switch would keep gauging the OLD workspace's disk — and a
                // pane that survived a host switch would keep every model bound to the
                // previous daemon's stores.
                .id(paneIdentity)
        }
        .toolbar(removing: .sidebarToggle)
        .navigationTitle(navigationTitle)
        // ⌘K command palette — type-to-find anything, act inline. Gated on a dashboard
        // being available, since it now acts on whichever daemon that pane is showing.
        .background(
            Button("") { if dashboard != nil { showPalette = true } }
                .keyboardShortcut("k")
                .hidden()
        )
        .sheet(isPresented: $showPalette) { palette }
        .alert("Switch Docker context to Velox?", isPresented: $engine.showContextPrompt) {
            Button("Switch") { engine.adoptVeloxContext() }
            Button("Not Now", role: .cancel) { engine.declineVeloxContext() }
        } message: {
            Text("Your active Docker context isn't `velox`, so `docker` commands won't reach Velox. Switch now? You can also change this any time in Settings → General.")
        }
    }

    /// What the detail pane is currently able to show: the store trio for whichever engine
    /// is selected, plus the bits that differ between a local VM and a remote daemon.
    ///
    /// Assembling it in one place is what keeps `detail(for:)` a plain dispatch table — the
    /// dashboards themselves are entirely unaware there is more than one engine, because
    /// they were already written against `any DockerClientProtocol`.
    private struct Dashboard {
        let docker: any DockerClientProtocol
        let store: DockerResourceStore
        let stats: StatsStore
        let ui: PaneUIState
        let issues: PortIssues
        let target: DockerTarget
        /// nil for a remote host — its storage is on another machine.
        let dataDiskURL: URL?
        let remote: RemoteHostSession?
        /// Freshly resolved from the manifest each time, so a rename shows immediately.
        let remoteHost: RemoteHost?
    }

    private var dashboard: Dashboard? {
        switch remotes.selection {
        case .local:
            guard engine.state.isRunning, let docker = engine.docker,
                  let store = engine.resources, let stats = engine.stats else { return nil }
            return Dashboard(docker: docker, store: store, stats: stats,
                             ui: engine.paneUI, issues: engine.portIssues, target: .local,
                             dataDiskURL: engine.activeWorkspace?.dataDiskURL
                                 ?? engine.config.dataDiskURL,
                             remote: nil, remoteHost: nil)
        case .remote(let id):
            guard let host = remotes.host(id: id), let session = remotes.session(for: id)
            else { return nil }
            // Show the dashboards once the daemon has answered, and keep showing the
            // last-known lists across a redial so a brief drop doesn't blank the pane.
            // But a FAILED tunnel must fall through to `HostDownView`: `containersLoaded`
            // latches true forever, so gating on it alone meant a host that died after one
            // successful load could never show its error again — the pane just kept
            // rendering hours-old data as if it were live.
            let showsData = session.state == .connected
                || (session.state == .connecting && session.resources.containersLoaded)
            guard showsData else { return nil }
            return Dashboard(docker: session.docker, store: session.resources,
                             stats: session.stats, ui: session.paneUI,
                             issues: session.portIssues,
                             target: .remote(id: host.id, socket: host.localSocketURL,
                                             user: host.user, hostname: host.hostname,
                                             port: host.port),
                             dataDiskURL: nil,
                             remote: session, remoteHost: host)
        }
    }

    /// Forces a fresh detail pane per (host, workspace). A workspace only scopes the local
    /// engine, so it is deliberately not part of a remote host's identity.
    private var paneIdentity: String {
        switch remotes.selection {
        case .local:            return "local:\(engine.workspaces?.activeID ?? "")"
        case .remote(let id):   return "remote:\(id)"
        }
    }

    /// The ⌘K palette, bound to the daemon currently on screen. Extracted from `body`
    /// because inlining it made the view expression too large for the type checker.
    @ViewBuilder
    private var palette: some View {
        if let d = dashboard {
            CommandPalette(store: d.store, docker: d.docker, isPresented: $showPalette) { id in
                selection = .containers
                d.ui.containerSelection = [id]
            }
            .environment(\.dockerTarget, d.target)
        }
    }

    /// The window title names the pane *and* the engine. With more than one daemon on
    /// screen the single most costly mistake is acting on the wrong one, and the title bar
    /// is the one piece of chrome that is always visible.
    private var navigationTitle: String {
        let pane = selection?.title ?? "Velox"
        guard let id = remotes.selection.remoteID,
              let host = remotes.host(id: id) else { return pane }
        return "\(pane) — \(host.name)"
    }

    /// One selectable sidebar row.
    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.systemImage).tag(item)
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .engineLogs:
            if remotes.selection.isLocal {
                // Always available — also shows the boot log and why a start failed.
                EngineLogsView(store: engine.engineLog)
            } else {
                // This is Velox's own guest serial console. A remote host doesn't have one
                // and never will — its daemon logs live in that machine's journal.
                ContentUnavailableView {
                    Label("Engine Logs", systemImage: SidebarItem.engineLogs.systemImage)
                } description: {
                    Text("These are the Velox engine's own boot and daemon logs on this Mac. "
                         + "Select This Mac to see them.")
                } actions: {
                    Button("Show This Mac") { remotes.select(.local) }
                }
            }
        case .overview, .containers, .images, .volumes, .networks:
            if let d = dashboard {
                switch item {
                case .overview:   OverviewView(store: d.store, stats: d.stats, docker: d.docker,
                                               dataDiskURL: d.dataDiskURL,
                                               remoteHost: d.remoteHost,
                                               remoteState: d.remote?.state)
                case .containers: ContainersView(docker: d.docker, store: d.store, stats: d.stats,
                                                 ui: d.ui, issues: d.issues)
                case .images:     ImagesView(docker: d.docker, store: d.store, ui: d.ui)
                case .volumes:    VolumesView(docker: d.docker, store: d.store, ui: d.ui)
                default:          NetworksView(docker: d.docker, store: d.store)
                }
            } else if let id = remotes.selection.remoteID {
                HostDownView(item: item, hostID: id)
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
            if let fraction = engine.engineOwner?.progress {
                // A cross-volume move or duplicate copies every used byte and can run for
                // minutes; a bare spinner there is indistinguishable from a hang.
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 54)
            } else if engine.isEngineOwned || engine.state.isBusy {
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
                if let fraction = owner.progress {
                    Text("\(owner.explanation) (\(Int(fraction * 100))%)")
                } else {
                    Text(owner.explanation)
                }
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

/// Shown in the detail pane while a selected remote host isn't answering yet — connecting,
/// never connected, or failed.
///
/// The failure text is ssh's own diagnostic, translated by `SSHTunnel.explain`. That
/// matters more here than for the local engine: the three things that actually go wrong
/// (an unverified host key, a key the agent doesn't hold, a user who can't reach the
/// docker socket) are all fixed on the *server* or in `~/.ssh`, and none of them are
/// guessable from a spinner.
struct HostDownView: View {
    @Environment(RemoteHostController.self) private var remotes
    let item: SidebarItem
    let hostID: String

    var body: some View {
        let host = remotes.host(id: hostID)
        let session = remotes.session(for: hostID)
        let state = session?.state ?? .stopped

        ContentUnavailableView {
            Label(host?.name ?? item.title, systemImage: "server.rack")
        } description: {
            VStack(spacing: 6) {
                Text(state.failureMessage ?? description(for: state))
                if let host {
                    Text(host.subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } actions: {
            if let host {
                HStack {
                    Button("Reconnect") {
                        remotes.disconnect(id: host.id)
                        remotes.select(.remote(host.id))
                    }
                    Button("Open SSH Session") {
                        RowActions.openSSH(user: host.user, hostname: host.hostname, port: host.port)
                    }
                }
            }
        }
    }

    private func description(for state: SSHTunnel.State) -> String {
        switch state {
        case .connecting:
            return "Connecting over SSH…"
        case .connected:
            // The tunnel is up but the daemon hasn't answered a list yet.
            return "Connected — waiting for the Docker daemon to respond."
        case .stopped:
            return "Not connected."
        case .failed(let message):
            return message
        }
    }
}

#if DEBUG
struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
            .environment(EngineController())
            .environment(RemoteHostController())
            .frame(width: 820, height: 480)
    }
}
#endif
