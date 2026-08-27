import SwiftUI
import VeloxCore

/// A user-initiated container lifecycle action, shown optimistically in the UI
/// (the row reads "Stopping…") the instant it's clicked — Docker only reports the
/// new state once the action actually finishes, which can take several seconds.
enum PendingAction: Hashable {
    case starting, stopping, restarting
    var label: String {
        switch self {
        case .starting:   return "Starting…"
        case .stopping:   return "Stopping…"
        case .restarting: return "Restarting…"
        }
    }
    /// Transitional tint, distinct from the green/red terminal states.
    var tint: Color { .orange }
}

/// Loads and live-updates the container list. Refreshes on a Docker `events`
/// subscription rather than polling, so start/stop/create/destroy reflect
/// immediately.
@MainActor
@Observable
final class ContainersModel {
    let docker: any DockerClientProtocol
    let store: DockerResourceStore
    var actionError: String?

    /// Containers with an action in flight, keyed by id — drives the optimistic
    /// "Starting…/Stopping…/Restarting…" badge until the action completes.
    private(set) var pending: [String: PendingAction] = [:]

    init(docker: any DockerClientProtocol, store: DockerResourceStore) {
        self.docker = docker; self.store = store
    }

    // Data is read from the shared store (persistent across pane switches).
    var containers: [ContainerSummary] { store.containers }
    var loadError: String? { store.containersError }
    var hasLoaded: Bool { store.containersLoaded }
    var anchors: [String: DockerResourceStore.LifeAnchor] { store.anchors }

    func setPending(_ ids: [String], _ action: PendingAction) {
        for id in ids { pending[id] = action }
    }
    func clearPending(_ ids: [String]) {
        for id in ids { pending.removeValue(forKey: id) }
    }

    func perform(_ action: @Sendable (any DockerClientProtocol) async throws -> Void) async {
        do { try await action(docker); await store.refreshContainers() }
        catch { actionError = "\(error)" }
    }

    /// Run an action over many containers (a selection, or a Compose project's
    /// members), then refresh once. Runs them **concurrently** — `stopContainer`
    /// blocks until the container actually stops, so a serial loop would stop a
    /// multi-selection one-at-a-time; this stops them all at once. Concurrency is
    /// capped so a huge "stop all" doesn't open hundreds of VSOCK connections at
    /// once. Collects the first failure into `actionError`.
    func performAll(_ ids: [String],
                    _ action: @Sendable @escaping (any DockerClientProtocol, String) async throws -> Void) async {
        let docker = self.docker
        let firstError = await runBounded(over: ids) { id in try await action(docker, id) }
        if let firstError { actionError = firstError }
        await store.refreshContainers()
    }

    // Memoized grouping/sort. The grouping does an O(N log N) ICU-collation sort, and
    // the Containers `body` re-evaluates on selection/badge changes (not just data
    // changes), so cache the result and recompute only when the data or the search text
    // actually changed. The signature must hash the FULL container value: the cache
    // stores the values themselves, so hashing only the sort keys (id/name/project)
    // served stale rows after a state flip — a stopped container kept showing "Up …"
    // until a pane switch rebuilt the view. Ignored by Observation so updating the
    // cache during `body` doesn't invalidate the view.
    @ObservationIgnored private var topLevelSig: Int?
    @ObservationIgnored private var topLevelCache: [TopLevelEntry] = []

    fileprivate func topLevel(searchText: String) -> [TopLevelEntry] {
        let cs = store.containers
        var hasher = Hasher()
        for c in cs { hasher.combine(c) }
        hasher.combine(searchText)
        let sig = hasher.finalize()
        if topLevelSig == sig { return topLevelCache }
        let result = Self.computeTopLevel(cs, searchText: searchText)
        topLevelSig = sig
        topLevelCache = result
        return result
    }

