import Foundation

/// A held exclusive `flock`, released on `release()`.
///
/// Distinct from `InstanceLock` on purpose. That one answers "is an engine running?" and is
/// held for a VM's entire lifetime; this one is a short-lived mutex around a file write.
/// Reusing `engine.lock` here would make the GUI unable to edit its own workspace list while
/// its own engine is up.
///
/// Shared by every manifest under `~/.velox` (`workspaces.json`, `hosts.json`) — the
/// bounded-wait/`EWOULDBLOCK` handling is subtle enough that a second copy would drift
/// (CLAUDE.md §10). `what` names the list in the contention message so the user is told
/// which one is busy.
struct FileLock {
    private let fd: Int32

    /// Seconds to wait for the lock before giving up. Bounded rather than blocking: the GUI
    /// takes this lock **on the main actor** (a workspace switch persists `activeID` before
    /// booting), so an indefinite `flock(LOCK_EX)` would hang the whole UI with no way out if
    /// anything ever held the file. Contention is one small JSON write, so a real waiter
    /// finishes in milliseconds; anything longer is a stuck holder and deserves an error the
    /// user can see, not a beachball.
    private static let timeout: TimeInterval = 5

    init(at url: URL, what: String = "workspace list") throws {
        fd = open(url.path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw VeloxError.socketSetupFailed("open(\(url.lastPathComponent))", errno)
        }
        var waited: TimeInterval = 0
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            guard err == EWOULDBLOCK, waited < Self.timeout else {
                close(fd)
                if err == EWOULDBLOCK {
                    throw VeloxError.workspace(
                        "Another Velox process is still updating the \(what). "
                        + "Try again in a moment.")
                }
                throw VeloxError.socketSetupFailed("flock(\(url.lastPathComponent))", err)
            }
            usleep(20_000)
            waited += 0.02
        }
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
