import Foundation

/// Locates the guest kernel/initrd and the kernel command line.
///
/// Defaults live under ~/.velox; each can be overridden by an environment
/// variable so a freshly built (or downloaded) kernel can be tried without
/// touching the install location:
///   VELOX_KERNEL, VELOX_INITRD, VELOX_CMDLINE
public struct GuestImage: Sendable {
    public let kernelURL: URL
    public let initrdURL: URL?
    public let kernelCommandLine: String

    public init(kernelURL: URL, initrdURL: URL?, kernelCommandLine: String) {
        self.kernelURL = kernelURL
        self.initrdURL = initrdURL
        self.kernelCommandLine = kernelCommandLine
    }

    /// `console=hvc0` routes the kernel console to the virtio console device
    /// that VMConfiguration wires to this process's stdout.
    public static let defaultCommandLine = "console=hvc0"

    public static func resolve(environment env: [String: String] = ProcessInfo.processInfo.environment)
        throws -> GuestImage
    {
        let kernel = env["VELOX_KERNEL"].map { URL(fileURLWithPath: $0) } ?? Paths.kernel
        let initrdCandidate = env["VELOX_INITRD"].map { URL(fileURLWithPath: $0) } ?? Paths.initrd
        let cmdline = env["VELOX_CMDLINE"] ?? defaultCommandLine

        guard FileManager.default.fileExists(atPath: kernel.path) else {
            throw VeloxError.guestArtifactMissing(kernel)
        }
        let initrd = FileManager.default.fileExists(atPath: initrdCandidate.path)
            ? initrdCandidate : nil

        return GuestImage(kernelURL: kernel, initrdURL: initrd, kernelCommandLine: cmdline)
    }
}
