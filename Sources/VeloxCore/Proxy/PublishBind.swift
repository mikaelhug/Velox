import Foundation

/// Which **host** address the published-port listeners bind.
///
/// Docker's documented default — and what Docker Desktop, OrbStack and colima all do —
/// is to publish `-p 8080:80` on every host interface, so the container is reachable
/// from other machines. Velox used to hard-code `127.0.0.1`, which silently made every
/// published port host-local: `docker ps` reported `0.0.0.0:8080->8080/tcp` (the *guest*
/// daemon's truth) while the Mac only ever listened on loopback. `VeloxConfig.publishHostIP`
/// drives this; the default is the Docker-compatible wildcard, and `"127.0.0.1"` restores
/// the old host-only behaviour for anyone who wants it.
///
/// A per-container `-p <hostIP>:8080:80` overrides this for its port (`PublishedPort`). The
/// guest dockerd accepts the Mac address only because vinit sets `ip_nonlocal_bind` — which
/// also means it accepts an address the Mac doesn't have, where Docker would fail the
/// `docker run`. That error surfaces here instead: the host bind fails, `bindFailure` names
/// the address, and the port gets its bind-issue badge. IPv4 only; an IPv6 host address
/// fails closed to loopback.
public struct PublishBind: Sendable, Equatable {
    /// IPv4 address to bind, in network byte order.
    public let v4: in_addr_t
    /// IPv6 twin to bind (always V6ONLY so it never shadows the v4 socket), or nil to skip.
    ///
    /// macOS resolves `localhost` to `::1` first, so a v4-only listener produces the
    /// baffling "refused on localhost, works on 127.0.0.1". Wildcard pairs with `::`,
    /// loopback with `::1`; a specific v4 address has no meaningful v6 twin, so it skips.
    public let v6: in6_addr?
    /// True when bound to `0.0.0.0` — i.e. reachable from other hosts.
    public let isWildcard: Bool
    /// Address as written, for logs and errors.
    public let label: String

    public init(v4: in_addr_t, v6: in6_addr?, isWildcard: Bool, label: String) {
        self.v4 = v4; self.v6 = v6; self.isWildcard = isWildcard; self.label = label
    }

    /// All interfaces — Docker's default, and Velox's.
    public static let wildcard = PublishBind(v4: in_addr_t(0), v6: in6addr_any,
                                             isWildcard: true, label: "0.0.0.0")
    /// Host-only: what Velox did before published ports honoured `publishHostIP`.
    public static let loopback = PublishBind(v4: inet_addr("127.0.0.1"), v6: in6addr_loopback,
                                             isWildcard: false, label: "127.0.0.1")

    /// True when this is the host-only bind. (`label` is canonical — `parse` maps every
    /// spelling of loopback onto `.loopback` — so comparing it is exact, and `in6_addr`
    /// isn't Equatable, which is why equality is hand-written rather than synthesized.)
    public var isLoopback: Bool { label == Self.loopback.label }

    public static func == (a: PublishBind, b: PublishBind) -> Bool { a.label == b.label }

    /// Parse a `publishHostIP` config value.
    ///
    /// An unparseable value falls back to **loopback**, not to the wildcard default: the
    /// only reason to set this key at all is to restrict (the default is already
    /// all-interfaces), so a typo means someone was trying to lock down — resolving that
    /// to "exposed on the LAN" would be exactly the wrong direction. Warns either way.
    ///
    /// `origin` names where the value came from in that warning — the `publishHostIP` setting
    /// by default, or a container's `-p <hostIP>:<port>`.
    public static func parse(_ raw: String, origin: String? = nil) -> PublishBind {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch s {
        case "", "0.0.0.0", "*", "::": return .wildcard
        case "127.0.0.1", "localhost", "::1": return .loopback
        default: break
        }
        var a = in_addr()
        guard s.withCString({ inet_pton(AF_INET, $0, &a) }) == 1 else {
            let what = origin ?? "publishHostIP \"\(raw)\""
            let why = s.contains(":") ? "IPv6 host addresses aren't supported for published ports"
                                      : "not a valid IPv4 address"
            Log.warn("\(what): \(why) — binding 127.0.0.1 instead (host-only)")
            return .loopback
        }
        // A specific host address: bind exactly it. If it isn't assigned to any interface
        // the bind fails with EADDRNOTAVAIL and the forwarder logs the address by name.
        return PublishBind(v4: a.s_addr, v6: nil, isWildcard: false, label: s)
    }

