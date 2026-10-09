import Foundation

/// The reconnect delay for the informer loops that ride the Docker `/events` stream —
/// `DockerEventsWatcher`, `ResourceSaver` and the GUI's `DockerResourceStore`. One type so
/// the three loops can't drift apart (CLAUDE.md §10).
///
/// Each of them used to sleep a flat 1 s after every failed pass. At boot that put a 1 s
/// quantum on readiness: the GUI leaves `.starting` on the watcher's first successful
/// reconcile, so a dockerd that came up just after a failed attempt still waited out the
/// rest of the second. This backs off from 50 ms, doubling to the same 1 s ceiling, so
/// readiness tracks the daemon while a long outage still retries at no more than 1 Hz.
///
/// It resets once a pass has lasted at least the ceiling. A pass that long was a real
/// connection (or a request the guest held open while dockerd started), not a refusal, so
/// the next outage — a dockerd restart — again starts at 50 ms. The bound on reconnect rate
/// holds regardless: at most one fast burst (50 → 800 ms, five attempts) per pass of ≥1 s.
public struct ReconnectBackoff: Sendable {
    public static let initial: Duration = .milliseconds(50)
    public static let ceiling: Duration = .seconds(1)

    private var next: Duration = Self.initial
    private var passStarted = ContinuousClock.now

    public init() {}

    /// Call at the top of each connect + reconcile + stream pass.
    public mutating func passBegan() {
        passStarted = .now
    }

    /// The delay to sleep before the next pass, now that the current one has ended.
    public mutating func delayAfterPass() -> Duration {
        if ContinuousClock.now - passStarted >= Self.ceiling { next = Self.initial }
        let delay = next
        next = min(next * 2, Self.ceiling)
        return delay
    }
}
