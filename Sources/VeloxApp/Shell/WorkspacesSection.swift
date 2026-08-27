import AppKit
import SwiftUI
import VeloxCore

/// The sidebar's Workspaces list: every workspace, which one is active, and the actions
/// that create, duplicate, rename, relocate and delete them.
///
/// The rows are deliberately **not** `List` selection items. Clicking one switches the
/// engine — it does not navigate — so tagging them would make the detail pane follow a
/// click that was never about the detail pane. They are plain buttons inside the section,
/// which also keeps the sidebar's `selection` binding meaning exactly what it did before.
struct WorkspacesSection: View {
    @Environment(EngineController.self) private var engine

    @State private var pendingSwitch: Workspace?
    @State private var creating = false
    @State private var newName = ""
    @State private var renaming: Workspace?
    @State private var renameText = ""
    @State private var duplicating: Workspace?
    @State private var duplicateName = ""
    @State private var pendingDelete: Workspace?
    @State private var deleteConfirmation = ""
    @State private var actionError: String?

    var body: some View {
        Section {
            ForEach(engine.workspaces?.workspaces.sorted(by: { $0.created < $1.created }) ?? []) { workspace in
                WorkspaceRow(workspace: workspace,
                             isActive: workspace.id == engine.workspaces?.activeID,
                             action: { requestSwitch(to: workspace) })
                    .contextMenu { menu(for: workspace) }
            }
        } header: {
            HStack(spacing: 4) {
                Text("Workspaces")
                Spacer()
                Button {
                    newName = ""
                    creating = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New workspace")
                .disabled(engine.isEngineOwned)
            }
        }
        .confirmationDialog(
            "Switch to “\(pendingSwitch?.name ?? "")”?",
            isPresented: Binding(get: { pendingSwitch != nil },
                                 set: { if !$0 { pendingSwitch = nil } }),
            presenting: pendingSwitch
        ) { workspace in
            Button("Switch") { performSwitch(to: workspace) }
            Button("Cancel", role: .cancel) { pendingSwitch = nil }
        } message: { workspace in
            Text("The engine restarts with \(workspace.name)'s containers, images and "
                + "volumes. Anything running now keeps its state and comes back when you "
                + "switch back.")
        }
        .alert("New Workspace", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("An empty workspace with its own containers, images and volumes. "
                + "It starts at \(engine.activeWorkspace?.diskGiB ?? 64) GB, and takes up "
                + "no space on your Mac until you use it.")
        }
        .alert("Rename Workspace", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField("Name", text: $renameText)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Duplicate “\(duplicating?.name ?? "")”", isPresented: Binding(
            get: { duplicating != nil }, set: { if !$0 { duplicating = nil } })
        ) {
            TextField("Name", text: $duplicateName)
            Button("Duplicate") { duplicate() }
            Button("Cancel", role: .cancel) { duplicating = nil }
        } message: {
            // The APFS clone shares every block until the two copies diverge, so this is
            // instant and initially free — worth saying, because "duplicate my 40 GB
            // workspace" otherwise sounds like something you'd avoid doing.
            Text("Copies every container, image and volume. On an Apple File System disk "
                + "this is instant and uses no extra space until the two workspaces "
                + "diverge.")
        }
        .alert("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil; deleteConfirmation = "" } })
        ) {
            TextField("Type the workspace name", text: $deleteConfirmation)
            Button("Delete Permanently", role: .destructive) { delete() }
                .disabled(!deleteConfirmationMatches)
            Button("Cancel", role: .cancel) { pendingDelete = nil; deleteConfirmation = "" }
        } message: {
            if let workspace = pendingDelete {
                Text("This permanently deletes every container, image, volume and network in "
                    + "“\(workspace.name)”, and its \(workspace.allocatedDescription) disk at "
                    + "\(workspace.dataDiskURL.path). This can't be undone.\n\n"
                    + "Type “\(workspace.name)” to confirm.")
            }
        }
        .alert("Action failed", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) { Button("OK", role: .cancel) {} } message: { Text(actionError ?? "") }
    }

    // MARK: - Menu

