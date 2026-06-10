import Foundation
import UserNotifications

/// Posts a macOS notification when a container dies with a non-zero exit code — the
/// app being useful *while closed*, which is most of the time. Pure event-driven: it
/// rides the resource store's existing `/events` stream (no new connection, nothing
/// at idle), and is inert unless the user opts in (Settings → General).
///
/// Exit codes 130 (SIGINT) and 143 (SIGTERM) are skipped — those are how a normal
/// `docker stop`/Ctrl-C ends a container, not a crash. 137 stays in: it's ambiguous
/// (OOM kill vs a stop that escalated to SIGKILL), and the OOM case is precisely the
/// one developers want a tap on the shoulder for.
@MainActor
final class CrashNotifier {
    private var authorizationRequested = false

    var enabled = false {
        didSet {
            if enabled && !authorizationRequested {
                authorizationRequested = true
                requestAuthorization()
            }
        }
    }

    /// Hooked to the resource store's die events.
    func containerDied(name: String, exitCode: Int) {
        guard enabled, exitCode != 0, exitCode != 130, exitCode != 143,
              Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Container crashed"
        content.body = exitCode == 137
            ? "\(name) exited (137 — killed, possibly OOM)"
            : "\(name) exited (\(exitCode))"
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// UNUserNotificationCenter requires a real bundle — the bare dev binary skips
    /// gracefully (the packaged Velox.app is the supported shape).
    private func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
