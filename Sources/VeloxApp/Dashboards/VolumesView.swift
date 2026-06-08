import SwiftUI
import VeloxCore

@MainActor
@Observable
final class VolumesModel {
    let docker: any DockerClientProtocol
    let store: DockerResourceStore
    var actionError: String?

    init(docker: any DockerClientProtocol, store: DockerResourceStore) {
        self.docker = docker; self.store = store
    }

    // Data is read from the shared store (persistent across pane switches).
    var volumes: [Volume] { store.volumes }
    var loadError: String? { store.volumesError }
    var hasLoaded: Bool { store.volumesLoaded }

    func refresh() async { await store.refreshVolumes() }

    func perform(_ action: @Sendable (any DockerClientProtocol) async throws -> Void) async {
        do { try await action(docker); await store.refreshVolumes() }
        catch { actionError = "\(error)" }
    }

    func removeVolumes(_ ids: Set<Volume.ID>, force: Bool) async {
        let docker = self.docker
        let firstError = await runBounded(over: ids) { id in
            try await docker.removeVolume(id, force: force)
        }
        if let firstError { actionError = firstError }
        await store.refreshVolumes()
    }
}

struct VolumesView: View {
    let docker: any DockerClientProtocol
    @State private var model: VolumesModel
    @State private var selection = Set<Volume.ID>()
    @State private var showInspector = true
    @State private var pruneConfirm = false
    @State private var removeConfirm = false
    @State private var tableLayout: TableColumnCustomization<Volume>

    init(docker: any DockerClientProtocol, store: DockerResourceStore) {
        self.docker = docker
        _model = State(initialValue: VolumesModel(docker: docker, store: store))
        _tableLayout = State(initialValue: TableLayout.load("volumes"))
    }

    private var selected: Volume? { model.volumes.first { selection.contains($0.id) } }

    var body: some View {
        Table(model.volumes, selection: $selection, columnCustomization: $tableLayout) {
            TableColumn("Name") { v in Text(v.name).fontWeight(.medium).lineLimit(1) }
                .customizationID("name")
            TableColumn("Driver") { v in Text(v.driver).foregroundStyle(.secondary) }
                .customizationID("driver")
            TableColumn("Size") { v in
                Text(v.size.map(Format.bytes) ?? "—").font(.callout.monospacedDigit())
            }
                .customizationID("size")
            TableColumn("Created") { v in
                Text(Format.age(iso: v.createdAt)).foregroundStyle(.secondary)
            }
                .customizationID("created")
        }
        .overlay {
            if model.hasLoaded && model.volumes.isEmpty {
                ContentUnavailableView("No Volumes", systemImage: SidebarItem.volumes.systemImage,
                                       description: Text(model.loadError ?? "Named volumes appear here."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { pruneConfirm = true } label: {
                    Label("Prune Unused Volumes", systemImage: "sparkles")
                }
                .help("Prune unused volumes")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { removeConfirm = true } label: {
                    Label("Remove Selected", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                .help(selection.isEmpty ? "Select volumes to remove" : "Remove the selected volume(s)")
            }
            ToolbarItem(placement: .automatic) {
                Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                    .help("Toggle inspector")
            }
        }
        .inspector(isPresented: $showInspector) {
            VolumeInspector(volume: selected)
                .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
        }
        .persistTableLayout(tableLayout, "volumes")
        .confirmationDialog("Prune unused volumes?", isPresented: $pruneConfirm) {
            Button("Prune Volumes", role: .destructive) {
                Task { await model.perform { _ = try await $0.pruneVolumes() } }
            }
        } message: {
            Text("Removes every volume not used by at least one container. Data is deleted permanently.")
        }
        .confirmationDialog(
            "Remove \(selection.count) selected volume\(selection.count == 1 ? "" : "s")?",
            isPresented: $removeConfirm
        ) {
            Button("Remove", role: .destructive) {
                let ids = selection
                Task {
                    await model.removeVolumes(ids, force: false)
                    selection.removeAll()
                }
            }
        } message: {
            Text("This removes the selected volume\(selection.count == 1 ? "" : "s"). A volume still used by a container can't be removed.")
        }
        .alert("Action failed", isPresented: Binding(
            get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
        ) { Button("OK", role: .cancel) {} } message: { Text(model.actionError ?? "") }
    }
}

private struct VolumeInspector: View {
    let volume: Volume?

    var body: some View {
        if let volume {
            Form {
                Section("Volume") {
                    LabeledContent("Name", value: volume.name)
                    LabeledContent("Driver", value: volume.driver)
                    LabeledContent("Size", value: volume.size.map(Format.bytes) ?? "Unknown")
                    LabeledContent("Created", value: Format.age(iso: volume.createdAt))
                }
                Section("Mountpoint") {
                    Text(volume.mountpoint)
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Selection", systemImage: "externaldrive",
                                   description: Text("Select a volume to inspect."))
        }
    }
}

#if DEBUG
struct VolumesView_Previews: PreviewProvider {
    static var previews: some View {
        VolumesView(docker: MockDockerClient(), store: DockerResourceStore(docker: MockDockerClient()))
            .frame(width: 820, height: 420)
    }
}
#endif
