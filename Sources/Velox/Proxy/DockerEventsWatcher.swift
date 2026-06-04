import Foundation

/// Polls the Docker API for the set of published container ports and reports
/// changes. Polling (vs. streaming /events) keeps the implementation simple and
/// robust; 1s granularity is fine for port publishing.
final class DockerEventsWatcher {
    private let socketPath: String
    private let onPorts: (Set<UInt16>) -> Void
    private let queue = DispatchQueue(label: "dev.velox.events")
    private var timer: DispatchSourceTimer?
    private var last: Set<UInt16> = []

    init(socketPath: String, onPorts: @escaping (Set<UInt16>) -> Void) {
        self.socketPath = socketPath
        self.onPorts = onPorts
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
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
