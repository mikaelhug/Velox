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
    /// Relocating the active workspace's `data.img` to another folder or disk.
    case movingDisk(Double)
    /// Stop → repoint the manifest → boot the other workspace's disk.
    case switchingWorkspace(String)
    /// Duplicating a workspace's disk (APFS clone, or a copy across volumes).
    case cloningWorkspace(String)

    /// Status text while this operation runs.
    var label: String {
        switch self {
        case .movingDisk:                  return "Moving disk…"
        case .switchingWorkspace(let name): return "Switching to \(name)…"
        case .cloningWorkspace(let name):   return "Duplicating \(name)…"
        }
    }

    /// Sentence for the empty detail pane, which has room to say what happens next.
    var explanation: String {
        switch self {
        case .movingDisk:
            return "Moving the data disk… the engine will restart when it's done."
        case .switchingWorkspace(let name):
            return "Switching to \(name)… the engine restarts with that workspace's "
                 + "containers, images and volumes."
        case .cloningWorkspace(let name):
            return "Duplicating \(name)… the engine will restart when it's done."
        }
    }

    /// 0…1 where the operation can report it, else nil for an indeterminate spinner.
    var progress: Double? {
        switch self {
        case .movingDisk(let fraction): return fraction
        case .switchingWorkspace:       return nil
        case .cloningWorkspace:         return nil
        }
    }
}
