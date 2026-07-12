import Foundation

/// Host side of the privileged port helper (`velox-porthelper`).
///
/// macOS blocks an unprivileged process from binding ports below 1024, so the
/// user-owned host can't open a `127.0.0.1:80` listener for a published port (e.g. a
/// reverse proxy on `:80`). A tiny root LaunchDaemon does the privileged bind and
/// passes the listening socket fd back over a unix socket; the host then accepts on it
/// and reverse-forwards exactly as it does for ports ≥ 1024 — the helper is never in
/// the data path. This file is the client (request an fd), the installer (one-time
/// admin-authorized install of the daemon), and the manager that the forwarders use.
///
/// This is the single sanctioned exception to CLAUDE.md §2's "no helper daemons" — it
/// exists only because the macOS kernel offers no unprivileged way to bind low ports.

public enum PortHelperProto: Sendable { case tcp, udp }

/// Supplies a bound, loopback listener fd for a privileged (<1024) port. Injected into
/// `PortForwarder` / `UDPForwarder`; nil result ⇒ the helper isn't available yet.
public protocol PrivilegedPortBinder: AnyObject, Sendable {
    /// `ipv6: true` binds `[::1]` (the address `localhost` resolves to first) instead of
    /// 127.0.0.1 — needed so a published `<1024` port is reachable via `localhost`, not
    /// just `127.0.0.1`. An old helper that predates the v6 verb returns nil (skipped).
    func boundListener(port: UInt16, proto: PortHelperProto, ipv6: Bool) -> Int32?
}

// MARK: - Manager (what the forwarders + engine talk to)

public final class PortHelperManager: PrivilegedPortBinder, @unchecked Sendable {
    private let lock = NSLock()
    private var installTask: Task<Bool, Never>?
    /// Set once the user dismisses the auth prompt — so a published <1024 port doesn't
    /// re-prompt on every subsequent Docker event this session.
    private var declined = false
    /// The most recent desired port sets, so a post-install reconcile applies current
    /// state rather than a stale snapshot from whichever event triggered the install.
    private var latestTCP: Set<UInt16> = []
    private var latestUDP: Set<UInt16> = []

    public init() {}

    /// Request a privileged-port listener fd from the running helper (nil if it isn't
    /// installed/answering, or the bind failed). Thread-safe — just syscalls.
    public func boundListener(port: UInt16, proto: PortHelperProto, ipv6: Bool = false) -> Int32? {
        PortHelperClient.requestListener(port: port, proto: proto, ipv6: ipv6)
    }

    /// Add/remove a host route to a container subnet via the helper (named-access routing).
    /// Best-effort; requires the helper to be installed (the same one-time grant). Routes are
    /// control-plane — the helper never sees connection data.
    @discardableResult
    public func route(add: Bool, subnet: String, gateway: String) -> Bool {
        PortHelperClient.route(add: add, subnet: subnet, gateway: gateway)
    }

    /// Switch `net.inet.ip.forwarding` back on via the helper (restore-only — the
    /// helper cannot turn it off). It's the kernel switch Apple's vmnet NAT (the whole
    /// container datapath) rides on; some VPN clients zero it on connect. Best-effort;
    /// requires the helper to be installed (the same one-time grant).
    @discardableResult
    public func restoreIPForwarding() -> Bool {
        PortHelperClient.restoreIPForwarding()
    }

    /// Ensure the helper is installed and running, prompting for admin authorization
    /// once if needed. Single-flight; never re-prompts after a decline.
    public func ensureInstalled() async -> Bool {
        if PortHelperInstaller.isInstalledAndCurrent() { return true }
        guard let task = claimInstallTask() else { return false }
        return await task.value
    }

    /// The in-flight (or freshly started) install task, or nil if the user already
    /// declined this session. Synchronous, so the lock is never held across an await.
    private func claimInstallTask() -> Task<Bool, Never>? {
        lock.lock(); defer { lock.unlock() }
        if declined { return nil }
        if let existing = installTask { return existing }
        let task = Task<Bool, Never> { [weak self] in
            let ok = await PortHelperInstaller.install()
            self?.finishInstall(ok: ok)
            return ok
        }
        installTask = task
        return task
    }

    private func finishInstall(ok: Bool) {
        lock.lock(); defer { lock.unlock() }
        installTask = nil
        if !ok { declined = true }
    }

