import CryptoKit
import Foundation
import VeloxCore

// A tiny, dependency-free test runner for VeloxCore's pure logic. XCTest isn't
// available under Command Line Tools (this repo's toolchain), so we assert by
// hand and exit non-zero on the first failure. Run: `swift run velox-selftest`.

var failures = 0
@MainActor func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok  \(message)")
    } else {
        failures += 1
        print("FAIL  \(message)")
    }
}
@MainActor func equal<T: Equatable>(_ a: T, _ b: T, _ message: String) {
    check(a == b, "\(message) (\(a) == \(b))")
}

func section(_ name: String) { print("\n== \(name) ==") }

// MARK: ANSIParser

section("ANSIParser")
do {
    let plain = ANSIParser.parse("hello")
    equal(plain.count, 1, "plain text is one span")
    check(plain.first?.foreground == nil, "plain text has no color")

    let red = ANSIParser.parse("\u{1B}[31mRED\u{1B}[0m")
    equal(red.first?.text ?? "", "RED", "red span text")
    check(red.first?.foreground == .standard(1), "red is standard(1)")

    let mixed = ANSIParser.parse("\u{1B}[1;92mOK\u{1B}[0mdone")
    equal(mixed.count, 2, "bold-bright then reset → two spans")
    check(mixed[0].bold, "first span is bold")
    check(mixed[0].foreground == .bright(2), "first span is bright green")
    check(mixed[1].foreground == nil, "reset clears color")

    check(ANSIParser.parse("\u{1B}[38;2;10;20;30mX").first?.foreground == .rgb(10, 20, 30), "truecolor fg")
    check(ANSIParser.parse("\u{1B}[38;5;200mY").first?.foreground == .indexed(200), "256-color fg")
    check(ANSIParser.parse("\u{1B}[4;44mU").first?.underline == true, "underline flag")
    equal(ANSIParser.parse("\u{1B}[2K\u{1B}[1AHi").map(\.text).joined(), "Hi", "cursor sequences stripped")
}

// MARK: HTTP response decoding (over a pipe)

