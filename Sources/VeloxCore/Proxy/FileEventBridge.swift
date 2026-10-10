import Foundation
import CoreServices

/// Host file changes → inotify events inside the guest, for bind mounts.
///
/// VirtioFS gives the guest no notification when a file changes on the Mac, so a container
/// watching a bind-mounted source tree (webpack/vite/next, nodemon, watchdog, rails `listen`)
/// never sees an editor's save — measured: zero events for a host append/create/rename/delete,
/// where OrbStack delivers CREATE/MODIFY/CLOSE_WRITE/MOVED/DELETE. This closes the common case
/// without a kernel patch or a new daemon:
///
/// - **Event-driven on both sides** (CLAUDE.md §8): one `FSEventStream` over the bind-mount
///   sources of *running* containers only (the set arrives from `DockerEventsWatcher`'s
///   reconcile, so it follows `docker run`/`rm` with no scan), and one persistent vsock stream
///   to vinit (`VsockPort.fileEvents`). Nothing polls.
/// - **The guest re-creates the event with a no-op `chmod(path, <host mode>)`** — the mode the
///   host just read, so nothing changes on the Mac but ctime. Linux turns that into IN_ATTRIB
///   on the file and on its parent's watch, which libuv (`fs.watch`), chokidar, watchdog,
///   rb-inotify and watchman all treat as a change. Deletes and renames poke the parent
///   directory the same way, which makes watchers rescan it. Mode — not mtime — is the carrier
///   because re-stamping mtime races a second save (it could roll mtime back).
/// - **The echo is filtered at the source** (`EchoFilter`): our chmod comes back as an FSEvent,
///   and with FileEvents the flags are sticky, so only a moved mtime or size counts as a change.
///
/// `VELOX_FILE_EVENTS=0` turns it off (EngineRuntime).
public final class FileEventBridge: @unchecked Sendable {
    private let manager: VMManager
    private let queue = DispatchQueue(label: "dev.velox.fileevents")
    private var stream: FSEventStreamRef?
    private var roots: Set<String> = []
    private var fd: Int32 = -1
    private var connecting = false
    private var pending: [UInt8] = []
    private var stopped = false
    private var echo = EchoFilter()

    public init(manager: VMManager) { self.manager = manager }

    /// Replace the watched set with the bind-mount sources of running containers.
    public func update(sources: Set<String>) {
        queue.async { [self] in
            guard !stopped else { return }
            // Watch directories; a file bind mount is watched through its parent.
            var dirs = Set<String>()
            for s in sources where s.hasPrefix("/") {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: s, isDirectory: &isDir) else { continue }
                dirs.insert(isDir.boolValue ? s : (s as NSString).deletingLastPathComponent)
            }
            guard dirs != roots else { return }
            roots = dirs
            restartStream()
        }
    }

    public func stop() {
        queue.async { [self] in
            stopped = true
            stopStream()
            pending.removeAll()
            if fd >= 0 { close(fd); fd = -1 }
        }
    }

    // MARK: - FSEvents (on `queue`)

    private func restartStream() {
        stopStream()
        guard !roots.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagNoDefer
                                             | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let me = Unmanaged<FileEventBridge>.fromOpaque(info).takeUnretainedValue()
            let arr = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            var batch: [(String, FSEventStreamEventFlags)] = []
            for i in 0..<count {
                if let p = arr[i] as? String { batch.append((p, eventFlags[i])) }
            }
            me.handle(batch)
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, Array(roots) as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.02, flags) else {
            Log.warn("file events: FSEventStreamCreate failed for \(roots.count) path(s)")
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
        Log.info("file events: watching \(roots.count) bind-mount source(s)")
    }

    private func stopStream() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    private static let contentMask = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated
        | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
        | kFSEventStreamEventFlagItemModified)

    /// On `queue` (the stream's dispatch queue).
    private func handle(_ batch: [(String, FSEventStreamEventFlags)]) {
        var lines: [String] = []
        var seen = Set<String>()
        func poke(_ path: String) {
            guard seen.insert(path).inserted else { return }
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { return }
            guard echo.admit(path, mtimeSec: st.st_mtimespec.tv_sec, mtimeNsec: st.st_mtimespec.tv_nsec,
                             size: Int64(st.st_size)) else { return }
            if let line = Self.line(mode: st.st_mode, path: path) { lines.append(line) }
        }
        for (path, flags) in batch where flags & Self.contentMask != 0 {
            let parent = (path as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: path) {
                poke(path)
                // A new entry: the parent's listing changed too.
                if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated
                                                   | kFSEventStreamEventFlagItemRenamed) != 0 { poke(parent) }
            } else {
                poke(parent)   // removed / renamed away: make watchers rescan the directory
            }
        }
        guard !lines.isEmpty else { return }
        send(Array(lines.joined().utf8))
    }

    /// The wire line for one path: `A <mode-octal> <absolute path>\n`, or nil for a path the
    /// line format can't carry (a newline in it) or that isn't absolute.
    public static func line(mode: mode_t, path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\n") else { return nil }
        return "A \(String(mode & 0o7777, radix: 8)) \(path)\n"
    }

    /// Our no-op chmod comes back as an FSEvent too — and with FileEvents the flags are sticky
    /// (a path modified a moment ago still reports ItemModified on the echo), so flags alone
    /// can't tell the echo from a real save; the first prototype fed back on itself (an
    /// IN_ATTRIB storm). A real change always moves mtime or size; our chmod moves only ctime.
    public struct EchoFilter {
        private var last: [String: (Int, Int, Int64)] = [:]
        static let capacity = 20_000

        /// True when `path` changed since it was last forwarded (and records it).
        public init() {}

        public mutating func admit(_ path: String, mtimeSec: Int, mtimeNsec: Int, size: Int64) -> Bool {
            let key = (mtimeSec, mtimeNsec, size)
            if let prev = last[path], prev == key { return false }
            if last.count >= Self.capacity { last.removeAll(keepingCapacity: true) }
            last[path] = key
            return true
        }
    }

    /// Best effort: one persistent vsock stream, dialled on first use and re-dialled after a
    /// failure. Lines produced while a dial is in flight queue behind it rather than opening a
    /// second connection. On `queue`; the connect completes on the VM queue and hops back.
    private func send(_ bytes: [UInt8]) {
        if fd >= 0 {
            if FDIO.writeAll(fd, bytes) { return }
            close(fd); fd = -1
        }
        pending.append(contentsOf: bytes)
        guard !connecting else { return }
        connecting = true
        manager.connectToGuestPort(VsockPort.fileEvents) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.connecting = false
                guard case .success(let newFd) = result, !self.stopped else {
                    if case .success(let newFd) = result { close(newFd) }
                    self.pending.removeAll()   // the guest isn't there; events are best effort
                    return
                }
                self.fd = newFd
                let queued = self.pending
                self.pending.removeAll()
                if !FDIO.writeAll(newFd, queued) { close(newFd); self.fd = -1 }
            }
        }
    }
}
