import Foundation

/// Filesystem layout for Velox state, all rooted at ~/.velox (rootless).
enum Paths {
    static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// ~/.velox — owns runtime state, guest artifacts, and the Docker socket.
    static var root: URL {
        home.appendingPathComponent(".velox", isDirectory: true)
    }

    static var kernel: URL { root.appendingPathComponent("kernel") }
    static var initrd: URL { root.appendingPathComponent("initrd.img") }
    static var dataDisk: URL { root.appendingPathComponent("data.img") }
    static var dockerSocket: URL { root.appendingPathComponent("docker.sock") }

    @discardableResult
    static func ensureRoot() throws -> URL {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }
}

/// Well-known guest VSOCK ports.
enum VsockPort {
    /// Guest relay forwarding to dockerd.
    static let docker: UInt32 = 2375
    /// Control port: connecting triggers sync(2) in the guest.
    static let control: UInt32 = 2374
    /// Reverse port-forward: host sends "<port>\n", guest dials 127.0.0.1:<port>.
    static let reverse: UInt32 = 2376
}
