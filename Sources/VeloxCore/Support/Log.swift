import Foundation

/// Minimal logger. Writes to stderr so diagnostics never interleave with the
/// guest serial console, which Velox streams to stdout.
public enum Log {
    private static func emit(_ level: String, _ message: String) {
        FileHandle.standardError.write(Data("[velox] \(level)\(message)\n".utf8))
    }

    public static func info(_ message: String) { emit("", message) }
    public static func warn(_ message: String) { emit("warning: ", message) }
    public static func error(_ message: String) { emit("error: ", message) }
}

/// Errors surfaced to the user with a readable description. `LocalizedError` so the
/// message also rides `localizedDescription` — that's what the GUI stores in
/// `EngineState.failed` and shows; without it macOS substitutes the generic
/// "operation couldn't be completed."
public enum VeloxError: Error, CustomStringConvertible, LocalizedError {
    case guestArtifactMissing(URL)
    case configurationInvalid(String)
    case vmNotRunning
    case noSocketDevice
    case socketSetupFailed(String, Int32)
    /// A configured non-default data disk is gone (e.g. its external drive is unplugged).
    /// We refuse to boot rather than silently create a fresh empty one in its place.
    case dataDiskMissing(URL)
    /// A data-disk move couldn't proceed; the string is the user-facing reason.
    case diskMove(String)
    /// Another Velox engine already holds the single-instance lock.
    case engineAlreadyRunning
    /// A workspace operation couldn't proceed; the string is the user-facing reason.
    case workspace(String)
    /// The workspace manifest exists but couldn't be parsed. We refuse rather than
    /// synthesize a fresh one, which would hide every real workspace behind an empty
    /// "Default" and boot the legacy disk in their place.
    case workspaceManifestUnreadable(String)

    public var description: String {
        switch self {
        case .guestArtifactMissing(let url):
            return "guest artifact not found: \(url.path)\n"
                + "       build the guest image (./Scripts/make-guest.sh) or set "
                + "VELOX_KERNEL / VELOX_ROOT."
        case .configurationInvalid(let message):
            return "invalid VM configuration: \(message)"
        case .vmNotRunning:
            return "virtual machine is not running"
        case .noSocketDevice:
            return "no virtio socket device on the running VM"
        case .socketSetupFailed(let op, let err):
            let detail = err == 0 ? "" : ": \(String(cString: strerror(err))) (errno \(err))"
            return "socket setup failed at \(op)\(detail)"
        case .dataDiskMissing(let url):
            return "Velox data disk not found at \(url.path). The drive holding it may be "
                + "disconnected — reconnect it, or switch to another workspace and use "
                + "Change Location… on this one (right-click it in the sidebar)."
        case .diskMove(let message):
            return message
        case .engineAlreadyRunning:
            return "Another Velox engine is already running (the Velox app or `velox start`). "
                + "Stop it before starting a second one — two engines would attach the same "
                + "data disk and corrupt it."
        case .workspace(let message):
            return message
        case .workspaceManifestUnreadable(let detail):
            return "The workspace list at \(Paths.workspaceManifest.path) couldn't be read "
                + "(\(detail)). Velox won't start rather than risk hiding your workspaces. "
                + "A backup of the last good copy is alongside it as workspaces.json.bak."
        }
    }

    public var errorDescription: String? { description }
}