    /// Standalone containers first (alphabetical), then Compose project groups
    /// (alphabetical) — two stable bands, not an interleave.
    private static func computeTopLevel(_ containers: [ContainerSummary], searchText: String) -> [TopLevelEntry] {
        let filtered = searchText.isEmpty ? containers : containers.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.image.localizedCaseInsensitiveContains(searchText)
                || ($0.composeProject?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
        var groups: [String: [ContainerSummary]] = [:]
        var standalone: [ContainerSummary] = []
        for c in filtered {
            if let project = c.composeProject { groups[project, default: []].append(c) }
            else { standalone.append(c) }
        }
        let standaloneEntries = standalone
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map(TopLevelEntry.standalone)
        let groupEntries = groups
            .map { name, members in
                ProjectGroup(name: name, containers: members.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                })
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(TopLevelEntry.group)
        return standaloneEntries + groupEntries
    }
}

/// A set of containers that share a `com.docker.compose.project` label.
struct ProjectGroup: Identifiable, Hashable {
    let name: String
    let containers: [ContainerSummary]
    var id: String { name }
    var runningCount: Int { containers.filter(\.isRunning).count }
}

/// One row in the containers table: either a Compose-project header (expandable)
/// or a single container. Both share this type so the table can nest them under
/// a `DisclosureTableRow`.
enum ContainerRow: Identifiable, Hashable {
    case project(ProjectGroup)
    case container(ContainerSummary)

    var id: String {
        switch self {
        case .project(let g):   return "project:\(g.name)"
        case .container(let c): return c.id
        }
    }
}

/// A top-level table entry: standalone containers band first, project groups band
/// below, each alphabetical.
private enum TopLevelEntry: Identifiable {
    case standalone(ContainerSummary)
    case group(ProjectGroup)

    var id: String {
        switch self {
        case .standalone(let c): return c.id
        case .group(let g):      return "project:\(g.name)"
        }
    }
}

struct ContainersView: View {
    let stats: StatsStore
    @Environment(\.openWindow) private var openWindow
    @State private var model: ContainersModel
    /// Search/selection/expansion live in `PaneUIState` (owned by EngineController) so
    /// they survive pane switches — this view is recreated on every switch by design
    /// (its on-screen-scoped tasks must stop when hidden).
    @Bindable private var ui: PaneUIState
    @State private var pendingDelete: ContainerSummary?
    @State private var pendingBulkDelete: [ContainerSummary] = []
    @State private var tableLayout: TableColumnCustomization<ContainerRow>

    /// Published ports whose localhost bind failed — their links render red.
    private let issues: PortIssues

    init(docker: any DockerClientProtocol, store: DockerResourceStore, stats: StatsStore,
         ui: PaneUIState, issues: PortIssues) {
        self.stats = stats
        self.ui = ui
        self.issues = issues
        _model = State(initialValue: ContainersModel(docker: docker, store: store))
        // v3: Ports column became hidden-by-default — bump the key so an existing
        // persisted layout doesn't pin the old visibility.
        _tableLayout = State(initialValue: TableLayout.load("containers3"))
    }

    /// Standalone containers (alphabetical) above Compose project groups (alphabetical) —
    /// memoized in the model (recomputed only when the data or search text changes).
    private var topLevel: [TopLevelEntry] { model.topLevel(searchText: ui.containerSearch) }

    private func expansion(_ name: String) -> Binding<Bool> {
        Binding(get: { [ui] in !ui.containerCollapsed.contains(name) },
                set: { [ui] isExpanded in
                    if isExpanded { ui.containerCollapsed.remove(name) }
                    else { ui.containerCollapsed.insert(name) }
                })
    }

