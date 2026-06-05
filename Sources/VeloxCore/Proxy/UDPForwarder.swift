import Foundation

/// Maintains a `127.0.0.1:<port>` **UDP** listener on the Mac for each published
/// container UDP port (the datagram sibling of `PortForwarder`).
///
/// UDP is connectionless, so it can't reuse the TCP stream pump. Instead, per client
/// flow (keyed by source address+port) the host opens one VSOCK connection to the
/// guest reverse-relay with the header `"udp <port>\n"`, then tunnels each datagram
/// length-prefixed (`[u16 BE len][payload]`) in both directions. The guest dials the
/// published UDP port inside the guest (docker-proxy on 127.0.0.1:port, exactly like
/// the TCP path). Flows idle for `idleSeconds` are reclaimed.
public final class UDPForwarder: @unchecked Sendable {
    private struct FlowKey: Hashable { let addr: UInt32; let port: UInt16 }

    /// Per-flow state. All mutable access is serialized on `queue` (the reader thread
    /// only reads immutable copies it captured and pings `touch(...)` back onto the
    /// queue), so the unchecked Sendable conformance is sound.
    private final class Flow: @unchecked Sendable {
        var vsockFd: Int32 = -1          // set once the VSOCK connection is ready
        var ready = false
        var pending: [[UInt8]] = []      // datagrams buffered during async connect
        var lastActive = Date()
        var client = sockaddr_in()
    }

    private final class Listener {
        let fd: Int32
        let source: DispatchSourceRead
        var flows: [FlowKey: Flow] = [:]
        init(fd: Int32, source: DispatchSourceRead) { self.fd = fd; self.source = source }
    }

    private let manager: VMManager
    private let queue = DispatchQueue(label: "dev.velox.udpfwd")
    private var listeners: [UInt16: Listener] = [:]
    private let idleSeconds: TimeInterval
    private var reaper: DispatchSourceTimer?
    private let maxPending = 32

    public init(manager: VMManager, idleSeconds: TimeInterval = 60) {
        self.manager = manager
        self.idleSeconds = idleSeconds
    }

    /// Reconcile open UDP listeners against the desired set of published ports.
    public func reconcile(_ wanted: Set<UInt16>) {
        queue.async {
            let current = Set(self.listeners.keys)
            for port in wanted.subtracting(current) { self.open(port) }
            for port in current.subtracting(wanted) { self.closeListener(port) }
            self.ensureReaper()
        }
    }

    public func stopAll() {
        queue.async {
            for port in Array(self.listeners.keys) { self.closeListener(port) }
            self.reaper?.cancel(); self.reaper = nil
        }
    }

    // MARK: - private (all on `queue` unless noted)

    private func open(_ port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
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
        guard bound == 0 else {
            Log.warn("udp-forward: could not bind 127.0.0.1:\(port)/udp (errno \(errno))")
            Darwin.close(fd); return
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readDatagrams(port) }
        source.setCancelHandler { Darwin.close(fd) }
        let listener = Listener(fd: fd, source: source)
        listeners[port] = listener
        source.resume()
        Log.info("udp-forward: localhost:\(port)/udp → guest:\(port)/udp")
    }

    private func closeListener(_ port: UInt16) {
        guard let listener = listeners.removeValue(forKey: port) else { return }
        for (_, flow) in listener.flows { teardown(flow) }   // close flows before the udp fd
        listener.source.cancel()
        Log.info("udp-forward: closed localhost:\(port)/udp")
    }

