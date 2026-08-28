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
                // Effective active, not the raw `activeID`: with a dangling pointer the
                // fallback workspace is what will boot, and it must wear the marker.
                WorkspaceRow(workspace: workspace,
                             isActive: workspace.id == engine.activeWorkspace?.id)
                    .contextMenu { menu(for: workspace) }
            }
            if engine.workspaces?.activeIsFallback == true {
                // The stored pointer names a workspace that isn't in the list (a hand-edited
                // or restored manifest). Say so rather than silently booting the fallback —
                // switching to any workspace rewrites the pointer and clears this.
                Label {
                    Text("The saved selection is missing — using "
                        + "\(engine.activeWorkspace?.name ?? "Default"). Switching "
                        + "workspaces will clear this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        // A List row is a single truncating line by default, which cut this
                        // to "The saved selection i…" and lost the entire message — the one
                        // thing a banner exists to deliver. `fixedSize` vertically is what
                        // lets the row grow to fit the wrapped text in a ~160pt sidebar.
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack(spacing: 4) {
                Text("Workspaces")
                Spacer(minLength: 8)
                AddWorkspaceButton { engine.workspacePanel.begin(.create) }
                    .disabled(engine.isEngineOwned)
            }
            // A section header stretches to the row's trailing edge, so a bare `Spacer()`
            // parks the glyph almost flush against it.
            //
            // 8, not a smaller "just off the edge" value: the header's own text sits ~14.5pt
            // in from the leading edge, and the eye reads the difference. With the button's
            // 3pt of internal padding this lands the glyph ~13pt from the trailing edge, so
            // the two ends of the header balance. Measured off a render at 2 / 8 / 14 — 2 is
            // visibly crowded and 14 makes the plus look detached from the edge.
            .padding(.trailing, 8)
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

/// The "+" in the section header.
///
/// Split out because a bare `Image` in a `.plain` button is a ~10pt hit target with no
/// feedback — it reads as decoration rather than a control. The padding gives it a real
/// target, and the hover fill is what tells you it is one.
private struct AddWorkspaceButton: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.caption.weight(.semibold))
                .frame(width: 13, height: 13)          // square, so the hover fill isn't oblong
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hovering && isEnabled ? AnyShapeStyle(.quaternary)
                                                    : AnyShapeStyle(.clear)))
                .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help("New workspace")
    }
}

/// One workspace row: a button, not a navigation item (see `WorkspacesSection`).
private struct WorkspaceRow: View {
    let workspace: Workspace
    let isActive: Bool

    @Environment(EngineController.self) private var engine
    @State private var hovering = false

