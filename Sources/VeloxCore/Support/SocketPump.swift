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
final class SocketPump: @unchecked Sendable {
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

    init(fdA: Int32, fdB: Int32,
         queue: DispatchQueue = DispatchQueue(label: "dev.velox.pump"),
         onClose: @escaping @Sendable () -> Void) {
        self.fdA = fdA
        self.fdB = fdB
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        let a = fdA, b = fdB
        let chA = DispatchIO(type: .stream, fileDescriptor: a, queue: queue) { _ in close(a) }
        let chB = DispatchIO(type: .stream, fileDescriptor: b, queue: queue) { _ in close(b) }
        chA.setLimit(lowWater: 1)
        chB.setLimit(lowWater: 1)
        ioA = chA
        ioB = chB
        copy(from: chA, to: chB, peerFd: fdB, direction: .aToB)
        copy(from: chB, to: chA, peerFd: fdA, direction: .bToA)
    }

    private func copy(from src: DispatchIO, to dst: DispatchIO, peerFd: Int32, direction: Direction) {
        src.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                dst.write(offset: 0, data: data, queue: self.queue) { [weak self] _, _, writeError in
                    if writeError != 0 { self?.abort() }
                }
            }
            if error != 0 {
                self.abort()
                return
            }
            if done {
                // Source reached EOF: propagate a half-close to the peer's write
                // side, then keep the other direction running until it EOFs too.
                shutdown(peerFd, SHUT_WR)
                self.markDone(direction)
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
