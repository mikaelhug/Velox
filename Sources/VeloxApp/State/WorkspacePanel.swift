import Foundation
import Observation
import VeloxCore

/// Which workspace prompt is on screen, and the text the user has typed into it.
///
/// This lives outside the sidebar view on purpose, for two reasons that are easy to get
/// wrong and hard to notice:
///
/// 1. **The modals must not hang off a `Section`.** `WorkspacesSection`'s body *is* a
///    `Section` inside the sidebar `List`, and presentation modifiers attached to a section
///    are unreliable — the alert can simply never appear. Hoisting the state here lets
///    `RootView` attach them to the `List` itself, which is a stable host.
/// 2. **A second alert can't be presented while the first is dismissing.** Every failure
///    path here is reached from inside a dialog's own button, so `fail(_:)` dismisses first
///    and surfaces the error on a later turn of the run loop. Setting both at once loses the
///    error silently, which is exactly the case that matters (a duplicate name, a delete the
///    store refuses).
///
/// Keeping it as a plain observable object also makes the decisions — what the prompt says,
/// whether Delete is armed, what a confirmed action resolves to — testable without a UI.
@MainActor
@Observable
final class WorkspacePanel {
    /// The prompt currently on screen. Exactly one at a time. (Presentation is driven by
    /// per-kind `isPresented` bindings in `WorkspacePrompts`, so no `Identifiable` needed.)
    enum Prompt: Equatable {
        case create
        case rename(Workspace)
        case duplicate(Workspace)
        case delete(Workspace)
        case confirmSwitch(Workspace)
    }

    private(set) var prompt: Prompt?
    /// Backs the text field: the new name for create/rename/duplicate, and the typed
    /// confirmation for delete.
    var text = ""
    /// Set only once any prompt has dismissed — see the note above.
    var error: String?

    /// Delay before an error alert is presented, to let a dismissing prompt finish. Short
    /// enough to feel immediate, long enough that the two don't collide.
    static let errorPresentationDelay = Duration.milliseconds(150)

    // MARK: - Transitions

    func begin(_ prompt: Prompt, suggesting text: String = "") {
        self.prompt = prompt
        self.text = text
    }

    func dismiss() {
        prompt = nil
        text = ""
    }

    /// Dismiss the current prompt and report a failure once it is off screen.
    func fail(_ message: String) {
        dismiss()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.errorPresentationDelay)
            self?.error = message
        }
    }

    // MARK: - Decisions
    //
    // Pure, so the rules can be tested without presenting anything.

    /// The trimmed name a create/rename/duplicate would use, or nil when it isn't usable yet.
    var proposedName: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the typed confirmation matches the workspace being deleted. The rule itself
    /// lives on `Workspace` so it can be tested without a UI.
    var deleteConfirmed: Bool {
        guard case .delete(let workspace) = prompt else { return false }
        return workspace.deleteConfirmationMatches(text)
    }

    /// Whether the primary button of the current prompt should be enabled.
    var primaryEnabled: Bool {
        switch prompt {
        case .create, .rename, .duplicate: return proposedName != nil
        case .delete:                      return deleteConfirmed
        case .confirmSwitch:               return true
        case .none:                        return false
        }
    }
}