    /// Build the `DockerEventsWatcher` `onPorts` callback. The full desired set is
    /// reconciled synchronously every time — privileged (<1024) ports the helper can't
    /// bind yet are simply skipped by the forwarder and retried later, so we never pass
    /// a *subset* to `reconcile()` (which would close ports a newer event just opened).
    /// When a published port <1024 appears, the helper is authorized+installed once and
    /// the *latest* set is re-reconciled so those ports bind. Shared by GUI + CLI.
    public func reconciler(
        tcp tcpReconcile: @escaping @Sendable (Set<UInt16>) -> Void,
        udp udpReconcile: @escaping @Sendable (Set<UInt16>) -> Void
    ) -> @Sendable (Set<UInt16>, Set<UInt16>) -> Void {
        return { [weak self] tcp, udp in
            // Always reconcile the complete set, in the watcher's serialized callback.
            tcpReconcile(tcp); udpReconcile(udp)
            guard let self, tcp.contains(where: { $0 < 1024 }) || udp.contains(where: { $0 < 1024 }) else { return }
            self.setLatest(tcp: tcp, udp: udp)
            Task {
                guard await self.ensureInstalled() else { return }
                // Re-reconcile the newest set so the now-bindable privileged ports open.
                let (t, u) = self.latest()
                tcpReconcile(t); udpReconcile(u)
            }
        }
    }

    private func setLatest(tcp: Set<UInt16>, udp: Set<UInt16>) {
        lock.lock(); latestTCP = tcp; latestUDP = udp; lock.unlock()
    }

    private func latest() -> (Set<UInt16>, Set<UInt16>) {
        lock.lock(); defer { lock.unlock() }
        return (latestTCP, latestUDP)
    }

    /// Remove the installed helper + LaunchDaemon (one admin prompt). For a Settings action.
    @discardableResult
    public func uninstall() async -> Bool { await PortHelperInstaller.uninstall() }
}

// MARK: - Client (request a listener fd over the unix socket)

package enum PortHelperClient {
    /// MUST match `SOCKET_PATH` in Sources/velox-porthelper/main.swift.
    package static let productionSocketPath = "/var/run/velox-porthelper.sock"
    /// Overridable seam so the selftest can stand up a fake daemon on a temp socket.
    /// Production never touches it. (Written once by the test before any use.)
    package nonisolated(unsafe) static var socketPath = productionSocketPath

    package static func requestListener(port: UInt16, proto: PortHelperProto, ipv6: Bool = false) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // Bound the round-trip: this runs on the forwarder's serial queue, so a wedged
        // daemon must not hang it — time out and skip the port instead (retried later).
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard connected == 0 else { return nil }
        let verb = (proto == .tcp ? "tcp" : "udp") + (ipv6 ? "6" : "")
        let request = "\(verb) \(port)\n"
        guard FDIO.writeAll(fd, Array(request.utf8)) else { return nil }
        let (status, received) = receiveFD(fd)
        guard status == 0, let received else {
            if let received { close(received) }
            return nil
        }
        return received
    }

    /// Ask the helper to add/remove a host route to a container subnet (named-access routing).
    /// The helper strictly validates the CIDR/IPv4. Returns true on status 0.
    package static func route(add: Bool, subnet: String, gateway: String) -> Bool {
        guard let fd = connectToDaemon() else { return false }
        defer { close(fd) }
        let req = add ? "route add \(subnet) \(gateway)\n" : "route del \(subnet)\n"
        guard FDIO.writeAll(fd, Array(req.utf8)) else { return false }
        var status: UInt8 = 0xFF
        return recv(fd, &status, 1, 0) == 1 && status == 0
    }

    /// Ask the helper to restore `net.inet.ip.forwarding=1` (it can never set 0).
    package static func restoreIPForwarding() -> Bool {
        guard let fd = connectToDaemon() else { return false }
        defer { close(fd) }
        guard FDIO.writeAll(fd, Array("ipfwd\n".utf8)) else { return false }
        var status: UInt8 = 0xFF
        return recv(fd, &status, 1, 0) == 1 && status == 0
    }

    /// Connect to the daemon's unix socket with send/recv timeouts. nil if it isn't running.
    private static func connectToDaemon() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard connected == 0 else { close(fd); return nil }
        return fd
    }

    // Single-fd ancillary-message layout (Darwin aligns to 4 bytes); mirrors the daemon.
    private static let cmsgHdrLen = (MemoryLayout<cmsghdr>.size + 3) & ~3
    private static let cmsgLen1FD = cmsgHdrLen + MemoryLayout<Int32>.size
    private static let cmsgSpace1FD = cmsgHdrLen + ((MemoryLayout<Int32>.size + 3) & ~3)

    /// Receive the 1-byte status and, on success, the fd passed via SCM_RIGHTS.
    private static func receiveFD(_ conn: Int32) -> (status: UInt8, fd: Int32?) {
        var statusByte: UInt8 = 0xFF
        return withUnsafeMutablePointer(to: &statusByte) { sp in
            var iov = iovec(iov_base: UnsafeMutableRawPointer(sp), iov_len: 1)
            return withUnsafeMutablePointer(to: &iov) { iovp -> (UInt8, Int32?) in
                var msg = msghdr()
                msg.msg_iov = iovp
                msg.msg_iovlen = 1
                let control = UnsafeMutableRawPointer.allocate(byteCount: cmsgSpace1FD,
                                                               alignment: MemoryLayout<cmsghdr>.alignment)
                defer { control.deallocate() }
                memset(control, 0, cmsgSpace1FD)
                msg.msg_control = control
                msg.msg_controllen = socklen_t(cmsgSpace1FD)
                let n = recvmsg(conn, &msg, 0)
                if n <= 0 { return (0xFF, nil) }
                var fd: Int32?
                if msg.msg_controllen >= socklen_t(cmsgLen1FD) {
                    let cmsg = control.assumingMemoryBound(to: cmsghdr.self)
                    if cmsg.pointee.cmsg_level == SOL_SOCKET, cmsg.pointee.cmsg_type == SCM_RIGHTS {
                        fd = (control + cmsgHdrLen).assumingMemoryBound(to: Int32.self).pointee
                    }
                }
                return (sp.pointee, fd)
            }
        }
    }
}

