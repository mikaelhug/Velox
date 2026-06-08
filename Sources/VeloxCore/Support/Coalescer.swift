import Foundation

/// Collapses a burst of `trigger()` calls into a single `action` run, ~`delay` after
/// the *first* trigger of the burst (leading-edge schedule, trailing fire).
///
/// It deliberately does **not** reset the timer on each trigger — that classic debounce
/// starves under a sustained trigger stream and never fires. Triggers arriving while a
/// run is already pending are absorbed; a trigger that lands *during* the run schedules
/// the next one, so nothing is missed (eventual consistency). Thread-safe: `trigger()`
/// is synchronous and callable from any context.
///
/// Used by the event-driven watchers (`DockerEventsWatcher`, `ResourceSaver`) so a
/// healthcheck/`compose up` storm of `/events` collapses to one `containers()` fetch
/// instead of one per event serialized on the shared `DockerClient` actor.
public final class Coalescer: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: Duration
    private let action: @Sendable () async -> Void
    private var pending: Task<Void, Never>?

    public init(delay: Duration = .milliseconds(120), action: @escaping @Sendable () async -> Void) {
        self.delay = delay
        self.action = action
    }

    /// Request a run. If one is already scheduled, this call is absorbed into it.
    public func trigger() {
        lock.lock()
        guard pending == nil else { lock.unlock(); return }
        let delay = self.delay
        let action = self.action
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            // Clear the slot *before* running, so a trigger during the run re-schedules.
            self?.clearPending()
            if Task.isCancelled { return }
            await action()
        }
        lock.unlock()
    }

    private func clearPending() {
        lock.lock(); pending = nil; lock.unlock()
    }

    public func cancel() {
        lock.lock(); pending?.cancel(); pending = nil; lock.unlock()
    }
}