section("HTTPCodec")
func pipeWith(_ s: String) -> Int32 {
    var fds = [Int32](repeating: 0, count: 2)
    _ = pipe(&fds)
    Array(s.utf8).withUnsafeBytes { _ = write(fds[1], $0.baseAddress, $0.count) }
    close(fds[1])
    return fds[0]
}
do {
    let clFd = pipeWith("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")
    let (clStatus, clBody) = try HTTPCodec.readResponse(fd: clFd); close(clFd)
    equal(clStatus, 200, "content-length status")
    equal(String(decoding: clBody, as: UTF8.self), "{}", "content-length body")

    let chFd = pipeWith("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
    let (chStatus, chBody) = try HTTPCodec.readResponse(fd: chFd); close(chFd)
    equal(chStatus, 200, "chunked status")
    equal(String(decoding: chBody, as: UTF8.self), "hello world", "chunked body reassembled")

    let eofFd = pipeWith("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nstreamed")
    let (_, eofBody) = try HTTPCodec.readResponse(fd: eofFd); close(eofFd)
    equal(String(decoding: eofBody, as: UTF8.self), "streamed", "read-to-EOF body")

    let req = String(decoding: HTTPCodec.request(method: "POST", path: "/p", body: Data("{}".utf8)), as: UTF8.self)
    check(req.hasPrefix("POST /p HTTP/1.1\r\n"), "request line")
    check(req.contains("Content-Length: 2\r\n"), "request content-length")
} catch {
    failures += 1
    print("FAIL  HTTPCodec threw: \(error)")
}

// MARK: Log frame parsing

section("LogFrameParser")
func frame(_ stream: UInt8, _ text: String) -> Data {
    var d = Data([stream, 0, 0, 0])
    let p = Array(text.utf8); let n = UInt32(p.count)
    d.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
    d.append(contentsOf: p)
    return d
}
do {
    let parser = LogFrameParser()
    var acc = frame(1, "out\n") + frame(2, "err\n")
    var frames: [LogFrame] = []
    parser.parse(&acc) { frames.append($0) }
    equal(frames.count, 2, "two multiplexed frames")
    check(frames.first?.stream == .stdout && frames.first?.text == "out\n", "stdout frame")
    check(frames.last?.stream == .stderr && frames.last?.text == "err\n", "stderr frame")
    check(acc.isEmpty, "buffer fully consumed")

    var partial = Data(frame(1, "hello").prefix(10)) // header + 2 of 5 payload bytes
    var none: [LogFrame] = []
    parser.parse(&partial) { none.append($0) }
    check(none.isEmpty, "partial frame yields nothing")
    equal(partial.count, 10, "partial frame preserved")
}

// MARK: Model decoding

section("Models")
do {
    let cjson = """
    [{"Id":"abc123def456","Names":["/web"],"Image":"nginx:latest","ImageID":"sha256:x",
      "State":"running","Status":"Up 2 minutes","Created":1717000000,
      "Ports":[{"PrivatePort":80,"PublicPort":8080,"Type":"tcp"}]}]
    """
    let containers = try JSONDecoder().decode([ContainerSummary].self, from: Data(cjson.utf8))
    equal(containers.first?.displayName ?? "", "web", "container name slash stripped")
    check(containers.first?.isRunning == true, "container running")
    equal(containers.first?.ports.first?.label ?? "", "8080:80/tcp", "port label")

    let ijson = """
    [{"Id":"sha256:deadbeefcafef00d","RepoTags":["ghcr.io/acme/api:2.3"],"Created":1,"Size":92}]
    """
    let images = try JSONDecoder().decode([ImageSummary].self, from: Data(ijson.utf8))
    equal(images.first?.repository ?? "", "ghcr.io/acme/api", "image repository split")
    equal(images.first?.tag ?? "", "2.3", "image tag split")
    equal(images.first?.shortID ?? "", "deadbeefcafe", "image short id")

    let vjson = """
    {"Volumes":[{"Name":"pgdata","Driver":"local","Mountpoint":"/m","UsageData":{"Size":1024,"RefCount":1}}]}
    """
    let vols = try JSONDecoder().decode(VolumeListResponse.self, from: Data(vjson.utf8))
    equal(vols.volumes.first?.size ?? -1, 1024, "volume usage size")

    let njson = """
    [{"Id":"n","Name":"bridge","Driver":"bridge","Scope":"local",
      "IPAM":{"Config":[{"Subnet":"172.17.0.0/16"}]},
      "Containers":{"abc":{"Name":"web","IPv4Address":"172.17.0.2/16"}}}]
    """
    let nets = try JSONDecoder().decode([NetworkSummary].self, from: Data(njson.utf8))
    equal(nets.first?.subnets ?? [], ["172.17.0.0/16"], "network subnet")
    equal(nets.first?.attachedContainers.first?.name ?? "", "web", "attached container")
} catch {
    failures += 1
    print("FAIL  Models threw: \(error)")
}

// MARK: Reference + config + shares

section("Misc")
equal(DockerClient.splitReference("nginx").tag, "latest", "bare ref defaults to latest")
equal(DockerClient.splitReference("nginx:1.25").tag, "1.25", "ref tag parsed")
equal(DockerClient.splitReference("localhost:5000/app").tag, "latest", "registry port not a tag")

do {
    var cfg = VeloxConfig.default
    cfg.cpuCount = 6; cfg.fileShares = ["/opt/data"]
    let round = try JSONDecoder().decode(VeloxConfig.self, from: JSONEncoder().encode(cfg))
    equal(round.cpuCount, 6, "config cpu round-trips")
    equal(round.fileShares, ["/opt/data"], "config shares round-trip")
    equal(round.resources.cpuCount, 6, "config → resources")
} catch {
    failures += 1
    print("FAIL  VeloxConfig threw: \(error)")
}

let adverts = VMConfiguration.shareAdvertisement(for: [
    URL(fileURLWithPath: "/Users"),
    URL(fileURLWithPath: "/definitely/not/here/xyz"),
    URL(fileURLWithPath: "/tmp"),
])
equal(adverts.count, 1, "shareAdvertisement skips /Users and missing dirs")
equal(adverts.first?.path ?? "", "/tmp", "shareAdvertisement keeps existing dir")
check(adverts.first?.tag.hasPrefix("vlx") ?? false, "share tag prefixed vlx")

// MARK: Resources (swap + resource saver)

section("Resources")
do {
    var cfg = VeloxConfig.default
    cfg.swapGiB = 2
    cfg.resourceSaverEnabled = false
    cfg.resourceSaverMinutes = 12
    let round = try JSONDecoder().decode(VeloxConfig.self, from: JSONEncoder().encode(cfg))
    equal(round.swapGiB, 2, "swap round-trips")
    equal(round.resources.swapMiB, 2048, "swapGiB → swapMiB")
    equal(round.resourceSaverEnabled, false, "resource saver toggle round-trips")
    equal(round.resourceSaverMinutes, 12, "resource saver minutes round-trip")

    // swap=0 means no swap advertised.
    var noSwap = VeloxConfig.default; noSwap.swapGiB = 0
    equal(noSwap.resources.swapMiB, 0, "swap off → 0 MiB")

    // Resource Saver floor: ¼ of RAM clamped to [512 MiB, 1 GiB].
    var big = VeloxConfig.default; big.memoryGiB = 16
    equal(big.resourceSaverFloorBytes, 1024 * 1024 * 1024, "floor clamped to 1 GiB ceiling")
    var small = VeloxConfig.default; small.memoryGiB = 1
    equal(small.resourceSaverFloorBytes, 512 * 1024 * 1024, "floor clamped to 512 MiB minimum")
    var mid = VeloxConfig.default; mid.memoryGiB = 3
    equal(mid.resourceSaverFloorBytes, 768 * 1024 * 1024, "floor is ¼ of RAM in the band")
} catch {
    failures += 1
    print("FAIL  Resources threw: \(error)")
}

// MARK: GuestImage share advertising

section("GuestImage.advertising")
do {
    let base = GuestImage(kernelURL: URL(fileURLWithPath: "/k"),
                          rootDiskURL: URL(fileURLWithPath: "/r"),
                          kernelCommandLine: "console=hvc0")
    equal(base.advertising(shares: []).kernelCommandLine, "console=hvc0",
          "no shares → cmdline unchanged")
    let adv = base.advertising(shares: [URL(fileURLWithPath: "/tmp")])
    check(adv.kernelCommandLine.contains(" velox.shares="), "shares → velox.shares on cmdline")
    if let b64 = adv.kernelCommandLine.split(separator: " ")
        .first(where: { $0.hasPrefix("velox.shares=") })?.dropFirst("velox.shares=".count),
       let decoded = Data(base64Encoded: String(b64)),
       let text = String(data: decoded, encoding: .utf8) {
        check(text.hasSuffix("\t/tmp"), "advertised payload maps tag → /tmp")
    } else {
        failures += 1; print("FAIL  could not decode velox.shares payload")
    }
}

// MARK: NameDNSResponder wire format

section("NameDNSResponder")
do {
    /// A minimal DNS query: header (id 0xBEEF, RD) + QNAME labels + qtype/qclass IN.
    func query(_ name: String, qtype: UInt8 = 1) -> [UInt8] {
        var q: [UInt8] = [0xBE, 0xEF, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            q.append(UInt8(label.utf8.count)); q.append(contentsOf: Array(label.utf8))
        }
        q.append(contentsOf: [0, 0, qtype, 0, 1])
        return q
    }
    let registry = NameRegistry()
    registry.update(["web": inet_addr("172.17.0.2")])

    if let (name, qtype, qend) = NameDNSResponder.parseQName(query("WeB.Velox.Local")) {
        equal(name, "web.velox.local", "qname lowercased")
        equal(qtype, 1, "qtype A")
        equal(qend, 12 + 17 + 4, "qend just past the question")
    } else { failures += 1; print("FAIL  parseQName on valid query") }
    check(NameDNSResponder.parseQName([0xBE, 0xEF, 0x01]) == nil, "short packet → nil")
    check(NameDNSResponder.parseQName(query("web.velox.local").dropLast(3).map { $0 }) == nil,
          "truncated question → nil")

    let a = NameDNSResponder.buildReply(query("web.velox.local"), registry: registry)
    check(a[2] & 0x80 != 0 && a[3] & 0x0F == 0, "known name → QR=1, NOERROR")
    equal(Int(a[7]), 1, "known name → ANCOUNT=1")
    equal(Array(a.suffix(4)), [172, 17, 0, 2], "answer carries the container IP")

    let nx = NameDNSResponder.buildReply(query("ghost.velox.local"), registry: registry)
    equal(Int(nx[3] & 0x0F), 3, "unknown name → NXDOMAIN")
    equal(Int(nx[7]), 0, "unknown name → no answers")

    let aaaa = NameDNSResponder.buildReply(query("web.velox.local", qtype: 28), registry: registry)
    equal(Int(aaaa[3] & 0x0F), 0, "AAAA → NOERROR (so the client falls back to A)")
    equal(Int(aaaa[7]), 0, "AAAA → empty answer section")

    let foreign = NameDNSResponder.buildReply(query("example.com"), registry: registry)
    equal(Int(foreign[3] & 0x0F), 3, "non-velox.local suffix → NXDOMAIN")
}

// MARK: Named-access domain + published bindings (UI affordances)

section("ContainerSummary affordances")
do {
    let running = ContainerSummary(id: "aaa", names: ["Web"], image: "nginx", state: "running",
                                   status: "Up 1 minute",
                                   ports: [PortMapping(ip: "0.0.0.0", privatePort: 80, publicPort: 8080),
                                           PortMapping(ip: "::", privatePort: 80, publicPort: 8080)],
                                   networkIPs: ["172.17.0.2"])
    equal(running.namedAccessDomain ?? "nil", "web.velox.local", "domain lowercased + suffixed")
    equal(running.publishedBindings.count, 1, "v4+v6 of the same publish dedup to one binding")
    equal(running.publishedBindings.first?.publicPort ?? 0, 8080, "binding carries the host port")

    let stopped = ContainerSummary(id: "bbb", names: ["web"], image: "nginx", state: "exited",
                                   status: "", networkIPs: ["172.17.0.2"])
    check(stopped.namedAccessDomain == nil, "stopped container → no domain")

    let multi = ContainerSummary(id: "ccc", names: ["web"], image: "nginx", state: "running",
                                 status: "", networkIPs: ["172.17.0.2", "172.18.0.2"])
    check(multi.namedAccessDomain == nil, "multi-network (ambiguous IP) → no domain")
}

// MARK: DockerRunCommand reconstruction

section("DockerRunCommand")
do {
    let inspect = ContainerInspect(
        name: "/web",
        config: .init(image: "nginx:latest", env: ["A=plain", "B=has space"],
                      cmd: ["nginx", "-g", "daemon off;"], workingDir: "/app"),
        hostConfig: .init(binds: ["pgdata:/data"],
                          portBindings: ["80/tcp": [.init(hostPort: "8080")],
                                         "53/udp": [.init(hostPort: "5353")]],
                          restartPolicy: .init(name: "unless-stopped")))
    equal(DockerRunCommand.build(from: inspect),
          "docker run -d --name web -p 5353:53/udp -p 8080:80 -v pgdata:/data "
        + "-e A=plain -e 'B=has space' --restart unless-stopped -w /app "
        + "nginx:latest nginx -g 'daemon off;'",
          "full docker run reconstruction")
    equal(DockerRunCommand.quote("it's"), "'it'\\''s'", "single-quote escaping")
    let bare = ContainerInspect(name: "/x", config: .init(image: "alpine"), hostConfig: .init())
    equal(DockerRunCommand.build(from: bare), "docker run -d --name x alpine", "minimal container")
}

// MARK: DockerDates (RFC3339 + Go zero-time sentinel)

section("DockerDates")
do {
    let d = DockerDates.parse("2026-06-10T09:15:01.123456789Z")
    check(d != nil, "nanosecond-fraction timestamp parses")
    if let d {
        equal(Int(d.timeIntervalSince1970), 1_781_082_901, "fraction stripped, seconds exact")
    }
    check(DockerDates.parse("2026-06-10T09:15:01Z") != nil, "no-fraction timestamp parses")
    check(DockerDates.parse("0001-01-01T00:00:00Z") == nil, "Go zero time → nil (never)")
    check(DockerDates.parse(nil) == nil && DockerDates.parse("") == nil, "nil/empty → nil")
}

// MARK: DiskUsage (/system/df) category math

section("DiskUsage")
do {
    let json = #"""
    {"LayersSize": 1000,
     "Images": [{"Size": 600, "SharedSize": 100, "Containers": 0},
                {"Size": 400, "SharedSize": 0, "Containers": 2}],
     "Containers": [{"SizeRw": 50, "State": "running"}, {"SizeRw": 30, "State": "exited"}],
     "Volumes": [{"UsageData": {"Size": 200, "RefCount": 1}},
                 {"UsageData": {"Size": 70, "RefCount": 0}}],
     "BuildCache": [{"Size": 90, "InUse": true}, {"Size": 25, "InUse": false}]}
    """#
    if let df = try? JSONDecoder().decode(DiskUsage.self, from: Data(json.utf8)) {
        equal(df.imagesTotal, 1000, "images total = LayersSize")
        equal(df.imagesReclaimable, 500, "unused image minus shared layers")
        equal(df.containersTotal, 80, "container rw layers summed")
        equal(df.containersReclaimable, 30, "only stopped containers reclaimable")
        equal(df.volumesTotal, 270, "volume sizes summed")
        equal(df.volumesReclaimable, 70, "only refcount-0 volumes reclaimable")
        equal(df.buildCacheTotal, 115, "build cache summed")
        equal(df.buildCacheReclaimable, 25, "only not-in-use cache reclaimable")
    } else { failures += 1; print("FAIL  DiskUsage decode") }
}

// MARK: ChurnBreaker state machine

section("ChurnBreaker")
do {
    /// Synthetic clock: milliseconds from an arbitrary base.
    func at(_ ms: UInt64) -> DispatchTime { DispatchTime(uptimeNanoseconds: 1_000_000_000 + ms * 1_000_000) }

    // A continuous empty streak must be sustained ≤100ms apart; brief bursts queue.
    var b = ChurnBreaker()
    equal(b.emptySubmit(now: at(0)), .queue, "first empty submit queues")
    equal(b.emptySubmit(now: at(80)), .queue, "empty at 80ms still queues")
    equal(b.emptySubmit(now: at(160)), .queue, "empty at 160ms still queues")
    equal(b.emptySubmit(now: at(240)), .queue, "empty at 240ms still queues (< 300ms trip)")
    check(!b.isOpen(now: at(250)), "not open before tripping")

    // Sustained continuous emptiness (> 300ms) trips → bypass + 2s cooldown.
    equal(b.emptySubmit(now: at(320)), .bypass, "continuous emptiness past 300ms trips")
    check(b.isOpen(now: at(400)), "open during the 2s cooldown")
    check(b.isOpen(now: at(2300)), "still open at 2.3s (cooldown ends at 2.32s)")
    check(!b.isOpen(now: at(2400)), "closed after the cooldown")

    // Persisting churn backs off: the next trip opens for 4s.
    equal(b.emptySubmit(now: at(2400)), .queue, "post-cooldown empty restarts the streak")
    equal(b.emptySubmit(now: at(2480)), .queue, "still within the streak window")
    equal(b.emptySubmit(now: at(2560)), .queue, "streak building")
    equal(b.emptySubmit(now: at(2640)), .queue, "streak building")
    equal(b.emptySubmit(now: at(2720)), .bypass, "second trip after another 300ms continuous")
    check(b.isOpen(now: at(6600)), "second cooldown backed off to 4s (ends at 6.72s)")
    check(!b.isOpen(now: at(6800)), "second cooldown over")

    // A served submit resets streak AND backoff: the next trip cools down 2s again.
    b.served()
    equal(b.emptySubmit(now: at(7000)), .queue, "served() restarted the streak")
    equal(b.emptySubmit(now: at(7080)), .queue, "streak building")
    equal(b.emptySubmit(now: at(7160)), .queue, "streak building")
    equal(b.emptySubmit(now: at(7240)), .queue, "streak building")
    equal(b.emptySubmit(now: at(7320)), .bypass, "trips again after 300ms continuous")
    check(b.isOpen(now: at(9300)), "cooldown is back to 2s after served() (ends at 9.32s)")
    check(!b.isOpen(now: at(9400)), "and closed after it")

    // A quiet gap (> 100ms with no empty submit) restarts the streak — no trip.
    var g = ChurnBreaker()
    equal(g.emptySubmit(now: at(0)), .queue, "gap test: streak starts")
    equal(g.emptySubmit(now: at(200)), .queue, "150ms+ quiet gap restarted the streak")
    equal(g.emptySubmit(now: at(450)), .queue, "another gap — 450ms total but never 300ms continuous")
}

// MARK: Storage — data-disk move (sparse-preserving)

/// Write a sparse file: 1 MiB of real data at each given offset, then truncate to `logical`.
func mkSparse(at url: URL, logical: off_t, dataAt offsets: [off_t]) {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let fd = open(url.path, O_WRONLY)
    guard fd >= 0 else { return }
    let block = [UInt8](repeating: 0xAB, count: 1 << 20)
    for off in offsets { block.withUnsafeBytes { _ = pwrite(fd, $0.baseAddress, $0.count, off) } }
    _ = ftruncate(fd, logical)
    close(fd)
}
func allocBytes(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? -1 }
func logicalBytes(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1 }
@discardableResult func runTool(_ path: String, _ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
}

section("VeloxConfig.dataDiskURL")
do {
    var cfg = VeloxConfig.default
    equal(cfg.dataDiskURL.path, Paths.dataDisk.path, "nil dataDirectory → ~/.velox/data.img")
    cfg.dataDirectory = "/Volumes/Ext/Velox"
    equal(cfg.dataDiskURL.path, "/Volumes/Ext/Velox/data.img", "custom dataDirectory resolves under it")
}

section("Storage.stageDataDiskMove")
do {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("velox-move-\(getpid())")
    let srcDir = base.appendingPathComponent("a"); let dstDir = base.appendingPathComponent("b")
    try? fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    // Same volume → rename: instant, preserves the (sparse) file exactly.
    let src = srcDir.appendingPathComponent("data.img")
    mkSparse(at: src, logical: 256 << 20, dataAt: [0, 64 << 20, 200 << 20])
    check(allocBytes(src) < 16 << 20, "source is sparse (alloc \(allocBytes(src)) « 256 MiB)")
    let dst = dstDir.appendingPathComponent("data.img")
    do {
        try Storage.stageDataDiskMove(from: src, to: dst)
        check(fm.fileExists(atPath: src.path), "same-vol: stage leaves source intact (crash-safe)")
        equal(logicalBytes(dst), 256 << 20, "same-vol: logical size preserved")
        Storage.removeMovedSource(at: src)
        check(!fm.fileExists(atPath: src.path), "same-vol: source removed after commit")
    } catch { check(false, "same-vol move threw: \(error)") }

    // Refuse to clobber an existing destination (source left intact).
    let src2 = srcDir.appendingPathComponent("again.img")
    mkSparse(at: src2, logical: 8 << 20, dataAt: [0])
    var refused = false
    do { try Storage.stageDataDiskMove(from: src2, to: dst) } catch { refused = true }
    check(refused && fm.fileExists(atPath: src2.path), "refuses existing dst, leaves source intact")

    // Cross volume → sparse-preserving copy onto a real second APFS volume.
    let dmg = base.appendingPathComponent("vol.dmg")
    let vol = "VeloxMove\(getpid())"
    if runTool("/usr/bin/hdiutil", ["create", "-size", "512m", "-fs", "APFS", "-volname", vol, "-quiet", dmg.path]) == 0,
       runTool("/usr/bin/hdiutil", ["attach", "-quiet", dmg.path]) == 0 {
        let volDir = URL(fileURLWithPath: "/Volumes/\(vol)")
        let xsrc = srcDir.appendingPathComponent("cross.img")
        mkSparse(at: xsrc, logical: 256 << 20, dataAt: [0, 100 << 20, 255 << 20])
        let xAlloc = allocBytes(xsrc)
        let xdst = volDir.appendingPathComponent("data.img")
        do {
            try Storage.stageDataDiskMove(from: xsrc, to: xdst)
            equal(logicalBytes(xdst), 256 << 20, "cross-vol: logical size preserved")
            check(allocBytes(xdst) <= xAlloc + (4 << 20),
                  "cross-vol: SPARSE preserved (dst alloc \(allocBytes(xdst)) ≈ src \(xAlloc), not 256 MiB)")
            check(fm.fileExists(atPath: xsrc.path), "cross-vol: stage leaves source intact (crash-safe)")
            Storage.removeMovedSource(at: xsrc)
            check(!fm.fileExists(atPath: xsrc.path), "cross-vol: source removed after commit")
        } catch { check(false, "cross-vol move threw: \(error)") }
        runTool("/usr/bin/hdiutil", ["detach", "-quiet", volDir.path])
    } else {
        print("  skip  cross-volume sparse test (hdiutil unavailable)")
    }
}

// MARK: Updater semver ordering

section("Updater.compareSemver")
do {
    check(Updater.compareSemver("1.2.3", "1.2.3") == 0, "equal versions")
    check(Updater.compareSemver("1.2.10", "1.2.9") > 0, "numeric (not lexical) compare")
    check(Updater.compareSemver("0.3", "0.2.9") > 0, "shorter version padded with zeros")
    check(Updater.compareSemver("1.0.0", "1.0") == 0, "trailing zero segments equal")
    check(Updater.compareSemver("0.9.9", "1.0.0") < 0, "major bump wins")
}

// MARK: Ed25519 release-signature verification

section("Updater.ed25519Verify")
do {
    let key = Curve25519.Signing.PrivateKey()
    let pubB64 = key.publicKey.rawRepresentation.base64EncodedString()
    let payload = Data("velox release bytes".utf8)
    let sigB64 = try key.signature(for: payload).base64EncodedString()

    check(Updater.ed25519Verify(data: payload, signatureB64: sigB64, publicKeyB64: pubB64),
          "valid signature verifies")
    check(!Updater.ed25519Verify(data: payload + Data([0]), signatureB64: sigB64, publicKeyB64: pubB64),
          "tampered payload rejected")
    let otherPub = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    check(!Updater.ed25519Verify(data: payload, signatureB64: sigB64, publicKeyB64: otherPub),
          "wrong public key rejected")
    check(!Updater.ed25519Verify(data: payload, signatureB64: "not-base64!", publicKeyB64: pubB64),
          "garbage signature rejected")
    check(!Updater.ed25519Verify(data: payload, signatureB64: sigB64, publicKeyB64: ""),
          "empty public key rejected")
}

// MARK: Coalescer (leading-edge schedule, trailing fire)

section("Coalescer")
do {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
    let runs = Counter()
    let coalescer = Coalescer(delay: .milliseconds(50)) { runs.bump() }
    for _ in 0..<10 { coalescer.trigger() }
    try? await Task.sleep(for: .milliseconds(300))
    equal(runs.value, 1, "burst of 10 triggers coalesces to one run")
    coalescer.trigger()
    coalescer.trigger()
    try? await Task.sleep(for: .milliseconds(300))
    equal(runs.value, 2, "a later burst fires exactly once more")
    coalescer.trigger()
    coalescer.cancel()
    try? await Task.sleep(for: .milliseconds(150))
    equal(runs.value, 2, "cancel() suppresses the pending run")
}

// MARK: NameRegistry

section("NameRegistry")
do {
    let reg = NameRegistry()
    check(reg.address(for: "web") == nil, "empty registry resolves nothing")
    reg.update(["web": inet_addr("172.17.0.2"), "db": inet_addr("172.17.0.3")])
    check(reg.address(for: "web") == inet_addr("172.17.0.2"), "lookup returns the stored address")
    check(reg.address(for: "WEB") == inet_addr("172.17.0.2"), "lookup is case-insensitive")
    check(reg.address(for: "ghost") == nil, "unknown name is nil")
    reg.update(["db": inet_addr("172.17.0.9")])
    check(reg.address(for: "web") == nil, "update replaces (not merges) the map")
    check(reg.address(for: "db") == inet_addr("172.17.0.9"), "replaced entry has the new address")
}

// MARK: PortHelperClient wire protocol (against an in-process fake daemon)

section("PortHelperClient protocol")
do {
    // A fake velox-porthelper: accepts one connection per scripted step, records the
    // request line, replies with a status byte (and an SCM_RIGHTS fd when scripted) —
    // byte-for-byte the daemon's `reply()` layout.
    final class FakeDaemon: @unchecked Sendable {
        let path: String
        private let fd: Int32
        private let lock = NSLock()
        private var received: [String] = []
        /// (status, fd-to-pass or -1) per accepted connection, consumed in order.
        private var script: [(UInt8, Int32)]

        init?(script: [(UInt8, Int32)]) {
            // sockaddr_un paths are capped at 104 bytes — keep it short.
            path = FileManager.default.temporaryDirectory.path + "/velox-selftest-\(getpid()).sock"
            unlink(path)
            self.script = script
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { p in
                p.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
                    for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                    dst[bytes.count] = 0
                }
            }
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(fd, 4) == 0 else { close(fd); return nil }
            let steps = script.count
            Thread.detachNewThread { [self] in
                for _ in 0..<steps {
                    let conn = accept(fd, nil, nil)
                    guard conn >= 0 else { return }
                    var line = [UInt8]()
                    var byte: UInt8 = 0
                    while read(conn, &byte, 1) == 1, byte != UInt8(ascii: "\n") { line.append(byte) }
                    lock.lock()
                    received.append(String(decoding: line, as: UTF8.self))
                    let (status, passFd) = self.script.isEmpty ? (UInt8(1), Int32(-1)) : self.script.removeFirst()
                    lock.unlock()
                    reply(conn, status: status, passFd: passFd)
                    close(conn)
                }
            }
        }

        var requests: [String] { lock.lock(); defer { lock.unlock() }; return received }
        func stop() { close(fd); unlink(path) }

        // Mirrors velox-porthelper's reply(): 1 status byte, optional SCM_RIGHTS fd.
        private func reply(_ conn: Int32, status: UInt8, passFd: Int32) {
            let hdrLen = (MemoryLayout<cmsghdr>.size + 3) & ~3
            let cmsgLen = hdrLen + MemoryLayout<Int32>.size
            let space = hdrLen + ((MemoryLayout<Int32>.size + 3) & ~3)
            var statusByte = status
            withUnsafeMutablePointer(to: &statusByte) { sp in
                var iov = iovec(iov_base: UnsafeMutableRawPointer(sp), iov_len: 1)
                withUnsafeMutablePointer(to: &iov) { iovp in
                    var msg = msghdr()
                    msg.msg_iov = iovp
                    msg.msg_iovlen = 1
                    guard passFd >= 0 else { _ = sendmsg(conn, &msg, 0); return }
                    let control = UnsafeMutableRawPointer.allocate(byteCount: space,
                                                                   alignment: MemoryLayout<cmsghdr>.alignment)
                    defer { control.deallocate() }
                    memset(control, 0, space)
                    msg.msg_control = control
                    msg.msg_controllen = socklen_t(space)
                    let cmsg = control.assumingMemoryBound(to: cmsghdr.self)
                    cmsg.pointee.cmsg_len = socklen_t(cmsgLen)
                    cmsg.pointee.cmsg_level = SOL_SOCKET
                    cmsg.pointee.cmsg_type = SCM_RIGHTS
                    (control + hdrLen).assumingMemoryBound(to: Int32.self).pointee = passFd
                    _ = sendmsg(conn, &msg, 0)
                }
            }
        }
    }

    // An fd with a known payload to pass through SCM_RIGHTS (proves real fd passage).
    var pipeFds = [Int32](repeating: 0, count: 2)
    _ = pipe(&pipeFds)
    var marker: UInt8 = 0x42
    _ = write(pipeFds[1], &marker, 1)
    close(pipeFds[1])

    let script: [(UInt8, Int32)] = [
        (0, pipeFds[0]),   // tcp bind → ok + fd
        (2, -1),           // udp bind → EACCES-style failure, no fd
        (0, -1),           // route add → ok
        (1, -1),           // route del → failure
        (0, -1),           // ipfwd → ok
    ]
    if let daemon = FakeDaemon(script: script) {
        PortHelperClient.socketPath = daemon.path

        let got = PortHelperClient.requestListener(port: 80, proto: .tcp)
        check(got != nil, "bind ok+fd → a descriptor is returned")
        if let got {
            var readBack: UInt8 = 0
            check(read(got, &readBack, 1) == 1 && readBack == 0x42, "passed fd is the real one (payload survives)")
            close(got)
        }
        check(PortHelperClient.requestListener(port: 81, proto: .udp) == nil, "non-zero status → nil, no fd")
        check(PortHelperClient.route(add: true, subnet: "172.18.0.0/16", gateway: "192.168.64.2"), "route add status 0 → true")
        check(!PortHelperClient.route(add: false, subnet: "172.18.0.0/16", gateway: ""), "route del status 1 → false")
        check(PortHelperClient.restoreIPForwarding(), "ipfwd status 0 → true")

        // The wire format is the contract with the root daemon — assert it verbatim.
        equal(daemon.requests, ["tcp 80", "udp 81",
                                "route add 172.18.0.0/16 192.168.64.2",
                                "route del 172.18.0.0/16", "ipfwd"],
              "request lines match the daemon protocol")
        daemon.stop()
        close(pipeFds[0])
        PortHelperClient.socketPath = PortHelperClient.productionSocketPath
    } else {
        check(false, "fake daemon failed to start")
    }
}

// MARK: Summary

print("\n----------------------------------------")
if failures == 0 {
    print("All self-tests passed.")
    exit(0)
} else {
    print("\(failures) self-test(s) FAILED.")
    exit(1)
}
