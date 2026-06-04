import SwiftUI
import VeloxCore

@MainActor
@Observable
final class VolumesModel {
    let docker: any DockerClientProtocol
    private(set) var volumes: [Volume] = []
    private(set) var loadError: String?
    var actionError: String?

    init(docker: any DockerClientProtocol) { self.docker = docker }

    func observe() async {
        await refresh()
        for await event in docker.events() {
            if event.type == nil || event.type == "volume" { await refresh() }
        }
    }

    func refresh() async {
        do { volumes = try await docker.volumes(); loadError = nil }
        catch { loadError = "\(error)" }
    }

    func perform(_ action: @Sendable (any DockerClientProtocol) async throws -> Void) async {
        do { try await action(docker); await refresh() }
        catch { actionError = "\(error)" }
    }
}

struct VolumesView: View {
    let docker: any DockerClientProtocol
    @State private var model: VolumesModel
    @State private var selection: Volume.ID?
    @State private var showInspector = true
    @State private var pruneConfirm = false

    init(docker: any DockerClientProtocol) {
        self.docker = docker
        _model = State(initialValue: VolumesModel(docker: docker))
    }

    private var selected: Volume? { model.volumes.first { $0.id == selection } }

    var body: some View {
        Table(model.volumes, selection: $selection) {
            TableColumn("Name") { v in Text(v.name).fontWeight(.medium).lineLimit(1) }
                .width(min: 140, ideal: 200)
            TableColumn("Driver") { v in Text(v.driver).foregroundStyle(.secondary) }
                .width(80)
            TableColumn("Size") { v in
                Text(v.size.map(Format.bytes) ?? "—").font(.callout.monospacedDigit())
            }.width(90)
            TableColumn("Created") { v in
                Text(Format.age(iso: v.createdAt)).foregroundStyle(.secondary)
            }.width(110)
            TableColumn("") { v in
                Button(role: .destructive) {
                    Task { await model.perform { try await $0.removeVolume(v.name, force: false) } }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove volume")
            }.width(40)
        }
        .overlay {
            if model.volumes.isEmpty {
                ContentUnavailableView("No Volumes", systemImage: SidebarItem.volumes.systemImage,
                                       description: Text(model.loadError ?? "Named volumes appear here."))
            }
        }
        .inspector(isPresented: $showInspector) {
            VolumeInspector(volume: selected)
                .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { pruneConfirm = true } label: {
                    Label("Prune", systemImage: "trash")
                }.help("Remove all unused volumes")
            }
            ToolbarItem(placement: .automatic) {
                Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                    .help("Toggle inspector")
            }
        }
        .task { await model.observe() }
        .confirmationDialog("Prune unused volumes?", isPresented: $pruneConfirm) {
            Button("Prune Volumes", role: .destructive) {
                Task { await model.perform { _ = try await $0.pruneVolumes() } }
            }
        } message: {
            Text("Removes every volume not used by at least one container. Data is deleted permanently.")
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
        VolumesView(docker: MockDockerClient())
            .frame(width: 820, height: 420)
    }
}
#endif
