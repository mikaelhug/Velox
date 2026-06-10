import Foundation

/// Thread-safe `name → container IPv4` map for direct (named) container access. Maintained
/// host-side by `DockerEventsWatcher` on every reconcile (it already lists containers); read by
/// `NameDNSResponder` to answer `<name>.velox.local`. The address is stored in **network byte
/// order** (`in_addr_t`) so the responder drops it straight into a DNS A record. Mirrors the
/// `PublishedEndpoints` holder used by the conduit pool.
public final class NameRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: in_addr_t] = [:]

    public init() {}

    /// Replace the whole map. The full reconcile is the source of truth (CLAUDE.md §8), so a
    /// missed Docker event self-heals on the next reconcile.
    public func update(_ m: [String: in_addr_t]) {
        lock.lock(); map = m; lock.unlock()
    }

    /// The container address (network byte order) for a bare, lowercased name, or nil.
    public func address(for name: String) -> in_addr_t? {
        lock.lock(); defer { lock.unlock() }; return map[name.lowercased()]
    }
}
