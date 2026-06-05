import Foundation
import Virtualization

/// Builds a validated `VZVirtualMachineConfiguration` for the Linux guest.
///
/// Phase 2 covers boot essentials: linux boot loader, serial console, entropy,
/// and a memory balloon. Block/VirtioFS/NAT/VSOCK devices are layered on in
/// later phases.
public enum VMConfiguration {
    public struct Resources: Sendable, Codable, Equatable {
        public var cpuCount: Int
        public var memoryBytes: UInt64
        /// Size of the persistent data disk backing /var/lib/docker.
        public var diskGiB: UInt64

        public init(cpuCount: Int, memoryBytes: UInt64, diskGiB: UInt64 = 16) {
            self.cpuCount = cpuCount
            self.memoryBytes = memoryBytes
            self.diskGiB = diskGiB
        }

        /// Sensible defaults, clamped to the framework's allowed range.
        public static var `default`: Resources {
            Resources(
                cpuCount: max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)),
                memoryBytes: 4 * 1024 * 1024 * 1024, // 4 GiB (headroom for vfs-on-tmpfs)
                diskGiB: 16
            )
        }
    }

    /// Build the VM configuration.
    ///
    /// `extraShares` lists additional host directories to expose to the guest
    /// over VirtioFS (the File Sharing setting). The host `/Users` share is
    /// always present so `docker run -v /Users/…` keeps working.
    public static func build(image: GuestImage,
                             dataDisk: URL? = nil,
                             resources: Resources = .default,
                             extraShares: [URL] = [])
        throws -> VZVirtualMachineConfiguration
    {
        let config = VZVirtualMachineConfiguration()

        config.cpuCount = clampCPUCount(resources.cpuCount)
        config.memorySize = clampMemory(resources.memoryBytes)

        let bootLoader = VZLinuxBootLoader(kernelURL: image.kernelURL)
        // The kernel mounts the read-only erofs root directly off /dev/vda (the
        // first block device attached below) — no initramfs. Apple VZ exposes no
        // RTC, so we also stamp the host's wall-clock as `velox.epoch` (vinit reads
        // it and sets the guest clock first thing; otherwise the guest boots at
        // 1970 and every registry TLS handshake fails).
        bootLoader.commandLine = image.kernelCommandLine
            + " velox.epoch=\(Int(Date().timeIntervalSince1970))"
            + " root=/dev/vda rootfstype=erofs ro init=/sbin/vinit"
        config.bootLoader = bootLoader

        config.serialPorts = [Console.makeSerialPort()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // VSOCK device for the Docker API bridge (host ↔ guest). Only one
        // virtio socket device is allowed per VM.
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // NAT networking for outbound internet (image pulls).
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]

        // Block devices, in order: /dev/vda = the read-only erofs root (the OS),
        // /dev/vdb = the persistent data disk for /var/lib/docker (formatted +
        // mounted in-guest by vinit). Order matters — it defines the device names.
        var storage: [VZStorageDeviceConfiguration] = []
        let rootAttachment = try VZDiskImageStorageDeviceAttachment(url: image.rootDiskURL, readOnly: true)
        storage.append(VZVirtioBlockDeviceConfiguration(attachment: rootAttachment))
        if let dataDisk, FileManager.default.fileExists(atPath: dataDisk.path) {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: dataDisk, readOnly: false)
            storage.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
        }
        config.storageDevices = storage

        var sharingDevices: [VZDirectorySharingDeviceConfiguration] = []

        // VirtioFS: share the host's /Users at the same path in the guest, so
        // `docker run -v /Users/...:/...` resolves transparently (Docker Desktop
        // model). Tag must match the guest VirtioFS mount in vinit.
        let usersURL = URL(fileURLWithPath: "/Users", isDirectory: true)
        if FileManager.default.fileExists(atPath: usersURL.path) {
            let share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: usersURL, readOnly: false))
            let fsDevice = VZVirtioFileSystemDeviceConfiguration(tag: "vlxusers")
            fsDevice.share = share
            sharingDevices.append(fsDevice)
        }

        // User-configured extra shares (File Sharing setting). Each host dir is
        // exposed under its own VirtioFS tag; the guest mounts each tag at its
        // host path (advertised via the kernel cmdline — see velox.yml).
        for advert in shareAdvertisement(for: extraShares) {
            let url = URL(fileURLWithPath: advert.path, isDirectory: true)
            let share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: url, readOnly: false))
            let fsDevice = VZVirtioFileSystemDeviceConfiguration(tag: advert.tag)
            fsDevice.share = share
            sharingDevices.append(fsDevice)
        }

        // Rosetta: expose the x86-64 translation runtime as a VirtioFS share so
        // the guest can run linux/amd64 images (binfmt registered in-guest).
        switch VZLinuxRosettaDirectoryShare.availability {
        case .installed:
            do {
                let rosetta = try VZLinuxRosettaDirectoryShare()
                let fsRosetta = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                fsRosetta.share = rosetta
                sharingDevices.append(fsRosetta)
            } catch {
                Log.warn("Rosetta share unavailable: \(error.localizedDescription)")
            }
        case .notInstalled:
            Log.info("Rosetta not installed — x86 emulation off (run: softwareupdate --install-rosetta)")
        case .notSupported:
            break
        @unknown default:
            break
        }

        config.directorySharingDevices = sharingDevices

        do {
            try config.validate()
        } catch {
            throw VeloxError.configurationInvalid(error.localizedDescription)
        }
        return config
    }

    private static func clampCPUCount(_ requested: Int) -> Int {
        min(max(requested, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
            VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    }

    private static func clampMemory(_ requested: UInt64) -> UInt64 {
        min(max(requested, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
            VZVirtualMachineConfiguration.maximumAllowedMemorySize)
    }

    /// Resolve the user's extra file shares into (tag, path) pairs, filtering out
    /// nonexistent dirs and anything already covered by the `/Users` share. Both
    /// the host VirtioFS devices and the guest mount cmdline derive from this, so
    /// their tags always agree.
    public static func shareAdvertisement(for shares: [URL]) -> [(tag: String, path: String)] {
        var seen = Set<String>()
        var result: [(tag: String, path: String)] = []
        for dir in shares {
            let path = dir.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path),
                  path != "/Users", !path.hasPrefix("/Users/"),
                  seen.insert(path).inserted else { continue }
            result.append((shareTag(for: path), path))
        }
        return result
    }

    /// A stable, valid VirtioFS tag (≤36 chars) derived from a host path. The
    /// guest mounts by this same tag, so it must be deterministic across runs —
    /// hence a fixed djb2 hash rather than Swift's per-process `Hasher`.
    static func shareTag(for path: String) -> String {
        var hash: UInt64 = 5381
        for byte in path.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return "vlx" + String(hash, radix: 36)
    }
}
