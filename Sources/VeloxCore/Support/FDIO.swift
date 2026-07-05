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
}