    var body: some View {
        Table(of: ContainerRow.self, selection: $ui.containerSelection,
              columnCustomization: $tableLayout) {
            TableColumn("Name") { row in nameCell(row) }
                .customizationID("name")

            // Hidden by default: the image string is long and rarely the scanning key
            // (the inspector shows it for the selected row). Right-click the header to
            // re-enable — useful when auto-named containers make the image the only hint.
            TableColumn("Image") { row in
                if case .container(let c) = row {
                    Text(c.image).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
            }
                .customizationID("image")
                .defaultVisibility(.hidden)

            TableColumn("Status") { row in statusCell(row) }
                .customizationID("status")

            // Hidden by default, like Image: port launchpads live in the inspector and
            // the name cell's named-access link; right-click the header to re-enable.
            TableColumn("Ports") { row in portsCell(row) }
                .customizationID("ports")
                .defaultVisibility(.hidden)

            TableColumn("CPU / MEM") { row in
                if case .container(let c) = row {
                    ContainerUsageCell(stats: stats, containerID: c.id)
                }
            }
                .customizationID("usage")
        } rows: {
            ForEach(topLevel) { entry in
                switch entry {
                case .standalone(let c):
                    TableRow(ContainerRow.container(c))
                case .group(let g):
                    DisclosureTableRow(ContainerRow.project(g), isExpanded: expansion(g.name)) {
                        ForEach(g.containers) { c in
                            TableRow(ContainerRow.container(c))
                        }
                    }
                }
            }
        }
        .suppressHorizontalScroller()
        // Uniform rows: the alternating stripes repaint out of sync with the clip
        // during inspector-resize animations and read as flicker.
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: ContainerRow.ID.self) { ids in
            contextMenu(for: ids)
        }
        .searchable(text: $ui.containerSearch, placement: .toolbar, prompt: "Filter containers")
        // Keyboard-first: ⌘L logs, ⌘I inspector, ⌘⌫ delete — for the selection.
        .background(Group {
            Button("") { if let c = selectedContainers.first { openLogs(c) } }
                .keyboardShortcut("l").hidden()
            Button("") { ui.containerInspector.toggle() }
                .keyboardShortcut("i").hidden()
            Button("") { if !selectedContainers.isEmpty { pendingBulkDelete = selectedContainers } }
                .keyboardShortcut(.delete, modifiers: .command).hidden()
        })
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ControlGroup {
                    Button { start(selectedContainers) } label: {
                        Label("Start selected", systemImage: "play.fill")
                    }
                    .help("Start selected")
                    .disabled(!selectedContainers.contains { !$0.isRunning })

                    Button { stop(selectedContainers) } label: {
                        Label("Stop selected", systemImage: "stop.fill")
                    }
                    .help("Stop selected")
                    .disabled(!selectedContainers.contains { $0.isRunning || $0.isPaused })

                    Button { restart(selectedContainers) } label: {
                        Label("Restart selected", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("Restart selected")
                    .disabled(selectedContainers.isEmpty)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { pendingBulkDelete = selectedContainers } label: {
                    Label("Delete selected", systemImage: "trash")
                }
                .help("Delete selected")
                .disabled(selectedContainers.isEmpty)
            }
            ToolbarItem(placement: .automatic) {
                Button { ui.containerInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                    .help("Toggle inspector")
            }
        }
        .inspector(isPresented: $ui.containerInspector) {
            ContainerInspector(container: inspected, docker: model.docker)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
        }
        .overlay {
            if model.hasLoaded && model.containers.isEmpty {
                ContentUnavailableView("No Containers", systemImage: SidebarItem.containers.systemImage,
                                       description: Text(model.loadError ?? "Run one with `docker run`."))
            }
        }
        .persistTableLayout(tableLayout, "containers3")
        .retainingStats(stats)
        // No uptime re-list: rows render "Up …" from each container's lifecycle anchor
        // (dockerd's StartedAt/FinishedAt, fetched once per transition) with
        // self-ticking relative date text — the system updates the label, events
        // update the anchor, and the GUI's last repeating timer is gone.
        .confirmationDialog(
            "Delete container \(pendingDelete?.displayName ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { c in
            Button("Delete", role: .destructive) {
                Task { await model.perform { try await $0.removeContainer(c.id, force: true) } }
            }
        } message: { c in
            Text("This permanently removes “\(c.displayName)” and its writable layer.")
        }
        .confirmationDialog(
            "Delete \(pendingBulkDelete.count) selected container\(pendingBulkDelete.count == 1 ? "" : "s")?",
            isPresented: Binding(get: { !pendingBulkDelete.isEmpty }, set: { if !$0 { pendingBulkDelete = [] } })
        ) {
            Button("Delete", role: .destructive) {
                let ids = pendingBulkDelete.map(\.id)
                pendingBulkDelete = []
                Task {
                    await model.performAll(ids) { try await $0.removeContainer($1, force: true) }
                    ui.containerSelection.removeAll()
                }
            }
        } message: {
            Text("This permanently removes the selected container\(pendingBulkDelete.count == 1 ? "" : "s") and their writable layers.")
        }
        .alert("Action failed", isPresented: Binding(
            get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
        ) { Button("OK", role: .cancel) {} } message: { Text(model.actionError ?? "") }
    }

    /// Open a free-floating logs window for `c` (reuses the existing one if already open).
    private func openLogs(_ c: ContainerSummary) {
        openWindow(id: WindowID.logs,
                   value: LogWindowTarget(id: c.id, name: c.displayName, image: c.image))
    }

    // MARK: Cells

    @ViewBuilder
    private func nameCell(_ row: ContainerRow) -> some View {
        switch row {
        case .container(let c):
            HStack(spacing: 6) {
                Circle().fill(dotColor(for: c)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.displayName).fontWeight(.medium)
                    // Named access — the engine's flagship: the container's real IP by
                    // name, any protocol, no -p. Click → browser; copy lives in the menu.
                    if let domain = c.namedAccessDomain {
                        Button(domain) { RowActions.openDomain(domain) }
                            .buttonStyle(.plain)
                            .font(.caption2)
                            .foregroundStyle(.link)
                            .help("Open http://\(domain)/")
                    }
                }
            }
        case .project(let g):
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.blue)
                Text(g.name).fontWeight(.semibold)
            }
        }
    }

