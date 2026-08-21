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
}
