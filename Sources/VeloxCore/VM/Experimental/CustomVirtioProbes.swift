import Foundation
import Darwin
@preconcurrency import Virtualization

// EXPERIMENTAL — macOS 27 `VZCustomVirtioDevice` feasibility probes (perf/orbstack-gap).
//
// Two questions decide whether Velox can match OrbStack's file-sharing and memory moats
// without leaving Virtualization.framework:
//   1. ProbeFS: what does a virtqueue round-trip through a *custom* device cost (guest notify →
//      VZ → this process's delegate → reply → interrupt)? A minimal virtio-fs (ID 26) device
//      with a FUSE passthrough server over a host directory, so the same guest workload can be
//      timed against Apple's VirtioFS (/Users) and OrbStack.
//   2. ProbeBalloon: can this process release guest RAM from the host? A virtio-balloon (ID 5)
//      whose inflate queue madvise()s the guest pages through VZGuestMemoryMapping.
//
// Off unless VELOX_EXPERIMENT_VFS=<host dir> / VELOX_EXPERIMENT_BALLOON=1 is set. Not wired into
// any release path; it is a measuring instrument, deleted or rewritten once the answers are in.

public enum CustomVirtioProbes {
    /// Strong references: VZ holds both delegates weakly.
    nonisolated(unsafe) static var retained: [AnyObject] = []

    public static func configure(_ config: VZVirtualMachineConfiguration) {
        guard #available(macOS 27.0, *) else { return }
        let env = ProcessInfo.processInfo.environment
        var devices: [VZCustomVirtioDeviceConfiguration] = []
        if let dir = env["VELOX_EXPERIMENT_VFS"], !dir.isEmpty {
            let queues = UInt16(env["VELOX_EXPERIMENT_VFS_QUEUES"].flatMap(Int.init) ?? 1)
            let fs = ProbeFS(root: dir, tag: env["VELOX_EXPERIMENT_VFS_TAG"] ?? "vlxprobe",
                             requestQueues: queues,
                             parallel: env["VELOX_EXPERIMENT_VFS_PARALLEL"] == "1",
                             cacheSeconds: env["VELOX_EXPERIMENT_VFS_CACHE"].flatMap(UInt64.init) ?? 0,
                             writeback: env["VELOX_EXPERIMENT_VFS_WRITEBACK"] == "1")
            retained.append(fs)
            devices.append(fs.makeConfiguration())
            probeLog("vfs: tag=\(fs.tag) root=\(dir) queues=\(queues)")
        }
        if env["VELOX_EXPERIMENT_BALLOON"] == "1" {
            let b = ProbeBalloon()
            retained.append(b)
            devices.append(b.makeConfiguration())
            // One page-reporting registrant / one balloon: drop Apple's for the probe.
            config.memoryBalloonDevices = []
            probeLog("balloon: custom device replaces Apple's traditional balloon")
        }
        if !devices.isEmpty { config.customVirtioDevices = devices }
    }
}

func probeLog(_ s: String) {
    FileHandle.standardError.write(Data("[velox-probe] \(s)\n".utf8))
}

// MARK: - little-endian wire helpers

struct WireReader {
    let d: Data
    var o = 0
    init(_ d: Data) { self.d = d }
    mutating func u16() -> UInt16 { let v = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) }; o += 2; return UInt16(littleEndian: v) }
    mutating func u32() -> UInt32 { let v = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }; o += 4; return UInt32(littleEndian: v) }
    mutating func u64() -> UInt64 { let v = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) }; o += 8; return UInt64(littleEndian: v) }
    mutating func skip(_ n: Int) { o += n }
    var remaining: Int { d.count - o }
    /// NUL-terminated string at the cursor.
    mutating func cstr() -> String {
        let rest = d[d.startIndex + o ..< d.endIndex]
        let end = rest.firstIndex(of: 0) ?? rest.endIndex
        let s = String(decoding: rest[rest.startIndex ..< end], as: UTF8.self)
        o += (end - rest.startIndex) + 1
        return s
    }
    func bytes(from: Int, count: Int) -> Data { d.subdata(in: d.startIndex + from ..< d.startIndex + from + count) }
}

