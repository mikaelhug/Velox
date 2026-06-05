import Foundation

/// Locates the guest kernel + read-only erofs root disk and the kernel command line.
///
/// Defaults live under ~/.velox; each can be overridden by an environment
/// variable so a freshly built kernel/root can be tried without touching the
/// install location: VELOX_KERNEL, VELOX_ROOT, VELOX_CMDLINE.
public struct GuestImage: Sendable {
    public let kernelURL: URL
    /// The erofs root filesystem image, attached read-only as /dev/vda.
    public let rootDiskURL: URL
    public let kernelCommandLine: String

    public init(kernelURL: URL, rootDiskURL: URL, kernelCommandLine: String) {
        self.kernelURL = kernelURL
        self.rootDiskURL = rootDiskURL
        self.kernelCommandLine = kernelCommandLine
    }

    /// `console=hvc0` routes the kernel console to the virtio console device
    /// that VMConfiguration wires to this process's stdout. The `root=` params
    /// (erofs on /dev/vda) are appended by `VMConfiguration.build`, which owns
    /// the disk ordering.
    public static let defaultCommandLine = "console=hvc0"

    public static func resolve(environment env: [String: String] = ProcessInfo.processInfo.environment)
        throws -> GuestImage
    {
        let kernel = try locate("VELOX_KERNEL", env: env, installed: Paths.kernel, bundled: "kernel")
        let rootDisk = try locate("VELOX_ROOT", env: env, installed: Paths.rootDisk, bundled: "root.img")
        let cmdline = env["VELOX_CMDLINE"] ?? defaultCommandLine
        return GuestImage(kernelURL: kernel, rootDiskURL: rootDisk, kernelCommandLine: cmdline)
    }

    /// Resolve a guest artifact in priority order so the same code works in dev and
    /// for a shipped `.app`:
    ///  1. an explicit env override (dev: try a freshly built kernel/root in place),
    ///  2. the installed copy under `~/.velox` (written by `make-guest.sh` or an update),
    ///  3. the copy bundled inside `Velox.app/Contents/Resources` (a downloaded release
    ///     is self-contained — no `make-guest.sh` required on the user's machine).
    private static func locate(_ envKey: String, env: [String: String],
                               installed: URL, bundled name: String) throws -> URL {
        let fm = FileManager.default
        if let path = env[envKey] {
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: url.path) else { throw VeloxError.guestArtifactMissing(url) }
            return url
        }
        if fm.fileExists(atPath: installed.path) { return installed }
        // GUI app: VeloxApp is in Contents/MacOS, so Resources/<name> is the bundle copy.
        if let res = Bundle.main.resourceURL?.appendingPathComponent(name),
           fm.fileExists(atPath: res.path) { return res }
        // CLI shipped inside the .app (Contents/Resources/bin/velox): the artifacts sit
        // one directory up, in Contents/Resources.
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let up = execDir.deletingLastPathComponent().appendingPathComponent(name)
            if fm.fileExists(atPath: up.path) { return up }
        }
        throw VeloxError.guestArtifactMissing(installed)
    }

    /// Return a copy whose command line advertises `shares` to the guest as
    /// `velox.shares=<base64 of "tag\tpath\n"…>`, so vinit mounts each VirtioFS
    /// tag at its host path. The host attaches the matching devices in
    /// `VMConfiguration.build(extraShares:)`, which derives tags from the same
    /// `shareAdvertisement`, so the two always agree. Both the CLI and the GUI
    /// call this — keep the share-advertising logic here, not in either front end.
    public func advertising(shares: [URL]) -> GuestImage {
        let adverts = VMConfiguration.shareAdvertisement(for: shares)
        guard !adverts.isEmpty else { return self }
        let payload = adverts.map { "\($0.tag)\t\($0.path)" }.joined(separator: "\n")
        let encoded = Data(payload.utf8).base64EncodedString()
        return GuestImage(kernelURL: kernelURL, rootDiskURL: rootDiskURL,
                          kernelCommandLine: kernelCommandLine + " velox.shares=\(encoded)")
    }
}