    /// Drain all pending datagrams on a port's UDP socket, demultiplex by client.
    private func readDatagrams(_ port: UInt16) {
        guard let listener = listeners[port] else { return }
        var buf = [UInt8](repeating: 0, count: 65535)
        while true {
            var from = sockaddr_in()
            var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(listener.fd, &buf, buf.count, 0, sa, &flen)
                }
            }
            if n <= 0 { break }
            let datagram = Array(buf[0..<n])
            let key = FlowKey(addr: from.sin_addr.s_addr, port: from.sin_port)
            if let flow = listener.flows[key] {
                flow.lastActive = Date()
                if flow.ready { _ = Self.writeFrame(flow.vsockFd, datagram) }
                else if flow.pending.count < maxPending { flow.pending.append(datagram) }
            } else {
                let flow = Flow()
                flow.client = from
                flow.pending.append(datagram)
                listener.flows[key] = flow
                connect(flow, port: port, key: key)
            }
        }
    }

    /// Open the per-flow VSOCK connection (async), then flush buffered datagrams and
    /// start the guest→host reader.
    private func connect(_ flow: Flow, port: UInt16, key: FlowKey) {
        manager.connectToGuestPort(VsockPort.reverse) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                // Flow may have been reclaimed while connecting.
                guard let listener = self.listeners[port], listener.flows[key] === flow else {
                    if case .success(let fd) = result { Darwin.close(fd) }
                    return
                }
                switch result {
                case .failure(let error):
                    Log.error("udp-forward: vsock connect failed: \(error.localizedDescription)")
                    listener.flows[key] = nil
                case .success(let vsockFd):
                    let header = Array("udp \(port)\n".utf8)
                    guard Self.writeAll(vsockFd, header) else { Darwin.close(vsockFd); listener.flows[key] = nil; return }
                    flow.vsockFd = vsockFd
                    flow.ready = true
                    for dg in flow.pending { _ = Self.writeFrame(vsockFd, dg) }
                    flow.pending.removeAll()
                    self.startReader(listenerFd: listener.fd, flow: flow, port: port, key: key)
                }
            }
        }
    }

    /// Guest→host: read framed datagrams off the VSOCK stream, send each back to the
    /// originating client on the shared UDP socket. Runs on its own thread.
    private func startReader(listenerFd: Int32, flow: Flow, port: UInt16, key: FlowKey) {
        let vsockFd = flow.vsockFd
        let clientCopy = flow.client
        Thread.detachNewThread { [weak self] in
            var client = clientCopy
            var hdr = [UInt8](repeating: 0, count: 2)
            var buf = [UInt8](repeating: 0, count: 65535)
            while Self.readExact(vsockFd, &hdr, 2) {
                let len = Int(hdr[0]) << 8 | Int(hdr[1])
                if len == 0 { continue }
                if !Self.readExact(vsockFd, &buf, len) { break }
                _ = withUnsafePointer(to: &client) { cp in
                    cp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(listenerFd, buf, len, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                self?.touch(port: port, key: key)
            }
            self?.queue.async { self?.reclaim(port: port, key: key) }
        }
    }

    private func touch(port: UInt16, key: FlowKey) {
        queue.async { self.listeners[port]?.flows[key]?.lastActive = Date() }
    }

    /// Close + remove a single flow (idempotent).
    private func reclaim(port: UInt16, key: FlowKey) {
        guard let flow = listeners[port]?.flows.removeValue(forKey: key) else { return }
        teardown(flow)
    }

    private func teardown(_ flow: Flow) {
        if flow.vsockFd >= 0 {
            shutdown(flow.vsockFd, SHUT_RDWR)   // unblock the reader thread
            Darwin.close(flow.vsockFd)
            flow.vsockFd = -1
        }
        flow.ready = false
    }

    /// Periodically reclaim flows idle beyond `idleSeconds`. The only timer here is a
    /// genuine inactivity sweep — UDP has no connection close to ride.
    private func ensureReaper() {
        guard reaper == nil, !listeners.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.sweep() }
        reaper = timer
        timer.resume()
    }

    private func sweep() {
        let cutoff = Date().addingTimeInterval(-idleSeconds)
        for (_, listener) in listeners {
            for (key, flow) in listener.flows where flow.lastActive < cutoff {
                listener.flows[key] = nil
                teardown(flow)
            }
        }
    }

    // MARK: - framing helpers (fd I/O; safe to call off `queue`)

    /// Write `[u16 BE len][payload]` for one datagram.
    private static func writeFrame(_ fd: Int32, _ payload: [UInt8]) -> Bool {
        let len = payload.count
        let hdr: [UInt8] = [UInt8((len >> 8) & 0xff), UInt8(len & 0xff)]
        return writeAll(fd, hdr) && writeAll(fd, payload)
    }

    private static func writeAll(_ fd: Int32, _ buf: [UInt8]) -> Bool {
        var off = 0
        return buf.withUnsafeBytes { raw in
            while off < buf.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), buf.count - off)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }

    private static func readExact(_ fd: Int32, _ buf: inout [UInt8], _ count: Int) -> Bool {
        var off = 0
        return buf.withUnsafeMutableBytes { raw in
            while off < count {
                let n = read(fd, raw.baseAddress!.advanced(by: off), count - off)
                if n == 0 { return false }
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }
}
