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
/// This is a **host-side** bind address only. The guest always publishes on `0.0.0.0`
/// guest-locally, and a macOS host address means nothing inside the VM — asking the guest
/// dockerd for one fails with `cannot assign requested address` — so a per-container
/// `-p <hostIP>:8080:80` is not supported. This global setting is the supported knob.
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
    public static func parse(_ raw: String) -> PublishBind {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch s {
        case "", "0.0.0.0", "*": return .wildcard
        case "127.0.0.1", "localhost": return .loopback
        default: break
        }
        var a = in_addr()
        guard s.withCString({ inet_pton(AF_INET, $0, &a) }) == 1 else {
            Log.warn("publishHostIP \"\(raw)\" is not a valid IPv4 address — "
                     + "binding published ports to 127.0.0.1 (host-only)")
            return .loopback
        }
        // A specific host address: bind exactly it. If it isn't assigned to any interface
        // the bind fails with EADDRNOTAVAIL and the forwarder logs the address by name.
        return PublishBind(v4: a.s_addr, v6: nil, isWildcard: false, label: s)
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
    /// Every binding dockerd reported for this port was a loopback address.
    public let loopbackOnly: Bool

    public init(port: UInt16, loopbackOnly: Bool) {
        self.port = port; self.loopbackOnly = loopbackOnly
    }

    /// The address this port's host listener binds, given the configured default.
    public func bind(default def: PublishBind) -> PublishBind { loopbackOnly ? .loopback : def }
}
