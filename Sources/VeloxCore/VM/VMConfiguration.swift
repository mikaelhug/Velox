import Foundation
import Virtualization

/// Builds a validated `VZVirtualMachineConfiguration` for the Linux guest: the linux
/// boot loader, serial console, entropy source, memory balloon, root + data block
/// devices, VirtioFS shares, VZNAT networking, and the VSOCK device.
public enum VMConfiguration {
    public struct Resources: Sendable, Codable, Equatable {
        public var cpuCount: Int
        public var memoryBytes: UInt64
        /// Size of the persistent data disk backing /var/lib/docker.
        public var diskGiB: UInt64
        /// Guest swap file size in MiB (0 = no swap). vinit creates a swapfile of
        /// this size on the data disk and `swapon`s it; advertised via the kernel
        /// cmdline as `velox.swap=<MiB>`.
        public var swapMiB: UInt64

        public init(cpuCount: Int, memoryBytes: UInt64, diskGiB: UInt64 = 64, swapMiB: UInt64 = 1024) {
            self.cpuCount = cpuCount
            self.memoryBytes = memoryBytes
            self.diskGiB = diskGiB
            self.swapMiB = swapMiB
        }

        /// Sensible defaults, clamped to the framework's allowed range.
        public static var `default`: Resources {
            Resources(
                cpuCount: max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)),
                memoryBytes: 4 * 1024 * 1024 * 1024, // 4 GiB (headroom for vfs-on-tmpfs)
                // The data disk is a sparse ASIF image — it only consumes host space as
                // the guest writes to it — so a generous default is ~free and avoids
                // boxing users into an early "no space left on device". Changing this in
                // config re-sizes the ext4 on next start (via `velox.disk` → vinit's
                // planned_resize): raising grows it, lowering shrinks it (down to the
                // used space). The sparse ASIF image only ever grows; a shrink just
                // trims the filesystem inside it, which costs nothing.
                diskGiB: 64,
                swapMiB: 1024
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
                             extraShares: [URL] = [],
                             consoleOutput: FileHandle? = nil)
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
        var cmdline = image.kernelCommandLine
            + " velox.epoch=\(Int(Date().timeIntervalSince1970))"
            + (resources.swapMiB > 0 ? " velox.swap=\(resources.swapMiB)" : "")
            // Target data-disk size. vinit resizes the ext4 to match — growing online
            // after mount, or shrinking offline (e2fsck + resize2fs) before mount, since
            // ext4 can only be shrunk while unmounted. Lowering diskGiB therefore
            // actually reduces the filesystem (matching Docker Desktop's behaviour); the
            // sparse ASIF image stays at its high-water mark, which costs no host space.
            + " velox.disk=\(resources.diskGiB)"
            + " root=/dev/vda rootfstype=erofs ro init=/sbin/vinit"
            // Expedited RCU grace periods. Every `docker run --rm` tears down a veth pair
            // + network namespace, and each deletion makes in-kernel synchronize_net()
            // calls that otherwise block on a *normal* RCU grace period (several ms each).
            // Expedited forces them via IPIs in ~µs — measured to cut `docker run` latency
            // ~23% (≈117 → 93 ms) on this 8-vCPU guest, almost all of it container teardown.
            // Standard container-host tuning; the cost is a few extra IPIs, negligible for
            // an interactive dev engine where launch latency is the metric that matters.
            + " rcupdate.rcu_expedited=1"
        // Optional host-supplied extra kernel parameters, appended LAST so a
        // duplicated key overrides the defaults (kernel takes the last value).
        // Used for scheduler A/B tuning, e.g. VELOX_KCMDLINE_EXTRA="preempt=full".
        if let extra = ProcessInfo.processInfo.environment["VELOX_KCMDLINE_EXTRA"]?
            .trimmingCharacters(in: .whitespaces), !extra.isEmpty {
            cmdline += " " + extra
        }
        bootLoader.commandLine = cmdline
        config.bootLoader = bootLoader

