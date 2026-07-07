import Foundation

/// Filesystem layout for Velox state, all rooted at ~/.velox (rootless).
public enum Paths {
    public static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// ~/.velox — owns runtime state, guest artifacts, and the Docker socket.
    public static var root: URL {
        home.appendingPathComponent(".velox", isDirectory: true)
    }

    public static var kernel: URL { root.appendingPathComponent("kernel") }
    /// Read-only erofs root filesystem (the guest OS), booted as /dev/vda.
    public static var rootDisk: URL { root.appendingPathComponent("root.img") }
    public static var dataDisk: URL { root.appendingPathComponent("data.img") }
    public static var dockerSocket: URL { root.appendingPathComponent("docker.sock") }
    /// Single-instance lock: an exclusive `flock` on this file means an engine is
    /// running, so a second one (app or `velox start`) refuses to boot rather than
    /// attach the same data.img and fight over the docker socket / published ports.
    public static var engineLock: URL { root.appendingPathComponent("engine.lock") }
    /// User preferences persisted by the GUI (resources, file shares, etc.).
    public static var config: URL { root.appendingPathComponent("config.json") }

    @discardableResult
    public static func ensureRoot() throws -> URL {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }
}

/// Well-known guest VSOCK ports. MUST stay in sync with the guest-side constants in
/// `guest/vinit/src/main.rs` (`DOCKER_PORT`/`CONTROL_PORT`/`REVERSE_PORT`/`CLOCK_PORT`/`GW_PORT`).
public enum VsockPort {
    /// Guest relay forwarding to dockerd.
    public static let docker: UInt32 = 2375
    /// Control port: connecting triggers sync(2) in the guest.
    public static let control: UInt32 = 2374
    /// Reverse port-forward: host sends "<port>\n", guest dials 127.0.0.1:<port>.
    public static let reverse: UInt32 = 2376
    /// Clock sync: host sends "<unix-epoch>\n", guest re-sets its clock on drift.
    public static let clock: UInt32 = 2377
    /// Gateway probe: host connects once at boot, guest replies "<gw> <ip> <mask>\n".
    /// VZNATNetworkDeviceAttachment is opaque to Swift, so the host learns the vmnet
    /// gateway IP (and guest IP/mask) this way — needed to bind the conduit pool.
    public static let gateway: UInt32 = 2378
}

/// The VZNAT reverse-dial conduit pool's **TCP** port (NOT a vsock port). The guest dials
/// `GATEWAY_IP:<this>` over the fast VZNAT path; the host binds it on the gateway-IP (vmnet
/// bridge) interface and parks the connections as a warm pool. Kept in sync with the guest's
/// `POOL_PORT`. See `Sources/VeloxCore/Proxy/ConduitPool.swift`.
public enum ConduitPort {
    public static let pool: UInt16 = 2379
}

/// Direct (named) container access. The host runs a loopback DNS responder on `dnsPort`;
/// `/etc/resolver/<domain>` (installed once by the porthelper grant) routes `*.<domain>` there,
/// and it answers with the target container's real IP. The port is FIXED so the resolver file
/// stays static (an ephemeral port would force a re-install every launch). See
/// `Sources/VeloxCore/Proxy/NameDNSResponder.swift`.
public enum NamedAccess {
    public static let domain = "velox.local"
    public static let dnsPort: UInt16 = 49252
}
