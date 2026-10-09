import Foundation
import AppKit

/// Keeps the guest clock aligned with the host. Apple VZ gives the guest no RTC,
/// so vinit sets the clock once at boot from `velox.epoch` — but after the Mac
/// sleeps, the paused guest wakes up behind by the sleep duration, which is
/// enough to break registry TLS. This pushes the host wall-clock to the guest:
///
///  - immediately on `start()`,
///  - the instant the Mac wakes (`NSWorkspace.didWakeNotification`), and
///  - on a slow periodic timer as a robust backstop (the wake notification needs
///    a serviced run loop; the timer works under `dispatchMain` too).
///
/// The guest only re-sets its clock when the drift is large, so pushes never cause
/// visible jitter.
public final class ClockSync: @unchecked Sendable {
    private let manager: VMManager
    private let queue = DispatchQueue(label: "dev.velox.clocksync")
    private var timer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?

    /// Backstop re-push interval. Sleep — the one thing that actually moves the guest clock
    /// (VZ has no RTC to keep ticking while the VM is paused) — is covered by the wake push,
    /// so this only catches a missed wake notification and slow drift, neither of which needs
    /// minute resolution: the guest corrects only beyond ~2 s. It was 60 s, i.e. a vsock
    /// connection + a guest handler thread every minute for the life of an idle engine, which
    /// is exactly the idle CPU Velox is trying to shed.
    static let backstopInterval: TimeInterval = 15 * 60

    public init(manager: VMManager) { self.manager = manager }

    public func start() {
        manager.syncClock()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.backstopInterval, repeating: Self.backstopInterval,
                   leeway: .seconds(30))
        t.setEventHandler { [weak self] in self?.manager.syncClock() }
        t.resume()
        timer = t

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.manager.syncClock() }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }
}