struct WireWriter {
    var d = Data()
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    mutating func i32(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    mutating func zeros(_ n: Int) { d.append(Data(count: n)) }
    mutating func raw(_ x: Data) { d.append(x) }
}

/// macOS errno → Linux errno. FUSE replies carry the guest's (Linux) numbering; the two differ
/// above 34 (ENOSYS is 78 on macOS, 38 on Linux — sending 78 made the guest retry GETXATTR on
/// every write instead of caching "unsupported").
func linuxErrno(_ e: Int32) -> Int32 {
    switch e {
    case ENOSYS: return 38
    case EDEADLK: return 35
    case ENAMETOOLONG: return 36
    case ENOLCK: return 37
    case ENOTEMPTY: return 39
    case ELOOP: return 40
    case ENOATTR: return 61          // ENODATA
    case ENOTSUP, EOPNOTSUPP: return 95
    case EADDRINUSE: return 98
    case ENOTSOCK: return 88
    case EDQUOT: return 122
    case ESTALE: return 116
    case ETIMEDOUT: return 110
    case EOVERFLOW: return 75
    case EILSEQ: return 84
    case ECANCELED: return 125
    case EAGAIN: return 11
    default: return e <= 34 ? e : 5    // 1…34 match; anything else unmapped → EIO
    }
}

// MARK: - ProbeFS: virtio-fs device + minimal FUSE passthrough server

@available(macOS 27.0, *)
final class ProbeFS: NSObject, VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate, @unchecked Sendable {
    let root: String
    let tag: String
    let requestQueues: UInt16
    let parallel: Bool
    let cacheSeconds: UInt64
    let writeback: Bool
    let negative = ProcessInfo.processInfo.environment["VELOX_EXPERIMENT_VFS_NEG"] == "1"
    let noFlush = ProcessInfo.processInfo.environment["VELOX_EXPERIMENT_VFS_NOFLUSH"] == "1"
    /// Adaptive busy-poll window: after draining, keep calling nextElement() for this long so a
    /// request that arrives right behind the reply is picked up from the ring without waiting for
    /// the guest kick → VZ → XPC → delegate notification path.
    let spinNs = UInt64(ProcessInfo.processInfo.environment["VELOX_EXPERIMENT_VFS_SPIN_US"].flatMap(Int.init) ?? 0) * 1000
    let queue = DispatchQueue(label: "dev.velox.probe.vfs")
    let workers = DispatchQueue(label: "dev.velox.probe.vfs.workers", attributes: .concurrent)

    // nodeid ↔ path. 1 = root. Guarded by `lock` (parallel mode touches it from workers).
    private let lock = NSLock()
    private var paths: [UInt64: String] = [:]
    private var ids: [String: UInt64] = [:]
    private var nextID: UInt64 = 2
    private var fds: [UInt64: Int32] = [:]
    private var dirs: [UInt64: String] = [:]
    private var nextFH: UInt64 = 1
    private var ops = 0
    private var traceLookups = Int(ProcessInfo.processInfo.environment["VELOX_EXPERIMENT_VFS_TRACE"] ?? "0") ?? 0
    private var hist: [UInt32: Int] = [:]
    private var opNs: [UInt32: UInt64] = [:]

    init(root: String, tag: String, requestQueues: UInt16, parallel: Bool, cacheSeconds: UInt64, writeback: Bool) {
        self.root = (root as NSString).standardizingPath
        self.tag = tag
        self.requestQueues = max(1, requestQueues)
        self.parallel = parallel
        self.cacheSeconds = cacheSeconds
        self.writeback = writeback
        super.init()
        paths[1] = self.root
        ids[self.root] = 1
    }

