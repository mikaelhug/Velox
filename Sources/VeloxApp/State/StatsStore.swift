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
    /// Latest sample per running container — the Containers table reads this by id.
    /// Published as a ~1 Hz **snapshot** (see `recompute`), not per raw sample: Swift
    /// Observation tracks a dictionary at whole-property granularity, so updating it on
    /// every sample would re-evaluate *every* visible usage cell on *every* sample (≈N²).
    private(set) var latest: [String: ContainerStatsSample] = [:]
    /// Live aggregate across running containers — the Overview reads these.
    private(set) var totalCPU: Double = 0
    private(set) var totalMemBytes: UInt64 = 0
    private(set) var cpuHistory: [Double] = []
    private(set) var memHistory: [Double] = []
    // Disk/network are throughput (bytes/sec), derived per-container from successive
    // samples and SUMMED — the Overview's mirrored I/O graphs read these directional
    // totals + their 90-sample histories. (Read/In above the baseline, Write/Out below.)
    private(set) var totalDiskRead: Double = 0
    private(set) var totalDiskWrite: Double = 0
    private(set) var totalNetRx: Double = 0
    private(set) var totalNetTx: Double = 0
    private(set) var diskReadHistory: [Double] = []
    private(set) var diskWriteHistory: [Double] = []
    private(set) var netRxHistory: [Double] = []
    private(set) var netTxHistory: [Double] = []

    private let docker: any DockerClientProtocol
    private let resources: DockerResourceStore
    private let historyCap = 90

    /// Per-container I/O throughput (bytes/sec), the delta of each container's cumulative
    /// counters between its last two samples. Summed across containers in `recompute()`.
    private struct IORates { var diskRead = 0.0, diskWrite = 0.0, netRx = 0.0, netTx = 0.0 }
    private var rates: [String: IORates] = [:]

    /// Per-sample raw samples (NOT observed by any view) — the live source the deltas and
    /// the throttled `latest` snapshot are built from. Mutating this per sample is free:
    /// no view reads it, so it triggers no re-render.
    private var raw: [String: ContainerStatsSample] = [:]

    /// Timestamp of the last aggregate publish, so we refresh the Overview at ~1 Hz no
    /// matter how many containers stream (each emits ~1 Hz, out of phase). Driven by the
    /// sample's own clock — still event-driven, no timer — and it keeps the graphs from
    /// re-rendering N×/sec (lean: idle/off-screen ⇒ no work; active ⇒ one redraw/sec).
    private var lastTick: Date?

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
            raw[id] = nil
            rates[id] = nil            // drop its throughput so it leaves the sum cleanly
        }
        recompute(force: true)         // a container appeared/vanished — reflect it now
    }

    private func ingest(_ id: String, _ sample: ContainerStatsSample) {
        guard streams[id] != nil else { return } // late sample for a just-removed id
        // Derive throughput against THIS container's previous sample, before it's replaced.
        rates[id] = Self.rate(prev: raw[id], now: sample)
        raw[id] = sample
        recompute(now: sample.read)
    }

    /// Per-second I/O throughput from one container's two latest samples. The first sample
    /// (no `prev`) yields zero; a counter reset on container restart clamps to zero; dt comes
    /// from the samples' own `read` timestamps, floored to avoid div-by-zero / false spikes.
    private static func rate(prev: ContainerStatsSample?, now: ContainerStatsSample) -> IORates {
        guard let prev else { return IORates() }
        let dt: Double
        if let a = prev.read, let b = now.read { dt = max(b.timeIntervalSince(a), 0.5) }
        else { dt = 1.0 }
        func r(_ new: UInt64, _ old: UInt64) -> Double { new >= old ? Double(new - old) / dt : 0 }
        return IORates(diskRead: r(now.blkReadBytes, prev.blkReadBytes),
                       diskWrite: r(now.blkWriteBytes, prev.blkWriteBytes),
                       netRx: r(now.netRxBytes, prev.netRxBytes),
                       netTx: r(now.netTxBytes, prev.netTxBytes))
    }

    /// Recompute the aggregates and advance the histories. Throttled to ~1 Hz by the
    /// sample clock (unless `force`d by a container add/remove) so a fleet of containers
    /// can't drive the Overview to re-render many times a second. `latest`/`rates` are
    /// already updated per-sample by the caller; this only governs the *published* state.
    private func recompute(now: Date? = nil, force: Bool = false) {
        if !force, let last = lastTick {
            let dt = (now ?? Date()).timeIntervalSince(last)
            if dt >= 0 && dt < 0.9 { return }   // <0 ⇒ guest clock stepped back: let it through
        }
        lastTick = now ?? Date()
        // One pass over the running set: CPU/mem from the raw samples, disk/net from each
        // container's per-second rate. Aggregate-of-per-container-deltas (NOT delta-of-
        // aggregate): a container starting/stopping would otherwise inject its whole
        // lifetime counter as a one-tick spike.
        var cpu = 0.0, mem: UInt64 = 0, dRead = 0.0, dWrite = 0.0, nRx = 0.0, nTx = 0.0
        for (id, sample) in raw {
            cpu += sample.cpuPercent
            mem += sample.memoryBytes
            if let r = rates[id] { dRead += r.diskRead; dWrite += r.diskWrite; nRx += r.netRx; nTx += r.netTx }
        }
        totalCPU = cpu; totalMemBytes = mem
        totalDiskRead = dRead; totalDiskWrite = dWrite; totalNetRx = nRx; totalNetTx = nTx
        latest = raw   // publish the per-container snapshot the Containers table reads (1 Hz)
        push(&cpuHistory, cpu)
        push(&memHistory, Double(mem))
        push(&diskReadHistory, dRead)
        push(&diskWriteHistory, dWrite)
        push(&netRxHistory, nRx)
        push(&netTxHistory, nTx)
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
        raw.removeAll()
        rates.removeAll()
        lastTick = nil
        totalCPU = 0; totalMemBytes = 0
        totalDiskRead = 0; totalDiskWrite = 0; totalNetRx = 0; totalNetTx = 0
        cpuHistory.removeAll(); memHistory.removeAll()
        diskReadHistory.removeAll(); diskWriteHistory.removeAll()
        netRxHistory.removeAll(); netTxHistory.removeAll()
    }
}
