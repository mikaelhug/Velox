//! velox-porthelper — Velox's privileged port binder (runs as root under launchd).
//!
//! macOS forbids an unprivileged process from binding TCP/UDP ports below 1024, so
//! the (user-owned) VeloxApp can't open a `127.0.0.1:80` listener for a published
//! reverse-proxy port. This tiny daemon is the *only* privileged component in Velox
//! (CLAUDE.md §2 sanctioned exception). It does two root-only, **control-plane** jobs and
//! nothing else: (1) bind a port <1024 and pass the listening socket fd back to
//! VeloxApp, and (2) add/remove a host route to a container subnet (for direct named-container
//! access). It never touches a byte of connection data — root stays out of the datapath. Pure
//! Darwin, no Foundation, no dependencies: the smallest possible privileged surface.
//!
//! Protocol (one request per connection, on `/var/run/velox-porthelper.sock`):
//!   client → "tcp <port> [any]\n"  | "udp <port> [any]\n"   (1 ≤ port < 1024; 127.0.0.1, or 0.0.0.0 with `any`)
//!          | "tcp6 <port> [any]\n" | "udp6 <port> [any]\n"  (1 ≤ port < 1024; [::1], or [::] with `any`
//!                                                            — localhost resolves to ::1 first)
//!          | "route add <cidr> <ipv4>\n" | "route del <cidr>\n"  (RFC-1918 only, strictly validated)
//!          | "ipfwd\n"                                (restore net.inet.ip.forwarding=1; never 0)
//!          | "resolver <port>\n"                       (point /etc/resolver/<domain> at
//!                                                       127.0.0.1:<port>; `resolver 0` removes it)
//!   helper → 1 status byte (0 = ok, else errno) + on a port bind the fd via SCM_RIGHTS
//!
//! The optional `any` argument is what makes a published container port on a privileged
//! port (`-p 80:…`, `-p 22:…`) reachable from other machines, matching Docker's default of
//! publishing on all interfaces. It is strictly opt-in per request: a bare "tcp <port>"
//! still binds loopback, so an older client keeps its old behaviour, and a client talking
//! to an older helper gets EINVAL and falls back to loopback rather than failing.
//! Only the uid passed as `--uid` (the installing user) is served; everything else is
//! rejected. The control socket lives in root-only-writable /var/run, so no other
//! local user can replace it.

import Darwin

let SOCKET_PATH = "/var/run/velox-porthelper.sock"
/// Must match `NamedAccess.domain` in VeloxCore. Duplicated as a literal on purpose: the
/// helper deliberately links nothing (no Foundation, no VeloxCore) to keep the privileged
/// surface minimal, and this being a compile-time constant is what keeps caller-controlled
/// text out of a root-owned path under /etc.
let RESOLVER_DOMAIN = "velox.local"

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

/// Bind a fresh IPv4 socket on `port` (TCP listens; UDP just binds) — `127.0.0.1` by
/// default, `0.0.0.0` when `wildcard`. Returns the fd, or -1 with `errno` set.
func bindV4(type: Int32, port: UInt16, wildcard: Bool) -> Int32 {
    let s = socket(AF_INET, type, 0)
    if s < 0 { return -1 }
    var yes: Int32 = 1
    // Loopback binds only. On a wildcard bind SO_REUSEADDR succeeds even while another
    // process holds `127.0.0.1:<port>` (measured, TCP and UDP), so it would plant a
    // Velox-owned listener on the LAN-facing side of a daemon that deliberately chose
    // loopback — and it swallows the EADDRINUSE the forwarder needs to report a conflict.
    if !wildcard {
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = wildcard ? INADDR_ANY.bigEndian : inet_addr("127.0.0.1")
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    } }
    if r != 0 { let e = errno; close(s); errno = e; return -1 }
    if type == SOCK_STREAM, listen(s, 128) != 0 { let e = errno; close(s); errno = e; return -1 }
    return s
}

