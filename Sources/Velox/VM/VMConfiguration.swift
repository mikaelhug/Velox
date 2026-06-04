import Foundation
import Virtualization

/// Builds a validated `VZVirtualMachineConfiguration` for the Linux guest.
///
/// Phase 2 covers boot essentials: linux boot loader, serial console, entropy,
/// and a memory balloon. Block/VirtioFS/NAT/VSOCK devices are layered on in
/// later phases.
enum VMConfiguration {
    struct Resources {
        var cpuCount: Int
        var memoryBytes: UInt64

        /// Sensible defaults, clamped to the framework's allowed range.
        static var `default`: Resources {
            Resources(
                cpuCount: max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)),
                memoryBytes: 4 * 1024 * 1024 * 1024 // 4 GiB (headroom for vfs-on-tmpfs)
            )
        }
    }

    static func build(image: GuestImage, dataDisk: URL? = nil, resources: Resources = .default)
        throws -> VZVirtualMachineConfiguration
    {
        let config = VZVirtualMachineConfiguration()

        config.cpuCount = clampCPUCount(resources.cpuCount)
        config.memorySize = clampMemory(resources.memoryBytes)

        let bootLoader = VZLinuxBootLoader(kernelURL: image.kernelURL)
        bootLoader.commandLine = image.kernelCommandLine
        if let initrd = image.initrdURL {
            bootLoader.initialRamdiskURL = initrd
        }
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

        // Persistent data disk for /var/lib/docker (formatted/mounted in-guest).
        if let dataDisk, FileManager.default.fileExists(atPath: dataDisk.path) {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: dataDisk, readOnly: false)
            config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        }

        var sharingDevices: [VZDirectorySharingDeviceConfiguration] = []

        // VirtioFS: share the host's /Users at the same path in the guest, so
        // `vlcmd run -v /Users/...:/...` resolves transparently (Docker Desktop
        // model). Tag must match the guest mount command in velox.yml.
        let usersURL = URL(fileURLWithPath: "/Users", isDirectory: true)
        if FileManager.default.fileExists(atPath: usersURL.path) {
            let share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: usersURL, readOnly: false))
            let fsDevice = VZVirtioFileSystemDeviceConfiguration(tag: "vlxusers")
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
}
