import Foundation

/// The conduit pool's churn circuit breaker as a pure state machine. A flood of
/// *non-keep-alive* connections (one connection per request) drains the warm pool
/// faster than the guest can redial — each request would otherwise wait out the
/// conduit timeout and force a redial, burying the guest in TIME_WAIT sockets. So
/// when the pool stays *continuously* empty-on-submit longer than any keep-alive
/// establishment burst lasts, the breaker trips: connections bypass the pool for a
/// cooldown (straight to the vsock relay), the guest stops redialing, and the bypass
/// duration backs off exponentially while churn persists.
///
/// Extracted from `ConduitPool` so the self-tests can drive it with synthetic
/// clocks — every transition takes `now` as a parameter; nothing reads
/// `DispatchTime.now()` internally. All mutation happens on the pool's serial queue.
public struct ChurnBreaker {
    public enum Verdict: Equatable { case bypass, queue }

    private(set) var openUntil: DispatchTime?    // while set & future, bypass entirely
    private var emptySince: DispatchTime?        // start of the continuously-empty streak
    private var lastEmptyAt: DispatchTime?       // last empty-on-submit (gap detection)
    private var bypassSecs = 2.0                 // current cooldown; backs off under churn

    private let tripAfter: DispatchTimeInterval  // continuous emptiness before tripping
    private let gap: DispatchTimeInterval        // a quiet gap this long restarts the streak
    private let bypassMax: Double                // cap on the backed-off cooldown

    public init(tripAfter: DispatchTimeInterval = .milliseconds(300),
                gap: DispatchTimeInterval = .milliseconds(100),
                bypassMax: Double = 16.0) {
        self.tripAfter = tripAfter
        self.gap = gap
        self.bypassMax = bypassMax
    }

    /// True while a tripped cooldown is in force — checked before even looking at
    /// the pool, so an open breaker bypasses warm conduits too (they're left to
    /// re-fill while the churn passes).
    public func isOpen(now: DispatchTime) -> Bool {
        if let until = openUntil, now < until { return true }
        return false
    }

    /// A submit was served from the warm pool — the pool is healthy: end any empty
    /// streak and reset the cooldown backoff.
    public mutating func served() {
        emptySince = nil
        bypassSecs = 2.0
    }

    /// A submit found the pool empty at `now`. Tracks the *continuous* empty streak
    /// (a quiet gap restarts it, so a keep-alive establishment burst never trips) and
    /// returns whether this client should queue for a conduit or bypass to the relay.
    public mutating func emptySubmit(now: DispatchTime) -> Verdict {
        if let last = lastEmptyAt, now > last + gap { emptySince = now }
        else if emptySince == nil { emptySince = now }
        lastEmptyAt = now
        if let since = emptySince, now > since + tripAfter {
            openUntil = now + .milliseconds(Int(bypassSecs * 1000))
            bypassSecs = min(bypassMax, bypassSecs * 2) // back off if churn persists
            emptySince = nil
            return .bypass
        }
        return .queue
    }
}
