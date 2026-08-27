import Foundation

/// A long-running operation that owns the engine: it stops and restarts the VM itself, so
/// the ordinary Start/Stop/Restart controls must stand down while it runs.
///
/// This exists as one type instead of a boolean per operation because the "something is
/// holding the engine" ladder is written out three times in the UI — `EngineStatusBar`,
/// `EngineDownView` and the menu bar's engine control. With a flag apiece, every new
/// operation has to be threaded through all three by hand, which is how the three drift
/// apart. Adding a case here updates all of them.
enum EngineOwner: Equatable {
    /// Relocating a workspace's `data.img` to another folder or disk. Carries 0…1 progress:
    /// a same-volume move is an instant hard link, but a move to another disk copies every
    /// used byte and can run for minutes.
    case movingDisk(name: String, progress: Double)
    /// Stop → repoint the manifest → boot the other workspace's disk. No progress: the whole
    /// operation is one engine restart, over in seconds.
    case switchingWorkspace(name: String)
    /// Duplicating a workspace's disk. An APFS clone is instant; the cross-volume fallback
    /// copies used bytes and reports progress like a move.
    case cloningWorkspace(name: String, progress: Double)

    /// Status text while this operation runs, including a percentage once there is one worth
    /// showing. A long copy with no readout is indistinguishable from a hang.
    var label: String {
        switch self {
        case .movingDisk(let name, let p):
            return "Moving \(name)…" + Self.percent(p)
        case .switchingWorkspace(let name):
            return "Switching to \(name)…"
        case .cloningWorkspace(let name, let p):
            return "Duplicating \(name)…" + Self.percent(p)
        }
    }

    /// Sentence for the empty detail pane, which has room to say what happens next.
    var explanation: String {
        switch self {
        case .movingDisk(let name, _):
            return "Moving \(name)'s data disk… the engine will restart when it's done."
        case .switchingWorkspace(let name):
            return "Switching to \(name)… the engine restarts with that workspace's "
                 + "containers, images and volumes."
        case .cloningWorkspace(let name, _):
            return "Duplicating \(name)… every container, image and volume is being copied."
        }
    }

    /// 0…1 for a determinate bar, or nil for an indeterminate spinner.
    ///
    /// Deliberately nil until the operation has actually reported something: an APFS clone
    /// finishes before it can report, and a bar that appears at 0% and vanishes reads worse
    /// than a brief spinner.
    var progress: Double? {
        switch self {
        case .movingDisk(_, let p), .cloningWorkspace(_, let p):
            return p > 0 ? p : nil
        case .switchingWorkspace:
            return nil
        }
    }

    /// The same operation with updated progress, or unchanged for one that has none.
    func advanced(to fraction: Double) -> EngineOwner {
        switch self {
        case .movingDisk(let name, _):      return .movingDisk(name: name, progress: fraction)
        case .cloningWorkspace(let name, _): return .cloningWorkspace(name: name, progress: fraction)
        case .switchingWorkspace:            return self
        }
    }

    private static func percent(_ p: Double) -> String {
        p > 0 ? " \(Int(p * 100))%" : ""
    }
}