    func makeConfiguration() -> VZCustomVirtioDeviceConfiguration {
        let c = VZCustomVirtioDeviceConfiguration()
        c.deviceID = 26                     // virtio-fs
        c.pciClassID = 0x01                 // mass storage
        c.pciSubclassID = 0x80              // other
        c.virtioQueueCount = 1 + requestQueues   // hiprio + request queues
        var cfg = Data(count: 36)
        let t = Array(tag.utf8.prefix(36))
        cfg.replaceSubrange(0 ..< t.count, with: t)
        var w = WireWriter(); w.u32(UInt32(requestQueues)); cfg.append(w.d)
        c.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(configurationData: cfg)
        c.provider = VZCustomVirtioDeviceDelegateProvider(deviceQueue: queue, delegate: self)
        return c
    }

    @objc(customVirtioConfiguration:didCreateDevice:)
    func customVirtioConfiguration(_ deviceConfiguration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice) {
        device.delegate = self
        probeLog("vfs: device created")
    }

    @objc(customVirtioDeviceDidAcceptDriverOk:)
    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        probeLog("vfs: DRIVER_OK features=\(String(device.negotiatedFeatures?.subset0 ?? 0, radix: 16))")
    }

    // Timing: notifications, elements, and time spent inside serve() — separates our handler cost
    // from VZ's transport cost. Logged every 2000 elements.
    private var notes = 0, elems = 0, serveNs: UInt64 = 0, lastNote: UInt64 = 0, gapNs: UInt64 = 0
    private var pureNs: UInt64 = 0, retNs: UInt64 = 0, turnNs: UInt64 = 0, turns = 0, lastReturn: UInt64 = 0
    @objc(customVirtioDevice:didReceiveNotificationForQueue:)
    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        if lastNote != 0 { gapNs += t0 - lastNote }
        notes += 1
        defer {
            lastNote = DispatchTime.now().uptimeNanoseconds
            serveNs += lastNote - t0
            if false, elems >= 2000 {
                probeLog("vfs: \(elems) elems / \(notes) notifications, handler \(serveNs / UInt64(elems) / 1000) us/elem, notify-to-notify gap \(gapNs / UInt64(max(notes - 1, 1)) / 1000) us")
                lock.lock(); let h = hist.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "); hist = [:]; lock.unlock()
                probeLog("vfs: opcodes \(h)")
                elems = 0; notes = 0; serveNs = 0; gapNs = 0
            }
        }
        var idleSince = DispatchTime.now().uptimeNanoseconds
        while true {
            if let el = queue.nextElement() {
                let a = DispatchTime.now().uptimeNanoseconds
                if spinNs > 0 && lastReturn != 0 && a - lastReturn < spinNs { turnNs += a - lastReturn; turns += 1 }
                elems += 1
                if parallel {
                    workers.async { self.serve(el); el.returnToQueue() }
                } else {
                    serve(el)
                    let b = DispatchTime.now().uptimeNanoseconds
                    pureNs += b - a
                    el.returnToQueue()
                    lastReturn = DispatchTime.now().uptimeNanoseconds
                    retNs += lastReturn - b
                }
                idleSince = DispatchTime.now().uptimeNanoseconds
                if elems % 10000 == 0 {
                    probeLog("vfs: via-notify \(notes) serve \(pureNs / 10000 / 1000) us, returnToQueue \(retNs / 10000 / 1000) us, turnaround(reply→next req) \(turns > 0 ? turnNs / UInt64(turns) / 1000 : 0) us over \(turns)")
                    pureNs = 0; retNs = 0; turnNs = 0; turns = 0; notes = 0
                    lock.lock(); let h = hist.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)@\((opNs[$0.key] ?? 0) / UInt64($0.value) / 1000)us" }.joined(separator: " "); hist = [:]; opNs = [:]; lock.unlock()
                    probeLog("vfs: opcodes \(h)")
                }
                continue
            }
            if spinNs == 0 || DispatchTime.now().uptimeNanoseconds - idleSince > spinNs { break }
        }
    }

    // MARK: request dispatch

    private func serve(_ el: VZVirtioQueueElement) {
        let req = el.readBuffers().reduce(into: Data()) { $0.append($1) }
        guard req.count >= 40 else { return }
        var r = WireReader(req)
        _ = r.u32()                       // len
        let opcode = r.u32()
        let unique = r.u64()
        let nodeid = r.u64()
        r.skip(16)                        // uid gid pid total_extlen padding
        let t0 = DispatchTime.now().uptimeNanoseconds
        let (err, body): (Int32, Data?) = handle(opcode: opcode, nodeid: nodeid, r: &r)
        let dt = DispatchTime.now().uptimeNanoseconds - t0
        lock.lock(); hist[opcode, default: 0] += 1; opNs[opcode, default: 0] += dt; lock.unlock()
        if opcode == 2 || opcode == 42 { return }       // FORGET / BATCH_FORGET: no reply
        var w = WireWriter()
        let payload = err == 0 ? (body ?? Data()) : Data()
        w.u32(UInt32(16 + payload.count)); w.i32(err == 0 ? 0 : -linuxErrno(err)); w.u64(unique)
        w.raw(payload)
        let out = w.d.count <= el.writeBuffersAvailableByteCount ? w.d : w.d.prefix(el.writeBuffersAvailableByteCount)
        _ = try? el.write(Data(out))
    }

    private func path(_ id: UInt64) -> String? { lock.lock(); defer { lock.unlock() }; return paths[id] }
    private func intern(_ p: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        if let id = ids[p] { return id }
        let id = nextID; nextID += 1; ids[p] = id; paths[id] = p; return id
    }

    private func attr(_ st: stat, _ w: inout WireWriter) {
        w.u64(UInt64(st.st_ino)); w.u64(UInt64(st.st_size)); w.u64(UInt64(st.st_blocks))
        w.u64(UInt64(st.st_atimespec.tv_sec)); w.u64(UInt64(st.st_mtimespec.tv_sec)); w.u64(UInt64(st.st_ctimespec.tv_sec))
        w.u32(UInt32(st.st_atimespec.tv_nsec)); w.u32(UInt32(st.st_mtimespec.tv_nsec)); w.u32(UInt32(st.st_ctimespec.tv_nsec))
        w.u32(UInt32(st.st_mode)); w.u32(UInt32(st.st_nlink)); w.u32(st.st_uid); w.u32(st.st_gid)
        w.u32(UInt32(bitPattern: st.st_rdev)); w.u32(UInt32(st.st_blksize)); w.u32(0)
    }
    private func entry(_ p: String) -> (Int32, Data?) {
        var st = stat()
        if lstat(p, &st) != 0 { return (errno, nil) }
        var w = WireWriter()
        w.u64(intern(p)); w.u64(0); w.u64(cacheSeconds); w.u64(cacheSeconds); w.u32(0); w.u32(0)
        attr(st, &w)
        return (0, w.d)
    }
    private func attrOut(_ p: String) -> (Int32, Data?) {
        var st = stat()
        if lstat(p, &st) != 0 { return (errno, nil) }
        var w = WireWriter(); w.u64(cacheSeconds); w.u32(0); w.u32(0); attr(st, &w)
        return (0, w.d)
    }
    private func newFH(_ fd: Int32) -> UInt64 { lock.lock(); defer { lock.unlock() }; let h = nextFH; nextFH += 1; fds[h] = fd; return h }
    private func fd(_ fh: UInt64) -> Int32? { lock.lock(); defer { lock.unlock() }; return fds[fh] }
    private func closeFH(_ fh: UInt64) { lock.lock(); let f = fds.removeValue(forKey: fh); lock.unlock(); if let f { close(f) } }
    private func linuxFlags(_ f: UInt32) -> Int32 {
        var o: Int32 = 0
        switch f & 3 { case 1: o = O_WRONLY; case 2: o = O_RDWR; default: o = O_RDONLY }
        if f & 0o100 != 0 { o |= O_CREAT }
        if f & 0o200 != 0 { o |= O_EXCL }
        if f & 0o1000 != 0 { o |= O_TRUNC }
        if f & 0o2000 != 0 { o |= O_APPEND }
        return o
    }

    private func handle(opcode: UInt32, nodeid: UInt64, r: inout WireReader) -> (Int32, Data?) {
        switch opcode {
        case 26: // INIT
            let major = r.u32(); let minor = r.u32(); _ = r.u32(); let flags = r.u32()
            var want: UInt32 = (1 << 0) | (1 << 3) | (1 << 5) | (1 << 13) | (1 << 18) | (1 << 22) // ASYNC_READ ATOMIC_O_TRUNC BIG_WRITES DO_READDIRPLUS PARALLEL_DIROPS MAX_PAGES
            if writeback { want |= (1 << 16) }
            var w = WireWriter()
            w.u32(major); w.u32(min(minor, 41)); w.u32(1 << 20); w.u32(flags & want)
            w.u16(64); w.u16(48); w.u32(1 << 20); w.u32(1); w.u16(256); w.u16(0); w.u32(0); w.u32(0); w.u16(0)
            w.zeros(22)
            probeLog("vfs: INIT \(major).\(minor) guest-flags=\(String(flags, radix: 16)) granted=\(String(flags & want, radix: 16))")
            return (0, w.d)
        case 1: // LOOKUP
            guard let dir = path(nodeid) else { return (ENOENT, nil) }
            let nm = r.cstr()
            if traceLookups > 0 { traceLookups -= 1; probeLog("vfs: LOOKUP parent=\(nodeid) name=\(nm)") }
            let res = entry(dir + "/" + nm)
            if res.0 == ENOENT && negative {
                // Negative dentry: nodeid 0 + entry_valid caches "doesn't exist" in the guest.
                var w = WireWriter(); w.u64(0); w.u64(0); w.u64(cacheSeconds); w.u64(0); w.u32(0); w.u32(0); w.zeros(88)
                return (0, w.d)
            }
            return res
        case 2, 42: return (0, nil) // FORGET, BATCH_FORGET (probe keeps ids forever)
        case 3: // GETATTR
            guard let p = path(nodeid) else { return (ENOENT, nil) }
            return attrOut(p)
        case 4: // SETATTR
            guard let p = path(nodeid) else { return (ENOENT, nil) }
            let valid = r.u32(); _ = r.u32(); let fh = r.u64(); let size = r.u64(); _ = r.u64()
            let atime = r.u64(); let mtime = r.u64(); _ = r.u64()
            let atimens = r.u32(); let mtimens = r.u32(); _ = r.u32(); let mode = r.u32(); _ = r.u32()
            if valid & (1 << 0) != 0 { chmod(p, mode_t(mode & 0o7777)) }
            if valid & (1 << 3) != 0 { if let f = fd(fh), valid & (1 << 3) != 0, fh != 0 { ftruncate(f, off_t(size)) } else { truncate(p, off_t(size)) } }
            if valid & ((1 << 4) | (1 << 5)) != 0 {
                var ts = [timespec(tv_sec: Int(atime), tv_nsec: Int(atimens)), timespec(tv_sec: Int(mtime), tv_nsec: Int(mtimens))]
                if valid & (1 << 4) == 0 { ts[0].tv_nsec = Int(UTIME_OMIT) }
                if valid & (1 << 5) == 0 { ts[1].tv_nsec = Int(UTIME_OMIT) }
                if valid & (1 << 7) != 0 { ts[0].tv_nsec = Int(UTIME_NOW) }
                if valid & (1 << 8) != 0 { ts[1].tv_nsec = Int(UTIME_NOW) }
                utimensat(AT_FDCWD, p, &ts, AT_SYMLINK_NOFOLLOW)
            }
            return attrOut(p)
        case 5: // READLINK
            guard let p = path(nodeid) else { return (ENOENT, nil) }
            var buf = [CChar](repeating: 0, count: 4096)
            let n = readlink(p, &buf, 4096)
            if n < 0 { return (errno, nil) }
            return (0, Data(bytes: buf, count: n))
        case 6: // SYMLINK: name\0 target\0
            guard let dir = path(nodeid) else { return (ENOENT, nil) }
            let name = r.cstr(); let target = r.cstr()
            if symlink(target, dir + "/" + name) != 0 { return (errno, nil) }
            return entry(dir + "/" + name)
        case 9: // MKDIR
            guard let dir = path(nodeid) else { return (ENOENT, nil) }
            let mode = r.u32(); _ = r.u32(); let name = r.cstr()
            if mkdir(dir + "/" + name, mode_t(mode & 0o7777)) != 0 { return (errno, nil) }
            return entry(dir + "/" + name)
        case 10, 11: // UNLINK, RMDIR
            guard let dir = path(nodeid) else { return (ENOENT, nil) }
            let p = dir + "/" + r.cstr()
            if (opcode == 10 ? unlink(p) : rmdir(p)) != 0 { return (errno, nil) }
            return (0, nil)
        case 12, 45: // RENAME, RENAME2
            guard let dir = path(nodeid) else { return (ENOENT, nil) }
            let newdir = r.u64(); if opcode == 45 { r.skip(8) }
            let old = r.cstr(); let new = r.cstr()
            guard let nd = path(newdir) else { return (ENOENT, nil) }
            let from = dir + "/" + old, to = nd + "/" + new
            if rename(from, to) != 0 { return (errno, nil) }
            lock.lock(); if let id = ids.removeValue(forKey: from) { ids[to] = id; paths[id] = to }; lock.unlock()
            return (0, nil)
        case 13: // LINK
            guard let dir = path(nodeid) else { return (ENOENT, nil) }
            let old = r.u64(); let name = r.cstr()
            guard let src = path(old) else { return (ENOENT, nil) }
            if link(src, dir + "/" + name) != 0 { return (errno, nil) }
            return entry(dir + "/" + name)
        case 14: // OPEN
            guard let p = path(nodeid) else { return (ENOENT, nil) }
            let flags = r.u32()
            let f = open(p, linuxFlags(flags) & ~(O_CREAT | O_EXCL))
            if f < 0 { return (errno, nil) }
            var w = WireWriter(); w.u64(newFH(f)); w.u32(cacheSeconds > 0 ? (1 << 1) : 0); w.u32(0) // FOPEN_KEEP_CACHE
            return (0, w.d)
        case 15: // READ
            let fh = r.u64(); let off = r.u64(); let size = r.u32()
            guard let f = fd(fh) else { return (EBADF, nil) }
            var buf = Data(count: Int(size))
            let n = buf.withUnsafeMutableBytes { pread(f, $0.baseAddress, Int(size), off_t(off)) }
            if n < 0 { return (errno, nil) }
            return (0, buf.prefix(n))
        case 16: // WRITE
            let fh = r.u64(); let off = r.u64(); let size = r.u32(); r.skip(4 + 8 + 8)
            guard let f = fd(fh) else { return (EBADF, nil) }
            let data = r.bytes(from: r.o, count: min(Int(size), r.remaining))
            let n = data.withUnsafeBytes { pwrite(f, $0.baseAddress, data.count, off_t(off)) }
            if n < 0 { return (errno, nil) }
            var w = WireWriter(); w.u32(UInt32(n)); w.u32(0)
            return (0, w.d)
        case 17: // STATFS
            var s = statfs()
            if statfs(root, &s) != 0 { return (errno, nil) }
            var w = WireWriter()
            w.u64(s.f_blocks); w.u64(s.f_bfree); w.u64(s.f_bavail); w.u64(s.f_files); w.u64(s.f_ffree)
            w.u32(s.f_bsize); w.u32(255); w.u32(s.f_bsize); w.u32(0); w.zeros(24)
            return (0, w.d)
        case 18: // RELEASE
            closeFH(r.u64()); return (0, nil)
        case 20, 30: // FSYNC, FSYNCDIR
            let fh = r.u64()
            if let f = fd(fh) { fsync(f) }
            return (0, nil)
        case 25: return noFlush ? (ENOSYS, nil) : (0, nil) // FLUSH (ENOSYS ⇒ kernel stops sending it)
        case 27: // OPENDIR
            guard let p = path(nodeid) else { return (ENOENT, nil) }
            lock.lock(); let h = nextFH; nextFH += 1; dirs[h] = p; lock.unlock()
            var w = WireWriter(); w.u64(h); w.u32(0); w.u32(0)
            return (0, w.d)
        case 28, 44: // READDIR, READDIRPLUS
            let fh = r.u64(); let off = r.u64(); let size = r.u32()
            lock.lock(); let dp = dirs[fh]; lock.unlock()
            guard let dir = dp else { return (EBADF, nil) }
            let names = [".", ".."] + ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
            var w = WireWriter()
            var i = Int(off)
            while i < names.count {
                let name = names[i]; let nb = Array(name.utf8)
                let p = name == "." ? dir : name == ".." ? (dir as NSString).deletingLastPathComponent : dir + "/" + name
                var st = stat(); if lstat(p, &st) != 0 { i += 1; continue }
                let dirent = 24 + nb.count, padded = (dirent + 7) & ~7
                var rec = WireWriter()
                if opcode == 44 {
                    if name == "." || name == ".." { rec.zeros(40); rec.zeros(88) }
                    else { rec.u64(intern(p)); rec.u64(0); rec.u64(cacheSeconds); rec.u64(cacheSeconds); rec.u32(0); rec.u32(0); attr(st, &rec) }
                }
                rec.u64(UInt64(st.st_ino)); rec.u64(UInt64(i + 1)); rec.u32(UInt32(nb.count)); rec.u32(UInt32((st.st_mode & S_IFMT) >> 12))
                rec.raw(Data(nb)); rec.zeros(padded - dirent)
                if w.d.count + rec.d.count > Int(size) { break }
                w.raw(rec.d); i += 1
            }
            return (0, w.d)
        case 29: // RELEASEDIR
            let fh = r.u64(); lock.lock(); dirs.removeValue(forKey: fh); lock.unlock(); return (0, nil)
        case 34: // ACCESS
            return (0, nil)
        case 35: // CREATE
            guard let dir = path(nodeid) else { return (ENOENT, nil) }
            let flags = r.u32(); let mode = r.u32(); _ = r.u32(); _ = r.u32(); let name = r.cstr()
            let p = dir + "/" + name
            let f = open(p, linuxFlags(flags) | O_CREAT, mode_t(mode & 0o7777))
            if f < 0 { return (errno, nil) }
            guard case (0, let e?) = entry(p) else { close(f); return (EIO, nil) }
            var w = WireWriter(); w.raw(e); w.u64(newFH(f)); w.u32(0); w.u32(0)
            return (0, w.d)
        default:
            return (ENOSYS, nil)   // GETXATTR/SETXATTR/LISTXATTR/IOCTL/... — the kernel stops asking
        }
    }
}

