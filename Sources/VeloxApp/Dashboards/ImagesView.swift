import SwiftUI
import VeloxCore

@MainActor
@Observable
final class ImagesModel {
    let docker: any DockerClientProtocol
    private(set) var images: [ImageSummary] = []
    private(set) var loadError: String?
    var actionError: String?

    // Pull progress
    private(set) var isPulling = false
    private(set) var pullStatus = ""

    init(docker: any DockerClientProtocol) { self.docker = docker }

    func observe() async {
        await refresh()
        for await event in docker.events() {
            if event.type == nil || event.type == "image" { await refresh() }
        }
    }

    func refresh() async {
        do { images = try await docker.images(); loadError = nil }
        catch { loadError = "\(error)" }
    }

    func pull(_ reference: String) async {
        guard !reference.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isPulling = true; pullStatus = "Starting…"
        defer { isPulling = false; pullStatus = "" }
        do {
            for try await line in docker.pullImage(reference) { pullStatus = line }
        } catch {
            actionError = "\(error)"
        }
        await refresh()
    }

    func perform(_ action: @Sendable (any DockerClientProtocol) async throws -> Void) async {
        do { try await action(docker); await refresh() }
        catch { actionError = "\(error)" }
    }
}

struct ImagesView: View {
    let docker: any DockerClientProtocol
    @State private var model: ImagesModel
    @State private var selection: ImageSummary.ID?
    @State private var searchText = ""
    @State private var pullReference = ""
    @State private var pruneConfirm = false
    @State private var tagTarget: ImageSummary?

    init(docker: any DockerClientProtocol) {
        self.docker = docker
        _model = State(initialValue: ImagesModel(docker: docker))
    }

    private var filtered: [ImageSummary] {
        guard !searchText.isEmpty else { return model.images }
        return model.images.filter {
            $0.repository.localizedCaseInsensitiveContains(searchText)
                || $0.tag.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Table(filtered, selection: $selection) {
            TableColumn("Repository") { img in
                Text(img.repository).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            }.width(min: 140, ideal: 220)
            TableColumn("Tag") { img in
                Text(img.tag).font(.callout).foregroundStyle(.secondary)
            }.width(min: 70, ideal: 110)
            TableColumn("Image ID") { img in
                Text(img.shortID).font(.caption.monospaced()).foregroundStyle(.secondary)
            }.width(110)
            TableColumn("Created") { img in
                Text(Format.age(epoch: img.created)).foregroundStyle(.secondary)
            }.width(110)
            TableColumn("Size") { img in
                Text(Format.bytes(img.size)).font(.callout.monospacedDigit())
            }.width(90)
            TableColumn("") { img in
                HStack(spacing: 2) {
                    Button { tagTarget = img } label: { Image(systemName: "tag") }
                        .buttonStyle(.borderless).help("Tag image")
                    Button(role: .destructive) {
                        Task { await model.perform { try await $0.removeImage(img.id, force: false) } }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Remove image")
                }
            }.width(64)
        }
        .overlay {
            if model.images.isEmpty {
                ContentUnavailableView("No Images", systemImage: SidebarItem.images.systemImage,
                                       description: Text(model.loadError ?? "Pull one to get started."))
            }
        }
        .safeAreaInset(edge: .top) { pullBar }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter images")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { pruneConfirm = true } label: {
                    Label("Prune Unused", systemImage: "trash")
                }
                .help("Remove all images not used by a container")
            }
        }
        .task { await model.observe() }
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
        .sheet(item: $tagTarget) { img in TagSheet(image: img, model: model) }
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

/// Sheet for tagging an image with a new repository:tag.
private struct TagSheet: View {
    let image: ImageSummary
    let model: ImagesModel
    @Environment(\.dismiss) private var dismiss
    @State private var repository = ""
    @State private var tag = "latest"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tag Image").font(.headline)
            Text(image.repository + ":" + image.tag)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Form {
                TextField("Repository", text: $repository, prompt: Text("acme/web"))
                TextField("Tag", text: $tag)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Tag") {
                    Task {
                        await model.perform { try await $0.tagImage(image.id, repository: repository, tag: tag) }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(repository.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

#if DEBUG
struct ImagesView_Previews: PreviewProvider {
    static var previews: some View {
        ImagesView(docker: MockDockerClient())
            .frame(width: 820, height: 420)
    }
}
#endif
