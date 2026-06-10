import AppKit
import VeloxCore

/// Row affordances that terminate in the user's world — browser, terminal,
/// clipboard — instead of in-app re-implementations. The lean answer to Docker
/// Desktop's embedded everything: a published port opens in the default browser, a
/// shell opens in the user's own Terminal (their fonts, their profile, their PATH),
/// and everything else is a copy away.
@MainActor
enum WorkspaceActions {
    /// Open a published port in the default browser (`http://localhost:<port>`).
    /// Plain http on purpose: TLS-fronted containers redirect themselves, and a
    /// non-HTTP port just produces a connection error tab — harmless and obvious.
    static func openPort(_ port: Int) {
        if let url = URL(string: "http://localhost:\(port)/") { NSWorkspace.shared.open(url) }
    }

    /// Open a named-access domain (`http://<name>.velox.local/`).
    static func openDomain(_ domain: String) {
        if let url = URL(string: "http://\(domain)/") { NSWorkspace.shared.open(url) }
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Open the user's Terminal with an interactive shell inside the container —
    /// `docker --context velox exec` in their own terminal, profile and PATH intact
    /// (the first-run setup put `docker` on PATH). bash when the image has it,
    /// else sh. No embedded PTY: delegating to the real terminal IS the feature.
    static func openShell(containerID: String) {
        let exec = "docker --context velox exec -it \(containerID) sh -c 'command -v bash >/dev/null && exec bash || exec sh'"
        let script = """
        tell application "Terminal"
            activate
            do script "\(exec)"
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