    @ViewBuilder
    private func statusCell(_ row: ContainerRow) -> some View {
        switch row {
        case .container(let c):
            if let action = model.pending[c.id] {
                PendingBadge(action: action)
            } else {
                UptimeBadge(container: c, anchor: model.anchors[c.id])
            }
        case .project(let g):
            Text(projectStatus(g)).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Name-dot tint: transitional (orange) while an action is in flight,
    /// otherwise the container's real-state color.
    /// Only published ports (host bindings) — not Dockerfile EXPOSE metadata, which
    /// isn't reachable from the host. Each is a launchpad: click → localhost:<port>.
    /// (Extracted from the column builder — inline it grows the Table expression past
    /// what the type-checker will chew.)
    @ViewBuilder
    private func portsCell(_ row: ContainerRow) -> some View {
        if case .container(let c) = row {
            let bindings = c.publishedBindings
            if bindings.isEmpty {
                Text("—").font(.caption.monospaced()).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(bindings, id: \.self) { p in
                        if let pub = p.publicPort {
                            PortLink(label: p.label, port: pub,
                                     blocked: issues.blocked.contains(UInt16(pub)))
                        }
                    }
                }
                .lineLimit(1)
            }
        }
    }

    private func dotColor(for c: ContainerSummary) -> Color {
        if let pending = model.pending[c.id] { return pending.tint }
        if c.isUnhealthy { return .orange }
        return color(for: c.state)
    }

    private func projectStatus(_ g: ProjectGroup) -> String {
        // If every member shares one in-flight action, surface it on the header.
        let actions = g.containers.compactMap { model.pending[$0.id] }
        if actions.count == g.containers.count, let first = actions.first,
           actions.allSatisfy({ $0 == first }) {
            return first.label
        }
        let running = g.runningCount, total = g.containers.count
        if running == 0 { return "Stopped · \(total)" }
        if running == total { return "Running · \(total)" }
        return "\(running)/\(total) running"
    }

    // MARK: Bulk actions

    /// Resolve selected row IDs to the underlying containers — a selected project
    /// row expands to all its members — de-duplicated by container id.
    private func containers(for ids: Set<ContainerRow.ID>) -> [ContainerSummary] {
        var byID: [String: ContainerSummary] = [:]
        for id in ids {
            if let c = model.containers.first(where: { $0.id == id }) {
                byID[c.id] = c
            } else if let g = group(forRowID: id) {
                for c in g.containers { byID[c.id] = c }
            }
        }
        return Array(byID.values)
    }

    private var selectedContainers: [ContainerSummary] { containers(for: ui.containerSelection) }

    /// The single selected container, for the inspector (a project row never matches).
    private var inspected: ContainerSummary? {
        guard ui.containerSelection.count == 1, let id = ui.containerSelection.first else { return nil }
        return model.containers.first { $0.id == id }
    }

    private func start(_ cs: [ContainerSummary]) {
        runPending(cs.filter { !$0.isRunning }.map(\.id), .starting) { try await $0.startContainer($1) }
    }
    private func stop(_ cs: [ContainerSummary]) {
        runPending(cs.filter { $0.isRunning || $0.isPaused }.map(\.id), .stopping) { try await $0.stopContainer($1) }
    }
    private func restart(_ cs: [ContainerSummary]) {
        runPending(cs.map(\.id), .restarting) { try await $0.restartContainer($1) }
    }

    /// Optimistically badge `ids` with `action`, run it concurrently, then clear
    /// the badge. The row shows "Stopping…" etc. immediately instead of staying
    /// on the old state until Docker reports the change.
    private func runPending(_ ids: [String], _ action: PendingAction,
                            _ body: @Sendable @escaping (any DockerClientProtocol, String) async throws -> Void) {
        guard !ids.isEmpty else { return }
        model.setPending(ids, action)
        Task {
            await model.performAll(ids, body)
            model.clearPending(ids)
        }
    }

    // MARK: Context menus

    @ViewBuilder
    private func contextMenu(for ids: Set<ContainerRow.ID>) -> some View {
        if ids.count <= 1, let id = ids.first {
            if let c = model.containers.first(where: { $0.id == id }) {
                containerContext(c)
            } else if let g = group(forRowID: id) {
                projectContext(g)
            }
        } else if !containers(for: ids).isEmpty {
            bulkContext(containers(for: ids))
        }
    }

    @ViewBuilder
    private func bulkContext(_ cs: [ContainerSummary]) -> some View {
        Button("Start \(cs.count) Containers") { start(cs) }
        Button("Stop \(cs.count) Containers") { stop(cs) }
        Button("Restart \(cs.count) Containers") { restart(cs) }
    }

    @ViewBuilder
    private func containerContext(_ c: ContainerSummary) -> some View {
        if c.isRunning || c.isPaused {
            Button("Stop") { runPending([c.id], .stopping) { try await $0.stopContainer($1) } }
            Button("Restart") { runPending([c.id], .restarting) { try await $0.restartContainer($1) } }
            if c.isPaused {
                Button("Resume") { Task { await model.perform { try await $0.unpauseContainer(c.id) } } }
            } else {
                Button("Pause") { Task { await model.perform { try await $0.pauseContainer(c.id) } } }
            }
        } else {
            Button("Start") { runPending([c.id], .starting) { try await $0.startContainer($1) } }
        }
        Divider()
        Button("View Logs") { openLogs(c) }
        if c.isRunning {
            Button("Open in Terminal") { RowActions.openShell(containerID: c.shortID) }
            if RowActions.vsCodeAvailable {
                Button("Open in VS Code") { RowActions.openInVSCode(containerName: c.displayName) }
            }
        }
        // No "Open <domain>" here — the clickable domain link under the name IS that
        // affordance; duplicating it in the menu just lengthens it.
        Menu("Copy") {
            Button("Name") { RowActions.copy(c.displayName) }
            Button("Container ID") { RowActions.copy(c.id) }
            Button("As docker run Command") {
                let docker = model.docker
                Task {
                    if let inspect = try? await docker.inspectContainer(c.id) {
                        RowActions.copy(DockerRunCommand.build(from: inspect))
                    }
                }
            }
            if let ip = c.directIP { Button("IP (\(ip))") { RowActions.copy(ip) } }
            if let domain = c.namedAccessDomain { Button("Domain") { RowActions.copy(domain) } }
            ForEach(c.publishedBindings, id: \.self) { p in
                if let pub = p.publicPort {
                    // String-built (a literal's Int interpolation is locale-formatted).
                    let title = "URL (localhost:" + String(pub) + ")"
                    Button(title) { RowActions.copy("http://localhost:" + String(pub) + "/") }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { pendingDelete = c }
    }

    @ViewBuilder
    private func projectContext(_ g: ProjectGroup) -> some View {
        Button("Start Project") { start(g.containers) }
        Button("Stop Project") { stop(g.containers) }
        Button("Restart Project") { restart(g.containers) }
    }

    private func group(forRowID id: String) -> ProjectGroup? {
        guard id.hasPrefix("project:") else { return nil }
        let name = String(id.dropFirst("project:".count))
        for entry in topLevel { if case .group(let g) = entry, g.name == name { return g } }
        return nil
    }

    private func color(for state: String) -> Color {
        switch state {
        case "running": return .green
        case "paused":  return .yellow
        case "restarting": return .orange
        default:        return .secondary
        }
    }
}

/// The right-hand inspector for a single selected container: identity, network
/// reachability (clickable domain + ports), lifecycle (restart count = the
/// crash-loop tell), process, env, mounts, and labels. No CPU/MEM here — the
/// table column already shows live usage. List data renders instantly; one
/// `inspect` call per selection enriches the rest.
private struct ContainerInspector: View {
    let container: ContainerSummary?
    let docker: any DockerClientProtocol

    /// What the panel renders: a summary plus its enrichment, swapped in together.
    /// Rendering `container` directly while its inspect loads mixes generations —
    /// the new row's header over the previous row's process/env, then a blank,
    /// then the fill: three flickers per selection change (and recreating the view
    /// with `.id` instead re-hosts the whole AppKit form, which flashes a partial
    /// layout). Holding the last coherent snapshot until the next one is ready
    /// makes a selection change exactly ONE in-place update.
    private struct Snapshot {
        let c: ContainerSummary
        let inspect: ContainerInspect?
    }
    @State private var shown: Snapshot?

    var body: some View {
        Group {
            // Until the first snapshot lands, render the bare summary — its list
            // data is already on hand; afterwards always the last full snapshot.
            if let s = shown ?? container.map({ Snapshot(c: $0, inspect: nil) }) {
                form(s)
            } else {
                ContentUnavailableView("No Selection", systemImage: "shippingbox",
                                       description: Text("Select a container to inspect."))
            }
        }
        .task(id: container) {
            guard let c = container else { shown = nil; return }
            let info = try? await docker.inspectContainer(c.id)
            // The selection may have moved on mid-fetch; that id's run updates.
            guard container?.id == c.id else { return }
            shown = Snapshot(c: c, inspect: info)
        }
    }

    private func form(_ s: Snapshot) -> some View {
        let c = s.c
        let inspect = s.inspect
        return Form {
                Section("Container") {
                    LabeledContent("Name", value: c.displayName)
                    LabeledContent("ID", value: c.shortID)
                    LabeledContent("Image") {
                        Text(c.image).lineLimit(1).truncationMode(.middle)
                    }
                    // No Status/Started/Health here — the row's ticking badge already
                    // carries all three; the inspector holds what the table doesn't.
                    if let project = c.composeProject {
                        LabeledContent("Compose", value: project)
                    }
                    // Restarts is the one lifecycle datum NOT in the badge (the
                    // crash-loop tell) — shown only when it's actually signal.
                    if let restarts = inspect?.restartCount, restarts > 0 {
                        LabeledContent("Restarts") {
                            Text(verbatim: String(restarts))
                                .foregroundStyle(.orange)
                                .help("The engine restarted this container — repeated exits may mean a crash loop")
                        }
                    }
                }
                if let cfg = inspect?.config {
                    processSection(cfg)
                    if let env = cfg.env, !env.isEmpty { environmentSection(env) }
                }
                Section("Network") {
                    if let domain = c.namedAccessDomain {
                        LabeledContent("Domain") {
                            Button(domain) { RowActions.openDomain(domain) }
                                .buttonStyle(.plain).foregroundStyle(.link)
                        }
                    }
                    if !c.networkIPs.isEmpty {
                        LabeledContent(c.networkIPs.count == 1 ? "IP" : "IPs",
                                       value: c.networkIPs.joined(separator: ", "))
                    }
                    if c.publishedBindings.isEmpty {
                        LabeledContent("Ports", value: "none published")
                    } else {
                        LabeledContent("Ports") {
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(c.publishedBindings, id: \.self) { p in
                                    if let pub = p.publicPort {
                                        Button(p.label) { RowActions.openPort(pub) }
                                            .buttonStyle(.plain).foregroundStyle(.link)
                                            .font(.callout.monospaced())
                                    }
                                }
                            }
                        }
                    }
                }
                if !c.mounts.isEmpty {
                    Section("Mounts") {
                        ForEach(c.mounts, id: \.self) { m in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.destination).font(.caption.monospaced())
                                Text("\(m.type) · \(m.source)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
                let labels = c.labels.filter { !$0.key.hasPrefix("com.docker.compose") }
                if !labels.isEmpty {
                    Section("Labels") {
                        ForEach(labels.keys.sorted(), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(key).font(.caption2).foregroundStyle(.secondary)
                                Text(labels[key] ?? "").font(.caption.monospaced()).lineLimit(2)
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)
    }

    @ViewBuilder
    private func processSection(_ cfg: ContainerInspect.Config) -> some View {
        let command = ((cfg.entrypoint ?? []) + (cfg.cmd ?? [])).joined(separator: " ")
        if !command.isEmpty || cfg.workingDir?.isEmpty == false {
            Section("Process") {
                if !command.isEmpty {
                    Text(command).font(.caption.monospaced()).lineLimit(3)
                        .textSelection(.enabled)
                }
                if let wd = cfg.workingDir, !wd.isEmpty {
                    LabeledContent("Workdir") { Text(wd).font(.caption.monospaced()) }
                }
            }
        }
    }

    private func environmentSection(_ env: [String]) -> some View {
        Section("Environment (\(env.count))") {
            ForEach(env.sorted(), id: \.self) { line in
                Text(line).font(.caption.monospaced()).lineLimit(1)
                    .truncationMode(.middle).textSelection(.enabled)
                    .help(line)
            }
        }
    }
}

/// A clickable published-port link; red with an explanatory tooltip when its
/// localhost listener couldn't bind. Strings are String-built on purpose — a
/// literal's Int interpolation becomes a LocalizedStringKey and locale number
/// grouping renders port 3000 as "3 000".
private struct PortLink: View {
    let label: String
    let port: Int
    let blocked: Bool

    var body: some View {
        let portText = String(port)
        Button(label) { RowActions.openPort(port) }
            .buttonStyle(.plain)
            .font(.caption.monospaced())
            .foregroundStyle(blocked ? AnyShapeStyle(.red) : AnyShapeStyle(.link))
            .help(blocked
                  ? "localhost:" + portText + " is unavailable — another app holds it"
                  : "Open http://localhost:" + portText + "/")
    }
}

/// Status capsule with NATIVE uptime ("Up 12 seconds" → "Up 5 minutes"),
/// re-rendered from the container's lifecycle anchor (dockerd's StartedAt) by a
/// `TimelineView` on `UptimeTickSchedule`: second ticks only during the first
/// minute of uptime, minute ticks after — only while visible, no per-second churn
/// on settled rows; the anchor itself refreshes only on lifecycle events. Until
/// the anchor lands (a beat after a transition), Docker's pre-rendered status
/// string fills in. Stopped containers just say "Stopped" — exit code + when
/// live in the hover tooltip.
struct UptimeBadge: View {
    let container: ContainerSummary
    let anchor: DockerResourceStore.LifeAnchor?

    var body: some View {
        content
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
            .help(container.status)
    }

    /// The anchor only speaks for the state it was fetched for.
    private var validAnchor: DockerResourceStore.LifeAnchor? {
        anchor?.state == container.state ? anchor : nil
    }

    @ViewBuilder
    private var content: some View {
        if container.isRunning, let date = validAnchor?.date {
            TimelineView(UptimeTickSchedule(start: date)) { context in
                Text(verbatim: "Up " + Format.containerUptime(since: date, now: context.date)
                              + (container.isUnhealthy ? " · unhealthy" : ""))
            }
        } else if container.state == "exited" {
            Text("Stopped")
        } else {
            Text(container.status.isEmpty ? container.state.capitalized : container.status)
        }
    }

    private var tint: Color {
        // A failing healthcheck outranks "running" — the row should look wrong.
        if container.isUnhealthy { return .orange }
        switch container.state {
        case "running": return .green
        case "paused":  return .yellow
        case "restarting": return .orange
        case "exited", "dead": return .red
        default: return .secondary
        }
    }
}

/// Tick schedule matching the badge text's resolution: every second while the
/// container is in its first minute of uptime (the only window where seconds are
/// rendered), then once a minute. Rows older than a minute never wake per-second,
/// and TimelineView only ticks while the badge is on screen.
private struct UptimeTickSchedule: TimelineSchedule {
    let start: Date

    func entries(from startDate: Date, mode: Mode) -> AnyIterator<Date> {
        let cutover = start.addingTimeInterval(60)
        var next = startDate
        return AnyIterator {
            defer { next = next.addingTimeInterval(next < cutover ? 1 : 60) }
            return next
        }
    }
}

/// Capsule for an action in flight ("Stopping…"), with a small spinner. Shown in
/// place of `StatusBadge` until the action completes.
struct PendingBadge: View {
    let action: PendingAction

    var body: some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini).tint(action.tint)
            Text(action.label).font(.caption).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(action.tint.opacity(0.16), in: Capsule())
        .foregroundStyle(action.tint)
    }
}

#if DEBUG
struct ContainersView_Previews: PreviewProvider {
    static var previews: some View {
        ContainersView(docker: MockDockerClient(),
                       store: DockerResourceStore(docker: MockDockerClient()),
                       stats: StatsStore(docker: MockDockerClient(),
                                         resources: DockerResourceStore(docker: MockDockerClient())),
                       ui: PaneUIState(), issues: PortIssues())
            .frame(width: 860, height: 420)
    }
}
#endif
