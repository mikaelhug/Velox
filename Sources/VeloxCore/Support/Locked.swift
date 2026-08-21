import Foundation

/// A mutable value behind an `NSLock`, readable and writable from any isolation domain.
///
/// Used where a piece of state is normally owned by the main actor but one path must
/// reach it *without* the main actor — notably the app's terminate path, which has to
/// flush and power off the guest even if the main actor is busy (see
/// `EngineController.shutdownForTerminate`).
/// `T` is constrained to `Sendable` deliberately: this type moves a value across isolation
/// domains, and without the bound it would be a general-purpose hole in the checker.
public final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    public init(_ value: T) { storage = value }

    public var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }

    /// Read-modify-write under a single lock hold. `value` alone cannot express this: a
    /// `get`, a mutation and a `set` is three operations, so two callers on different queues
    /// can interleave and one update is silently lost.
    @discardableResult
    public func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&storage)
    }
}

extension DispatchQueue {
    /// Wait — bounded — for everything already queued on this serial queue to run.
    ///
    /// The "stop admitting, then drain" ordering in `EngineRuntime.stop()` needs each producer's
    /// async stop to have actually executed before the shared relay is drained; a serial queue
    /// makes an empty `sync` mean exactly that. It is bounded because `stop()` is reachable from
    /// the main actor (`EngineController.cleanup`, also on a guest crash) and the queue being
    /// drained can be sitting in a porthelper round-trip — an unbounded wait would beachball the
    /// UI. On timeout the drain proceeds anyway: that is exactly the behaviour before the
    /// barriers existed, so the worst case is the old race, not a hang.
    func settle(_ label: String, timeout: DispatchTimeInterval = .seconds(5)) {
        let done = DispatchSemaphore(value: 0)
        async { done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            Log.warn("\(label): did not quiesce in time; draining anyway")
        }
    }
}
