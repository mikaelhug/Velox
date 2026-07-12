import Foundation

/// Fans a single persistent `/events` stream out to every consumer, so the port watcher,
/// the resource saver, and the dashboards share ONE upstream VSOCK connection instead of
/// each opening its own — CLAUDE.md §8's "one persistent VSOCK connection over HTTPCodec,
/// straight to dockerd".
///
/// The informer contract is preserved. When the upstream drops (dockerd restart) every
/// subscriber stream FINISHES, so each consumer's loop runs a full reconcile and
/// re-subscribes — self-healing exactly as with per-consumer streams, just multiplexed.
/// The upstream connects lazily on the first subscriber and tears down when the last one
/// leaves, so an idle engine holds no events connection.
///
/// Note: this multiplexes the *connection*; consumers still each run their own reconcile
/// (they derive different state — port maps vs idle counts vs dashboard lists), which is
/// correct-by-design, not duplication to remove here.
package final class DockerEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<DockerEvent>.Continuation] = [:]
    private var upstream: Task<Void, Never>?
    /// Opens one raw `/events` connection (one real VSOCK stream). Called once per connect.
    private let makeUpstream: @Sendable () -> AsyncStream<DockerEvent>

    package init(makeUpstream: @escaping @Sendable () -> AsyncStream<DockerEvent>) {
        self.makeUpstream = makeUpstream
    }

    /// A new subscriber stream. Starts the shared upstream if it isn't already running.
    package func subscribe() -> AsyncStream<DockerEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
            lock.lock()
            subscribers[id] = continuation
            // Start the shared upstream on the first subscriber. `run()` can only start
            // while `upstream == nil`, and it nils `upstream` before returning, so at most
            // one upstream connection is ever live.
            if upstream == nil {
                upstream = Task { [weak self] in await self?.run() }
            }
            lock.unlock()
        }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        subscribers[id] = nil
        // Last subscriber left → drop the shared upstream (no idle events connection). The
        // cancel unblocks `run()`'s `for await`, which then clears `upstream` in its tail.
        let stop = subscribers.isEmpty ? upstream : nil
        if subscribers.isEmpty { upstream = nil }
        lock.unlock()
        stop?.cancel()
    }

    private func broadcast(_ event: DockerEvent) {
        lock.lock(); let conts = Array(subscribers.values); lock.unlock()
        for c in conts { c.yield(event) } // yielded outside the lock (no re-entrancy)
    }

    /// One upstream connection's lifetime: broadcast until it drops (or this task is
    /// cancelled), then finish the current subscribers so their consumers reconcile and
    /// re-subscribe — the re-subscribe starts a fresh `run()`. Single-shot on purpose:
    /// reconnect is driven by re-subscription, so two `run()`s never overlap.
    private func run() async {
        for await event in makeUpstream() {
            broadcast(event)
        }
        // → consumers reconcile + re-subscribe (informer self-heal). Cleared via a sync
        // helper so the NSLock is never touched from this async context.
        for c in takeSubscribersForReconnect() { c.finish() }
    }

    /// Clear the subscribers and the upstream slot, returning the continuations to finish.
    private func takeSubscribersForReconnect() -> [AsyncStream<DockerEvent>.Continuation] {
        lock.lock(); defer { lock.unlock() }
        let conts = Array(subscribers.values)
        subscribers.removeAll()
        upstream = nil
        return conts
    }
}
