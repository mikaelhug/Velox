import Foundation

/// Bidirectionally copies bytes between two stream file descriptors using
/// `DispatchIO`, with proper half-close semantics: when one direction reaches
/// EOF, the *write* side of the peer is shut down (so it observes EOF) while the
/// other direction keeps flowing. Both fds are closed once both directions
/// finish (or on error), and `onClose` fires exactly once.
///
/// Half-close matters for Docker's hijacked streams (`run`/attach, `logs -f`,
/// `exec -it`): tearing both directions down on first EOF would truncate the
/// response.
package final class SocketPump: @unchecked Sendable {
    private enum Direction { case aToB, bToA }

    private let fdA: Int32
    private let fdB: Int32
    private let queue: DispatchQueue
    private let onClose: @Sendable () -> Void
    private var ioA: DispatchIO?
    private var ioB: DispatchIO?
    private var aToBDone = false
    private var bToADone = false
    private var fullyClosed = false

    /// Max bytes read — and thus buffered toward the peer — per direction before the next
    /// read waits for the peer to drain. The backpressure bound (matches EventRelay).
    private let bufferSize = 256 * 1024

    /// One direction's pump state. `writesOutstanding` couples reads to writes so the next
    /// read is issued only once the current chunk has fully drained to `dst`. All access is
    /// on `queue` (serial), so the plain mutations are safe.
    private final class Flow {
        let src: DispatchIO
        let dst: DispatchIO
        let peerFd: Int32
        let direction: Direction
        var writesOutstanding = 0
        var readSatisfied = false   // current read hit its length; more may remain, waiting on drain
        var eof = false
        init(src: DispatchIO, dst: DispatchIO, peerFd: Int32, direction: Direction) {
            self.src = src; self.dst = dst; self.peerFd = peerFd; self.direction = direction
        }
    }

    package init(fdA: Int32, fdB: Int32,
                 queue: DispatchQueue = DispatchQueue(label: "dev.velox.pump"),
                 onClose: @escaping @Sendable () -> Void) {
        self.fdA = fdA
        self.fdB = fdB
        self.queue = queue
        self.onClose = onClose
    }

    package func start() {
        let a = fdA, b = fdB
        let chA = DispatchIO(type: .stream, fileDescriptor: a, queue: queue) { _ in close(a) }
        let chB = DispatchIO(type: .stream, fileDescriptor: b, queue: queue) { _ in close(b) }
        chA.setLimit(lowWater: 1)
        chB.setLimit(lowWater: 1)
        ioA = chA
        ioB = chB
        pump(Flow(src: chA, dst: chB, peerFd: fdB, direction: .aToB))
        pump(Flow(src: chB, dst: chA, peerFd: fdA, direction: .bToA))
    }

    /// Issue one bounded read and forward it, re-arming the next read only after the chunk
    /// has fully drained to `dst`. This caps in-flight bytes at ~`bufferSize` per direction:
    /// a `length: .max` streaming read instead let a slow `dst` (e.g. the guest during a
    /// `docker load` / build-context upload) queue unbounded data in host memory. Half-close
    /// is preserved: EOF on `src` shuts down the peer's write side and the other direction
    /// keeps flowing (so Docker's hijacked attach/exec/logs streams aren't truncated).
    private func pump(_ flow: Flow) {
        var opBytes = 0
        flow.src.read(offset: 0, length: bufferSize, queue: queue) { [weak self] done, data, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                opBytes += data.count
                flow.writesOutstanding += 1
                flow.dst.write(offset: 0, data: data, queue: self.queue) { [weak self] wdone, _, writeError in
                    guard let self else { return }
                    if writeError != 0 { self.abort(); return }
                    guard wdone else { return } // wait for the full chunk to land
                    flow.writesOutstanding -= 1
                    // Backpressure: only fetch more once this op's data has fully drained.
                    if flow.readSatisfied, flow.writesOutstanding == 0, !flow.eof {
                        flow.readSatisfied = false
                        self.pump(flow)
                    }
                }
            }
            if error != 0 { self.abort(); return }
            guard done else { return }
            if opBytes == 0 {
                // A finite-length read that completes having delivered nothing means the
                // stream is at its end (a cancelled read surfaces as `error` above, handled
                // first). Half-close the peer, then let the other direction drain.
                flow.eof = true
                shutdown(flow.peerFd, SHUT_WR)
                self.markDone(flow.direction)
            } else if flow.writesOutstanding == 0 {
                self.pump(flow) // a fast dst already drained — read the next chunk now
            } else {
                flow.readSatisfied = true // wait for the write to drain, then the writer re-arms
            }
        }
    }

    private func markDone(_ direction: Direction) {
        switch direction {
        case .aToB: aToBDone = true
        case .bToA: bToADone = true
        }
        if aToBDone && bToADone { closeAll() }
    }

    private func abort() {
        closeAll()
    }

    private func closeAll() {
        guard !fullyClosed else { return }
        fullyClosed = true
        ioA?.close(flags: .stop)
        ioB?.close(flags: .stop)
        onClose()
    }
}
