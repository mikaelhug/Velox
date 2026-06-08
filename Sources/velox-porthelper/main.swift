//! velox-porthelper — Velox's privileged port binder (runs as root under launchd).
//!
//! macOS forbids an unprivileged process from binding TCP/UDP ports below 1024, so
//! the (user-owned) VeloxApp can't open a `127.0.0.1:80` listener for a published
//! reverse-proxy port. This tiny daemon is the *only* privileged component in Velox
//! (CLAUDE.md §2 sanctioned exception): its sole job is to bind a loopback port <1024
//! on request and pass the listening socket fd back to VeloxApp over a unix socket,
//! then step out — it never touches a byte of connection data, so root stays out of
//! the data path. Pure Darwin, no Foundation, no dependencies: the smallest possible
//! privileged surface.
//!
//! Protocol (one request per connection, on `/var/run/velox-porthelper.sock`):
//!   client → "tcp <port>\n" | "udp <port>\n"   (1 ≤ port < 1024)
//!   helper → 1 status byte (0 = ok, else errno) + on success the bound fd via SCM_RIGHTS
//! Only the uid passed as `--uid` (the installing user) is served; everything else is
//! rejected. The control socket lives in root-only-writable /var/run, so no other
//! local user can replace it.

import Darwin

let SOCKET_PATH = "/var/run/velox-porthelper.sock"

// Darwin aligns control-message data to 4 bytes; CMSG_* aren't importable in Swift,
// so compute the layout for a single-fd ancillary message ourselves.
@inline(__always) func cmsgAlign(_ n: Int) -> Int { (n + 3) & ~3 }
let cmsgHdrLen = cmsgAlign(MemoryLayout<cmsghdr>.size)            // 12: aligned header
let cmsgLen1FD = cmsgHdrLen + MemoryLayout<Int32>.size           // 16: cmsg_len value
let cmsgSpace1FD = cmsgHdrLen + cmsgAlign(MemoryLayout<Int32>.size) // 16: buffer size

func log(_ m: String) { fputs("[velox-porthelper] " + m + "\n", stderr) }
func errExit(_ m: String) -> Never { log(m); exit(2) }

/// The uid this helper serves, from `--uid <n>` (set by the installer's LaunchDaemon).
func parseUID() -> uid_t? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--uid"), i + 1 < args.count, let v = UInt32(args[i + 1]) else { return nil }
    return v
}

/// Create the root-owned control socket: unlink any stale one, bind, restrict it to
/// the served uid (0600 + chown), and listen.
func bindControlSocket(_ allowedUID: uid_t) -> Int32 {
    unlink(SOCKET_PATH)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { errExit("socket: \(String(cString: strerror(errno)))") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(SOCKET_PATH.utf8)
    if pathBytes.count >= MemoryLayout.size(ofValue: addr.sun_path) { errExit("socket path too long") }
    withUnsafeMutablePointer(to: &addr.sun_path) { p in
        p.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
            for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
            dst[pathBytes.count] = 0
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
    if r != 0 { errExit("bind \(SOCKET_PATH): \(String(cString: strerror(errno)))") }
    chmod(SOCKET_PATH, 0o600)
    chown(SOCKET_PATH, allowedUID, 0)
    if listen(fd, 16) != 0 { errExit("listen: \(String(cString: strerror(errno)))") }
    return fd
}

/// Bind a fresh loopback socket on `port` (TCP listens; UDP just binds). Returns the
/// fd, or -1 with `errno` set.
func bindLoopback(type: Int32, port: UInt16) -> Int32 {
    let s = socket(AF_INET, type, 0)
    if s < 0 { return -1 }
    var yes: Int32 = 1
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    } }
    if r != 0 { let e = errno; close(s); errno = e; return -1 }
    if type == SOCK_STREAM, listen(s, 128) != 0 { let e = errno; close(s); errno = e; return -1 }
    return s
}

