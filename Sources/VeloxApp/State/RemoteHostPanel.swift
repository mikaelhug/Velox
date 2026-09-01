import Foundation
import Observation
import VeloxCore

/// Which remote-host prompt is on screen and the text typed into it — the same shape, and
/// for the same two reasons, as `WorkspacePanel`:
///
/// 1. **The modals must not hang off a `Section`.** `HostsSection`'s body *is* a `Section`
///    inside the sidebar `List`, and presentation modifiers attached to a section are
///    unreliable — a sheet can simply never appear. Hoisting the state here lets
///    `RootView` attach them to the `List`, which is a stable host.
/// 2. **A second alert can't be presented while the first is dismissing**, so `fail(_:)`
///    dismisses first and surfaces the error on a later turn of the run loop.
@MainActor
@Observable
final class RemoteHostPanel {
    enum Prompt: Equatable {
        /// The add-host sheet. Unlike a workspace (one text field), a host needs several
        /// fields, so this is a sheet rather than an `.alert`.
        case add
        case rename(RemoteHost)
        case delete(RemoteHost)
        /// Confirm moving an unreadable `hosts.json` aside. Confirmed, not automatic — it
        /// discards the user's configured hosts (their servers are untouched).
        case resetList
    }

    private(set) var prompt: Prompt?
    /// Backs the single-field prompts: the new name for rename, the typed confirmation
    /// for delete.
    var text = ""
    /// Set only once any prompt has dismissed — see the note above.
    var error: String?

    // MARK: - Add-sheet fields
    //
    // Held here rather than in the sheet so a validation failure can re-present without
    // the user retyping everything.

    var draftName = ""
    var draftUser = NSUserName()
    var draftHostname = ""
    var draftPort = "\(RemoteHost.defaultPort)"
    var draftSocketPath = RemoteHost.defaultSocketPath
    var draftIdentityFile = ""
    /// A rejected submit (duplicate name, unusable field), shown inside the sheet. Kept
    /// separate from `error` because that one is an alert raised *after* dismissing — which
    /// would throw away everything the user typed, defeating the point of these drafts.
    var draftError: String?

    static let errorPresentationDelay = Duration.milliseconds(150)

    // MARK: - Transitions

    func begin(_ prompt: Prompt, suggesting text: String = "") {
        self.prompt = prompt
        self.text = text
    }

    func beginAdd() {
        draftError = nil
        draftName = ""
        draftUser = NSUserName()
        draftHostname = ""
        draftPort = "\(RemoteHost.defaultPort)"
        draftSocketPath = RemoteHost.defaultSocketPath
        draftIdentityFile = ""
        prompt = .add
    }

    func dismiss() {
        prompt = nil
        text = ""
    }

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

    var proposedName: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var deleteConfirmed: Bool {
        guard case .delete(let host) = prompt else { return false }
        return host.deleteConfirmationMatches(text)
    }

    /// The port the draft resolves to, or nil when what's typed isn't a valid port.
    var draftPortValue: Int? {
        let trimmed = draftPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), RemoteHost.portRange.contains(value) else { return nil }
        return value
    }

    /// The first complaint about the add sheet's fields, or nil when it can be submitted.
    /// Name defaults to the hostname when left blank, so it isn't required.
    /// What to show under the fields: a live field complaint, else a rejected submit.
    var draftMessage: String? { draftComplaint ?? draftError }

    var draftComplaint: String? {
        if !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let complaint = RemoteHost.validate(name: draftName) { return complaint }
        if let complaint = RemoteHost.validate(user: draftUser) { return complaint }
        if let complaint = RemoteHost.validate(hostname: draftHostname) { return complaint }
        if let complaint = RemoteHost.validate(socketPath: draftSocketPath) { return complaint }
        if draftPortValue == nil { return "Port must be a number between 1 and 65535." }
        return nil
    }

    /// The name to save: what was typed, or the hostname when that was left blank.
    var effectiveDraftName: String {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? RemoteHost.normalized(draftHostname) : trimmed
    }

    var primaryEnabled: Bool {
        switch prompt {
        case .add:       return draftComplaint == nil
        case .rename:    return proposedName != nil
        case .delete:    return deleteConfirmed
        case .resetList: return true
        case .none:      return false
        }
    }
}
