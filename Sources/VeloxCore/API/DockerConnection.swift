import Foundation

/// How a `DockerClient` obtains a connected socket to a Docker daemon.
///
/// `DockerClient` speaks HTTP/1.1 on a bare `Int32` fd (see `HTTPCodec`), and never
/// cared *where* that fd came from — it just happened to always be a VSOCK fd to the
/// guest. Naming that seam is what lets one client serve both the embedded engine and a
/// remote daemon reached over an SSH-forwarded unix socket, instead of growing a second
/// Docker client for the remote case (CLAUDE.md §10).
///
/// The contract mirrors `VMManager.connectToGuestPort`: hand back a fd the **caller
/// owns and must close**.
public protocol DockerConnector: Sendable {
    func connect(_ completion: @escaping @Sendable (Result<Int32, Error>) -> Void)
}

/// The embedded engine: an in-process VSOCK connection to the guest's dockerd.
public struct VsockConnector: DockerConnector {
    private let manager: VMManager
    private let port: UInt32

    public init(manager: VMManager, port: UInt32 = VsockPort.docker) {
        self.manager = manager
        self.port = port
    }

    public func connect(_ completion: @escaping @Sendable (Result<Int32, Error>) -> Void) {
        manager.connectToGuestPort(port, completion: completion)
    }
}

/// A daemon reachable through a local `AF_UNIX` socket — used for remote hosts, where an
/// `SSHTunnel` forwards `~/.velox/hosts/<id>.sock` to the server's `/var/run/docker.sock`.
///
/// The connect is blocking, so it runs on a shared background queue rather than on the
/// caller's actor or the main thread — same discipline as `DockerClient.ioQueue`.
public struct UnixSocketConnector: DockerConnector {
    private static let queue = DispatchQueue(label: "dev.velox.docker.connect", attributes: .concurrent)

    private let path: String

    public init(path: String) { self.path = path }

    public func connect(_ completion: @escaping @Sendable (Result<Int32, Error>) -> Void) {
        let path = self.path
        Self.queue.async {
            completion(Self.connectSync(to: path))
        }
    }

    /// Blocking `socket(2)` + `connect(2)` on an `AF_UNIX` stream socket.
    /// Public so `velox-selftest` can drive a real listener through it — the premise of the
    /// whole remote path is that this fd is an ordinary socket `HTTPCodec` can speak on.
    public static func connectSync(to path: String) -> Result<Int32, Error> {
        // Reported with both lengths, because the usual cause is a deep `VELOX_HOME` and the
        // numbers are what make that diagnosable.
        guard UnixSocketAddress.canRepresent(path) else {
            return .failure(DockerError.transport(
                "socket path too long (\(path.utf8.count) ≥ \(UnixSocketAddress.pathCapacity)): \(path)"))
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .failure(VeloxError.socketSetupFailed("socket(AF_UNIX)", errno))
        }
        let connected = UnixSocketAddress.withSockaddr(path: path) { addr, len in
            Darwin.connect(fd, addr, len)
        }
        guard connected == 0 else {
            let err = errno
            close(fd)
            // ENOENT/ECONNREFUSED here means the tunnel isn't up (yet) — the common,
            // expected case while an SSH child is still connecting or has died.
            return .failure(VeloxError.socketSetupFailed("connect(\(path))", err))
        }
        return .success(fd)
    }
}
