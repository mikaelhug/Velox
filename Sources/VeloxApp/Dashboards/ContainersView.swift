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
    private(set) var containers: [ContainerSummary] = []
    private(set) var loadError: String?
    var actionError: String?

    /// Containers with an action in flight, keyed by id — drives the optimistic
    /// "Starting…/Stopping…/Restarting…" badge until the action completes.
    private(set) var pending: [String: PendingAction] = [:]

    init(docker: any DockerClientProtocol) { self.docker = docker }

    func setPending(_ ids: [String], _ action: PendingAction) {
        for id in ids { pending[id] = action }
    }
    func clearPending(_ ids: [String]) {
        for id in ids { pending.removeValue(forKey: id) }
    }

    func observe() async {
        await refresh()
        for await event in docker.events() {
            if event.type == nil || event.type == "container" { await refresh() }
        }
    }

    func refresh() async {
        do {
            containers = try await docker.containers()
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
    }

    func perform(_ action: @Sendable (any DockerClientProtocol) async throws -> Void) async {
        do { try await action(docker); await refresh() }
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
        guard !ids.isEmpty else { return }
        let docker = self.docker
        let maxConcurrent = min(ids.count, 16)
        let firstError = await withTaskGroup(of: String?.self) { group -> String? in
            func add(_ id: String) {
                group.addTask {
                    do { try await action(docker, id); return nil }
                    catch { return "\(error)" }
                }
            }
            var iterator = ids.makeIterator()
            for _ in 0..<maxConcurrent { if let id = iterator.next() { add(id) } }
            var err: String?
            while let result = await group.next() {
                if let result, err == nil { err = result }
                if let id = iterator.next() { add(id) }
            }
            return err
        }
        if let firstError { actionError = firstError }
        await refresh()
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

/// A top-level table entry, used to interleave standalone containers and project
/// groups into one alphabetical order before the table renders them.
private enum TopLevelEntry: Identifiable {
    case standalone(ContainerSummary)
    case group(ProjectGroup)

    var id: String {
        switch self {
        case .standalone(let c): return c.id
        case .group(let g):      return "project:\(g.name)"
        }
    }
    var sortKey: String {
        switch self {
        case .standalone(let c): return c.displayName
        case .group(let g):      return g.name
        }
    }
}

struct ContainersView: View {
    let docker: any DockerClientProtocol
    @Environment(\.openWindow) private var openWindow
    @State private var model: ContainersModel
    @State private var selection: Set<ContainerRow.ID> = []
    @State private var searchText = ""
    /// Project names the user has collapsed. Absence ⇒ expanded, so groups open
    /// by default (matching Docker Desktop).
    @State private var collapsed: Set<String> = []
    @State private var pendingDelete: ContainerSummary?
    @State private var pendingBulkDelete: [ContainerSummary] = []
    @State private var tableLayout: TableColumnCustomization<ContainerRow>

    init(docker: any DockerClientProtocol) {
        self.docker = docker
        _model = State(initialValue: ContainersModel(docker: docker))
        _tableLayout = State(initialValue: TableLayout.load("containers"))
    }

    private var filtered: [ContainerSummary] {
        guard !searchText.isEmpty else { return model.containers }
        return model.containers.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.image.localizedCaseInsensitiveContains(searchText)
                || ($0.composeProject?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    /// Standalone containers and Compose project groups, interleaved alphabetically.
    private var topLevel: [TopLevelEntry] {
        var groups: [String: [ContainerSummary]] = [:]
        var standalone: [ContainerSummary] = []
        for c in filtered {
            if let project = c.composeProject {
                groups[project, default: []].append(c)
            } else {
                standalone.append(c)
            }
        }
        var entries = standalone.map(TopLevelEntry.standalone)
        for (name, members) in groups {
            let sorted = members.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            entries.append(.group(ProjectGroup(name: name, containers: sorted)))
        }
        return entries.sorted {
            $0.sortKey.localizedCaseInsensitiveCompare($1.sortKey) == .orderedAscending
        }
    }

    private func expansion(_ name: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(name) },
                set: { isExpanded in
                    if isExpanded { collapsed.remove(name) } else { collapsed.insert(name) }
                })
    }

    var body: some View {
        Table(of: ContainerRow.self, selection: $selection, columnCustomization: $tableLayout) {
            TableColumn("Name") { row in nameCell(row) }
                .customizationID("name")

            TableColumn("Image") { row in
                if case .container(let c) = row {
                    Text(c.image).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
            }
                .customizationID("image")

            TableColumn("Status") { row in statusCell(row) }
                .customizationID("status")

            TableColumn("Ports") { row in
                if case .container(let c) = row {
                    Text(c.ports.isEmpty ? "—" : c.ports.map(\.label).joined(separator: ", "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
                .customizationID("ports")

            TableColumn("CPU / MEM") { row in
                if case .container(let c) = row {
                    ContainerUsageCell(docker: docker, containerID: c.id, isRunning: c.isRunning)
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
        .contextMenu(forSelectionType: ContainerRow.ID.self) { ids in
            contextMenu(for: ids)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter containers")
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
                Button { Task { await model.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { pendingBulkDelete = selectedContainers } label: {
                    Label("Delete selected", systemImage: "trash")
                }
                .help("Delete selected")
                .disabled(selectedContainers.isEmpty)
            }
        }
        .overlay {
            if model.containers.isEmpty {
                ContentUnavailableView("No Containers", systemImage: SidebarItem.containers.systemImage,
                                       description: Text(model.loadError ?? "Run one with `docker run`."))
            }
        }
        .task { await model.observe() }
        .persistTableLayout(tableLayout, "containers")
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
                    selection.removeAll()
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
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.displayName).fontWeight(.medium)
                    Text(c.shortID).font(.caption2.monospaced()).foregroundStyle(.secondary)
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
                StatusBadge(state: c.state, status: c.status)
            }
        case .project(let g):
            Text(projectStatus(g)).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Name-dot tint: transitional (orange) while an action is in flight,
    /// otherwise the container's real-state color.
    private func dotColor(for c: ContainerSummary) -> Color {
        model.pending[c.id]?.tint ?? color(for: c.state)
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

    private var selectedContainers: [ContainerSummary] { containers(for: selection) }

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
        } else {
            Button("Start") { runPending([c.id], .starting) { try await $0.startContainer($1) } }
        }
        Button("View Logs") { openLogs(c) }
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

/// A small status capsule colored by container state.
struct StatusBadge: View {
    let state: String
    let status: String

    var body: some View {
        Text(status.isEmpty ? state.capitalized : status)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch state {
        case "running": return .green
        case "paused":  return .yellow
        case "restarting": return .orange
        case "exited", "dead": return .red
        default: return .secondary
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
        ContainersView(docker: MockDockerClient())
            .frame(width: 860, height: 420)
    }
}
#endif
