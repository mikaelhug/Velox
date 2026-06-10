//! velox-porthelper — Velox's privileged port binder (runs as root under launchd).
//!
//! macOS forbids an unprivileged process from binding TCP/UDP ports below 1024, so
//! the (user-owned) VeloxApp can't open a `127.0.0.1:80` listener for a published
//! reverse-proxy port. This tiny daemon is the *only* privileged component in Velox
//! (CLAUDE.md §2 sanctioned exception). It does two root-only, **control-plane** jobs and
//! nothing else: (1) bind a loopback port <1024 and pass the listening socket fd back to
//! VeloxApp, and (2) add/remove a host route to a container subnet (for direct named-container
//! access). It never touches a byte of connection data — root stays out of the datapath. Pure
//! Darwin, no Foundation, no dependencies: the smallest possible privileged surface.
//!
//! Protocol (one request per connection, on `/var/run/velox-porthelper.sock`):
//!   client → "tcp <port>\n" | "udp <port>\n"          (1 ≤ port < 1024)
//!          | "route add <cidr> <ipv4>\n" | "route del <cidr>\n"  (strictly validated)
//!   helper → 1 status byte (0 = ok, else errno) + on a port bind the fd via SCM_RIGHTS
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

/// One parsed request: bind a privileged loopback port, or add/remove a host route.
enum Req {
    case bind(type: Int32, port: UInt16)
    case route(add: Bool, subnet: String, gateway: String)
}

@inline(__always) func validIPv4(_ s: String) -> Bool {
    var a = in_addr()
    return s.withCString { inet_pton(AF_INET, $0, &a) } == 1
}
/// A dotted-quad CIDR like `172.18.0.0/16`, prefix 0…32.
@inline(__always) func validCIDR(_ s: String) -> Bool {
    let p = s.split(separator: "/")
    guard p.count == 2, validIPv4(String(p[0])), let n = Int(p[1]), n >= 0, n <= 32 else { return false }
    return true
}

/// Add or delete a route to a container subnet via the guest. The daemon never sees connection
/// data — a route is pure control plane — so this keeps root out of the datapath (CLAUDE.md §2).
/// `posix_spawn` (no shell) + strict CIDR/IPv4 validation means no argument injection is possible.
func runRoute(add: Bool, subnet: String, gateway: String) -> Int32 {
    guard validCIDR(subnet), add ? validIPv4(gateway) : true else { return EINVAL }
    var pid: pid_t = 0
    // add needs the gateway; delete by subnet alone (robust even if the guest IP changed).
    let args = add ? ["/sbin/route", "-n", "add", "-net", subnet, gateway]
                   : ["/sbin/route", "-n", "delete", "-net", subnet]
    var argv = args.map { strdup($0) } + [UnsafeMutablePointer<CChar>?(nil)]
    defer { for a in argv where a != nil { free(a) } }
    let rc = posix_spawn(&pid, "/sbin/route", nil, nil, &argv, environ)
    if rc != 0 { return rc }
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    return 0   // best-effort: a delete of a missing route or add of an existing one is fine
}

/// Read one bounded request line, parse + validate it.
///   "tcp <port>" | "udp <port>"                 (1 ≤ port < 1024) → bind
///   "route add <cidr> <ipv4>" | "route del <cidr>" (validated)    → route
func readRequest(_ conn: Int32, max: Int = 96) -> Req? {
    var bytes = [UInt8](); bytes.reserveCapacity(max)
    var b: UInt8 = 0
    while bytes.count < max {
        let n = recv(conn, &b, 1, 0)
        if n <= 0 { return nil }
        if b == 0x0A { break }
        bytes.append(b)
    }
    let parts = String(decoding: bytes, as: UTF8.self).split(separator: " ").map(String.init)
    switch parts.first {
    case "tcp", "udp":
        guard parts.count == 2, let port = UInt16(parts[1]), port > 0, port < 1024 else { return nil }
        return .bind(type: parts[0] == "tcp" ? SOCK_STREAM : SOCK_DGRAM, port: port)
    case "route":
        guard parts.count >= 3 else { return nil }
        switch parts[1] {
        case "add": guard parts.count == 4 else { return nil }
                    return .route(add: true, subnet: parts[2], gateway: parts[3])
        case "del": return .route(add: false, subnet: parts[2], gateway: parts.count > 3 ? parts[3] : "0.0.0.0")
        default: return nil
        }
    default: return nil
    }
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
    guard let req = readRequest(conn) else {
        reply(conn, fd: -1, status: UInt8(EINVAL & 0xff))
        return
    }
    switch req {
    case let .bind(type, port):
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
    case let .route(add, subnet, gateway):
        let rc = runRoute(add: add, subnet: subnet, gateway: gateway)
        reply(conn, fd: -1, status: UInt8(truncatingIfNeeded: rc))
        log("route \(add ? "add" : "del") \(subnet)\(add ? " → \(gateway)" : "") (rc \(rc))")
    }
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
