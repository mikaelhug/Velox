import Foundation

/// The one shared "build a `sockaddr_un` for a filesystem path" helper.
///
/// Four places in VeloxCore needed this — the Docker-API unix connector, the CLI socket
/// proxy's listener, and both of `PortHelperClient`'s connects — and they had already
/// drifted: the `withMemoryRebound` capacity argument differed between copies of code that
/// is supposed to be identical (`capacity` in one, `pathBytes.count + 1` in another). That
/// is precisely the failure CLAUDE.md §10 predicts, and the same shape as the four copies of
/// an EINTR-retrying `writeAll` that `82a7044` folded into `FDIO.writeAll`.
///
/// It covers **only** address construction and the pointer rebind. Everything the call sites
/// genuinely differ on stays with them: `bind`+`listen` vs `connect`, `unlink` beforehand,
/// `O_NONBLOCK` afterwards, send/receive timeouts, fd ownership, and each site's error
/// channel (`Result` / `throws` / `nil`).
///
/// `Sources/velox-porthelper/` has a fifth copy and deliberately keeps it: that target
/// declares no dependency on VeloxCore (see `Package.swift`) because it is a separate,
/// root-privileged binary, which is the same boundary carve-out §10 already allows for the
/// guest's relay.
/// Public only so `velox-selftest` can pin the boundary and the address layout without
/// opening a socket — the same reason `WorkspaceStore.writeDurably` and
/// `Storage.fsyncDirectory` are public.
public enum UnixSocketAddress {
    /// `sun_path` is a fixed-size C array — 104 bytes on Darwin. A path that does not fit
    /// cannot be represented at all, so callers must fail rather than silently truncate.
    public static let pathCapacity: Int = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// Whether `path` fits in `sun_path` (strictly less than the capacity, leaving room for
    /// the NUL terminator).
    public static func canRepresent(_ path: String) -> Bool {
        path.utf8.count < pathCapacity
    }

    /// Run `body` with a populated `sockaddr_un` for `path`, already rebound to the
    /// `sockaddr` pointer the socket syscalls take. Returns nil — without calling `body` —
    /// when the path cannot be represented, so a caller can map that to its own error.
    ///
    /// The pointer is valid only for the duration of `body`; never let it escape.
    public static func withSockaddr<R>(path: String,
                                _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R? {
        let bytes = Array(path.utf8)
        guard bytes.count < pathCapacity else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, size) }
        }
    }
}
