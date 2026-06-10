import Foundation
import Observation

/// Published ports whose localhost listener couldn't bind (another app holds the
/// port, or a privileged port awaits the helper grant). Fed event-driven by the
/// PortForwarder via EngineRuntime; the Containers pane paints those port links red
/// instead of leaving the only signal in a log line.
@MainActor
@Observable
final class PortIssues {
    private(set) var blocked: Set<UInt16> = []

    func set(_ port: UInt16, blocked isBlocked: Bool) {
        if isBlocked { blocked.insert(port) } else { blocked.remove(port) }
    }

    func clear() { blocked.removeAll() }
}
