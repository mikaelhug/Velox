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
}

struct ContainersView: View {
    let docker: any DockerClientProtocol
    @State private var model: ContainersModel
    @State private var selection: ContainerSummary.ID?
    @State private var searchText = ""
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
        }
    }

    var body: some View {
        Table(filtered, selection: $selection) {
            TableColumn("Name") { c in
                HStack(spacing: 6) {
                    Circle().fill(color(for: c.state)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.displayName).fontWeight(.medium)
                        Text(c.shortID).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }.width(min: 140, ideal: 170)

            TableColumn("Image") { c in
                Text(c.image).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }.width(min: 120, ideal: 200)

            TableColumn("Status") { c in StatusBadge(state: c.state, status: c.status) }
                .width(min: 110, ideal: 150)

            TableColumn("Ports") { c in
                Text(c.ports.isEmpty ? "—" : c.ports.map(\.label).joined(separator: ", "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }.width(min: 90, ideal: 130)

            TableColumn("CPU / MEM") { c in
                ContainerUsageCell(docker: docker, containerID: c.id, isRunning: c.isRunning)
            }.width(min: 110, ideal: 130)

            TableColumn("") { c in rowActions(c) }.width(132)
        }
        .contextMenu(forSelectionType: ContainerSummary.ID.self) { ids in
            if let c = model.containers.first(where: { ids.contains($0.id) }) {
                contextActions(c)
            }
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
    private func contextActions(_ c: ContainerSummary) -> some View {
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
