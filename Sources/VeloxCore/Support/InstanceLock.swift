import Foundation

/// Per-user single-instance guard for the Velox engine.
///
/// Only one process may run the VM at a time. Two engines would attach the same
/// `data.img` read-write — two Linux kernels journaling one ext4 image → guaranteed
/// filesystem corruption and loss of every container/image/volume — and would also
/// fight over `~/.velox/docker.sock` and the published host ports. Nothing in
/// Virtualization.framework enforces this (Apple leaves disk-image exclusion to the
/// app), so we enforce it here with an exclusive advisory `flock` on
/// `~/.velox/engine.lock`, acquired before boot and held for the VM's lifetime.
///
/// The GUI holds an `InstanceLock` instance and `release()`s it on stop (so a restart
/// re-acquires); the CLI — whose process *is* the engine — uses
/// `acquireForProcess(at:)`, which holds the lock until the process exits.
public final class InstanceLock {
    private var fd: Int32

    /// Acquire the engine lock, or throw `VeloxError.engineAlreadyRunning` if another
    /// Velox engine already holds it. The lock is released by `release()` or `deinit`.
    public init(at url: URL) throws {
        self.fd = try Self.openLocked(url)
    }

    /// Release the lock. Idempotent; also runs from `deinit` and, ultimately, on process exit.
    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }

    /// Acquire the engine lock and hold it for the ENTIRE process lifetime — the OS
    /// releases it when the process exits. For the CLI, where the process is the engine
    /// and there is no separate stop event. The fd is deliberately never closed.
    public static func acquireForProcess(at url: URL) throws {
        _ = try openLocked(url) // fd intentionally leaked: held until process exit
    }

    /// Open `url` (creating it if needed) and take an exclusive, non-blocking `flock`.
    /// `O_CLOEXEC` keeps child processes (e.g. spawned `docker` CLIs) from inheriting
    /// the lock fd. Returns the locked fd; the caller owns its lifetime.
    private static func openLocked(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw VeloxError.socketSetupFailed("open(\(url.lastPathComponent))", errno)
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            close(fd)
            if err == EWOULDBLOCK { throw VeloxError.engineAlreadyRunning }
            throw VeloxError.socketSetupFailed("flock(\(url.lastPathComponent))", err)
        }
        return fd
    }
}
