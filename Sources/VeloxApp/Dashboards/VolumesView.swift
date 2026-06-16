import AppKit
import SwiftUI
import UniformTypeIdentifiers
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

    // Memoized grouping/sort (same shape as the Containers pane). The `body`
    // re-evaluates on selection changes too, so cache and recompute only when the
    // volumes OR the cross-referenced container list actually changed — orphan and
    // dangling state both depend on the live container list. `@ObservationIgnored`
    // so updating the cache during `body` doesn't invalidate the view.
    @ObservationIgnored private var layoutSig: Int?
    @ObservationIgnored private var layoutCache = VolumeLayout(entries: [], dangling: [], orphanedProjects: [])

    fileprivate func layout() -> VolumeLayout {
        let vols = store.volumes
        let conts = store.containers
        let loaded = store.containersLoaded
        var hasher = Hasher()
        for v in vols { hasher.combine(v) }
        for c in conts {
            hasher.combine(c.composeProject)
            for m in c.mounts where m.type == "volume" { hasher.combine(m.name) }
        }
        hasher.combine(loaded)
        let sig = hasher.finalize()
        if layoutSig == sig { return layoutCache }
        let result = Self.computeLayout(volumes: vols, containers: conts, containersLoaded: loaded)
        layoutSig = sig
        layoutCache = result
        return result
    }

    /// Standalone volumes first (alphabetical), then Compose-project groups
    /// (alphabetical) — two stable bands, mirroring the Containers pane. A Compose
    /// group is **orphaned** when no container belongs to its project any more (the
    /// project was `compose down`ed but its named volumes survived); a standalone
    /// volume is **dangling** when no container mounts it. Both are computed only once
    /// the container list has loaded, so the pane never flashes "everything dangling"
    /// before that list arrives.
    private static func computeLayout(volumes: [Volume], containers: [ContainerSummary],
                                      containersLoaded: Bool) -> VolumeLayout {
        // Live Compose projects = any project with ≥1 container (all states — the list
        // is `all=1`, so a merely-stopped project still counts as live).
        let liveProjects = Set(containers.compactMap { $0.composeProject })
        // Volume names referenced by some container's named-volume mount.
        let referenced = Set(containers.flatMap { c in
            c.mounts.filter { $0.type == "volume" }.compactMap { $0.name }
        })

        var groups: [String: [Volume]] = [:]
        var standalone: [Volume] = []
        for v in volumes {
            if let project = v.composeProject { groups[project, default: []].append(v) }
            else { standalone.append(v) }
        }

        // A volume is dangling when NO container mounts it — Docker's own definition,
        // applied to EVERY volume (standalone or grouped). Removing one container from a
        // live Compose project leaves that container's exclusive volumes unreferenced, so
        // they go dangling; a volume a surviving container still mounts stays in the
        // `referenced` set, so the shared-volume case is handled by set membership. A
        // merely *stopped* container still appears in the `all=1` list with its mounts,
        // so its volumes are NOT dangling — only removal (gone from the list) is.
        let dangling: Set<String> = containersLoaded
            ? Set(volumes.filter { !referenced.contains($0.name) }.map(\.id))
            : []
        let orphanedProjects: Set<String> = containersLoaded
            ? Set(groups.keys.filter { !liveProjects.contains($0) })
            : []

        let standaloneEntries = standalone
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(VolumeEntry.standalone)
        let groupEntries = groups
            .map { name, members in
                VolumeGroup(name: name,
                            volumes: members.sorted {
                                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                            },
                            orphaned: orphanedProjects.contains(name))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(VolumeEntry.group)
        return VolumeLayout(entries: standaloneEntries + groupEntries,
                            dangling: dangling,
                            orphanedProjects: orphanedProjects)
    }

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

/// A set of volumes sharing a `com.docker.compose.project` label.
struct VolumeGroup: Identifiable, Hashable {
    let name: String
    let volumes: [Volume]
    /// True when no container belongs to this Compose project any more — the project
    /// was torn down (`compose down`) but its named volumes survived.
    let orphaned: Bool
    var id: String { name }
}

/// One row in the volumes table: a Compose-project header (expandable) or a single
/// volume. Both share this type so the table can nest them under a `DisclosureTableRow`.
enum VolumeRow: Identifiable, Hashable {
    case project(VolumeGroup)
    case volume(Volume)

    var id: String {
        switch self {
        case .project(let g): return "project:\(g.name)"
        case .volume(let v):  return v.id
        }
    }
}

/// A top-level table entry: standalone volumes band first, project groups band below,
/// each alphabetical.
fileprivate enum VolumeEntry: Identifiable {
    case standalone(Volume)
    case group(VolumeGroup)

    var id: String {
        switch self {
        case .standalone(let v): return v.id
        case .group(let g):      return "project:\(g.name)"
        }
    }
}

/// The memoized result the Volumes table renders: the ordered entries plus the
/// cross-referenced state the cells colour by.
fileprivate struct VolumeLayout {
    let entries: [VolumeEntry]
    /// Volume ids no container mounts — Docker-dangling, standalone or grouped.
    let dangling: Set<String>
    /// Compose projects with no containers left.
    let orphanedProjects: Set<String>
}

struct VolumesView: View {
    @State private var model: VolumesModel
    /// Selection + inspector visibility survive pane switches (see PaneUIState).
    @Bindable private var ui: PaneUIState
    @State private var pruneConfirm = false
    @State private var removeConfirm = false
    @State private var tableLayout: TableColumnCustomization<VolumeRow>
    // Volume ↔ tar transfer (backup/migrate): export streams `tar cf` straight to the
    // chosen file; import creates the volume and untars into it. Both via the engine.
    @State private var importTar: URL?
    @State private var importName = ""
    @State private var transferMessage: String?

    init(docker: any DockerClientProtocol, store: DockerResourceStore, ui: PaneUIState) {
        self.ui = ui
        _model = State(initialValue: VolumesModel(docker: docker, store: store))
        _tableLayout = State(initialValue: TableLayout.load("volumes"))
    }

    /// The single selected volume, for the inspector (a project header never matches).
    private var selected: Volume? {
        guard ui.volumeSelection.count == 1, let id = ui.volumeSelection.first else { return nil }
        return model.volumes.first { $0.id == id }
    }

    /// Standalone volumes (alphabetical) above Compose project groups (alphabetical),
    /// memoized in the model — recomputed only when the volumes or the cross-referenced
    /// container list change.
    private var layout: VolumeLayout { model.layout() }

    private func expansion(_ name: String) -> Binding<Bool> {
        Binding(get: { [ui] in !ui.volumeCollapsed.contains(name) },
                set: { [ui] isExpanded in
                    if isExpanded { ui.volumeCollapsed.remove(name) }
                    else { ui.volumeCollapsed.insert(name) }
                })
    }

    var body: some View {
        Table(of: VolumeRow.self, selection: $ui.volumeSelection, columnCustomization: $tableLayout) {
            TableColumn("Name") { row in nameCell(row) }
                .customizationID("name")
            // No "Driver" column — it's "local" for effectively every volume; the
            // inspector still shows it for the exceptions.
            TableColumn("Size") { row in sizeCell(row) }
                .customizationID("size")
            TableColumn("Created") { row in
                if case .volume(let v) = row {
                    Text(Format.age(iso: v.createdAt)).foregroundStyle(.secondary)
                }
            }
                .customizationID("created")
        } rows: {
            ForEach(layout.entries) { entry in
                switch entry {
                case .standalone(let v):
                    TableRow(VolumeRow.volume(v))
                case .group(let g):
                    DisclosureTableRow(VolumeRow.project(g), isExpanded: expansion(g.name)) {
                        ForEach(g.volumes) { v in TableRow(VolumeRow.volume(v)) }
                    }
                }
            }
        }
        .suppressHorizontalScroller()
        .alternatingRowBackgrounds(.disabled)
        .overlay {
            if model.hasLoaded && model.volumes.isEmpty {
                ContentUnavailableView("No Volumes", systemImage: SidebarItem.volumes.systemImage,
                                       description: Text(model.loadError ?? "Named volumes appear here."))
            }
        }
        .contextMenu(forSelectionType: VolumeRow.ID.self) { ids in
            contextMenu(for: ids)
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
                .disabled(selectedVolumes.isEmpty)
                .help(selectedVolumes.isEmpty ? "Select volumes to remove" : "Remove the selected volume(s)")
            }
            ToolbarItem(placement: .automatic) {
                Button { pickImportTar() } label: { Label("Import Volume", systemImage: "square.and.arrow.down") }
                    .help("Create a volume from a tar archive")
            }
            ToolbarItem(placement: .automatic) {
                Button { ui.volumeInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                    .help("Toggle inspector")
            }
        }
        .alert("Import Volume", isPresented: Binding(
            get: { importTar != nil }, set: { if !$0 { importTar = nil } })
        ) {
            TextField("Volume name", text: $importName)
            Button("Import") {
                guard let tar = importTar, !importName.isEmpty else { return }
                importTar = nil
                WorkspaceActions.importVolume(importName, from: tar) { failure in
                    transferMessage = failure.map { "Import failed: \($0)" }
                        ?? "Imported \(tar.lastPathComponent) into volume “\(importName)”"
                    Task { await model.perform { _ in } } // refresh the list
                }
            }
            Button("Cancel", role: .cancel) { importTar = nil }
        } message: {
            Text("The archive's contents become the volume's contents. An existing volume with this name is merged into.")
        }
        .alert("Volume Transfer", isPresented: Binding(
            get: { transferMessage != nil }, set: { if !$0 { transferMessage = nil } })
        ) { Button("OK", role: .cancel) {} } message: { Text(transferMessage ?? "") }
        .inspector(isPresented: $ui.volumeInspector) {
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
            "Remove \(selectedVolumes.count) selected volume\(selectedVolumes.count == 1 ? "" : "s")?",
            isPresented: $removeConfirm
        ) {
            Button("Remove", role: .destructive) {
                let ids = Set(selectedVolumes.map(\.id))
                Task {
                    await model.removeVolumes(ids, force: false)
                    ui.volumeSelection.removeAll()
                }
            }
        } message: {
            Text("This removes the selected volume\(selectedVolumes.count == 1 ? "" : "s"). A volume still used by a container can't be removed.")
        }
        .alert("Action failed", isPresented: Binding(
            get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
        ) { Button("OK", role: .cancel) {} } message: { Text(model.actionError ?? "") }
    }
}

extension VolumesView {
    private static let tarType = UTType(filenameExtension: "tar") ?? .data

    fileprivate func exportVolume(_ v: Volume) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(v.name).tar"
        panel.allowedContentTypes = [Self.tarType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        WorkspaceActions.exportVolume(v.name, to: url) { failure in
            transferMessage = failure.map { "Export failed: \($0)" }
                ?? "Exported “\(v.name)” to \(url.lastPathComponent)"
        }
    }

    fileprivate func pickImportTar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.tarType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importName = url.deletingPathExtension().lastPathComponent
        importTar = url
    }
}

// MARK: - Cells

extension VolumesView {
    @ViewBuilder
    fileprivate func nameCell(_ row: VolumeRow) -> some View {
        switch row {
        case .volume(let v):
            // Dangling (no container mounts it), or a member of a fully-orphaned project —
            // either way greyed. The per-row "dangling" badge marks the standalone and the
            // *live-group* cases (a single container removed from an otherwise-running
            // project); inside an orphaned group the header badge already says it, so the
            // per-row badge is suppressed to avoid doubling up.
            let dangling = layout.dangling.contains(v.id)
            let inOrphan = v.composeProject.map(layout.orphanedProjects.contains) ?? false
            HStack(spacing: 6) {
                Text(v.name).fontWeight(.medium).lineLimit(1)
                    .foregroundStyle(dangling || inOrphan ? .secondary : .primary)
                if dangling && !inOrphan {
                    VolumeBadge(text: "dangling", help: "No container references this volume")
                }
            }
        case .project(let g):
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(g.orphaned ? AnyShapeStyle(.secondary) : AnyShapeStyle(.blue))
                Text(g.name).fontWeight(.semibold)
                    .foregroundStyle(g.orphaned ? .secondary : .primary)
                if g.orphaned {
                    VolumeBadge(text: "orphaned",
                                help: "This Compose project no longer has any containers")
                }
            }
        }
    }

    @ViewBuilder
    fileprivate func sizeCell(_ row: VolumeRow) -> some View {
        switch row {
        case .volume(let v):
            Text(v.size.map(Format.bytes) ?? "—").font(.callout.monospacedDigit())
        case .project(let g):
            // Sum the members' known sizes — "—" only when none are known yet.
            let total = g.volumes.compactMap(\.size).reduce(0, +)
            Text(g.volumes.contains { $0.size != nil } ? Format.bytes(total) : "—")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Selection & context menus

extension VolumesView {
    /// Selected rows resolved to concrete volumes — a selected project header expands
    /// to all its members.
    fileprivate var selectedVolumes: [Volume] { volumes(for: ui.volumeSelection) }

    private func volumes(for ids: Set<VolumeRow.ID>) -> [Volume] {
        var byID: [String: Volume] = [:]
        for id in ids {
            if let v = model.volumes.first(where: { $0.id == id }) {
                byID[v.id] = v
            } else if let g = group(forRowID: id) {
                for v in g.volumes { byID[v.id] = v }
            }
        }
        return Array(byID.values)
    }

    private func group(forRowID id: String) -> VolumeGroup? {
        guard id.hasPrefix("project:") else { return nil }
        let name = String(id.dropFirst("project:".count))
        for entry in layout.entries { if case .group(let g) = entry, g.name == name { return g } }
        return nil
    }

    @ViewBuilder
    fileprivate func contextMenu(for ids: Set<VolumeRow.ID>) -> some View {
        if ids.count <= 1, let id = ids.first {
            if let v = model.volumes.first(where: { $0.id == id }) {
                volumeContext(v)
            } else if let g = group(forRowID: id) {
                projectContext(g)
            }
        } else {
            let vols = volumes(for: ids)
            if !vols.isEmpty {
                Button("Remove \(vols.count) Volumes", role: .destructive) {
                    ui.volumeSelection = ids; removeConfirm = true
                }
            }
        }
    }

    @ViewBuilder
    private func volumeContext(_ v: Volume) -> some View {
        Button("Copy Name") { WorkspaceActions.copy(v.name) }
        Button("Copy Mountpoint") { WorkspaceActions.copy(v.mountpoint) }
        Divider()
        Button("Export as tar…") { exportVolume(v) }
        Divider()
        Button("Remove", role: .destructive) { ui.volumeSelection = [v.id]; removeConfirm = true }
    }

    @ViewBuilder
    private func projectContext(_ g: VolumeGroup) -> some View {
        // Only the dangling members are actually removable — an in-use volume errors out
        // under force:false — so scope this one-click action to those and it never
        // half-fails. An orphaned project's members are all dangling, so this still clears
        // the whole group; a live group offers it only for the danglers it has.
        let removable = g.volumes.filter { layout.dangling.contains($0.id) }
        if !removable.isEmpty {
            let noun = g.orphaned ? "Project Volume" : "Dangling Volume"
            Button("Remove \(removable.count) \(noun)\(removable.count == 1 ? "" : "s")",
                   role: .destructive) {
                ui.volumeSelection = Set(removable.map(\.id)); removeConfirm = true
            }
        }
    }
}

/// A small capsule badge for a volume's lifecycle state ("dangling" / "orphaned").
private struct VolumeBadge: View {
    let text: String
    let help: String
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
            .help(help)
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
        VolumesView(docker: MockDockerClient(), store: DockerResourceStore(docker: MockDockerClient()), ui: PaneUIState())
            .frame(width: 820, height: 420)
    }
}
#endif
