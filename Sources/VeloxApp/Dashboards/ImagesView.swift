import SwiftUI
import VeloxCore

@MainActor
@Observable
final class ImagesModel {
    let docker: any DockerClientProtocol
    let store: DockerResourceStore
    var actionError: String?

    // Pull progress
    private(set) var isPulling = false
    private(set) var pullStatus = ""

    init(docker: any DockerClientProtocol, store: DockerResourceStore) {
        self.docker = docker; self.store = store
    }

    // Data is read from the shared store (persistent across pane switches).
    var images: [ImageSummary] { store.images }
    var loadError: String? { store.imagesError }
    var hasLoaded: Bool { store.imagesLoaded }

    func refresh() async { await store.refreshImages() }

    func pull(_ reference: String) async {
        guard !reference.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isPulling = true; pullStatus = "Starting…"
        defer { isPulling = false; pullStatus = "" }
        do {
            for try await line in docker.pullImage(reference) { pullStatus = line }
        } catch {
            actionError = "\(error)"
        }
        await store.refreshImages()
    }

    func perform(_ action: @Sendable (any DockerClientProtocol) async throws -> Void) async {
        do { try await action(docker); await store.refreshImages() }
        catch { actionError = "\(error)" }
    }

    /// Remove several images (capped-parallel), then refresh once. Collects the first
    /// failure (e.g. an image still referenced by a container) into `actionError`.
    func removeImages(_ ids: Set<ImageSummary.ID>, force: Bool) async {
        let docker = self.docker
        let firstError = await runBounded(over: ids) { id in
            try await docker.removeImage(id, force: force)
        }
        if let firstError { actionError = firstError }
        await store.refreshImages()
    }
}

struct ImagesView: View {
    let docker: any DockerClientProtocol
    @State private var model: ImagesModel
    @State private var selection = Set<ImageSummary.ID>()
    @State private var searchText = ""
    @State private var pullReference = ""
    @State private var pruneConfirm = false
    @State private var removeConfirm = false
    @State private var tableLayout: TableColumnCustomization<ImageSummary>

    init(docker: any DockerClientProtocol, store: DockerResourceStore) {
        self.docker = docker
        _model = State(initialValue: ImagesModel(docker: docker, store: store))
        _tableLayout = State(initialValue: TableLayout.load("images"))
    }

    private var filtered: [ImageSummary] {
        guard !searchText.isEmpty else { return model.images }
        return model.images.filter {
            $0.repository.localizedCaseInsensitiveContains(searchText)
                || $0.tag.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Table(filtered, selection: $selection, columnCustomization: $tableLayout) {
            TableColumn("Repository") { img in
                Text(img.repository).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            }
                .customizationID("repository")
            TableColumn("Tag") { img in
                Text(img.tag).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
                .customizationID("tag")
            TableColumn("Arch") { img in
                ArchBadge(arch: img.architecture)
            }
                .customizationID("arch")
            TableColumn("Image ID") { img in
                Text(img.shortID).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
                .customizationID("imageID")
            TableColumn("Created") { img in
                Text(Format.age(epoch: img.created)).foregroundStyle(.secondary).lineLimit(1)
            }
                .customizationID("created")
            TableColumn("Size") { img in
                Text(Format.bytes(img.size)).font(.callout.monospacedDigit())
            }
                .customizationID("size")
        }
        .overlay {
            if model.hasLoaded && model.images.isEmpty {
                ContentUnavailableView("No Images", systemImage: SidebarItem.images.systemImage,
                                       description: Text(model.loadError ?? "Pull one to get started."))
            }
        }
        .safeAreaInset(edge: .top) { pullBar }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter images")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { pruneConfirm = true } label: {
                    Label("Prune Unused Images", systemImage: "sparkles")
                }
                .help("Prune unused images")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { removeConfirm = true } label: {
                    Label("Remove Selected", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                .help(selection.isEmpty ? "Select images to remove" : "Remove the selected image(s)")
            }
        }
        .persistTableLayout(tableLayout, "images")
        .confirmationDialog(
            "Remove \(selection.count) selected image\(selection.count == 1 ? "" : "s")?",
            isPresented: $removeConfirm
        ) {
            Button("Remove", role: .destructive) {
                let ids = selection
                Task { await model.removeImages(ids, force: false); selection.removeAll() }
            }
        } message: {
            Text("This removes the selected image\(selection.count == 1 ? "" : "s"). An image still referenced by a container can't be removed.")
        }
        .confirmationDialog("Prune unused images?", isPresented: $pruneConfirm) {
            Button("Prune Unused Images", role: .destructive) {
                Task { await model.perform { _ = try await $0.pruneImages(all: true) } }
            }
        } message: {
            Text("Removes every image not referenced by a container. This cannot be undone.")
        }
        .alert("Action failed", isPresented: Binding(
            get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
        ) { Button("OK", role: .cancel) {} } message: { Text(model.actionError ?? "") }
    }

    private var pullBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
            TextField("Pull image (e.g. nginx:latest)", text: $pullReference)
                .textFieldStyle(.roundedBorder)
                .onSubmit(startPull)
                .disabled(model.isPulling)
            if model.isPulling {
                ProgressView().controlSize(.small)
                Text(model.pullStatus).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).frame(maxWidth: 240, alignment: .leading)
            } else {
                Button("Pull", action: startPull)
                    .disabled(pullReference.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(8)
        .background(.bar)
    }

    private func startPull() {
        let ref = pullReference
        pullReference = ""
        Task { await model.pull(ref) }
    }
}

/// A compact capsule for an image's architecture ("arm64" / "amd64" / "multi"),
/// or a dash when the daemon doesn't report one.
private struct ArchBadge: View {
    let arch: String?

    var body: some View {
        if let arch {
            Text(arch)
                .font(.caption.monospaced())
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
struct ImagesView_Previews: PreviewProvider {
    static var previews: some View {
        ImagesView(docker: MockDockerClient(), store: DockerResourceStore(docker: MockDockerClient()))
            .frame(width: 820, height: 420)
    }
}
#endif
