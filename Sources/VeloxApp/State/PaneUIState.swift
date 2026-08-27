import Foundation
import Observation

/// Per-pane UI state (search text, table selection, expansion) lifted above the
/// navigation. The dashboard views are deliberately recreated on every pane switch —
/// their on-screen-scoped tasks (the Containers re-list, stats retention) must stop
/// when hidden — so any state worth keeping across switches lives here instead of in
/// view `@State`. Owned by `EngineController` alongside the data stores; survives
/// engine restarts (it's pure UI state). Transient bits (pending-delete confirmations,
/// in-flight pull references) intentionally stay view-local.
@MainActor
@Observable
final class PaneUIState {
    // Containers
    var containerSearch = ""
    var containerSelection: Set<String> = []
    /// Compose project names the user collapsed (absence ⇒ expanded).
    var containerCollapsed: Set<String> = []
    var containerInspector = false
    // Images
    var imageSearch = ""
    var imageSelection: Set<String> = []
    // Volumes
    var volumeSelection: Set<String> = []
    /// Compose project names the user collapsed in the Volumes pane (absence ⇒ expanded).
    var volumeCollapsed: Set<String> = []
    var volumeInspector = true

    /// Drop every selection (but keep search text and expansion, which are harmless).
    ///
    /// Called on a workspace switch. Selections are keyed by volume **name** and image
    /// digest, and both collide across workspaces — `myapp_db_data` and the same
    /// `nginx:latest` exist in more than one. This state is deliberately long-lived (see the
    /// note above), so without this a selection made in one workspace silently re-resolves
    /// against the next one's list, where the Volumes context menu offers "Remove N Volumes"
    /// straight off it. Search text and collapsed-project sets can't destroy anything, so
    /// they stay.
    func clearSelections() {
        containerSelection.removeAll()
        imageSelection.removeAll()
        volumeSelection.removeAll()
    }
}
