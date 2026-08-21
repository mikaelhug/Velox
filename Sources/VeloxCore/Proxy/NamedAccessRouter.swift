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
    private var warnedOverlap: Set<String> = []   // log the refusal once per subnet
    /// Set by `stop()`. Everything after it must be inert: an events reconcile already past
    /// its `await` still delivers `onSubnets`, and the gateway can arrive late — either would
    /// re-run `reconcile()` and `route add` on a stopped engine, with no later `stop()` to
    /// take those routes back out. On `queue`.
    private var stopped = false

    public init(helper: PortHelperManager) { self.helper = helper }

    /// Set the route target (guest IP) and reconcile any subnets seen before it was known.
    public func setGateway(_ ip: in_addr_t) {
        let s = Self.ipString(ip)
        queue.async { guard !self.stopped else { return }; self.gateway = s; self.reconcile() }
    }

    /// The latest bridge subnets (from the watcher's `onSubnets`).
    public func update(subnets: Set<String>) {
        queue.async { guard !self.stopped else { return }; self.desired = subnets; self.reconcile() }
    }

    /// Re-run the reconcile now — used after the one-time porthelper grant completes, since routes
    /// attempted before the helper was installed (and subnets that won't change to re-trigger
    /// `update`) need re-applying once it's available.
    public func refresh() {
        queue.async {
            guard !self.stopped else { return }
            // Forget what we believe is installed so `reconcile` re-applies EVERY desired
            // subnet. A plain diff can never heal a route removed behind our back (VPN churn
            // flushing the table), because the subnet is still in `routed` — and upstream,
            // `commitSubnets` suppresses `onSubnets` when the set is unchanged, so nothing
            // else revisits it either. `reconcile` deletes before every add, so re-applying
            // an already-present route is idempotent.
            self.routed.removeAll()
            self.reconcile()
        }
    }

    /// Remove every installed route (on engine stop). Pass `wait: true` when the caller is
    /// about to exit the process — an async removal would simply never run, leaving host
    /// routes pointing at a dead VM until the next start's delete-before-add cleans them up.
    public func stop(wait: Bool = false) {
        let removeAll: @Sendable () -> Void = {
            for s in self.routed where !self.helper.route(add: false, subnet: s, gateway: "") {
                // Not fatal: the delete-before-add in `reconcile` repoints it next start.
                Log.warn("named-access: could not remove route \(s)")
            }
            self.routed = []; self.desired = []; self.gateway = nil
            self.stopped = true
        }
        if wait { queue.sync(execute: removeAll) } else { queue.async(execute: removeAll) }
    }

    /// Networks the host itself is on (IPv4, from `getifaddrs`), as (network, mask) pairs.
    /// A docker bridge subnet that overlaps one of these must never be routed to the guest.
    private static func hostNetworks() -> [(net: UInt32, mask: UInt32)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [(UInt32, UInt32)] = []
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let netmask = ifa.pointee.ifa_netmask,
                  ifa.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            guard mask != 0, ip != 0 else { continue }
            out.append((ip & mask, mask))
        }
        return out
    }

    /// True when `cidr` overlaps a network this Mac is already on.
    ///
    /// dockerd hands us whatever subnet a network was created with, and we route it to the
    /// guest — which means `docker network create --subnet 192.168.1.0/24` (or an
    /// `ipam.config.subnet` in someone else's compose file) would delete the host's own LAN
    /// route and divert that traffic into the VM. The porthelper's RFC-1918 check is no
    /// defence: a home LAN *is* RFC-1918. Velox's own pools (172.17+/16) never collide, so
    /// refusing an overlap costs nothing real.
    private static func overlapsHost(_ cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let plen = Int(parts[1]), plen >= 0, plen <= 32 else { return true }
        var a = in_addr()
        guard String(parts[0]).withCString({ inet_pton(AF_INET, $0, &a) }) == 1 else { return true }
        let ip = UInt32(bigEndian: a.s_addr)
        let mask: UInt32 = plen == 0 ? 0 : ~UInt32(0) << (32 - plen)
        let net = ip & mask
        return hostNetworks().contains { host in
            let common = host.mask & mask          // the coarser of the two masks
            return (host.net & common) == (net & common)
        }
    }

    /// Diff desired vs installed and apply — always on `queue`.
    private func reconcile() {
        guard let gw = gateway else { return }   // wait until the guest IP is known
        for s in desired.subtracting(routed) where Self.overlapsHost(s) {
            if warnedOverlap.insert(s).inserted {
                Log.warn("named-access: refusing to route \(s) — it overlaps a network this Mac "
                         + "is already on. Routing it would divert that traffic into the VM. "
                         + "Recreate the docker network with a non-overlapping subnet.")
            }
        }
        for s in desired.subtracting(routed) where !Self.overlapsHost(s) {
            // A route left over from a crashed session (stop() never ran) can point at a
            // stale guest IP, and BSD `route add` can't repoint an existing route — so
            // delete first to make the add idempotent. Deleting a missing route is a no-op
            // to the helper, and subnet adds are rare (engine start / network create).
            helper.route(add: false, subnet: s, gateway: "")
            if helper.route(add: true, subnet: s, gateway: gw) { routed.insert(s) }
        }
        for s in routed.subtracting(desired) {
            // Keep it in `routed` if the delete failed, so a later pass retries instead of
            // leaving a live route to the guest that Velox has forgotten about.
            guard helper.route(add: false, subnet: s, gateway: gw) else { continue }
            routed.remove(s)
        }
    }

    /// Dotted-quad from an `in_addr_t` (network byte order): its in-memory bytes are the octets.
    static func ipString(_ a: in_addr_t) -> String {
        let b = withUnsafeBytes(of: a) { Array($0) }
        return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
    }
}
