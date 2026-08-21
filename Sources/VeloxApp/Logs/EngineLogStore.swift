import Foundation
import VeloxCore
import Observation

/// Captures the guest's serial-console stream — kernel + `vinit` + `dockerd` output,
/// i.e. the engine's full diagnostic log — into a capped ring buffer for the
/// "Engine Logs" view. Pure host-side Swift (no guest change, no extra vsock verb):
/// the GUI hands the VM a pipe as its console write end (see `EngineController`), and
/// this drains the read end continuously on a background queue — so the VM never
/// blocks on a full pipe — publishing lines on the main actor, throttled.
@MainActor
@Observable
final class EngineLogStore {
    struct Line: Identifiable, Sendable { let id: Int; let text: String }

    private(set) var lines: [Line] = []
    var autoScroll = true
    var filter = ""
    /// Bumped on `clear()` so the text view knows to rebuild rather than append.
    private(set) var generation = 0

    private let capacity = 10_000
    private var nextID = 0
    private var partial = ""
    private var pending: [Line] = []
    private var flushScheduled = false
    private var source: DispatchSourceRead?

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")

    var filteredLines: [Line] {
        filter.isEmpty ? lines : lines.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }

    /// Begin draining `handle` (the read end of the console pipe). Safe to call once.
    func attach(_ handle: FileHandle) {
        // Replace, don't silently skip: after a stop that timed out, `detach()` never ran and
        // the old source is still bound to the PREVIOUS pipe (whose write end a still-live VM
        // holds, so it never EOFs). Skipping left Engine Logs blank for the whole new boot.
        if source != nil {
            Log.warn("engine log: replacing a console reader that was never detached")
            detach()
        }
        // Own a DUP of the pipe's read fd. `cancel()` is asynchronous, and
        // `EngineController.cleanup()` releases the owning `Pipe` — closing its fd — on the
        // very next line after `detach()`. Reading or closing an fd out from under a live
        // DispatchSource is an fd-reuse bug and an EXC_GUARD crash, so give the source an fd
        // it owns and closes itself in the cancel handler.
        let fd = dup(handle.fileDescriptor)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: DispatchQueue(label: "dev.velox.enginelog"))
        // The handler runs on the background queue above, so it MUST be non-isolated.
        // Declaring it `@Sendable` stops the compiler inferring `@MainActor` from this
        // `@MainActor` method (the SDK's @convention(block) param would silently accept
        // an isolated closure, then trap at runtime via swift_task_isCurrentExecutor).
        // It reads off-main and hops to the main actor only to ingest.
        let handler: @Sendable () -> Void = { [weak self] in
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            let n = read(fd, &buf, buf.count)
            // EOF: every write end is gone. A level-triggered read source keeps firing on a
            // stale EOF forever, so tear it down instead of spinning a core.
            if n == 0 {
                // Cancel on THIS queue, immediately. Hopping to the main actor first left the
                // level-triggered source re-firing until the hop landed — one `Task` spawned
                // per fire, spinning `dev.velox.enginelog` and flooding the main actor with a
                // burst of no-op detaches. `cancel()` is idempotent, so the `detach()` below
                // (which also clears the stored reference) stays correct.
                src.cancel()
                Task { @MainActor in self?.detach() }
                return
            }
            guard n > 0 else { return }   // EINTR/EAGAIN — wait for the next event
            let chunk = String(decoding: buf[0 ..< n], as: UTF8.self)
            Task { @MainActor in self?.ingest(chunk) }
        }
        src.setEventHandler(handler: handler)
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func detach() { source?.cancel(); source = nil }

    func clear() {
        lines.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        generation += 1
    }

    // MARK: - Ingest

    private func ingest(_ chunk: String) {
        // The guest serial console terminates lines with CRLF. In a Swift String,
        // "\r\n" is a *single* grapheme cluster, so `firstIndex(of: "\n")` never
        // matches (there is no standalone "\n" Character to find) and nothing would
        // ever split into lines — leaving the Engine Logs view empty. Strip the CR so
        // lines break on the LF; this also makes a CRLF that straddles two reads split
        // cleanly, with no spurious blank line.
        partial += chunk.replacingOccurrences(of: "\r", with: "")
        while let nl = partial.firstIndex(of: "\n") {
            appendLine(String(partial[..<nl]))
            partial = String(partial[partial.index(after: nl)...])
        }
        scheduleFlush()
    }

    private func appendLine(_ raw: String) {
        let stripped = Self.ansi.stringByReplacingMatches(
            in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
        pending.append(Line(id: nextID, text: stripped))
        nextID += 1
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
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
        }
    }
}
