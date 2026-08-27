import AppKit
import SwiftUI
import VeloxCore

/// The sidebar's Workspaces list: every workspace, which one is active, and a "+" to add one.
///
/// This renders **only** the section. Every dialog it can raise is attached to the sidebar
/// `List` by `RootView` via `.workspacePrompts()`, because presentation modifiers hung off a
/// `Section` are unreliable — the alert can silently never appear. The state they share lives
/// in `EngineController.workspacePanel`.
///
/// The rows are deliberately **not** `List` selection items either. Clicking one switches the
/// engine; it does not navigate. Tagging them would make the detail pane follow a click that
/// was never about the detail pane.
struct WorkspacesSection: View {
    @Environment(EngineController.self) private var engine

    var body: some View {
        Section {
            ForEach(engine.sortedWorkspaces) { workspace in
                WorkspaceRow(workspace: workspace,
                             isActive: workspace.id == engine.workspaces?.activeID)
                    .contextMenu { menu(for: workspace) }
            }
        } header: {
            HStack(spacing: 4) {
                Text("Workspaces")
                Spacer()
                Button {
                    engine.workspacePanel.begin(.create)
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
    }

    @ViewBuilder
    private func menu(for workspace: Workspace) -> some View {
        let state = engine.capabilities(for: workspace)
        let panel = engine.workspacePanel

        if !state.isActive {
            Button("Switch to This Workspace") { panel.begin(.confirmSwitch(workspace)) }
                .disabled(!state.canSwitch)
            Divider()
        }
        Button("Duplicate…") {
            panel.begin(.duplicate(workspace), suggesting: "\(workspace.name) copy")
        }
        .disabled(!state.canDuplicate)
        Button("Rename…") {
            panel.begin(.rename(workspace), suggesting: workspace.name)
        }
        .disabled(!state.canRename)
        Button("Change Location…") { relocate(workspace) }
            .disabled(!state.canRelocate)
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([workspace.dataDiskURL])
        }
        .disabled(!state.canRevealInFinder)
        Divider()
        Button("Delete…", role: .destructive) { panel.begin(.delete(workspace)) }
            .disabled(!state.canDelete)
            .help(state.deleteBlockedReason ?? "")
    }

    /// The folder picker is the one action that can't be driven from the panel state: it must
    /// run its modal before there is anything to confirm.
    private func relocate(_ workspace: Workspace) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to hold “\(workspace.name)” (data.img)"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task { await engine.performMove(workspace, to: dir) }
    }
}

/// One workspace row: a button, not a navigation item (see `WorkspacesSection`).
private struct WorkspaceRow: View {
    let workspace: Workspace
    let isActive: Bool

    @Environment(EngineController.self) private var engine

    var body: some View {
        Button {
            guard !isActive, !engine.isEngineOwned else { return }
            engine.workspacePanel.begin(.confirmSwitch(workspace))
        } label: {
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
                    // fail loudly instead of quietly creating an empty one in its place.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
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
        if missing {
            return "This workspace's disk is missing — is the drive it lives on connected?\n"
                 + workspace.dataDiskURL.path
        }
        let folder = (workspace.dataDiskURL.deletingLastPathComponent().path as NSString)
            .abbreviatingWithTildeInPath
        let size = workspace.diskExists
            ? "\(workspace.allocatedDescription) used of \(workspace.diskGiB) GB"
            : "not created yet · \(workspace.diskGiB) GB max"
        return (isActive ? "Active · \(size)" : "Click to switch · \(size)") + "\n\(folder)"
    }
}

// MARK: - Prompts

extension View {
    /// Host every workspace dialog on a stable view (the sidebar `List`), not on the section
    /// that raises them. See `WorkspacePanel` for why this separation exists.
    func workspacePrompts(_ engine: EngineController) -> some View {
        modifier(WorkspacePrompts(engine: engine))
    }
}

private struct WorkspacePrompts: ViewModifier {
    let engine: EngineController

    private var panel: WorkspacePanel { engine.workspacePanel }

