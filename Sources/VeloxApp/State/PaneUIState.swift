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
    // Images
    var imageSearch = ""
    var imageSelection: Set<String> = []
    // Volumes
    var volumeSelection: Set<String> = []
    var volumeInspector = true
}
