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
        let kernel = env["VELOX_KERNEL"].map { URL(fileURLWithPath: $0) } ?? Paths.kernel
        let rootDisk = env["VELOX_ROOT"].map { URL(fileURLWithPath: $0) } ?? Paths.rootDisk
        let cmdline = env["VELOX_CMDLINE"] ?? defaultCommandLine

        guard FileManager.default.fileExists(atPath: kernel.path) else {
            throw VeloxError.guestArtifactMissing(kernel)
        }
        guard FileManager.default.fileExists(atPath: rootDisk.path) else {
            throw VeloxError.guestArtifactMissing(rootDisk)
        }
        return GuestImage(kernelURL: kernel, rootDiskURL: rootDisk, kernelCommandLine: cmdline)
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
