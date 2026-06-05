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

/// Errors surfaced to the user with a readable description.
public enum VeloxError: Error, CustomStringConvertible {
    case guestArtifactMissing(URL)
    case configurationInvalid(String)
    case vmNotRunning
    case noSocketDevice
    case socketSetupFailed(String, Int32)

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
        }
    }
}