        config.serialPorts = [Console.makeSerialPort(write: consoleOutput ?? .standardOutput)]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // VSOCK device for the Docker API bridge (host ↔ guest). Only one
        // virtio socket device is allowed per VM.
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // Container data network: Apple's in-kernel NAT (vmnet). This is the
        // fastest datapath on Virtualization.framework — GSO/segmentation offload
        // in the kernel — measured >80 Gbit/s up, >13 Gbit/s down, beating Docker
        // Desktop. The host reaches the guest's vmnet IP directly (port forwarding)
        // and host.docker.internal resolves to the vmnet gateway (dockerd
        // --host-gateway-ip, set by vinit). A userspace stack (smoltcp over a
        // file-handle device) was prototyped but is ~6x slower on this datapath.
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]

        // Block devices, in order: /dev/vda = the read-only erofs root (the OS),
        // /dev/vdb = the persistent data disk for /var/lib/docker (formatted +
        // mounted in-guest by vinit). Order matters — it defines the device names.
        var storage: [VZStorageDeviceConfiguration] = []
        // Cache the read-only erofs root in the host page cache: dockerd / containerd /
        // runc / containerd-shim are demand-paged from here and re-read on every single
        // container spawn, so keeping their hot pages in host RAM avoids re-reading (and
        // re-decompressing) the image each time. `.none` sync — there are no writes.
        let rootAttachment = try VZDiskImageStorageDeviceAttachment(
            url: image.rootDiskURL, readOnly: true,
            cachingMode: .cached, synchronizationMode: .none)
        storage.append(VZVirtioBlockDeviceConfiguration(attachment: rootAttachment))
        if let dataDisk, FileManager.default.fileExists(atPath: dataDisk.path) {
            // /var/lib/docker is the hot path for `docker run` and for any IO/DB
            // workload in a container: each guest fsync → ext4 barrier → virtio FLUSH.
            // `.cached` keeps the disk in the host page cache; `synchronizationMode`
            // decides what a guest flush costs:
            //   .fsync → a real host fsync() per flush — durable across a host crash, but
            //            on macOS APFS that's ~2–4 ms each, so durable commits cap at a
            //            few hundred/s (Postgres pgbench, image unpacks, etc. crawl).
            //   .none  → acknowledge the flush from the host page cache, no per-flush host
            //            sync (a writeback cache). ~18× faster commits. This is exactly
            //            what Docker Desktop does — measured on this Mac: DD 131 µs/commit
            //            vs a real native macOS fsync at 3.9 ms (i.e. DD is *not* durably
            //            syncing). Velox `.fsync` was 2.3 ms.
            // Velox is a *development* engine (containers/images/volumes are recreatable
            // dev state, not a system of record), so we match DD and take `.none`: speed
            // over per-commit durability. Risk window = an unclean *host* shutdown (power
            // loss / host kernel panic) loses the last unflushed writes; a guest crash or
            // a clean Velox quit is safe — graceful stop sync's the guest, and the host
            // page cache survives the VM teardown for macOS to flush.
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: dataDisk, readOnly: false,
                cachingMode: .cached, synchronizationMode: .none)
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
        // host path (the tag→path map is advertised on the kernel cmdline as
        // `velox.shares=<base64>` — assembled in EngineController, read by vinit).
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
                // Persist Rosetta's ahead-of-time translation cache across runs via a
                // host-side cache daemon on a unix socket, so x86-64 binaries aren't
                // re-translated every launch (Docker-Desktop parity). The caching
                // classes/property are NS_REFINED_FOR_SWIFT with no overlay in the
                // Command-Line-Tools SDK, so they import under their __-prefixed
                // names — functionally identical, and the spelling is guaranteed by
                // the refinement contract.
                let cacheSock = Paths.root.appendingPathComponent("rosetta.sock")
                do {
                    rosetta.__options = try __VZLinuxRosettaUnixSocketCachingOptions(path: cacheSock.path)
                    Log.info("Rosetta translation cache: \(cacheSock.path)")
                } catch {
                    Log.warn("Rosetta cache off (translations won't persist): \(error.localizedDescription)")
                }
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
