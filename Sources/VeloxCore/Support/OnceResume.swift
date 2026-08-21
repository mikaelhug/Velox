import Foundation

/// A `CheckedContinuation` that resumes **exactly once**, whichever of several racing
/// callbacks gets there first — the standard shape for "bound this callback-style API
/// with a deadline".
///
/// Both failure modes are fatal in their own way: resuming twice traps, and never
/// resuming hangs the awaiting task forever (which is how a stalled engine stop used to
/// wedge the app's quit). `fire` reports whether it was the one that resumed, so the
/// timeout arm can log only when it actually won the race.
public final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?

    public init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }

    /// Resume with `value`. Returns true if this call is the one that resumed.
    @discardableResult
    public func fire(_ value: T) -> Bool {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: value)
        return c != nil
    }
}