// MARK: - Installer (one-time admin-authorized LaunchDaemon install)

enum PortHelperInstaller {
    static let label = "dev.velox.porthelper"
    static let installedBinary = "/Library/PrivilegedHelperTools/dev.velox.porthelper"
    static let plistPath = "/Library/LaunchDaemons/dev.velox.porthelper.plist"
    static let versionMarker = "/Library/Application Support/Velox/porthelper.version"
    static let socketPath = PortHelperClient.productionSocketPath

    /// The helper revision that must be installed, from versions.env (`Versions.porthelperRevision`).
    /// The install (one admin prompt) is repeated ONLY when this changes — i.e. only when the
    /// helper's binary/socket protocol actually changes — not on every Velox update. (It used to be
    /// the app version, which changes every release, so the install re-prompted on every update.)
    static var requiredRevision: String { Versions.porthelperRevision }

    /// Installed, current, and the daemon's socket is present (so it's actually running).
    static func isInstalledAndCurrent() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: plistPath),
              fm.fileExists(atPath: installedBinary),
              fm.fileExists(atPath: socketPath) else { return false }
        let marker = (try? String(contentsOfFile: versionMarker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Grandfather installs from the old scheme (the marker was an app version like "0.1.12",
        // which contains dots) as revision "1" — the immutable baseline the revision scheme launched
        // at — so existing users aren't re-prompted merely to migrate the marker. Only a genuine
        // `PORTHELPER_REVISION` bump (a changed helper) reinstalls thereafter.
        let installedRevision = (marker?.contains(".") ?? false) ? "1" : marker
        return installedRevision == requiredRevision
    }

    /// Locate the helper binary shipped inside the app bundle (or next to the CLI,
    /// which lives in the same Contents/Resources/bin when bundled).
    static func bundledHelperURL() -> URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            let u = res.appendingPathComponent("bin/velox-porthelper")
            if fm.fileExists(atPath: u.path) { return u }
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let sibling = exe.deletingLastPathComponent().appendingPathComponent("velox-porthelper")
        if fm.fileExists(atPath: sibling.path) { return sibling }
        return nil
    }

    static func install() async -> Bool {
        guard let helper = bundledHelperURL() else {
            Log.warn("port-helper: bundled velox-porthelper not found — cannot install")
            return false
        }
        let plistB64 = Data(launchDaemonPlist(uid: getuid()).utf8).base64EncodedString()
        let script = installScript(helperSrc: helper.path, plistB64: plistB64, version: requiredRevision)
        Log.info("port-helper: requesting authorization to install the privileged port helper")
        let prompt = "Velox needs administrator access once to enable direct container access — "
            + "reaching containers by name (like web.velox.local), publishing ports below 1024 "
            + "(such as 80 and 443), and keeping container networking alive alongside VPN clients. "
            + "This is a one-time setup — you won't be asked again."
        guard await runAsAdmin(script, prompt: prompt) else {
            Log.warn("port-helper: installation was not authorized")
            return false
        }
        // The daemon creates its socket on launch (RunAtLoad); wait briefly for it.
        for _ in 0..<30 {
            if FileManager.default.fileExists(atPath: socketPath) {
                Log.info("port-helper: installed and running")
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Log.warn("port-helper: installed but the daemon socket did not appear")
        return false
    }

    @discardableResult
    static func uninstall() async -> Bool {
        let script = [
            "launchctl bootout system \(shq(plistPath)) 2>/dev/null; true",
            "rm -f \(shq(plistPath)) \(shq(installedBinary)) \(shq(versionMarker)) /etc/resolver/\(shq(NamedAccess.domain))",
        ].joined(separator: " && ")
        return await runAsAdmin(script, prompt: "Velox needs administrator access to remove its privileged-port helper.")
    }

    /// POSIX single-quote a value so it can't break out of the privileged install
    /// command — even if Velox.app sits at a path with spaces or quotes (which would
    /// otherwise inject shell run as root). Every interpolated value goes through this.
    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// One privileged shell command (so one auth prompt) that installs the binary,
    /// the LaunchDaemon, and (re)bootstraps it. The plist is base64-piped so the whole
    /// thing stays a single line — no heredoc/newlines to fight the AppleScript string.
    private static func installScript(helperSrc: String, plistB64: String, version: String) -> String {
        [
            "mkdir -p /Library/PrivilegedHelperTools '/Library/Application Support/Velox'",
            "cp \(shq(helperSrc)) \(shq(installedBinary))",
            "chown root:wheel \(shq(installedBinary))",
            "chmod 755 \(shq(installedBinary))",
            // A downloaded (notarized) build carries a quarantine xattr that `cp` can
            // propagate; strip it so launchd can exec the daemon without Gatekeeper.
            "xattr -dr com.apple.quarantine \(shq(installedBinary)) 2>/dev/null; true",
            "printf '%s' \(shq(plistB64)) | base64 -D > \(shq(plistPath))",
            "chown root:wheel \(shq(plistPath))",
            "chmod 644 \(shq(plistPath))",
            "printf '%s' \(shq(version)) > \(shq(versionMarker))",
            // Direct (named) container access: route *.<domain> DNS queries to Velox's loopback
            // responder. Folded into the same one-time grant as the port helper (CLAUDE.md §2) so
            // the user is prompted only once. The responder port is fixed, so the file is static.
            "mkdir -p /etc/resolver",
            "printf 'nameserver 127.0.0.1\\nport %s\\n' \(shq(String(NamedAccess.dnsPort))) > /etc/resolver/\(shq(NamedAccess.domain))",
            "chmod 644 /etc/resolver/\(shq(NamedAccess.domain))",
            "launchctl bootout system \(shq(plistPath)) 2>/dev/null; true",
            "launchctl bootstrap system \(shq(plistPath))",
        ].joined(separator: " && ")
    }

    private static func launchDaemonPlist(uid: uid_t) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(installedBinary)</string>
                <string>--uid</string>
                <string>\(uid)</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ProcessType</key><string>Adaptive</string>
            <key>StandardErrorPath</key><string>/var/log/velox-porthelper.log</string>
        </dict>
        </plist>
        """
    }

    /// Run a shell command as root via a single GUI authorization prompt. `prompt` is shown in
    /// the macOS authorization dialog so the user reads a clear, Velox-specific reason instead of
    /// a bare password request. (A fully native dialog with the app's own name + icon would need
    /// SMAppService, which requires a Developer ID signature this build doesn't carry — so the
    /// custom prompt is the best UX available on the osascript path.)
    private static func runAsAdmin(_ shell: String, prompt: String) async -> Bool {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let appleScript = "do shell script \"\(esc(shell))\" with administrator privileges "
            + "with prompt \"\(esc(prompt))\""
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", appleScript]
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus == 0) }
            do { try p.run() }
            catch {
                Log.warn("port-helper: failed to launch osascript: \(error.localizedDescription)")
                cont.resume(returning: false)
            }
        }
    }
}