/// Send the 1-byte status, attaching `fd` via SCM_RIGHTS when `fd >= 0`.
func reply(_ conn: Int32, fd: Int32, status: UInt8) {
    var statusByte = status
    withUnsafeMutablePointer(to: &statusByte) { sp in
        var iov = iovec(iov_base: UnsafeMutableRawPointer(sp), iov_len: 1)
        withUnsafeMutablePointer(to: &iov) { iovp in
            var msg = msghdr()
            msg.msg_iov = iovp
            msg.msg_iovlen = 1
            guard fd >= 0 else { _ = sendmsg(conn, &msg, 0); return }
            let control = UnsafeMutableRawPointer.allocate(byteCount: cmsgSpace1FD,
                                                           alignment: MemoryLayout<cmsghdr>.alignment)
            defer { control.deallocate() }
            memset(control, 0, cmsgSpace1FD)
            msg.msg_control = control
            msg.msg_controllen = socklen_t(cmsgSpace1FD)
            let cmsg = control.assumingMemoryBound(to: cmsghdr.self)
            cmsg.pointee.cmsg_len = socklen_t(cmsgLen1FD)
            cmsg.pointee.cmsg_level = SOL_SOCKET
            cmsg.pointee.cmsg_type = SCM_RIGHTS
            (control + cmsgHdrLen).assumingMemoryBound(to: Int32.self).pointee = fd
            _ = sendmsg(conn, &msg, 0)
        }
    }
}

/// Read one `"<proto> <port>"` request line (bounded), parse + validate it.
func readRequest(_ conn: Int32, max: Int = 32) -> (type: Int32, port: UInt16)? {
    var bytes = [UInt8](); bytes.reserveCapacity(max)
    var b: UInt8 = 0
    while bytes.count < max {
        let n = recv(conn, &b, 1, 0)
        if n <= 0 { return nil }
        if b == 0x0A { break }
        bytes.append(b)
    }
    let parts = String(decoding: bytes, as: UTF8.self).split(separator: " ")
    guard parts.count == 2 else { return nil }
    let type: Int32
    switch parts[0] {
    case "tcp": type = SOCK_STREAM
    case "udp": type = SOCK_DGRAM
    default: return nil
    }
    guard let port = UInt16(parts[1]), port > 0, port < 1024 else { return nil }
    return (type, port)
}

/// Handle one connection: authenticate the peer, bind the requested port, hand back fd.
func serve(_ conn: Int32, _ allowedUID: uid_t) {
    defer { close(conn) }
    // A stalled client must not wedge the single-threaded accept loop.
    var tv = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    // Only the installing user may ask root to bind ports. This (uid) is the strongest
    // peer check available while the app is ad-hoc signed; verifying the client's code
    // signature (via the peer audit token) is the gold standard and the right follow-up
    // once Velox ships with a Developer ID — at which point SMAppService also replaces
    // this manual install. The residual risk is another process *of the same user*
    // squatting a loopback <1024 port; loopback-only + <1024-only keep it contained.
    var euid: uid_t = 0, egid: gid_t = 0
    guard getpeereid(conn, &euid, &egid) == 0, euid == allowedUID else {
        log("reject: peer uid \(euid) != \(allowedUID)")
        return
    }
    guard let (type, port) = readRequest(conn) else {
        reply(conn, fd: -1, status: UInt8(EINVAL & 0xff))
        return
    }
    let s = bindLoopback(type: type, port: port)
    if s < 0 {
        let e = errno
        log("bind \(port) failed: \(String(cString: strerror(e)))")
        reply(conn, fd: -1, status: UInt8(truncatingIfNeeded: e))
        return
    }
    reply(conn, fd: s, status: 0)
    close(s) // hand-off complete — VeloxApp holds the only reference now
    log("bound 127.0.0.1:\(port)/\(type == SOCK_STREAM ? "tcp" : "udp")")
}

// ---- main ----
guard let allowedUID = parseUID() else { errExit("missing --uid <n>") }
signal(SIGPIPE, SIG_IGN) // a client that vanishes mid-reply must not kill us
umask(0o077)             // the control socket is owner-only from creation, no chmod race
let listenFD = bindControlSocket(allowedUID)
log("ready (uid \(allowedUID)) on \(SOCKET_PATH)")
while true {
    let conn = accept(listenFD, nil, nil)
    if conn < 0 {
        if errno == EINTR { continue }
        usleep(10_000)
        continue
    }
    serve(conn, allowedUID)
}
