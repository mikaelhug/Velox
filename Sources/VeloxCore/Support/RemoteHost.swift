import Foundation

/// One remote Docker Engine reachable over SSH.
///
/// Velox stores **no credentials** — not a password, not a key, not a passphrase. `user`,
/// `hostname`, `port` and an optional `identityFile` path are the whole record;
/// authentication is delegated entirely to the user's `~/.ssh/config`, their keys and
/// `ssh-agent` (`SSHTunnel` runs ssh with `BatchMode=yes`). That is deliberate: the repo
/// has no secret-storage mechanism today, and under CLAUDE.md §10 whatever were added
/// here would become *the* mechanism for the whole project.
///
/// Unlike a `Workspace` — which *is* a `data.img` Velox owns — a host is only a pointer
/// to a daemon someone else runs. Velox never formats, migrates or deletes anything on
/// the far side; removing a host removes a row from `hosts.json` and nothing more.
public struct RemoteHost: Codable, Sendable, Equatable, Identifiable {
    /// Short random hex. Deliberately short: it lands in the forwarded socket path
    /// (`~/.velox/hosts/<id>.sock`) and `sockaddr_un.sun_path` is only 104 bytes.
    public let id: String
    public var name: String
    public var user: String
    public var hostname: String
    public var port: Int
    /// Path to the daemon socket **on the server**.
    public var socketPath: String
    /// Optional explicit key (`ssh -i`). Normally nil — `~/.ssh/config` is the better
    /// place for this, and the whole point is to not re-implement ssh's own config.
    public var identityFile: String?
    public var created: Date

    public static let defaultSocketPath = "/var/run/docker.sock"
    public static let defaultPort = 22
    public static let portRange = 1...65535

    public init(id: String = RemoteHost.newID(),
                name: String,
                user: String,
                hostname: String,
                port: Int = RemoteHost.defaultPort,
                socketPath: String = RemoteHost.defaultSocketPath,
                identityFile: String? = nil,
                created: Date = Date()) {
        self.id = id
        self.name = name
        self.user = user
        self.hostname = hostname
        self.port = port
        self.socketPath = socketPath
        self.identityFile = identityFile
        self.created = created
    }

    /// 8 hex characters — 4 bytes of randomness. Collisions only matter within one
    /// user's own host list, and `RemoteHostStore.create` rejects a duplicate id anyway.
    public static func newID() -> String {
        (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Tolerant decode, matching `Workspace`: a manifest written by a newer or older build
    /// must never fail to load over a key that has a sensible default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        user = try c.decode(String.self, forKey: .user)
        hostname = try c.decode(String.self, forKey: .hostname)
        port = Self.clampPort(try c.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort)
        socketPath = try c.decodeIfPresent(String.self, forKey: .socketPath) ?? Self.defaultSocketPath
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }

    public static func clampPort(_ value: Int) -> Int {
        min(max(value, portRange.lowerBound), portRange.upperBound)
    }

    // MARK: - Derived

    /// The SSH destination (`user@hostname`) — what ssh and the Terminal hand-off use.
    public var sshDestination: String { "\(user)@\(hostname)" }

    /// **The one resolver** for this host's forwarded socket, in the spirit of §11's
    /// `Workspace.dataDiskURL`. Nothing else may compose this path.
    public var localSocketURL: URL {
        Paths.remoteHosts.appendingPathComponent("\(id).sock")
    }

    /// A short "who am I talking to" line for the UI.
    public var subtitle: String {
        let base = port == Self.defaultPort
            ? sshDestination
            : "\(user)@\(Self.urlHost(hostname)):\(port)"
        return socketPath == Self.defaultSocketPath ? base : "\(base) · \(socketPath)"
    }

    // MARK: - Validation

    public static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Validate user input from the add/rename sheet. Returns a human-readable complaint,
    /// or nil when the field is acceptable.
    public static func validate(name: String) -> String? {
        let trimmed = normalized(name)
        if trimmed.isEmpty { return "Name can't be empty." }
        if trimmed.count > 40 { return "Name is too long." }
        return nil
    }

    public static func validate(user: String) -> String? {
        let trimmed = normalized(user)
        if trimmed.isEmpty { return "Username can't be empty." }
        if let complaint = optionLikeComplaint(trimmed, field: "Username") { return complaint }
        if trimmed.contains(where: { $0 == "@" || $0 == "/" }) || hasBlankOrControl(trimmed) {
            return "Username can't contain @, slashes or whitespace."
        }
        return nil
    }

    /// Any whitespace (not just a literal space) or control character. `normalized` only
    /// trims the ends, so a value pasted into a single-line field can still carry a newline
    /// in the middle — which an AppleScript string literal cannot represent, silently
    /// breaking every Terminal hand-off with no error anywhere.
    public static func hasBlankOrControl(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
    }

    /// A leading `-` makes ssh read the value as an option rather than a destination or a
    /// path — and `-oProxyCommand=…` is executed through `/bin/sh`.
    static func optionLikeComplaint(_ text: String, field: String) -> String? {
        text.hasPrefix("-") ? "\(field) can't start with a dash." : nil
    }

    public static func validate(hostname: String) -> String? {
        let trimmed = normalized(hostname)
        if trimmed.isEmpty { return "Host can't be empty." }
        // Reject anything that would need shell quoting or change ssh's argument meaning.
        if let complaint = optionLikeComplaint(trimmed, field: "Host") { return complaint }
        if trimmed.contains(where: { $0 == "@" || $0 == "/" }) || hasBlankOrControl(trimmed) {
            return "Host must be a plain hostname or IP address."
        }
        // A colon is legitimate in exactly one case: an IPv6 literal, which ssh accepts as
        // `user@2001:db8::1`. Anything else with a colon is almost always a pasted
        // "host:port", which would otherwise be swallowed into the ssh destination and fail
        // with a baffling resolver error — so name the real mistake.
        if trimmed.contains(":") && !isIPv6Literal(trimmed) {
            return "Host must not include a port — use the Port field instead."
        }
        return nil
    }

    /// Whether `text` is a valid IPv6 address, per the resolver rather than a guess.
    public static func isIPv6Literal(_ text: String) -> Bool {
        var buffer = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &buffer) == 1 }
    }

    /// The host as it must appear inside a URL. IPv6 literals are bracketed, without which
    /// `http://fe80::1:8080/` is unparseable — the colons collide with the port separator.
    public static func urlHost(_ hostname: String) -> String {
        isIPv6Literal(hostname) ? "[\(hostname)]" : hostname
    }

    public static func validate(socketPath: String) -> String? {
        let trimmed = normalized(socketPath)
        if trimmed.isEmpty { return "Socket path can't be empty." }
        if !trimmed.hasPrefix("/") { return "Socket path must be absolute." }
        // This is concatenated into ssh's colon-delimited `-L <local>:<remote>` spec, so a
        // colon would silently change what ssh parses rather than failing visibly.
        if trimmed.contains(":") { return "Socket path can't contain a colon." }
        if hasBlankOrControl(trimmed) { return "Socket path can't contain whitespace." }
        return nil
    }

    /// Deleting is typed-name confirmed, like a workspace.
    public func deleteConfirmationMatches(_ typed: String) -> Bool {
        Self.normalized(typed).caseInsensitiveCompare(Self.normalized(name)) == .orderedSame
    }
}