    @ViewBuilder
    private func menu(for workspace: Workspace) -> some View {
        let isActive = workspace.id == engine.workspaces?.activeID
        let busy = engine.isEngineOwned
        if !isActive {
            Button("Switch to This Workspace") { requestSwitch(to: workspace) }
                .disabled(busy)
            Divider()
        }
        Button("Duplicate…") {
            duplicateName = "\(workspace.name) copy"
            duplicating = workspace
        }
        // Duplicating the ACTIVE workspace is allowed — `cloneWorkspace` stops the engine
        // first, which is what actually makes the copy safe. The disk check here only
        // catches a filesystem that has recorded errors (see `Storage.dataDiskIsClean`).
        .disabled(busy || !workspace.diskExists
                  || !Storage.dataDiskIsClean(at: workspace.dataDiskURL))
        Button("Rename…") {
            renameText = workspace.name
            renaming = workspace
        }
        Button("Change Location…") { relocate(workspace) }
            .disabled(busy)
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([workspace.dataDiskURL])
        }
        .disabled(!workspace.diskExists)
        Divider()
        Button("Delete…", role: .destructive) {
            deleteConfirmation = ""
            pendingDelete = workspace
        }
        // Deleting the active workspace would mean an implicit engine restart hidden inside
        // a delete; deleting the last one would leave Velox with nothing to boot.
        .disabled(busy || isActive || (engine.workspaces?.workspaces.count ?? 0) <= 1)
    }

    private var deleteConfirmationMatches: Bool {
        guard let pendingDelete else { return false }
        return Workspace.normalized(deleteConfirmation) == Workspace.normalized(pendingDelete.name)
    }

    // MARK: - Actions

    private func requestSwitch(to workspace: Workspace) {
        guard workspace.id != engine.workspaces?.activeID, !engine.isEngineOwned else { return }
        pendingSwitch = workspace
    }

    private func performSwitch(to workspace: Workspace) {
        pendingSwitch = nil
        Task {
            do { try await engine.switchWorkspace(to: workspace) }
            catch { actionError = message(error) }
        }
    }

    private func create() {
        do { try engine.createWorkspace(name: newName) }
        catch { actionError = message(error) }
    }

    private func rename() {
        guard let workspace = renaming else { return }
        renaming = nil
        do { try engine.renameWorkspace(workspace, to: renameText) }
        catch { actionError = message(error) }
    }

    private func duplicate() {
        guard let workspace = duplicating else { return }
        duplicating = nil
        let name = duplicateName
        Task {
            do { _ = try await engine.cloneWorkspace(workspace, newName: name) }
            catch { actionError = message(error) }
        }
    }

    private func delete() {
        guard let workspace = pendingDelete, deleteConfirmationMatches else { return }
        pendingDelete = nil
        deleteConfirmation = ""
        do { try engine.deleteWorkspace(workspace) }
        catch { actionError = message(error) }
    }

    private func relocate(_ workspace: Workspace) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to hold “\(workspace.name)” (data.img)"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task {
            do { try await engine.moveWorkspace(workspace, to: dir) }
            catch { actionError = message(error) }
        }
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

/// One workspace row: a button, not a navigation item (see `WorkspacesSection`).
private struct WorkspaceRow: View {
    let workspace: Workspace
    let isActive: Bool
    let action: () -> Void

    @Environment(EngineController.self) private var engine

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .font(.caption)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(workspace.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(isActive ? .semibold : .regular)
                Spacer(minLength: 0)
                if missing {
                    // The entry is real but its disk isn't there — an unplugged drive, most
                    // likely. Flagged rather than hidden, because starting it will (rightly)
                    // fail loudly instead of quietly creating an empty one.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("This workspace's disk is missing — is the drive it lives on "
                            + "connected?\n\(workspace.dataDiskURL.path)")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(engine.isEngineOwned)
        .help(helpText)
    }

    private var missing: Bool { workspace.firstBootedAt != nil && !workspace.diskExists }

    private var helpText: String {
        let where_ = (workspace.dataDiskURL.deletingLastPathComponent().path as NSString)
            .abbreviatingWithTildeInPath
        let size = workspace.diskExists
            ? "\(workspace.allocatedDescription) used of \(workspace.diskGiB) GB"
            : "not created yet · \(workspace.diskGiB) GB max"
        return isActive ? "Active · \(size)\n\(where_)"
                        : "Click to switch · \(size)\n\(where_)"
    }
}