// MARK: - ProbeBalloon: can this process release guest RAM?

@available(macOS 27.0, *)
final class ProbeBalloon: NSObject, VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.velox.probe.balloon")
    private var device: VZCustomVirtioDevice?
    private var ballooned = Set<UInt64>()     // 4 KiB guest PFNs currently in the balloon
    private var released = 0                  // 16 KiB host pages madvised
    private var signalSource: DispatchSourceSignal?
    let advice: Int32 = {
        switch ProcessInfo.processInfo.environment["VELOX_EXPERIMENT_BALLOON_ADVICE"] {
        case "free": return MADV_FREE
        case "dontneed": return MADV_DONTNEED
        default: return MADV_FREE_REUSABLE
        }
    }()

    func makeConfiguration() -> VZCustomVirtioDeviceConfiguration {
        let c = VZCustomVirtioDeviceConfiguration()
        c.deviceID = 5
        c.pciClassID = 0x05      // memory controller
        c.pciSubclassID = 0x80
        c.virtioQueueCount = 2   // inflate, deflate
        c.optionalFeatures.subset0 = (1 << 2)   // DEFLATE_ON_OOM
        c.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(configurationData: config(numPages: 0))
        c.provider = VZCustomVirtioDeviceDelegateProvider(deviceQueue: queue, delegate: self)
        return c
    }

    private func config(numPages: UInt32) -> Data {
        var w = WireWriter(); w.u32(numPages); w.u32(0); w.u32(0); w.u32(0); return w.d
    }

    @objc(customVirtioConfiguration:didCreateDevice:)
    func customVirtioConfiguration(_ deviceConfiguration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice) {
        device.delegate = self
        self.device = device
        // `kill -USR1 <pid>` re-reads ~/.velox/probe-balloon-mib and sets that as the balloon size.
        signal(SIGUSR1, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: queue)
        s.setEventHandler { [weak self] in self?.applyTarget() }
        s.resume()
        signalSource = s
    }

    @objc(customVirtioDeviceDidAcceptDriverOk:)
    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        probeLog("balloon: DRIVER_OK features=\(String(device.negotiatedFeatures?.subset0 ?? 0, radix: 16))")
    }

    private func applyTarget() {
        let file = NSHomeDirectory() + "/.velox/probe-balloon-mib"
        let mib = (try? String(contentsOfFile: file, encoding: .utf8)).flatMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let pages = mib * 256
        probeLog("balloon: target \(mib) MiB (\(pages) pages); held \(ballooned.count) pages, released \(released) host pages")
        device?.update(VZVirtioDeviceSpecificConfiguration(configurationData: config(numPages: pages))) { err in
            if let err { probeLog("balloon: config update failed: \(err)") }
        }
    }

    @objc(customVirtioDevice:didReceiveNotificationForQueue:)
    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        let inflate = queue.queueIndex == 0
        var touched = Set<UInt64>()
        while let el = queue.nextElement() {
            let data = el.readBuffers().reduce(into: Data()) { $0.append($1) }
            var r = WireReader(data)
            while r.remaining >= 4 {
                let pfn = UInt64(r.u32())
                if inflate { ballooned.insert(pfn) } else { ballooned.remove(pfn) }
                touched.insert(pfn & ~3)
            }
            el.returnToQueue()
        }
        // Release (or re-arm) each 16 KiB host page whose four 4 KiB guest pages are all ballooned.
        var advised = 0, failed = 0
        for base in touched {
            let full = (0 ..< 4).allSatisfy { ballooned.contains(base + $0) }
            guard full == inflate else { continue }
            guard let m = device.guestMemoryMapping(atPhysicalAddress: base << 12, length: 16384) else { failed += 1; continue }
            let rc = madvise(m.mutableBytes, 16384, inflate ? advice : MADV_FREE_REUSE)
            if rc == 0 { advised += 1 } else { failed += 1 }
        }
        if inflate { released += advised }
        probeLog("balloon: \(inflate ? "inflate" : "deflate") → held \(ballooned.count) pages, advised \(advised) host pages, failed \(failed) (errno \(errno))")
    }
}
