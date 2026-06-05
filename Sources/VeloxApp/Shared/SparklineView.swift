import SwiftUI
import VeloxCore

/// Holds the most recent stats sample for a container row. `@Observable` so a new
/// sample redraws the cell's CPU/memory numbers.
@MainActor
@Observable
final class StatsBuffer {
    private(set) var latest: ContainerStatsSample?

    func append(_ sample: ContainerStatsSample) { latest = sample }
}

/// A compact line chart drawn with `Canvas` — cheap enough to live in every
/// table row and update several times a second.
struct SparklineView: View {
    let values: [Double]
    /// Upper bound for the y-axis. When nil, scales to the data's own max.
    var maxValue: Double? = nil
    var tint: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let ceiling = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let stepX = size.width / CGFloat(values.count - 1)

            var line = Path()
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * stepX
                let y = size.height * (1 - CGFloat(min(v, ceiling) / ceiling))
                if i == 0 { line.move(to: CGPoint(x: x, y: y)) }
                else { line.addLine(to: CGPoint(x: x, y: y)) }
            }

            // Soft fill under the line.
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.25), tint.opacity(0.0)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)))

            context.stroke(line, with: .color(tint), lineWidth: 1.5)
        }
        .drawingGroup()
    }
}

/// One cell that subscribes to a container's stats stream and shows its live CPU
/// and memory as plain numbers (no per-row chart — the numbers are enough).
struct ContainerUsageCell: View {
    let docker: any DockerClientProtocol
    let containerID: String
    let isRunning: Bool
    @State private var buffer = StatsBuffer()

    var body: some View {
        HStack(spacing: 14) {
            metric(title: "CPU", value: buffer.latest.map { String(format: "%.0f%%", $0.cpuPercent) } ?? "—")
            metric(title: "MEM", value: buffer.latest.map { Format.bytes($0.memoryBytes) } ?? "—")
        }
        .task(id: containerID) {
            guard isRunning else { return }
            for await sample in docker.stats(container: containerID) {
                buffer.append(sample)
            }
        }
    }

    private func metric(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}