    /// The log line for a failed host bind. `EADDRNOTAVAIL` on a specific address is the one
    /// worth spelling out: it means the Mac has no such address, and because the guest accepted
    /// it (`ip_nonlocal_bind`) the container is running while its port silently isn't.
    public func bindFailure(port: UInt16, proto: String, errno err: Int32) -> String {
        if err == EADDRNOTAVAIL, !isWildcard, !isLoopback {
            return "\(proto)-forward: \(label) is not an address of this Mac — port \(port) is NOT "
                + "published (the container is running). Use an address `ifconfig` lists, or "
                + "publish without a host IP."
        }
        return "\(proto)-forward: could not bind \(label):\(port) (errno \(err))"
    }

    /// True when a `HostIp` reported by dockerd is a loopback literal.
    ///
    /// dockerd reports the address each published port is bound to *inside the guest*:
    /// `0.0.0.0`/`::` for a plain `-p 8080:80`, and `127.0.0.1` when the user explicitly
    /// wrote `-p 127.0.0.1:8080:80`. That distinction is the user's stated intent, and it
    /// is the one part of the `HostIp` spec Velox can honour without rewriting the Docker
    /// API stream — loopback exists in the guest netns, so the container create succeeds
    /// and the address comes back to us on the events/list path.
    public static func isLoopbackLiteral(_ ip: String?) -> Bool {
        guard let ip, !ip.isEmpty else { return false }
        return ip == "127.0.0.1" || ip == "::1" || ip.hasPrefix("127.")
    }
}

/// One published host port and the bind it resolved to.
///
/// A container that explicitly published on loopback (`-p 127.0.0.1:5432:5432`) must stay
/// host-only even when `publishHostIP` defaults to all interfaces: an explicit per-container
/// request always beats the global default, or turning on Docker-compatible publishing would
/// silently widen every deliberately-private service (a database, an admin port) onto the LAN.
public struct PublishedPort: Hashable, Sendable {
    public let port: UInt16
    /// The host address the container asked for (`-p <hostIP>:…`), or nil for a plain `-p`,
    /// which follows the global `publishHostIP` default. `"127.0.0.1"` is the loopback pin.
    public let hostIP: String?

    public init(port: UInt16, hostIP: String?) {
        self.port = port; self.hostIP = hostIP
    }

    public init(port: UInt16, loopbackOnly: Bool) {
        self.init(port: port, hostIP: loopbackOnly ? PublishBind.loopback.label : nil)
    }

    /// Every binding dockerd reported for this port was a loopback address.
    public var loopbackOnly: Bool { hostIP.map(PublishBind.isLoopbackLiteral) ?? false }

    /// The address this port's host listener binds, given the configured default. An explicit
    /// per-container address always wins over the global default, in both directions: a
    /// loopback pin is never widened, and a specific LAN address is bound exactly (an
    /// unparseable one fails closed to loopback, as `PublishBind.parse` does).
    public func bind(default def: PublishBind) -> PublishBind {
        guard let hostIP else { return def }
        return PublishBind.isLoopbackLiteral(hostIP)
            ? .loopback
            : PublishBind.parse(hostIP, origin: "-p \(hostIP.contains(":") ? "[\(hostIP)]" : hostIP):\(port)")
    }

    /// Resolve the host address for one port from every binding dockerd reported for it
    /// (v4 and v6 entries, possibly several containers). Any wildcard binding means the
    /// global default. Otherwise all-loopback pins loopback; one specific address binds
    /// exactly that; anything mixed (two different addresses) narrows to loopback — the
    /// fail-closed direction, since one listener per port can carry only one address.
    public static func resolveHostIP(_ reported: [String?]) -> String? {
        var specific = Set<String>()
        var sawLoopback = false
        for ip in reported {
            guard let ip, !ip.isEmpty, ip != "0.0.0.0", ip != "::" else { return nil }
            if PublishBind.isLoopbackLiteral(ip) { sawLoopback = true } else { specific.insert(ip) }
        }
        if specific.isEmpty { return sawLoopback ? PublishBind.loopback.label : nil }
        if specific.count == 1, !sawLoopback { return specific.first }
        return PublishBind.loopback.label
    }
}
