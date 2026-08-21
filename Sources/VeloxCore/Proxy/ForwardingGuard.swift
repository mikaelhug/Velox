import Darwin
import Foundation
import Network

/// Keeps macOS IP forwarding ON while the engine runs.
///
/// The whole container datapath is Apple's in-kernel vmnet NAT (CLAUDE.md §1), which
/// is nothing more than kernel packet forwarding plus translation — and some VPN
/// clients (measured: the OpenVPN-based AWS VPN Client) set
/// `net.inet.ip.forwarding=0` system-wide when they connect. The instant that happens,
/// every container loses all connectivity past the Mac (DNS still answers — the vmnet
/// gateway is the Mac itself — so pulls fail as resolve-then-timeout) while the
/// routing table stays clean, and no engine restart helps while the VPN is up (vmnet
/// does not re-assert the sysctl — measured). The heal is equally simple and instant:
/// switch forwarding back on and traffic resumes mid-flight, VPN connected or not.
///
/// Event-driven (CLAUDE.md §8): NWPathMonitor pushes a path change when a VPN brings
/// its utun up or tears it down (the trigger); the sysctl is re-read on each push (the
/// truth — an unprivileged read). The restore itself goes through the porthelper
/// (control-plane root op, §2's sanctioned exception). No timers, no polling.
public final class ForwardingGuard: @unchecked Sendable {
    private let helper: PortHelperManager
    private let queue = DispatchQueue(label: "velox.forwarding-guard")
    private var monitor: NWPathMonitor?
    /// Also fired on every path change. The same VPN churn that clears the forwarding
    /// sysctl can flush host routes, and the named-access router only ever applies a diff —
    /// so a route removed behind its back was never re-added and `<name>.velox.local`
    /// resolved to an unreachable IP for the rest of the session. Reuses this monitor
    /// rather than starting a second one.
    private var onPathChange: (@Sendable () -> Void)?

    public init(helper: PortHelperManager) {
        self.helper = helper
    }

    /// Set before `start()`. Called on the guard queue for every network path change.
    public func setPathChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        onPathChange = handler
    }

    /// Begin watching. NWPathMonitor fires once immediately with the current path,
    /// so this doubles as the boot-time check.
    public func start() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.check()
            self?.onPathChange?()
        }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    public func stop() {
        monitor?.cancel()
        monitor = nil
    }

    /// On the guard queue: re-read the switch, restore through the helper if cleared.
    private func check() {
        guard Self.forwardingEnabled() == false else { return }
        Log.warn("net.inet.ip.forwarding is OFF (a VPN client likely disabled it) — "
                 + "container egress is dead; restoring via the helper")
        if helper.restoreIPForwarding(), Self.forwardingEnabled() == true {
            Log.info("ip forwarding restored — container networking is back")
        } else {
            Log.warn("could not restore ip forwarding (helper not installed or declined) — "
                     + "containers have no internet until you run: "
                     + "sudo sysctl -w net.inet.ip.forwarding=1")
        }
    }

    /// Unprivileged read of the kernel switch. nil if unreadable (treated as fine).
    public static func forwardingEnabled() -> Bool? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("net.inet.ip.forwarding", &value, &size, nil, 0) == 0 else { return nil }
        return value != 0
    }
}
