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
    /// Stop completions that arrived while the VM wasn't yet stoppable (a stop racing
    /// the boot window). Honored the moment `machine.start` completes — never dropped,
    /// so a stop during `.starting` can't leave a running VM with no plumbing. On `queue`.
    private var pendingStops: [@Sendable () -> Void] = []

    public override init() { super.init() }

    /// Called when the guest stops (cleanly or with an error). Invoked on the VM queue.
    public func onStop(_ handler: @escaping @Sendable (Error?) -> Void) {
        queue.async { self.stopHandler = handler }
    }

    public func start(configuration: VZVirtualMachineConfiguration,
                      completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        // The configuration is only ever touched on the VM queue (where the machine is created
        // and runs) and the caller hands it off without reusing it — safe to carry into the queue.
        nonisolated(unsafe) let configuration = configuration
        queue.async {
            // Defense-in-depth against a double-start orphaning a live VM onto the same
            // data disk (the EngineController state machine + the process-wide InstanceLock
            // are the primary guards; this makes VMManager itself refuse).
            guard self.vm == nil else {
                Log.error("VMManager.start called while a VM is already running — refusing")
                completion(.failure(VeloxError.engineAlreadyRunning)); return
            }
            let machine = VZVirtualMachine(configuration: configuration, queue: self.queue)
            machine.delegate = self
            self.vm = machine
            machine.start { [weak self] result in
                guard let self else { completion(result); return }
                switch result {
                case .success:
                    completion(.success(()))
                    // A stop that raced the boot window couldn't run while the VM was
                    // still `.starting`; now that it's up (and stoppable) honor it, so we
                    // never leave a running-but-unwired VM behind (the stop's caller bumped
                    // the start generation, so `performStart` bails without plumbing it).
                    if !self.pendingStops.isEmpty { self.attemptStop() }
                case .failure(let error):
                    // Boot failed: VZ does not deliver the delegate stop callbacks for a
                    // machine that never ran, so clear the handle here — otherwise the next
                    // start() is refused by the `vm == nil` guard and the engine is dead
                    // until relaunch. Any queued stop is trivially satisfied (nothing runs).
                    self.vm = nil
                    completion(.failure(error))
                    self.drainPendingStops()
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

    /// Push the host's current wall-clock to the guest so it can correct drift.
    /// Apple VZ gives the guest no RTC, so after the Mac sleeps the guest clock
    /// lags by the sleep duration — enough to fail registry TLS. The host calls
    /// this at start and on wake; the guest re-sets its clock if the drift is
    /// large. Best-effort and fire-and-forget.
    public func syncClock() {
        let epoch = Int(Date().timeIntervalSince1970)
        connectToGuestPort(VsockPort.clock) { result in
            guard case .success(let fd) = result else { return }
            DispatchQueue.global().async {
                _ = Array("\(epoch)\n".utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                close(fd)
            }
        }
    }

    /// Adjust the guest's effective memory ceiling at runtime via the virtio
    /// memory balloon. Setting `bytes` below the configured `memorySize` inflates
    /// the balloon, so the guest returns that many pages to the host (host RSS
    /// drops); setting it back to the full size deflates it and returns the RAM.
    /// Resource Saver uses this to shrink Velox's footprint while idle. No-op if
    /// the VM isn't running or has no traditional balloon device. Runs on the VM
    /// queue, as all Virtualization.framework access must.
    public func setMemoryTarget(_ bytes: UInt64) {
        queue.async {
            guard let balloon = self.vm?.memoryBalloonDevices.first
                    as? VZVirtioTraditionalMemoryBalloonDevice else { return }
            balloon.targetVirtualMachineMemorySize = bytes
        }
    }

    /// Flush the guest's filesystems (via the relay's control port) so the data
    /// disk is durable, then stop the VM. The guest has no ACPI shutdown path
    /// (vinit is a bare PID 1, not an init system), so we sync explicitly over
    /// the VSOCK control port and then power off.
    public func stopGracefully(completion: @escaping @Sendable () -> Void) {
        Log.info("flushing guest filesystems before stop…")
        connectToGuestPort(VsockPort.control) { result in
            switch result {
            case .success(let fd):
                // Read the "OK" off the VM queue would stall the VM, so block on
                // a background thread; the sync ack flows over VSOCK meanwhile.
                DispatchQueue.global().async {
                    // Bounded: an unresponsive guest must not hang the stop forever — that
                    // strands the engine mid-teardown with no way out (the GUI sits in
                    // `.stopping`, the CLI never exits). Generous, because a sync against a
                    // busy data disk legitimately takes a while; on timeout we stop anyway,
                    // which is the same guarantee a crash gives (ext4 journal recovery).
                    var timeout = timeval(tv_sec: 60, tv_usec: 0)
                    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                               socklen_t(MemoryLayout<timeval>.size))
                    var buf = [UInt8](repeating: 0, count: 8)
                    if read(fd, &buf, buf.count) <= 0 {   // returns once sync() completes
                        Log.warn("guest flush did not ack in time; stopping anyway")
                    }
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
            self.pendingStops.append(completion)
            self.attemptStop()
        }
    }

    /// Stop the VM if it exists and is stoppable, firing every queued stop completion
    /// once it's confirmed stopped (or already gone). If the VM exists but isn't
    /// stoppable yet (mid-boot), leave the requests queued — `machine.start`'s
    /// completion re-invokes this, so a stop is deferred, never dropped. On `queue`.
    private func attemptStop() {
        guard let vm = self.vm else { self.drainPendingStops(); return } // nothing to stop
        guard vm.canStop else { return } // mid-boot: start's completion will re-invoke us
        vm.stop { _ in self.vm = nil; self.drainPendingStops() } // host-initiated stop: clear the ref here
    }

    /// Fire and clear every queued stop completion (the VM is confirmed stopped/gone).
    private func drainPendingStops() {
        let pending = self.pendingStops
        self.pendingStops.removeAll()
        for completion in pending { completion() }
    }

    // MARK: - VZVirtualMachineDelegate

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Log.info("guest stopped")
        stopHandler?(nil)
        vm = nil // guest-initiated stop: allow a later start() to boot a fresh VM
        drainPendingStops() // a queued host stop is satisfied — the VM is down
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Log.error("guest stopped: \(error.localizedDescription)")
        stopHandler?(error)
        vm = nil
        drainPendingStops()
    }
}
