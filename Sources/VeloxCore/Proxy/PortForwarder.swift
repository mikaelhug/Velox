import Foundation

/// Maintains a `127.0.0.1:<port>` TCP listener on the Mac for each published
/// container port, forwarding connections over VSOCK to the guest reverse-relay
/// (which dials the same port inside the guest, where dockerd published it).
public final class PortForwarder: @unchecked Sendable {
    private struct Listener {
        let fd: Int32
        let source: DispatchSourceRead
    }

    private let bridge: VsockBridge
    private let queue = DispatchQueue(label: "dev.velox.portfwd")
    private var listeners: [UInt16: Listener] = [:]

    public init(bridge: VsockBridge) {
        self.bridge = bridge
    }

    /// Reconcile open listeners against the desired set of published ports.
    public func reconcile(_ wanted: Set<UInt16>) {
        queue.async {
            let current = Set(self.listeners.keys)
            for port in wanted.subtracting(current) { self.open(port) }
            for port in current.subtracting(wanted) { self.closeListener(port) }
        }
    }

    public func stopAll() {
        queue.async { for port in Array(self.listeners.keys) { self.closeListener(port) } }
    }

    // MARK: - private (all on `queue`)

    private func open(_ port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 128) == 0 else {
            Log.warn("port-forward: could not bind 127.0.0.1:\(port) (errno \(errno))")
            Darwin.close(fd)
            return
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(on: fd, port: port) }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        listeners[port] = Listener(fd: fd, source: source)
        Log.info("port-forward: localhost:\(port) → guest:\(port)")
    }

    private func closeListener(_ port: UInt16) {
        guard let listener = listeners.removeValue(forKey: port) else { return }
        listener.source.cancel()
        Log.info("port-forward: closed localhost:\(port)")
    }

    private func accept(on fd: Int32, port: UInt16) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 { break }
            bridge.bridge(localFd: client, toGuestPort: VsockPort.reverse, header: "\(port)\n")
        }
    }
}
