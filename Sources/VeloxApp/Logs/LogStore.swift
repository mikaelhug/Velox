import Foundation
import Observation
import VeloxCore

/// Buffers a container's log stream for display. Two performance guards keep a
/// high-velocity firehose from locking the UI:
///   1. ANSI parsing + line splitting happen as frames arrive, but appends are
///      **coalesced** — the observable `lines` array is only published on a
///      throttled tick (~30 Hz), not per line.
///   2. The buffer is a ring capped at `capacity`; older lines are dropped.
@MainActor
@Observable
final class LogStore {
    struct Line: Identifiable, Sendable {
        let id: Int
        let spans: [ANSISpan]
        let isStderr: Bool
        let plain: String
    }

    private(set) var lines: [Line] = []
    /// Bumps whenever the buffer is rebuilt wholesale (clear or ring trim) so the
    /// text view knows to re-render from scratch instead of appending a delta.
    private(set) var generation = 0

    var autoScroll = true
    var filter = ""
    /// True while the follow stream is live; flips false when it ends (container
    /// stopped, or the connection closed). Drives the footer "Streaming" pill.
    private(set) var isStreaming = false

    private let docker: any DockerClientProtocol
    private let containerID: String
    private let capacity = 20_000

    private var task: Task<Void, Never>?
    private var nextID = 0
    private var partialOut = ""
    private var partialErr = ""
    private var pending: [Line] = []
    private var flushScheduled = false

    init(docker: any DockerClientProtocol, containerID: String) {
        self.docker = docker
        self.containerID = containerID
    }

    var filteredLines: [Line] {
        guard !filter.isEmpty else { return lines }
        return lines.filter { $0.plain.localizedCaseInsensitiveContains(filter) }
    }

    func start() {
        guard task == nil else { return }
        isStreaming = true
        let stream = docker.logs(container: containerID, tail: 1000)
        task = Task { [weak self] in
            for await frame in stream {
                self?.ingest(frame)
            }
            self?.isStreaming = false       // follow stream ended
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isStreaming = false
    }

    /// All buffered lines as plain text — for the "Copy" button.
    func plainText() -> String {
        lines.map(\.plain).joined(separator: "\n")
    }

    func clear() {
        lines.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        generation += 1
    }

    // MARK: - Ingest

    private func ingest(_ frame: LogFrame) {
        let isErr = frame.stream == .stderr
        // Strip CR before splitting: in a Swift String "\r\n" is a *single* grapheme
        // cluster, so `firstIndex(of: "\n")` never matches it — a container that emits
        // CRLF-terminated lines would never split into lines and the view would stay
        // empty (the same bug that was fixed for the Engine Logs view). Dropping CR
        // makes lines break on the LF and avoids a stray CR rendering as a control glyph.
        var buffer = (isErr ? partialErr : partialOut) + frame.text.replacingOccurrences(of: "\r", with: "")
        while let nl = buffer.firstIndex(of: "\n") {
            let raw = String(buffer[..<nl])
            buffer = String(buffer[buffer.index(after: nl)...])
            appendLine(raw, isStderr: isErr)
        }
        if isErr { partialErr = buffer } else { partialOut = buffer }
        scheduleFlush()
    }

    private func appendLine(_ raw: String, isStderr: Bool) {
        let spans = ANSIParser.parse(raw)
        let plain = spans.map(\.text).joined()
        pending.append(Line(id: nextID, spans: spans, isStderr: isStderr, plain: plain))
        nextID += 1
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(33))
            self.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        lines.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
            generation += 1 // ring trimmed → force a full re-render
        }
    }
}
