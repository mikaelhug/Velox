import Foundation
@preconcurrency import Virtualization

/// Owns the `VZVirtualMachine` and the serial dispatch queue it runs on.
///
/// Every Virtualization.framework call — construction, `start`, `stop`, device
/// access, and delegate callbacks — must happen on this single queue. Routing
/// everything through `queue` is the simplest way to honor that contract.
///
/// All mutable state is confined to `queue`, so the type is safe to share across
/// concurrency domains (the GUI holds it from the main actor); `@unchecked
/// Sendable` documents that the queue — not the compiler — enforces the
/// invariant. Completion handlers are `@Sendable` because they hop from `queue`
/// back to whatever called in.
public final class VMManager: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.velox.vm")
    private var vm: VZVirtualMachine?
    private var stopHandler: (@Sendable (Error?) -> Void)?

    public override init() { super.init() }

    /// Called when the guest stops (cleanly or with an error). Invoked on the VM queue.
    public func onStop(_ handler: @escaping @Sendable (Error?) -> Void) {
        queue.async { self.stopHandler = handler }
    }

    public func start(configuration: VZVirtualMachineConfiguration,
                      completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            let machine = VZVirtualMachine(configuration: configuration, queue: self.queue)
            machine.delegate = self
            self.vm = machine
            machine.start { result in
                switch result {
                case .success: completion(.success(()))
                case .failure(let error): completion(.failure(error))
                }
            }
        }
    }

    /// Open a VSOCK connection to `port` in the guest and hand back a
    /// duplicated file descriptor the caller owns (and must close). Dup'ing
    /// decouples the fd's lifetime from the `VZVirtioSocketConnection`, so
    /// there is never a double-close. Runs the connect on the VM queue.
    public func connectToGuestPort(_ port: UInt32,
                                   completion: @escaping @Sendable (Result<Int32, Error>) -> Void) {
        queue.async {
            guard let vm = self.vm else {
                completion(.failure(VeloxError.vmNotRunning)); return
            }
            guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
                completion(.failure(VeloxError.noSocketDevice)); return
            }
            device.connect(toPort: port) { result in
                switch result {
                case .success(let connection):
                    let fd = dup(connection.fileDescriptor)
                    if fd < 0 {
                        completion(.failure(VeloxError.socketSetupFailed("dup(vsock)", errno)))
                    } else {
                        completion(.success(fd))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    /// Flush the guest's filesystems (via the relay's control port) so the data
    /// disk is durable, then stop the VM. ACPI-based graceful shutdown isn't
    /// reliable under LinuxKit, so we sync explicitly and then power off.
    public func stopGracefully(completion: @escaping @Sendable () -> Void) {
        Log.info("flushing guest filesystems before stop…")
        connectToGuestPort(VsockPort.control) { result in
            switch result {
            case .success(let fd):
                // Read the "OK" off the VM queue would stall the VM, so block on
                // a background thread; the sync ack flows over VSOCK meanwhile.
                DispatchQueue.global().async {
                    var buf = [UInt8](repeating: 0, count: 8)
                    _ = read(fd, &buf, buf.count) // returns once sync() completes
                    close(fd)
                    self.hardStop(completion)
                }
            case .failure(let error):
                Log.warn("flush failed (\(error.localizedDescription)); stopping anyway")
                self.hardStop(completion)
            }
        }
    }

    private func hardStop(_ completion: @escaping @Sendable () -> Void) {
        queue.async {
            guard let vm = self.vm, vm.canStop else { completion(); return }
            vm.stop { _ in completion() }
        }
    }

    // MARK: - VZVirtualMachineDelegate

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Log.info("guest stopped")
        stopHandler?(nil)
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Log.error("guest stopped: \(error.localizedDescription)")
        stopHandler?(error)
    }
}
