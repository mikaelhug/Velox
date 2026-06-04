import Foundation

/// Polls the Docker API for the set of published container ports and reports
/// changes. Polling (vs. streaming /events) keeps the implementation simple and
/// robust; 1s granularity is fine for port publishing.
public final class DockerEventsWatcher: @unchecked Sendable {
    private let socketPath: String
    private let onPorts: @Sendable (Set<UInt16>) -> Void
    private let queue = DispatchQueue(label: "dev.velox.events")
    private var timer: DispatchSourceTimer?
    private var last: Set<UInt16> = []

    public init(socketPath: String, onPorts: @escaping @Sendable (Set<UInt16>) -> Void) {
        self.socketPath = socketPath
        self.onPorts = onPorts
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
    }

    private func poll() {
        // nil = daemon not reachable yet; keep current forwards untouched.
        guard let ports = DockerAPI.publishedTCPPorts(socketPath: socketPath) else { return }
        if ports != last {
            last = ports
            onPorts(ports)
        }
    }
}
