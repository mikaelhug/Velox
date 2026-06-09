import Foundation

/// The VZNAT gateway IP is opaque to Swift — `VZNATNetworkDeviceAttachment` exposes no
/// subnet/gateway API. So the host learns it from the guest: connect once to
/// `VsockPort.gateway` and read `"<gw> <ip> <mask>\n"`. The gateway is the Mac's own
/// address on the vmnet bridge (e.g. `bridge100` = 192.168.64.1), so we confirm a local
/// interface carries it — that address is where `ConduitPool` binds the reverse-dial pool.
public struct GatewayInfo: Sendable {
    /// The Mac's bridge address (== the guest's default gateway), network byte order.
    public let gatewayIP: in_addr_t
    /// The guest's own VZNAT IP, network byte order (used to validate conduit peers).
    public let guestIP: in_addr_t
}

public enum GatewayProbe {
    /// Ask the guest for its network info and locate the matching host interface. Returns
    /// nil if the guest never answers with a usable gateway, or no local interface carries
    /// it — in which case the caller simply keeps the existing vsock reverse-relay path.
    public static func probe(manager: VMManager,
                             retries: Int = 20,
                             retryDelay: TimeInterval = 0.5) async -> GatewayInfo? {
        for _ in 0..<retries {
            if let line = await readLine(manager: manager), let info = parse(line) {
                return info
            }
            try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
        }
        Log.warn("gateway probe: guest never reported a usable gateway; conduit pool disabled")
        return nil
    }

    /// One vsock round-trip: connect to the gateway port, read a single `\n`-terminated line.
    /// Reads happen off the VM queue (same pattern as `VMManager.stopGracefully`).
    private static func readLine(manager: VMManager) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            manager.connectToGuestPort(VsockPort.gateway) { result in
                guard case .success(let fd) = result else { cont.resume(returning: nil); return }
                DispatchQueue.global().async {
                    var buf = [UInt8]()
                    var byte: UInt8 = 0
                    while buf.count < 64 {
                        let n = read(fd, &byte, 1)
                        if n <= 0 { break }
                        if byte == UInt8(ascii: "\n") { break }
                        buf.append(byte)
                    }
                    close(fd)
                    cont.resume(returning: buf.isEmpty ? nil : String(decoding: buf, as: UTF8.self))
                }
            }
        }
    }

    private static func parse(_ line: String) -> GatewayInfo? {
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count == 3,
              let gw = ipToBE(parts[0]), gw != 0,
              let ip = ipToBE(parts[1]),
              let mask = ipToBE(parts[2]) else { return nil }
        guard let iface = matchingInterface(gateway: gw, mask: mask) else {
            Log.warn("gateway probe: no local interface carries \(parts[0]); conduit pool disabled")
            return nil
        }
        Log.info("gateway probe: gw=\(parts[0]) guest=\(parts[1]) mask=\(parts[2]) iface=\(iface)")
        return GatewayInfo(gatewayIP: gw, guestIP: ip)
    }

    /// Parse dotted-decimal → `in_addr_t` (network byte order), or nil.
    private static func ipToBE(_ s: String) -> in_addr_t? {
        var a = in_addr()
        return inet_pton(AF_INET, s, &a) == 1 ? a.s_addr : nil
    }

    /// Find the local AF_INET interface whose address equals the gateway (the Mac's own
    /// address on the vmnet bridge) — preferred — or, failing an exact match, one in the
    /// same subnet. That address is the conduit pool's bind target.
    private static func matchingInterface(gateway: in_addr_t, mask: in_addr_t) -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }
        var exact: String?
        var subnet: String?
        var ptr = ifap
        while let cur = ptr {
            let next = cur.pointee.ifa_next
            defer { ptr = next }
            guard let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let addr = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self)
                .pointee.sin_addr.s_addr
            let name = String(cString: cur.pointee.ifa_name)
            if addr == gateway { exact = name }
            else if (addr & mask) == (gateway & mask) { subnet = name }
        }
        return exact ?? subnet
    }
}
