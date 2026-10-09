import Foundation

/// The one shared "write the whole buffer to an fd" helper — EINTR-retrying, short-write
/// looping. Every socket path in VeloxCore (proxy, conduits, vsock, helper client) uses
/// this instead of growing its own copy, so the retry semantics can't drift apart.
enum FDIO {
    /// Write all of `buf` to a (blocking) fd. Retries EINTR; any other error — including
    /// a 0-byte write, impossible for a non-empty buffer on a healthy stream — returns
    /// false. The caller owns the fd and decides whether to close it.
    @discardableResult
    static func writeAll(_ fd: Int32, _ buf: UnsafeRawBufferPointer) -> Bool {
        var off = 0
        while off < buf.count {
            let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
            if n > 0 { off += n; continue }
            if n < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ buf: [UInt8]) -> Bool {
        buf.withUnsafeBytes { writeAll(fd, $0) }
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { writeAll(fd, $0) }
    }

    /// Socket buffer size for bulk Docker-API streams (`docker cp`, `load`/`save`, build
    /// contexts). macOS gives an AF_UNIX stream socket 8 KiB each way, so every relay read
    /// came back ≤8 KiB and the relay's buffer never grew past its initial size: a syscall
    /// pair (plus a kevent round) per 8 KiB. 4 MiB is half of `kern.ipc.maxsockbuf` (8 MiB).
    /// A limit, not an allocation — mbufs are taken only for bytes actually queued, so an
    /// idle connection costs nothing more.
    static let bulkSocketBuffer: Int32 = 4 * 1024 * 1024

    /// Raise SO_SNDBUF and SO_RCVBUF on `fd`. Best-effort: returns false if either was
    /// refused (the socket keeps working with its defaults).
    @discardableResult
    static func setSocketBuffers(_ fd: Int32, bytes: Int32 = bulkSocketBuffer) -> Bool {
        var size = bytes
        let len = socklen_t(MemoryLayout<Int32>.size)
        let snd = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, len) == 0
        let rcv = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, len) == 0
        return snd && rcv
    }
}
