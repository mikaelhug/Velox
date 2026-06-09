import ServiceManagement
import VeloxCore

/// Thin wrapper over `SMAppService` for the "Launch at login" preference. Works
/// once the app runs from a signed `.app` bundle (Scripts/build-app.sh).
enum LoginItem {
    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            Log.warn("login item update failed: \(error.localizedDescription)")
        }
    }
}