    /// One binding per prompt kind: `.alert` needs an `isPresented` it can clear itself when
    /// the user dismisses with Esc or a Cancel button.
    private func presenting(_ match: @escaping (WorkspacePanel.Prompt) -> Bool) -> Binding<Bool> {
        Binding(
            get: { panel.prompt.map(match) ?? false },
            set: { if !$0 { panel.dismiss() } })
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                switchTitle,
                isPresented: presenting { if case .confirmSwitch = $0 { return true }; return false }
            ) {
                Button("Switch") { confirmSwitch() }
                Button("Cancel", role: .cancel) { panel.dismiss() }
            } message: {
                Text("The engine restarts with this workspace's containers, images and "
                    + "volumes. Anything running now keeps its state and comes back when you "
                    + "switch back.")
            }
            .alert("New Workspace",
                   isPresented: presenting { $0 == .create }) {
                TextField("Name", text: Bindable(panel).text)
                Button("Create") { confirmCreate() }.disabled(!panel.primaryEnabled)
                Button("Cancel", role: .cancel) { panel.dismiss() }
            } message: {
                Text("An empty workspace with its own containers, images and volumes. It "
                    + "starts at \(engine.activeWorkspace?.diskGiB ?? 64) GB and takes up no "
                    + "space on your Mac until you use it.")
            }
            .alert("Rename Workspace",
                   isPresented: presenting { if case .rename = $0 { return true }; return false }) {
                TextField("Name", text: Bindable(panel).text)
                Button("Rename") { confirmRename() }.disabled(!panel.primaryEnabled)
                Button("Cancel", role: .cancel) { panel.dismiss() }
            }
            .alert(duplicateTitle,
                   isPresented: presenting { if case .duplicate = $0 { return true }; return false }) {
                TextField("Name", text: Bindable(panel).text)
                Button("Duplicate") { confirmDuplicate() }.disabled(!panel.primaryEnabled)
                Button("Cancel", role: .cancel) { panel.dismiss() }
            } message: {
                // Worth saying: "duplicate my 40 GB workspace" otherwise sounds expensive.
                Text("Copies every container, image and volume. On an Apple File System disk "
                    + "this is instant and uses no extra space until the two diverge.")
            }
            .alert(deleteTitle,
                   isPresented: presenting { if case .delete = $0 { return true }; return false }) {
                TextField("Type the workspace name", text: Bindable(panel).text)
                Button("Delete Permanently", role: .destructive) { confirmDelete() }
                    .disabled(!panel.primaryEnabled)
                Button("Cancel", role: .cancel) { panel.dismiss() }
            } message: {
                Text(deleteMessage)
            }
            .alert("Action failed", isPresented: Binding(
                get: { panel.error != nil },
                set: { if !$0 { panel.error = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(panel.error ?? "")
            }
    }

    // MARK: Titles

    private var switchTitle: String {
        guard case .confirmSwitch(let w)? = panel.prompt else { return "Switch workspace?" }
        return "Switch to “\(w.name)”?"
    }

    private var duplicateTitle: String {
        guard case .duplicate(let w)? = panel.prompt else { return "Duplicate Workspace" }
        return "Duplicate “\(w.name)”"
    }

    private var deleteTitle: String {
        guard case .delete(let w)? = panel.prompt else { return "Delete workspace?" }
        return "Delete “\(w.name)”?"
    }

    private var deleteMessage: String {
        guard case .delete(let w)? = panel.prompt else { return "" }
        return "This permanently deletes every container, image, volume and network in "
            + "“\(w.name)”, and its \(w.allocatedDescription) disk at \(w.dataDiskURL.path). "
            + "This can't be undone.\n\nType “\(w.name)” to confirm."
    }

    // MARK: Confirmations

    private func confirmSwitch() {
        guard case .confirmSwitch(let workspace)? = panel.prompt else { return }
        panel.dismiss()
        Task { await engine.performSwitch(to: workspace) }
    }

    private func confirmCreate() {
        guard let name = panel.proposedName else { return }
        panel.dismiss()
        engine.performCreate(name: name)
    }

    private func confirmRename() {
        guard case .rename(let workspace)? = panel.prompt, let name = panel.proposedName
        else { return }
        panel.dismiss()
        engine.performRename(workspace, to: name)
    }

    private func confirmDuplicate() {
        guard case .duplicate(let workspace)? = panel.prompt, let name = panel.proposedName
        else { return }
        panel.dismiss()
        Task { await engine.performDuplicate(workspace, newName: name) }
    }

    private func confirmDelete() {
        guard case .delete(let workspace)? = panel.prompt, panel.deleteConfirmed else { return }
        panel.dismiss()
        engine.performDelete(workspace)
    }
}
