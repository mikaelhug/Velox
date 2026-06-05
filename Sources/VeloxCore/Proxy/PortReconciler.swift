import Foundation

/// Reconciles published container ports against the userspace netstack's host
/// listeners. Polls the Docker API (like the VZNAT-era `DockerEventsWatcher`) and
/// calls `NetworkStack.expose`/`unexpose` for added/removed ports. Replaces
/// `PortForwarder` + `DockerEventsWatcher` + the guest reverse-relay when the
/// in-process netstack is active.
public final class PortReconciler: @unchecked Sendable {
    private let socketPath: String
    private let stack: NetworkStack
    private let queue = DispatchQueue(label: "dev.velox.portreconcile")
    private var timer: DispatchSourceTimer?
    private var published: Set<UInt16> = []

    public init(socketPath: String, stack: NetworkStack) {
        self.socketPath = socketPath
        self.stack = stack
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        for port in published { stack.unexpose(.tcp, hostPort: port) }
        published = []
    }

    private func poll() {
        // nil = daemon not reachable / transient API error; leave forwards untouched.
        guard let ports = DockerAPI.publishedTCPPorts(socketPath: socketPath),
              ports != published else { return }
        for port in ports.subtracting(published) {
            stack.expose(.tcp, hostPort: port, guestPort: port)
        }
        for port in published.subtracting(ports) {
            stack.unexpose(.tcp, hostPort: port)
        }
        published = ports
    }
}
