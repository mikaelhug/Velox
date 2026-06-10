import Foundation

/// Reconciles host routes for direct (named) container access. Each docker bridge subnet is routed
/// to the guest VM IP (via `velox-porthelper`, the only privileged component) so the Mac can reach
/// container IPs directly. Subnets arrive event-driven from `DockerEventsWatcher`; the guest IP from
/// `GatewayProbe`. Routes are added/removed on change and **all torn down on stop**, so a stale
/// route never lingers when Velox isn't running. Best-effort: every route needs the one-time
/// porthelper grant, so declining it simply leaves named access off. All state lives on one serial
/// queue (no locks); the porthelper round-trips run there too, off the watcher's callback.
public final class NamedAccessRouter: @unchecked Sendable {
    private let helper: PortHelperManager
    private let queue = DispatchQueue(label: "dev.velox.namedroutes")
    private var gateway: String?          // guest VM IP (route target), once GatewayProbe resolves
    private var desired: Set<String> = [] // latest bridge subnets from the watcher
    private var routed: Set<String> = []  // subnets we've actually installed

    public init(helper: PortHelperManager) { self.helper = helper }

    /// Set the route target (guest IP) and reconcile any subnets seen before it was known.
    public func setGateway(_ ip: in_addr_t) {
        let s = Self.ipString(ip)
        queue.async { self.gateway = s; self.reconcile() }
    }

    /// The latest bridge subnets (from the watcher's `onSubnets`).
    public func update(subnets: Set<String>) {
        queue.async { self.desired = subnets; self.reconcile() }
    }

    /// Re-run the reconcile now — used after the one-time porthelper grant completes, since routes
    /// attempted before the helper was installed (and subnets that won't change to re-trigger
    /// `update`) need re-applying once it's available.
    public func refresh() {
        queue.async { self.reconcile() }
    }

    /// Remove every installed route (on engine stop).
    public func stop() {
        queue.async {
            for s in self.routed { self.helper.route(add: false, subnet: s, gateway: "") }
            self.routed = []; self.desired = []; self.gateway = nil
        }
    }

    /// Diff desired vs installed and apply — always on `queue`.
    private func reconcile() {
        guard let gw = gateway else { return }   // wait until the guest IP is known
        for s in desired.subtracting(routed) where helper.route(add: true, subnet: s, gateway: gw) {
            routed.insert(s)
        }
        for s in routed.subtracting(desired) {
            helper.route(add: false, subnet: s, gateway: gw)
            routed.remove(s)
        }
    }

    /// Dotted-quad from an `in_addr_t` (network byte order): its in-memory bytes are the octets.
    static func ipString(_ a: in_addr_t) -> String {
        let b = withUnsafeBytes(of: a) { Array($0) }
        return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
    }
}