/// Bind a fresh IPv6 socket on `[::1]:port` — or `[::]:port` when `wildcard` — always
/// V6ONLY so it never shadows the v4 listener. macOS resolves `localhost` to `::1` first,
/// so a published `<1024` port (e.g. a reverse proxy on `:80`) needs this twin or
/// `curl http://localhost/` gets connection-refused while `127.0.0.1` works. Returns the
/// fd, or -1 with `errno` set.
func bindV6(type: Int32, port: UInt16, wildcard: Bool) -> Int32 {
    let s = socket(AF_INET6, type, 0)
    if s < 0 { return -1 }
    var yes: Int32 = 1
    if !wildcard {   // see bindV4
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in6()
    addr.sin6_family = sa_family_t(AF_INET6)
    addr.sin6_port = port.bigEndian
    addr.sin6_addr = wildcard ? in6addr_any : in6addr_loopback
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
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

/// One parsed request: bind a privileged loopback port, add/remove a host route, or
/// restore IP forwarding.
enum Req {
    case bind(type: Int32, port: UInt16, ipv6: Bool, wildcard: Bool)
    case route(add: Bool, subnet: String, gateway: String)
    case ipForward
    /// `resolver <port>` writes /etc/resolver/<domain> pointing at 127.0.0.1:<port>;
    /// `resolver 0` removes it. Port 0 is never a valid listener, so it doubles as "off".
    case resolver(port: UInt16)
}

/// Parse a dotted-quad to a host-order UInt32, or nil.
@inline(__always) func parseIPv4(_ s: String) -> UInt32? {
    var a = in_addr()
    guard s.withCString({ inet_pton(AF_INET, $0, &a) }) == 1 else { return nil }
    return UInt32(bigEndian: a.s_addr)
}
/// True when `ip/prefix` lies wholly inside RFC-1918 private space (10/8, 172.16/12,
/// 192.168/16). Routes are system-wide state, so the helper only ever touches
/// container-side private subnets — never public space, never a default route — no
/// matter who asks. Docker subnets (`default-address-pools`) and the vmnet guest IP
/// are always private, so nothing real is lost.
@inline(__always) func privateIPv4Net(_ ip: UInt32, _ prefix: Int) -> Bool {
    let blocks: [(net: UInt32, plen: Int)] = [(0x0A00_0000, 8), (0xAC10_0000, 12), (0xC0A8_0000, 16)]
    return blocks.contains { prefix >= $0.plen && (ip ^ $0.net) >> (32 - $0.plen) == 0 }
}
/// Re-emit an IPv4 address in canonical dotted-quad form. The whole point: `inet_pton`
/// (what we validate with) and `inet_aton`/`inet_network` (what `/sbin/route` parses with)
/// DISAGREE on leading zeros — `inet_pton` reads `010.0.0.0` as 10.0.0.0, `route` reads it
/// as octal 8.0.0.0. Validating one string and executing another let a caller pass the
/// RFC-1918 check and have root install a route into PUBLIC space (measured:
/// `route -n get 010.0.0.1` → `route to: 8.0.0.1`). So nothing the client sent is ever
/// handed to `route` verbatim; only these re-rendered values are.
@inline(__always) func canonicalIPv4(_ ip: UInt32) -> String? {
    var a = in_addr(s_addr: ip.bigEndian)
    var buf = [UInt8](repeating: 0, count: Int(INET_ADDRSTRLEN))
    let ok = buf.withUnsafeMutableBufferPointer { p -> Bool in
        p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: p.count) {
            inet_ntop(AF_INET, &a, $0, socklen_t(INET_ADDRSTRLEN)) != nil
        }
    }
    guard ok, let end = buf.firstIndex(of: 0) else { return nil }
    return String(decoding: buf[..<end], as: UTF8.self)
}

/// A private dotted-quad CIDR like `172.18.0.0/16` (within one RFC-1918 block), returned
/// canonicalized to its network address, or nil. Empty segments are kept
/// (`omittingEmptySubsequences: false`) so `/10.0.0.0/8`, `10.0.0.0//8` and `10.0.0.0/8/`
/// are rejected rather than silently accepted, and the prefix must round-trip exactly so
/// `08` and `+8` are rejected too.
@inline(__always) func canonicalPrivateCIDR(_ s: String) -> String? {
    let p = s.split(separator: "/", omittingEmptySubsequences: false)
    guard p.count == 2, let ip = parseIPv4(String(p[0])),
          let n = Int(p[1]), String(p[1]) == String(n), n >= 0, n <= 32,
          privateIPv4Net(ip, n) else { return nil }
    let mask: UInt32 = n == 0 ? 0 : ~UInt32(0) << (32 - n)
    guard let net = canonicalIPv4(ip & mask) else { return nil }
    return net + "/\(n)"
}

/// The route's next hop (the guest VM IP), canonicalized, or nil.
@inline(__always) func canonicalPrivateHost(_ s: String) -> String? {
    guard let ip = parseIPv4(s), privateIPv4Net(ip, 32) else { return nil }
    return canonicalIPv4(ip)
}

/// Add or delete a route to a container subnet via the guest. The daemon never sees connection
/// data — a route is pure control plane — so this keeps root out of the datapath (CLAUDE.md §2).
/// `posix_spawn` (no shell) + strict RFC-1918 CIDR/IPv4 validation means no argument injection
/// and no routing of public space is possible.
func runRoute(add: Bool, subnet: String, gateway: String) -> Int32 {
    // Canonicalized, never the caller's strings — see `canonicalIPv4`.
    guard let cidr = canonicalPrivateCIDR(subnet) else { return EINVAL }
    var gw = ""
    if add {
        guard let g = canonicalPrivateHost(gateway) else { return EINVAL }
        gw = g
    }
    var pid: pid_t = 0
    // add needs the gateway; delete by subnet alone (robust even if the guest IP changed).
    let args = add ? ["/sbin/route", "-n", "add", "-net", cidr, gw]
                   : ["/sbin/route", "-n", "delete", "-net", cidr]
    var argv = args.map { strdup($0) } + [UnsafeMutablePointer<CChar>?(nil)]
    defer { for a in argv where a != nil { free(a) } }
    let rc = posix_spawn(&pid, "/sbin/route", nil, nil, &argv, environ)
    if rc != 0 { return rc }
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    // A delete stays best-effort (removing a missing route is fine → success). An add must
    // report a genuine failure, or the host records the subnet as routed when it isn't and
    // named access silently breaks. The host deletes before every add
    // (NamedAccessRouter.reconcile), so a failing add is a real error, not "already exists".
    if !add { return 0 }
    let exited = (status & 0x7f) == 0            // WIFEXITED
    let code = (status >> 8) & 0xff              // WEXITSTATUS
    return (exited && code == 0) ? 0 : EIO
}

/// Point the system resolver at Velox's loopback DNS responder, or remove the file.
///
/// This used to be written ONCE at install time with a hard-coded port, which meant the port
/// had to be fixed — and a fixed unprivileged port is squattable: any local process (even
/// another user's) could bind it while Velox was stopped and then answer `*.<domain>` for the
/// whole machine, because /etc/resolver sends every such query there. Writing it at runtime
/// lets the responder take an EPHEMERAL port (nothing to pre-bind) and lets the file be
/// removed when the engine stops, so it never points at a port nobody owns.
func writeResolver(port: UInt16) -> Int32 {
    let path = "/etc/resolver/" + RESOLVER_DOMAIN
    if port == 0 {
        unlink(path)                      // absent is the desired end state; ENOENT is fine
        return 0
    }
    // The domain is a compile-time constant, and `port` is a UInt16 parsed from digits — no
    // caller-controlled text reaches the filesystem or the file's contents.
    guard mkdir("/etc/resolver", 0o755) == 0 || errno == EEXIST else { return errno }
    let body = "nameserver 127.0.0.1\nport \(port)\n"
    let tmp = path + ".tmp"
    let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return errno }
    let ok = body.withCString { cs -> Bool in
        let n = strlen(cs)
        return write(fd, cs, n) == n
    }
    close(fd)
    guard ok else { unlink(tmp); return EIO }
    // Atomic publish so a reader never sees a half-written resolver file.
    guard rename(tmp, path) == 0 else { let e = errno; unlink(tmp); return e }
    _ = chmod(path, 0o644)
    return 0
}

