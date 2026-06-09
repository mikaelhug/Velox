import Foundation
import VeloxCore

/// The single, shared owner of live container CPU/memory stats.
///
/// **Why it exists:** the Containers table used to open one `docker.stats()` stream
/// *per row* (`ContainerUsageCell`) and the Overview opened a *second* fan-out — so with
/// N running containers you had N persistent VSOCK stats streams, re-established on every
/// Containers↔Overview switch, plus a `.task(id: containerID)` that captured `isRunning`
/// once and so never started streaming a container that went stopped→running. This store
/// owns **one** stream per running container, shared by both views, driven off the
/// running set — and only while a stats view is actually on screen (so nothing streams
/// on Images/Volumes). It's the stats sibling of `DockerResourceStore`.
@MainActor
@Observable
final class StatsStore {
    /// Latest sample per running container — table cells read this by id.
    private(set) var latest: [String: ContainerStatsSample] = [:]
    /// Live aggregate across running containers — the Overview reads these.
    private(set) var totalCPU: Double = 0
    private(set) var totalMemBytes: UInt64 = 0
    private(set) var cpuHistory: [Double] = []
    private(set) var memHistory: [Double] = []

    private let docker: any DockerClientProtocol
    private let resources: DockerResourceStore
    private let historyCap = 90

    // Streams run only while a stats view is retained. A short grace on the last
    // release means a Containers↔Overview switch (release-then-retain) doesn't tear
    // down and re-establish every stream.
    private var retainCount = 0
    private var stopGrace: Task<Void, Never>?
    private var tracking = false
    private var streams: [String: Task<Void, Never>] = [:]

    init(docker: any DockerClientProtocol, resources: DockerResourceStore) {
        self.docker = docker
        self.resources = resources
    }

    // MARK: - Lifecycle (called by the stats views' keep-alive `.task`)

    func retain() {
        retainCount += 1
        stopGrace?.cancel(); stopGrace = nil
        if !tracking { tracking = true; trackRunning() }
    }

    func release() {
        retainCount = max(0, retainCount - 1)
        guard retainCount == 0 else { return }
        stopGrace?.cancel()
        stopGrace = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, self.retainCount == 0 else { return }
            self.teardown()
        }
    }

    /// Full stop (engine teardown).
    func stop() {
        retainCount = 0
        stopGrace?.cancel(); stopGrace = nil
        teardown()
    }

    // MARK: - Running set → per-id streams

    /// Follow `resources.containers` via Observation: re-diff the running set into the
    /// per-id stream map on every change, then re-register. The `syncStreams` call is
    /// kept *outside* the tracked closure so only `resources.containers` is a tracked
    /// dependency (not `latest`/the aggregate it mutates), so re-arm fires only on a
    /// container-list change, never on every stats sample.
    private func trackRunning() {
        guard tracking else { return }
        let running = withObservationTracking {
            runningIDs()
        } onChange: {
            Task { @MainActor [weak self] in self?.trackRunning() }
        }
        syncStreams(running: running)
    }

    private func runningIDs() -> Set<String> {
        Set(resources.containers.filter(\.isRunning).map(\.id))
    }

    private func syncStreams(running: Set<String>) {
        for id in running where streams[id] == nil {
            streams[id] = Task { [weak self, docker] in
                for await sample in docker.stats(container: id) {
                    self?.ingest(id, sample)
                }
            }
        }
        for (id, task) in streams where !running.contains(id) {
            task.cancel()              // cancel unwinds an idle stats read promptly on shutdown
            streams[id] = nil
            latest[id] = nil
        }
        recompute()
    }

    private func ingest(_ id: String, _ sample: ContainerStatsSample) {
        guard streams[id] != nil else { return } // late sample for a just-removed id
        latest[id] = sample
        recompute()
    }

    private func recompute() {
        totalCPU = latest.values.reduce(0) { $0 + $1.cpuPercent }
        totalMemBytes = latest.values.reduce(0) { $0 + $1.memoryBytes }
        push(&cpuHistory, totalCPU)
        push(&memHistory, Double(totalMemBytes))
    }

    private func push(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > historyCap { array.removeFirst(array.count - historyCap) }
    }

    private func teardown() {
        tracking = false
        for task in streams.values { task.cancel() }
        streams.removeAll()
        latest.removeAll()
        totalCPU = 0; totalMemBytes = 0
        cpuHistory.removeAll(); memHistory.removeAll()
    }
}
