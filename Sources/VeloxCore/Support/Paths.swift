import Foundation

/// Filesystem layout for Velox state, all rooted at ~/.velox (rootless).
public enum Paths {
    public static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// ~/.velox — owns runtime state, guest artifacts, and the Docker socket.
    public static var root: URL {
        home.appendingPathComponent(".velox", isDirectory: true)
    }

    public static var kernel: URL { root.appendingPathComponent("kernel") }
    public static var initrd: URL { root.appendingPathComponent("initrd.img") }
    public static var dataDisk: URL { root.appendingPathComponent("data.img") }
    public static var dockerSocket: URL { root.appendingPathComponent("docker.sock") }
    /// User preferences persisted by the GUI (resources, file shares, etc.).
    public static var config: URL { root.appendingPathComponent("config.json") }

    @discardableResult
    public static func ensureRoot() throws -> URL {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }
}

/// Well-known guest VSOCK ports.
public enum VsockPort {
    /// Guest relay forwarding to dockerd.
    public static let docker: UInt32 = 2375
    /// Control port: connecting triggers sync(2) in the guest.
    public static let control: UInt32 = 2374
    /// Reverse port-forward: host sends "<port>\n", guest dials 127.0.0.1:<port>.
    public static let reverse: UInt32 = 2376
}