/// Restore the kernel IP-forwarding switch that Apple's vmnet NAT (the whole container
/// datapath) requires. Some VPN clients set `net.inet.ip.forwarding=0` system-wide on
/// connect (measured: AWS VPN Client), instantly killing every container's egress.
/// Restore-only by design: this helper can switch forwarding ON, never off — the
/// smallest possible capability, pure control plane.
func restoreIPForwarding() -> Int32 {
    var one: Int32 = 1
    let rc = sysctlbyname("net.inet.ip.forwarding", nil, nil, &one, MemoryLayout<Int32>.size)
    return rc == 0 ? 0 : errno
}

/// Read one bounded request line, parse + validate it.
///   "tcp <port> [any]" | "udp <port> [any]"     (1 ≤ port < 1024) → bind
///   "route add <cidr> <ipv4>" | "route del <cidr>" (validated)    → route
///   "ipfwd"                                                       → ipForward
func readRequest(_ conn: Int32, max: Int = 96) -> Req? {
    var bytes = [UInt8](); bytes.reserveCapacity(max)
    var b: UInt8 = 0
    var sawEOL = false
    while bytes.count < max {
        let n = recv(conn, &b, 1, 0)
        if n <= 0 { return nil }
        if b == 0x0A { sawEOL = true; break }
        bytes.append(b)
    }
    // Overflowing the cap used to fall through and parse the truncated prefix as a valid
    // request. A root parser fails closed.
    guard sawEOL else { return nil }
    let parts = String(decoding: bytes, as: UTF8.self).split(separator: " ").map(String.init)
    switch parts.first {
    case "tcp", "udp", "tcp6", "udp6":
        // The optional 3rd token is the literal "any" (bind all interfaces); anything
        // else is rejected outright rather than ignored, so a malformed request can
        // never widen a bind by accident.
        guard parts.count == 2 || (parts.count == 3 && parts[2] == "any"),
              let port = UInt16(parts[1]), port > 0, port < 1024 else { return nil }
        let stream = parts[0].hasPrefix("tcp")
        let ipv6 = parts[0].hasSuffix("6")
        return .bind(type: stream ? SOCK_STREAM : SOCK_DGRAM, port: port,
                     ipv6: ipv6, wildcard: parts.count == 3)
    case "resolver":
        // `resolver <port>` | `resolver 0` (remove). Digits only — this value ends up in a
        // root-owned file under /etc.
        guard parts.count == 2, let p = UInt16(parts[1]) else { return nil }
        return .resolver(port: p)
    case "route":
        guard parts.count >= 3 else { return nil }
        switch parts[1] {
        case "add": guard parts.count == 4 else { return nil }
                    return .route(add: true, subnet: parts[2], gateway: parts[3])
        case "del": return .route(add: false, subnet: parts[2], gateway: parts.count > 3 ? parts[3] : "0.0.0.0")
        default: return nil
        }
    case "ipfwd":
        guard parts.count == 1 else { return nil }
        return .ipForward
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
    // squatting a <1024 port; the <1024-only limit and the uid check keep it contained.
    // Note this surface widened when `any` arrived: a squatted port can now be bound on
    // all interfaces, not just loopback — reachable from the LAN. That is the same
    // exposure Docker's own default publishing has, and it is what makes a published
    // `-p 22:22` work off-box, but it does raise the value of the peer code-signature
    // check above from "nice to have" to the real fix.
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
    case let .bind(type, port, ipv6, wildcard):
        let s = ipv6 ? bindV6(type: type, port: port, wildcard: wildcard)
                     : bindV4(type: type, port: port, wildcard: wildcard)
        if s < 0 {
            let e = errno
            log("bind \(port) failed: \(String(cString: strerror(e)))")
            reply(conn, fd: -1, status: UInt8(truncatingIfNeeded: e))
            return
        }
        reply(conn, fd: s, status: 0)
        close(s) // hand-off complete — VeloxApp holds the only reference now
        let bound = ipv6 ? (wildcard ? "[::]" : "[::1]") : (wildcard ? "0.0.0.0" : "127.0.0.1")
        log("bound \(bound):\(port)/\(type == SOCK_STREAM ? "tcp" : "udp")")
    case let .route(add, subnet, gateway):
        let rc = runRoute(add: add, subnet: subnet, gateway: gateway)
        reply(conn, fd: -1, status: UInt8(truncatingIfNeeded: rc))
        log("route \(add ? "add" : "del") \(subnet)\(add ? " → \(gateway)" : "") (rc \(rc))")
    case let .resolver(port):
        let rc = writeResolver(port: port)
        reply(conn, fd: -1, status: UInt8(truncatingIfNeeded: rc))
        log(port == 0 ? "resolver file removed (rc \(rc))" : "resolver → 127.0.0.1:\(port) (rc \(rc))")
    case .ipForward:
        let rc = restoreIPForwarding()
        reply(conn, fd: -1, status: UInt8(truncatingIfNeeded: rc))
        log("ipfwd: net.inet.ip.forwarding restored to 1 (rc \(rc))")
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
