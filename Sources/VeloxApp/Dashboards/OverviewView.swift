import SwiftUI
import VeloxCore

/// Aggregates the four resource lists into headline counts/sizes and streams a
/// live CPU/memory total across every running container. Like the other models
/// it reconciles on the Docker `events` stream rather than polling.
@MainActor
@Observable
final class OverviewModel {
    let docker: any DockerClientProtocol
    private(set) var containers: [ContainerSummary] = []
    private(set) var images: [ImageSummary] = []
    private(set) var volumes: [Volume] = []
    private(set) var networks: [NetworkSummary] = []
    private(set) var diskUsedBytes: Int64?
    private(set) var loadError: String?

    // Live aggregate, summed from each running container's stats stream.
    private var latest: [String: ContainerStatsSample] = [:]
    private(set) var totalCPU: Double = 0
    private(set) var totalMemBytes: UInt64 = 0
    private(set) var cpuHistory: [Double] = []
    private(set) var memHistory: [Double] = []
    private let historyCap = 90

    init(docker: any DockerClientProtocol) { self.docker = docker }

    var runningCount: Int { containers.lazy.filter(\.isRunning).count }
    var totalImageBytes: Int64 { images.reduce(0) { $0 + $1.size } }
    var totalVolumeBytes: Int64 { volumes.reduce(0) { $0 + ($1.size ?? 0) } }
    var attachedCount: Int { networks.reduce(0) { $0 + $1.attachedContainers.count } }

    /// Identifies the current running set so the view restarts the stats fan-out
    /// (via `.task(id:)`) only when a container actually starts or stops.
    var runningKey: String { containers.filter(\.isRunning).map(\.id).sorted().joined(separator: ",") }

    func observe() async {
        await refresh()
        for await _ in docker.events() { await refresh() }
    }

    func refresh() async {
        do {
            async let c = docker.containers()
            async let i = docker.images()
            async let v = docker.volumes()
            async let n = docker.networks()
            containers = try await c
            images = try await i
            volumes = try await v
            networks = try await n
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
        // Host-side read of the data disk's actual (sparse) footprint.
        let vals = try? Paths.dataDisk.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        diskUsedBytes = vals?.totalFileAllocatedSize.map(Int64.init)
    }

    /// Subscribe to each running container's stats stream and keep a live sum.
    /// Driven by `.task(id: runningKey)`, so it tears down and re-arms whenever
    /// the running set changes — no manual per-stream lifecycle tracking.
    func streamAggregate() async {
        let running = containers.filter(\.isRunning).map(\.id)
        latest = latest.filter { running.contains($0.key) }
        recompute()
        guard !running.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for id in running {
                group.addTask { [docker] in
                    for await sample in docker.stats(container: id) {
                        await self.ingest(id, sample)
                    }
                }
            }
        }
    }

    private func ingest(_ id: String, _ sample: ContainerStatsSample) {
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
}

/// The home page: an engine hero strip, a grid of resource metrics, and a live
/// usage section. Shown by the shell only while the engine is running.
struct OverviewView: View {
    let docker: any DockerClientProtocol
    @Environment(EngineController.self) private var engine
    @State private var model: OverviewModel

    init(docker: any DockerClientProtocol) {
        self.docker = docker
        _model = State(initialValue: OverviewModel(docker: docker))
    }

    private let columns = [GridItem(.adaptive(minimum: 176), spacing: Theme.gridSpacing)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if let error = model.loadError { errorBanner(error) }
                statGrid
                liveSection
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.observe() }
        .task(id: model.runningKey) { await model.streamAggregate() }
    }

    // MARK: Hero

    private var hero: some View {
        DashboardCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(engine.state.tint.opacity(0.18)).frame(width: 46, height: 46)
                    Image(systemName: engine.state.menuBarSymbol)
                        .font(.title2)
                        .foregroundStyle(engine.state.tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Engine \(engine.state.label)").font(.headline)
                        if engine.state.isRunning, let started = engine.startedAt {
                            TimelineView(.periodic(from: .now, by: 30)) { _ in
                                Text("· up \(Format.uptime(since: started))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(allocationSummary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Velox \(Versions.velox)").font(.callout).foregroundStyle(.secondary)
                    Text("Docker \(Versions.dockerVersion)").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var allocationSummary: String {
        let c = engine.config
        return "\(c.cpuCount) vCPU · \(c.memoryGiB) GB RAM · \(c.diskGiB) GB disk"
    }

    // MARK: Stat grid

    private var statGrid: some View {
        LazyVGrid(columns: columns, spacing: Theme.gridSpacing) {
            StatCard(title: "Containers", systemImage: "shippingbox", value: "\(model.runningCount)",
                     caption: "of \(model.containers.count) total", tint: .green)
            StatCard(title: "Images", systemImage: "square.stack.3d.up", value: "\(model.images.count)",
                     caption: "\(Format.bytes(model.totalImageBytes)) total", tint: .blue)
            StatCard(title: "Volumes", systemImage: "externaldrive", value: "\(model.volumes.count)",
                     caption: "\(Format.bytes(model.totalVolumeBytes)) stored", tint: .orange)
            StatCard(title: "Networks", systemImage: "network", value: "\(model.networks.count)",
                     caption: "\(model.attachedCount) attached", tint: .teal)
            StatCard(title: "Disk", systemImage: "internaldrive",
                     value: model.diskUsedBytes.map(Format.bytes) ?? "—",
                     caption: "of \(engine.config.diskGiB) GB allocated", tint: .purple)
        }
    }

    // MARK: Live usage

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Live Usage").font(.headline)
                Text("Aggregate across running containers")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: Theme.gridSpacing) {
                LiveMetricCard(title: "CPU", tint: .green,
                               value: String(format: "%.0f%%", model.totalCPU),
                               history: model.cpuHistory,
                               maxValue: Double(max(engine.config.cpuCount, 1)) * 100)
                LiveMetricCard(title: "Memory", tint: .blue,
                               value: Format.bytes(model.totalMemBytes),
                               history: model.memHistory,
                               maxValue: Double(max(engine.config.memoryGiB, 1)) * 1024 * 1024 * 1024)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A live metric tile: a headline value over a wide sparkline. Reuses the same
/// `SparklineView` the container rows draw, scaled to the engine's allocation.
private struct LiveMetricCard: View {
    let title: String
    let tint: Color
    let value: String
    let history: [Double]
    let maxValue: Double

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(value)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                SparklineView(values: history, maxValue: maxValue, tint: tint)
                    .frame(height: 46)
            }
        }
    }
}

#if DEBUG
struct OverviewView_Previews: PreviewProvider {
    static var previews: some View {
        OverviewView(docker: MockDockerClient())
            .environment(EngineController())
            .frame(width: 820, height: 560)
    }
}
#endif