    var body: some View {
        Button {
            // `isActive` is the EFFECTIVE active, so the fallback workspace's row is inert
            // like any active row. A dangling pointer is repaired by switching to any other
            // row — `activate` rewrites it to a valid id.
            guard !isActive, !engine.isEngineOwned else { return }
            engine.workspacePanel.begin(.confirmSwitch(workspace))
        } label: {
            HStack(spacing: 0) {
                // `Label`, not a hand-rolled HStack: it puts the icon in the same column the
                // sidebar's navigation rows use, so Workspaces lines up with Resources and
                // System instead of sitting a few points off.
                Label {
                    Text(workspace.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .fontWeight(isActive ? .semibold : .regular)
                } icon: {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isActive ? AnyShapeStyle(.tint)
                                                  : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 4)
                if missing {
                    // The entry is real but its disk isn't there — an unplugged drive, most
                    // likely. Flagged rather than hidden, because starting it will (rightly)
                    // fail loudly instead of quietly creating an empty one in its place.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            // The whole row is the target, including the gap after a short name.
            .contentShape(Rectangle())
            // Radius matches the selection capsule the navigation rows draw, so hovering a
            // workspace and hovering a nav item feel like the same control.
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(highlight))
            // Without this the separator is inset to the text, while every navigation row's
            // starts at the row edge — a seam that reads as two different lists.
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        }
        .buttonStyle(.plain)
        .disabled(engine.isEngineOwned)
        .onHover { hovering = $0 }
        .help(helpText)
        // NO custom padding or row insets on purpose: the defaults are what put `Label`'s
        // icon in the same column as Overview/Containers/Engine Logs. Adding padding here
        // shifted the whole section ~25pt right of the rest of the sidebar.
    }

    /// Hover feedback only — the active workspace is marked by its filled icon and weight, not
    /// by a persistent fill, so it can't be mistaken for the navigation selection.
    private var highlight: AnyShapeStyle {
        hovering && !isActive && !engine.isEngineOwned
            ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
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

    /// True while any *text-entry* prompt is up (create / rename / duplicate / delete).
    /// They share a single `.alert` — see `body`.
    private var editorPresented: Binding<Bool> {
        presenting { if case .confirmSwitch = $0 { return false }; return true }
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
                // One short line. This dialog is on the path of a routine action, and what a
                // workspace holds is self-evident from the sidebar — spelling out
                // "containers, images and volumes … comes back when you switch back" every
                // time is a wall of text the user stops reading by the third switch. The only
                // non-obvious fact is the restart, so that is all it says. Still branched:
                // promising a restart when the engine is stopped would just be wrong.
                if engine.state.isRunning || engine.state.isBusy {
                    Text("The engine will restart.")
                } else {
                    Text("Takes effect on the next start.")
                }
            }
            // ONE alert for all four text-entry prompts, switched on `panel.prompt`, rather
            // than four `.alert` modifiers on the same view.
            //
            // Stacking presentation modifiers is the pattern that has already bitten this
            // feature once (they were hung off a `Section`, where they can silently never
            // appear), and multiple alerts on a single view is the same family of
            // not-quite-guaranteed behaviour. There is no way to test it from here, so the
            // fix is to not rely on it: one alert can only ever present the one prompt that
            // is set. Fewer moving parts, and it collapses four near-identical text fields
            // into one.
            .alert(editorTitle, isPresented: editorPresented) {
                TextField(editorFieldLabel, text: Bindable(panel).text)
                Button(editorConfirmLabel, role: editorIsDestructive ? .destructive : nil) {
                    confirmEditor()
                }
                .disabled(!panel.primaryEnabled)
                Button("Cancel", role: .cancel) { panel.dismiss() }
            } message: {
                // Omitted entirely for Rename, which has nothing worth saying — an empty
                // `Text` still reserves the message area and leaves a blank gap.
                if !editorMessage.isEmpty { Text(editorMessage) }
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

    // MARK: Prompt text
    //
    // One prompt is set at a time, so each of these switches on it. The fallbacks are
    // unreachable in practice (the alert is only presented when a prompt exists) and exist
    // so a missing case can never crash a dialog.

    private var switchTitle: String {
        guard case .confirmSwitch(let w)? = panel.prompt else { return "Switch workspace?" }
        return "Switch to “\(w.name)”?"
    }

    private var editorTitle: String {
        switch panel.prompt {
        case .create:             return "New Workspace"
        case .rename:             return "Rename Workspace"
        case .duplicate(let w):   return "Duplicate “\(w.name)”"
        case .delete(let w):      return "Delete “\(w.name)”?"
        case .confirmSwitch, .none: return ""
        }
    }

    private var editorFieldLabel: String {
        if case .delete = panel.prompt { return "Type the workspace name" }
        return "Name"
    }

    private var editorConfirmLabel: String {
        switch panel.prompt {
        case .create:    return "Create"
        case .rename:    return "Rename"
        case .duplicate: return "Duplicate"
        case .delete:    return "Delete Permanently"
        case .confirmSwitch, .none: return "OK"
        }
    }

    private var editorIsDestructive: Bool {
        if case .delete = panel.prompt { return true }
        return false
    }

    private var editorMessage: String {
        switch panel.prompt {
        case .create:
            return "An empty workspace with its own containers, images and volumes. It "
                + "starts at \(engine.activeWorkspace?.diskGiB ?? 64) GB and takes up no "
                + "space on your Mac until you use it."
        case .rename:
            return ""
        case .duplicate:
            // Worth saying: "duplicate my 40 GB workspace" otherwise sounds expensive.
            return "Copies every container, image and volume. On an Apple File System disk "
                + "this is instant and uses no extra space until the two diverge."
        case .delete(let w):
            return "This permanently deletes every container, image, volume and network in "
                + "“\(w.name)”, and its \(w.allocatedDescription) disk at "
                + "\(w.dataDiskURL.path). This can't be undone.\n\nType “\(w.name)” to "
                + "confirm."
        case .confirmSwitch, .none:
            return ""
        }
    }

    // MARK: Confirmations

    private func confirmSwitch() {
        guard case .confirmSwitch(let workspace)? = panel.prompt else { return }
        panel.dismiss()
        Task { await engine.performSwitch(to: workspace) }
    }

    /// Single dispatch for the shared editor alert. Reads the prompt BEFORE dismissing it,
    /// because `dismiss()` clears both the prompt and the typed text.
    private func confirmEditor() {
        guard let prompt = panel.prompt, let name = panel.proposedName else { return }
        switch prompt {
        case .create:
            panel.dismiss()
            Task { await engine.performCreate(name: name) }
        case .rename(let workspace):
            panel.dismiss()
            Task { await engine.performRename(workspace, to: name) }
        case .duplicate(let workspace):
            panel.dismiss()
            Task { await engine.performDuplicate(workspace, newName: name) }
        case .delete(let workspace):
            // Re-check rather than trust the disabled state: the button is the last gate on
            // an unrecoverable action.
            guard panel.deleteConfirmed else { return }
            panel.dismiss()
            Task { await engine.performDelete(workspace) }
        case .confirmSwitch:
            break   // not presented by this alert
        }
    }
}
