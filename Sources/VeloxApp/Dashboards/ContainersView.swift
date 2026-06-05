import SwiftUI
import VeloxCore

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

    init(docker: any DockerClientProtocol) { self.docker = docker }

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

    /// Run an action over many containers (a Compose project's members), then
    /// refresh once. Collects the first failure into `actionError`.
    func performAll(_ ids: [String],
                    _ action: @Sendable @escaping (any DockerClientProtocol, String) async throws -> Void) async {
        guard !ids.isEmpty else { return }
        var firstError: String?
        for id in ids {
            do { try await action(docker, id) }
            catch { if firstError == nil { firstError = "\(error)" } }
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
    @State private var model: ContainersModel
    @State private var selection: ContainerRow.ID?
    @State private var searchText = ""
    /// Project names the user has collapsed. Absence ⇒ expanded, so groups open
    /// by default (matching Docker Desktop).
    @State private var collapsed: Set<String> = []
    @State private var pendingDelete: ContainerSummary?
    @State private var logsTarget: ContainerSummary?

    init(docker: any DockerClientProtocol) {
        self.docker = docker
        _model = State(initialValue: ContainersModel(docker: docker))
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
        Table(of: ContainerRow.self, selection: $selection) {
            TableColumn("Name") { row in nameCell(row) }
                .width(min: 150, ideal: 200, max: 320)

            TableColumn("Image") { row in
                if case .container(let c) = row {
                    Text(c.image).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
            }.width(min: 110, ideal: 170, max: 300)

            TableColumn("Status") { row in statusCell(row) }
                .width(min: 90, ideal: 130, max: 200)

            TableColumn("Ports") { row in
                if case .container(let c) = row {
                    Text(c.ports.isEmpty ? "—" : c.ports.map(\.label).joined(separator: ", "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }.width(min: 70, ideal: 110, max: 180)

            TableColumn("CPU / MEM") { row in
                if case .container(let c) = row {
                    ContainerUsageCell(docker: docker, containerID: c.id, isRunning: c.isRunning)
                }
            }.width(min: 100, ideal: 118, max: 140)

            TableColumn("") { row in actionsCell(row) }.width(132)
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
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
        .overlay {
            if model.containers.isEmpty {
                ContentUnavailableView("No Containers", systemImage: SidebarItem.containers.systemImage,
                                       description: Text(model.loadError ?? "Run one with `docker run`."))
            }
        }
        .task { await model.observe() }
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
        .alert("Action failed", isPresented: Binding(
            get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
        ) { Button("OK", role: .cancel) {} } message: { Text(model.actionError ?? "") }
        .sheet(item: $logsTarget) { c in
            LogStreamView(docker: docker, container: c)
        }
    }

    // MARK: Cells

    @ViewBuilder
    private func nameCell(_ row: ContainerRow) -> some View {
        switch row {
        case .container(let c):
            HStack(spacing: 6) {
                Circle().fill(color(for: c.state)).frame(width: 7, height: 7)
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
            StatusBadge(state: c.state, status: c.status)
        case .project(let g):
            Text(projectStatus(g)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func projectStatus(_ g: ProjectGroup) -> String {
        let running = g.runningCount, total = g.containers.count
        if running == 0 { return "Stopped · \(total)" }
        if running == total { return "Running · \(total)" }
        return "\(running)/\(total) running"
    }

    @ViewBuilder
    private func actionsCell(_ row: ContainerRow) -> some View {
        switch row {
        case .container(let c): rowActions(c)
        case .project(let g):   projectActions(g)
        }
    }

    // MARK: Row actions

    @ViewBuilder
    private func rowActions(_ c: ContainerSummary) -> some View {
        HStack(spacing: 2) {
            if c.isRunning || c.isPaused {
                iconButton("stop.fill", "Stop") { await model.perform { try await $0.stopContainer(c.id) } }
                iconButton("arrow.clockwise", "Restart") { await model.perform { try await $0.restartContainer(c.id) } }
            } else {
                iconButton("play.fill", "Start") { await model.perform { try await $0.startContainer(c.id) } }
            }
            iconButton("text.alignleft", "Logs") { logsTarget = c }
            iconButton("trash", "Delete", role: .destructive) { pendingDelete = c }
        }
    }

    @ViewBuilder
    private func projectActions(_ g: ProjectGroup) -> some View {
        HStack(spacing: 2) {
            if g.runningCount < g.containers.count {
                iconButton("play.fill", "Start project") {
                    await model.performAll(g.containers.filter { !$0.isRunning }.map(\.id)) {
                        try await $0.startContainer($1)
                    }
                }
            }
            if g.runningCount > 0 {
                iconButton("stop.fill", "Stop project") {
                    await model.performAll(g.containers.filter(\.isRunning).map(\.id)) {
                        try await $0.stopContainer($1)
                    }
                }
            }
        }
    }

    // MARK: Context menus

    @ViewBuilder
    private func contextMenu(for ids: Set<ContainerRow.ID>) -> some View {
        if let id = ids.first {
            if let c = model.containers.first(where: { $0.id == id }) {
                containerContext(c)
            } else if let g = group(forRowID: id) {
                projectContext(g)
            }
        }
    }

    @ViewBuilder
    private func containerContext(_ c: ContainerSummary) -> some View {
        if c.isRunning || c.isPaused {
            Button("Stop") { Task { await model.perform { try await $0.stopContainer(c.id) } } }
            Button("Restart") { Task { await model.perform { try await $0.restartContainer(c.id) } } }
        } else {
            Button("Start") { Task { await model.perform { try await $0.startContainer(c.id) } } }
        }
        Button("View Logs") { logsTarget = c }
        Divider()
        Button("Delete", role: .destructive) { pendingDelete = c }
    }

    @ViewBuilder
    private func projectContext(_ g: ProjectGroup) -> some View {
        Button("Start Project") {
            Task { await model.performAll(g.containers.filter { !$0.isRunning }.map(\.id)) { try await $0.startContainer($1) } }
        }
        Button("Stop Project") {
            Task { await model.performAll(g.containers.filter(\.isRunning).map(\.id)) { try await $0.stopContainer($1) } }
        }
        Button("Restart Project") {
            Task { await model.performAll(g.containers.map(\.id)) { try await $0.restartContainer($1) } }
        }
    }

    private func group(forRowID id: String) -> ProjectGroup? {
        guard id.hasPrefix("project:") else { return nil }
        let name = String(id.dropFirst("project:".count))
        for entry in topLevel { if case .group(let g) = entry, g.name == name { return g } }
        return nil
    }

    @ViewBuilder
    private func iconButton(_ symbol: String, _ help: String, role: ButtonRole? = nil,
                            _ action: @escaping () async -> Void) -> some View {
        Button(role: role) { Task { await action() } } label: {
            Image(systemName: symbol).frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
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

#if DEBUG
struct ContainersView_Previews: PreviewProvider {
    static var previews: some View {
        ContainersView(docker: MockDockerClient())
            .frame(width: 860, height: 420)
    }
}
#endif
