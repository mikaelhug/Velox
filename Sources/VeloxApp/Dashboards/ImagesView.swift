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
    @State private var model: ImagesModel
    /// Search + selection survive pane switches (see PaneUIState).
    @Bindable private var ui: PaneUIState
    @State private var pullReference = ""
    @State private var pruneConfirm = false
    @State private var removeConfirm = false
    @State private var tableLayout: TableColumnCustomization<ImageSummary>
    @State private var loadMessage: String?
    @State private var runTarget: ImageSummary?

    init(docker: any DockerClientProtocol, store: DockerResourceStore, ui: PaneUIState) {
        self.ui = ui
        _model = State(initialValue: ImagesModel(docker: docker, store: store))
        _tableLayout = State(initialValue: TableLayout.load("images"))
    }

    private var filtered: [ImageSummary] {
        guard !ui.imageSearch.isEmpty else { return model.images }
        return model.images.filter {
            $0.repository.localizedCaseInsensitiveContains(ui.imageSearch)
                || $0.tag.localizedCaseInsensitiveContains(ui.imageSearch)
        }
    }

    var body: some View {
        Table(filtered, selection: $ui.imageSelection, columnCustomization: $tableLayout) {
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
            // No "Image ID" column — noise at a glance, and it can't show the full
            // SHA anyway; the full ID is one right-click → Copy away.
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
        .contextMenu(forSelectionType: ImageSummary.ID.self) { ids in
            if ids.count == 1, let img = model.images.first(where: { ids.contains($0.id) }) {
                Button("Run…") { runTarget = img }
                Divider()
                Button("Copy Reference") { WorkspaceActions.copy("\(img.repository):\(img.tag)") }
                Button("Copy Image ID") { WorkspaceActions.copy(img.id) }
                Divider()
                Button("Remove", role: .destructive) { ui.imageSelection = ids; removeConfirm = true }
            } else if !ids.isEmpty {
                Button("Remove \(ids.count) Images", role: .destructive) {
                    ui.imageSelection = ids; removeConfirm = true
                }
            }
        }
        // Drag an image tarball (`docker save` output) from Finder onto the table →
        // `docker load`. The events stream refreshes the list when it lands.
        .dropDestination(for: URL.self) { urls, _ in
            guard let tar = urls.first(where: {
                ["tar", "tgz", "gz"].contains($0.pathExtension.lowercased())
            }) else { return false }
            WorkspaceActions.loadImageTar(tar) { failure in
                loadMessage = failure.map { "Load failed: \($0)" }
                    ?? "Loaded \(tar.lastPathComponent)"
            }
            return true
        }
        .alert("Image", isPresented: Binding(
            get: { loadMessage != nil }, set: { if !$0 { loadMessage = nil } })
        ) { Button("OK", role: .cancel) {} } message: { Text(loadMessage ?? "") }
        .sheet(item: $runTarget) { img in
            RunImageSheet(image: img) { message in loadMessage = message }
        }
        .safeAreaInset(edge: .top) { pullBar }
        .searchable(text: $ui.imageSearch, placement: .toolbar, prompt: "Filter images")
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
                .disabled(ui.imageSelection.isEmpty)
                .help(ui.imageSelection.isEmpty ? "Select images to remove" : "Remove the selected image(s)")
            }
        }
        .persistTableLayout(tableLayout, "images")
        .confirmationDialog(
            "Remove \(ui.imageSelection.count) selected image\(ui.imageSelection.count == 1 ? "" : "s")?",
            isPresented: $removeConfirm
        ) {
            Button("Remove", role: .destructive) {
                let ids = ui.imageSelection
                Task { await model.removeImages(ids, force: false); ui.imageSelection.removeAll() }
            }
        } message: {
            Text("This removes the selected image\(ui.imageSelection.count == 1 ? "" : "s"). An image still referenced by a container can't be removed.")
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

/// Minimal quick-run: name, published ports, --rm. Deliberately not a docker-run
/// builder — anything beyond a one-off belongs in the terminal (or compose).
private struct RunImageSheet: View {
    let image: ImageSummary
    var onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var ports = ""
    @State private var removeOnExit = false
    @State private var starting = false

    private var reference: String {
        image.repository == "<none>" ? image.id : "\(image.repository):\(image.tag)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name (optional)", text: $name)
                    TextField("Publish ports — e.g. 8080:80, 5432:5432", text: $ports)
                    Toggle("Remove when it exits (--rm)", isOn: $removeOnExit)
                } header: {
                    Text(verbatim: "Run \(reference)")
                } footer: {
                    Text("Starts detached. The new container appears in Containers the moment it's created.")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if starting { ProgressView().controlSize(.small) }
                Button("Run") { run() }.keyboardShortcut(.defaultAction).disabled(starting)
            }
            .padding(12)
        }
        .frame(width: 400)
    }

    private func run() {
        starting = true
        let publishes = ports.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        WorkspaceActions.runImage(reference: reference,
                                  name: name.isEmpty ? nil : name,
                                  publishes: publishes, removeOnExit: removeOnExit) { failure in
            starting = false
            dismiss()
            onDone(failure.map { "Run failed: \($0)" } ?? "Started \(reference)")
        }
    }
}

/// A compact capsule for an image's architecture ("arm64" / "amd64" / "multi"),
/// or a dash when the daemon doesn't report one.
private struct ArchBadge: View {
    let arch: String?

    var body: some View {
        if let arch {
            // amd64 on an Apple-silicon host runs through Rosetta translation —
            // tint it amber so "why is this one slower" answers itself.
            let foreign = arch == "amd64"
            Text(arch)
                .font(.caption.monospaced())
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(foreign ? AnyShapeStyle(.orange.opacity(0.2))
                                    : AnyShapeStyle(.quaternary), in: Capsule())
                .foregroundStyle(foreign ? .orange : .primary)
                .help(foreign ? "x86-64 image — runs via Rosetta translation" : "Native arm64")
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
struct ImagesView_Previews: PreviewProvider {
    static var previews: some View {
        ImagesView(docker: MockDockerClient(), store: DockerResourceStore(docker: MockDockerClient()), ui: PaneUIState())
            .frame(width: 820, height: 420)
    }
}
#endif
