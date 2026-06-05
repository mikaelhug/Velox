import Foundation
import Virtualization
import CVeloxNet

/// Configuration for the in-process userspace network stack. IPv4 only (v1).
public struct NetConfig: Sendable {
    public var gatewayIP: UInt32   // host byte order, e.g. 0xC0A8_7F01
    public var guestIP: UInt32
    public var prefixLen: UInt8
    public var mtu: UInt16

    public init(gatewayIP: UInt32, guestIP: UInt32, prefixLen: UInt8, mtu: UInt16) {
        self.gatewayIP = gatewayIP; self.guestIP = guestIP
        self.prefixLen = prefixLen; self.mtu = mtu
    }

    /// gvisor-tap-vsock-compatible defaults: gateway .1, guest .2, /24, MTU 1500.
    public static let `default` = NetConfig(
        gatewayIP: 0xC0A8_7F01, guestIP: 0xC0A8_7F02, prefixLen: 24, mtu: 1500)

    /// Dotted-quad of the gateway (e.g. "192.168.127.1"), for the guest cmdline/DNS.
    public var gatewayDotted: String { Self.dotted(gatewayIP) }
    public var guestDotted: String { Self.dotted(guestIP) }
    static func dotted(_ ip: UInt32) -> String {
        "\((ip >> 24) & 0xff).\((ip >> 16) & 0xff).\((ip >> 8) & 0xff).\(ip & 0xff)"
    }
}

public enum NetProto: Int32, Sendable { case tcp = 0, udp = 1 }

public struct NetStats: Sendable {
    public var rxFrames: UInt64, txFrames: UInt64, rxBytes: UInt64, txBytes: UInt64
}

/// Swift owner of the in-process `velox-net` stack and its VZ network attachment.
///
/// Creates the AF_UNIX SOCK_DGRAM socketpair, hands one end to VZ via
/// `VZFileHandleNetworkDeviceAttachment` (one datagram = one ethernet frame) and
/// the other to the Rust stack over the C ABI. All container data traffic flows
/// through here; the Docker control plane stays on VSOCK, untouched.
public final class NetworkStack: @unchecked Sendable {
    /// The VZ network attachment to install in `VMConfiguration`.
    public let attachment: VZFileHandleNetworkDeviceAttachment
    public let config: NetConfig
    private let vzFileHandle: FileHandle
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public init(config: NetConfig = .default) throws {
        self.config = config
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw VeloxError.socketSetupFailed("socketpair(net)", errno)
        }
        let vzFd = fds[0]
        let netFd = fds[1]
        // Larger socket buffers help throughput on the frame path.
        var bufSize: Int32 = 1 << 20
        for fd in [vzFd, netFd] {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        }

        // VZ does not close the file handle; FileHandle owns vzFd (closeOnDealloc).
        let fh = FileHandle(fileDescriptor: vzFd, closeOnDealloc: true)
        self.vzFileHandle = fh
        self.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: fh)

        var c = vn_config(gateway_ip: config.gatewayIP, guest_ip: config.guestIP,
                          prefix_len: config.prefixLen, mtu: config.mtu)
        guard let h = velox_net_start(netFd, &c, networkStackLog, nil) else {
            close(netFd)
            throw VeloxError.socketSetupFailed("velox_net_start", 0)
        }
        self.handle = h
        Log.info("netstack: gateway \(config.gatewayDotted), guest \(config.guestDotted)/\(config.prefixLen)")
    }

    /// Publish a host port that forwards to `guestPort` inside the guest.
    public func expose(_ proto: NetProto, hostPort: UInt16, guestPort: UInt16) {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return }
        _ = velox_net_expose(h, proto.rawValue, hostPort, guestPort)
    }

    public func unexpose(_ proto: NetProto, hostPort: UInt16) {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return }
        _ = velox_net_unexpose(h, proto.rawValue, hostPort)
    }

    public func stats() -> NetStats? {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return nil }
        var s = vn_stats()
        guard velox_net_stats(h, &s) == 0 else { return nil }
        return NetStats(rxFrames: s.rx_frames, txFrames: s.tx_frames,
                        rxBytes: s.rx_bytes, txBytes: s.tx_bytes)
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if let h = handle {
            velox_net_stop(h) // signals the loop, joins, closes netFd
            handle = nil
        }
    }
}

/// C log trampoline (no captured context): routes velox-net logs into `Log`.
private func networkStackLog(_ level: Int32, _ msg: UnsafePointer<CChar>?,
                             _ ctx: UnsafeMutableRawPointer?) {
    guard let msg else { return }
    let s = String(cString: msg)
    switch level {
    case 0: Log.error(s)
    case 1: Log.warn(s)
    default: Log.info(s)
    }
}
