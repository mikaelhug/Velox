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

// MARK: NXDOMAIN carries an SOA so the negative answer is not cached for long

section("NameDNSResponder.nxdomain")
@MainActor func nxdomainSOATest() {
    // A bare NXDOMAIN (no SOA) leaves the negative TTL to the resolver's own default, and
    // mDNSResponder's is long and sticky — which is why a container that happened to be down
    // when a name was first queried stayed unreachable by name long after it came back, while
    // the responder answered it correctly the whole time. RFC 2308: the negative-cache TTL is
    // the SOA MINIMUM in the authority section. Driven through the public entry point, so this
    // is what actually goes on the wire.
    var q: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
    for label in "nope.velox.local".split(separator: ".") {
        q.append(UInt8(label.utf8.count)); q.append(contentsOf: Array(label.utf8))
    }
    q.append(contentsOf: [0, 0x00, 0x01, 0x00, 0x01])          // root, QTYPE=A, QCLASS=IN
    let r = NameDNSResponder.buildReply(q, registry: NameRegistry())
    equal(Int(r[3] & 0x0f), 3, "RCODE is NXDOMAIN")
    equal((Int(r[6]) << 8) | Int(r[7]), 0, "ANCOUNT is 0")
    equal((Int(r[8]) << 8) | Int(r[9]), 1, "NSCOUNT is 1 — an SOA is present")
    // Walk to the authority record: header + question, then the owner name, type/class/ttl.
    let qend = q.count
    check(r.count > qend + 11, "the reply carries an authority record after the question")
    if r.count > qend + 11 {
        var p = qend
        while p < r.count, r[p] != 0 { p += Int(r[p]) + 1 }     // skip the owner labels
        p += 1
        equal((Int(r[p]) << 8) | Int(r[p + 1]), 6, "authority record is type SOA")
        let rdlen = (Int(r[p + 8]) << 8) | Int(r[p + 9])
        equal(rdlen, r.count - (p + 10), "SOA RDLENGTH matches the bytes that follow")
        // MINIMUM is the last 4 bytes of the RDATA — the field that bounds negative caching.
        let n = r.count
        let minimum = (UInt32(r[n - 4]) << 24) | (UInt32(r[n - 3]) << 16)
                    | (UInt32(r[n - 2]) << 8)  |  UInt32(r[n - 1])
        equal(minimum, 1, "SOA MINIMUM (negative-cache TTL) is 1 second")
    }
}
nxdomainSOATest()

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

// MARK: Workspaces

section("Workspace.dataDiskURL")
do {
    let now = Date()
    let def = Workspace(id: Workspace.defaultID, name: "Default", diskGiB: 64,
                        created: now, lastUsed: now)
    equal(def.dataDiskURL.path, Paths.dataDisk.path,
          "Default keeps the legacy ~/.velox/data.img slot")
    check(!def.ownsDirectory, "Default's folder is ~/.velox — not ours to delete")

    let fresh = Workspace(id: "abc-123", name: "Work", diskGiB: 64, created: now, lastUsed: now)
    equal(fresh.dataDiskURL.path,
          Paths.workspaces.appendingPathComponent("abc-123").appendingPathComponent("data.img").path,
          "a new workspace lands in workspaces/<id>/data.img")
    check(fresh.ownsDirectory, "an owned slot may have its folder removed")

    let moved = Workspace(id: "abc-123", name: "Work", directory: "/Volumes/Ext/Velox",
                          diskGiB: 64, created: now, lastUsed: now)
    equal(moved.dataDiskURL.path, "/Volumes/Ext/Velox/data.img",
          "a relocated workspace resolves under its directory")
    check(!moved.ownsDirectory,
          "a user-chosen folder is NEVER removed on delete (it could be ~/Documents)")
}

section("Workspace.validate")
do {
    check((try? Workspace.validate(name: "  Staging  ")) == "Staging", "names are trimmed")
    check((try? Workspace.validate(name: "   ")) == nil, "blank name rejected")
    check((try? Workspace.validate(name: String(repeating: "x", count: 65))) == nil,
          "over-long name rejected")
    check((try? Workspace.validate(name: "a\nb")) == nil, "newline in name rejected")
    equal(Workspace.normalized(" Staging "), "staging", "names compare case-insensitively")
}

section("WorkspaceStore.validateDiskPaths")
do {
    let now = Date()
    func ws(_ id: String, _ name: String, _ dir: String?) -> Workspace {
        Workspace(id: id, name: name, directory: dir, diskGiB: 64, created: now, lastUsed: now)
    }
    // Two entries resolving to the same file must be refused: they would share one inode,
    // and deleting either would destroy the other.
    var threw = false
    do { try WorkspaceStore.validateDiskPaths([ws("a", "A", "/tmp/velox-x"),
                                               ws("b", "B", "/tmp/velox-x")]) }
    catch { threw = true }
    check(threw, "two workspaces in one folder are rejected")

    // The legacy slot belongs to Default alone.
    threw = false
    do { try WorkspaceStore.validateDiskPaths([ws("other", "Other", Paths.root.path)]) }
    catch { threw = true }
    check(threw, "a non-default workspace may not claim ~/.velox/data.img")

    threw = false
    do { try WorkspaceStore.validateDiskPaths([ws(Workspace.defaultID, "Default", nil),
                                               ws("b", "B", "/tmp/velox-y")]) }
    catch { threw = true }
    check(!threw, "distinct locations are accepted")
}

section("Storage ext4 probes")
do {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("velox-sb-\(getpid())")
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    // A blank workspace disk: no ext4 yet, and — critically — not mistaken for a legacy
    // ASIF image, whose detection DELETES the file.
    let blank = base.appendingPathComponent("blank.img")
    try? Storage.createWorkspaceDisk(at: blank, sizeGiB: 1)
    check(fm.fileExists(atPath: blank.path), "createWorkspaceDisk makes the file")
    equal(logicalBytes(blank), 1 << 30, "…at the requested logical size")
    check(allocBytes(blank) < (1 << 20), "…and sparse (allocates ~nothing)")
    check(!Storage.hasExt4Superblock(at: blank), "a blank disk has no ext4 superblock")
    check(Storage.dataDiskIsClean(at: blank), "a never-formatted disk counts as clean")

    // Synthesize a superblock: magic 0xEF53 at 1080, s_state at 1082.
    func writeSuperblock(_ url: URL, state: UInt16) {
        let fd = open(url.path, O_WRONLY)
        guard fd >= 0 else { return }
        let bytes: [UInt8] = [0x53, 0xEF, UInt8(state & 0xFF), UInt8(state >> 8)]
        bytes.withUnsafeBytes { _ = pwrite(fd, $0.baseAddress, 4, 1080) }
        close(fd)
    }
    let clean = base.appendingPathComponent("clean.img")
    try? Storage.createWorkspaceDisk(at: clean, sizeGiB: 1)
    writeSuperblock(clean, state: 0x0001)                   // VALID_FS
    check(Storage.hasExt4Superblock(at: clean), "ext4 magic is detected")
    check(Storage.dataDiskIsClean(at: clean), "VALID_FS set, ERROR_FS clear ⇒ clean")

    // VALID_FS clear is NOT a dirtiness signal for a journaled ext4: the kernel only
    // clears it on mount when there is no journal. Measured on a real data disk, s_state
    // read VALID_FS=1 identically while mounted, after SIGKILL, and after a clean stop —
    // so this predicate must not claim to detect that.
    let mounted = base.appendingPathComponent("mounted.img")
    try? Storage.createWorkspaceDisk(at: mounted, sizeGiB: 1)
    writeSuperblock(mounted, state: 0x0000)
    check(Storage.dataDiskIsClean(at: mounted),
          "VALID_FS clear is NOT treated as unclean (journaled ext4 leaves it set)")

    let errored = base.appendingPathComponent("errored.img")
    try? Storage.createWorkspaceDisk(at: errored, sizeGiB: 1)
    writeSuperblock(errored, state: 0x0003)                 // VALID_FS | ERROR_FS
    check(!Storage.dataDiskIsClean(at: errored),
          "ERROR_FS set ⇒ refuse to duplicate (the one thing s_state really does tell us)")
}

section("Storage.cloneDataDisk")
do {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("velox-clone-\(getpid())")
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    let src = base.appendingPathComponent("src.img")
    mkSparse(at: src, logical: 256 << 20, dataAt: [0, 64 << 20, 200 << 20])
    let srcAlloc = allocBytes(src)
    let dst = base.appendingPathComponent("dst.img")
    do {
        try Storage.cloneDataDisk(from: src, to: dst)
        equal(logicalBytes(dst), 256 << 20, "clone preserves the logical size")
        check(allocBytes(dst) <= srcAlloc + (4 << 20), "clone preserves sparseness")
        check(fm.fileExists(atPath: src.path), "clone leaves the source in place")

        // Copy-on-write independence: writing through one must not disturb the other.
        let fd = open(dst.path, O_WRONLY)
        if fd >= 0 {
            var byte: UInt8 = 0x5A
            _ = pwrite(fd, &byte, 1, 0)
            close(fd)
        }
        let srcFD = open(src.path, O_RDONLY)
        var first: UInt8 = 0
        if srcFD >= 0 { _ = pread(srcFD, &first, 1, 0); close(srcFD) }
        equal(first, 0xAB, "writing the clone leaves the SOURCE unchanged (COW, not a link)")

        // Two names on one inode would make deleting either destroy both.
        var a = stat(), b = stat()
        stat(src.path, &a); stat(dst.path, &b)
        check(a.st_ino != b.st_ino, "clone is a distinct inode (NOT the move's hard link)")
    } catch { check(false, "clone threw: \(error)") }

    var refused = false
    do { try Storage.cloneDataDisk(from: src, to: dst) } catch { refused = true }
    check(refused, "refuses to clone onto an existing disk")
}

section("Storage.deleteWorkspaceDisk")
do {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("velox-del-\(getpid())")
    // A user-chosen folder holding the disk AND the user's own files — the ~/Documents case.
    let userDir = base.appendingPathComponent("Documents")
    try? fm.createDirectory(at: userDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let precious = userDir.appendingPathComponent("taxes.pdf")
    fm.createFile(atPath: precious.path, contents: Data("keep me".utf8))
    let disk = userDir.appendingPathComponent("data.img")
    try? Storage.createWorkspaceDisk(at: disk, sizeGiB: 1)

    try? Storage.deleteWorkspaceDisk(at: disk, mayRemoveDirectory: false)
    check(!fm.fileExists(atPath: disk.path), "the disk is removed")
    check(fm.fileExists(atPath: precious.path),
          "the user's OWN files beside it survive (delete is never rm -rf on a chosen folder)")
    check(fm.fileExists(atPath: userDir.path), "…and so does their folder")

    // Even asked to, it refuses on a folder that isn't a Velox-owned workspace slot.
    let disk2 = userDir.appendingPathComponent("data.img")
    try? Storage.createWorkspaceDisk(at: disk2, sizeGiB: 1)
    try? Storage.deleteWorkspaceDisk(at: disk2, mayRemoveDirectory: true)
    check(fm.fileExists(atPath: precious.path),
          "mayRemoveDirectory still won't touch a folder outside ~/.velox/workspaces")
}

section("WorkspaceStore (sandboxed VELOX_HOME)")
do {
    // `Paths.root` reads VELOX_HOME on every access, so the whole store can be exercised
    // against a throwaway tree. NSHomeDirectory() ignores $HOME on macOS, so this env
    // override is the only way to test these paths without writing to the real ~/.velox.
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("velox-ws-\(getpid())")
    try? fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
    setenv("VELOX_HOME", sandbox.path, 1)
    defer { unsetenv("VELOX_HOME"); try? fm.removeItem(at: sandbox) }
    equal(Paths.root.path, sandbox.path, "VELOX_HOME redirects Paths.root")

    func resetSandbox() {
        try? fm.removeItem(at: sandbox)
        try? fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    // --- Migration: an existing install's data.img is adopted, never moved. ---
    resetSandbox()
    let legacy = Paths.dataDisk
    mkSparse(at: legacy, logical: 8 << 20, dataAt: [0])
    var legacyStat = stat(); stat(legacy.path, &legacyStat)
    let legacyInode = legacyStat.st_ino
    try? Data("{\"diskGiB\": 96}".utf8).write(to: Paths.config)

    if let m = try? WorkspaceStore.load() {
        equal(m.workspaces.count, 1, "migration produces exactly one workspace")
        equal(m.active.id, Workspace.defaultID, "…which is the Default one")
        equal(m.active.diskGiB, 96, "…carrying the existing diskGiB")
        equal(m.active.dataDiskURL.path, legacy.path, "…pointing at the existing data.img")
        check(m.active.firstBootedAt != nil,
              "an adopted disk counts as already-booted (a later disappearance is a fault)")
        var after = stat(); stat(legacy.path, &after)
        equal(after.st_ino, legacyInode, "migration does NOT move or recreate data.img")
        check(fm.fileExists(atPath: Paths.workspaceManifest.path), "the manifest is written")
    } else { check(false, "migration failed") }

    // --- Migration honours a relocated dataDirectory. ---
    resetSandbox()
    let ext = sandbox.appendingPathComponent("FakeVolume")
    try? fm.createDirectory(at: ext, withIntermediateDirectories: true)
    try? Data("{\"dataDirectory\":\"\(ext.path)\",\"diskGiB\":32}".utf8).write(to: Paths.config)
    if let m = try? WorkspaceStore.load() {
        equal(m.active.dataDiskURL.path, ext.appendingPathComponent("data.img").path,
              "a relocated dataDirectory carries straight over")
    } else { check(false, "relocated migration failed") }

    // --- M1: a corrupt config.json must NOT be migrated into a wrong pointer. ---
    resetSandbox()
    try? Data("{ this is not json".utf8).write(to: Paths.config)
    var refused = false
    do { _ = try WorkspaceStore.load() } catch { refused = true }
    check(refused, "migration REFUSES on an unreadable config.json (never guesses ~/.velox)")
    check(!fm.fileExists(atPath: Paths.workspaceManifest.path),
          "…and writes no manifest, so the real location is still recoverable")

    // --- A corrupt manifest fails loudly instead of synthesizing a fresh Default. ---
    resetSandbox()
    try? Data("{}".utf8).write(to: Paths.config)
    try? Data("{ broken".utf8).write(to: Paths.workspaceManifest)
    refused = false
    do { _ = try WorkspaceStore.load() } catch { refused = true }
    check(refused, "a corrupt manifest throws (it never hides real workspaces behind a new Default)")

    // --- Create / rename / activate / delete. ---
    resetSandbox()
    try? Data("{}".utf8).write(to: Paths.config)
    _ = try? WorkspaceStore.load()
    let made = try! WorkspaceStore.create(name: "Staging", diskGiB: 8)
    check(made.diskExists, "create makes the workspace's blank disk")
    check(!Storage.hasExt4Superblock(at: made.dataDiskURL),
          "…blank, for vinit to format on first boot")
    equal((try? WorkspaceStore.load())?.workspaces.count ?? 0, 2, "the list now has two")

    var dup = false
    do { _ = try WorkspaceStore.create(name: "staging", diskGiB: 8) } catch { dup = true }
    check(dup, "a duplicate name (case-insensitively) is rejected")

    try? WorkspaceStore.rename(id: made.id, to: "Prod")
    equal((try? WorkspaceStore.load())?.workspace(id: made.id)?.name ?? "", "Prod", "rename works")
    check((try? WorkspaceStore.load())?.workspace(named: "prod") != nil,
          "name lookup is case-insensitive")

    // Deleting the ACTIVE workspace is refused — no implicit switch hidden in a delete.
    var blocked = false
    do { try WorkspaceStore.delete(id: Workspace.defaultID) } catch { blocked = true }
    check(blocked, "the active workspace can't be deleted")

    try? WorkspaceStore.activate(id: made.id)
    equal((try? WorkspaceStore.load())?.activeID ?? "", made.id, "activate repoints the manifest")

    blocked = false
    do { try WorkspaceStore.delete(id: made.id) } catch { blocked = true }
    check(blocked, "…and it's still refused after it BECOMES active")

    try? WorkspaceStore.activate(id: Workspace.defaultID)
    let deletedDisk = made.dataDiskURL
    try? WorkspaceStore.delete(id: made.id)
    equal((try? WorkspaceStore.load())?.workspaces.count ?? 0, 1, "delete removes the entry")
    check(!fm.fileExists(atPath: deletedDisk.path), "…and its disk")
    check(!fm.fileExists(atPath: deletedDisk.deletingLastPathComponent().path),
          "…and its now-empty owned slot folder")

    // The last workspace can never be removed.
    blocked = false
    do { try WorkspaceStore.delete(id: Workspace.defaultID) } catch { blocked = true }
    check(blocked, "the last workspace can't be deleted")

    // --- revision bumps on every write (stale-writer detection). ---
    let before = (try? WorkspaceStore.load())?.revision ?? -1
    try? WorkspaceStore.activate(id: Workspace.defaultID)
    let bumped = (try? WorkspaceStore.load())?.revision ?? -1
    check(bumped > before, "every mutation bumps revision (\(before) → \(bumped))")

    // --- mutate() re-reads from disk, so a stale in-memory copy can't clobber. ---
    let stale = try? WorkspaceStore.load()
    _ = try? WorkspaceStore.create(name: "FromElsewhere", diskGiB: 8)   // "another process"
    try? WorkspaceStore.rename(id: Workspace.defaultID, to: "Renamed")  // stale caller writes
    let merged = try? WorkspaceStore.load()
    check(merged?.workspace(named: "FromElsewhere") != nil,
          "a concurrent workspace SURVIVES a later write (read-modify-write under flock)")
    equal(merged?.workspace(id: Workspace.defaultID)?.name ?? "", "Renamed",
          "…and the later write still lands")
    check(stale != nil, "sanity: the stale snapshot existed")

    // --- Clone through the store: refuses an unclean source. ---
    let src = merged?.workspace(id: Workspace.defaultID)
    if let src {
        mkSparse(at: src.dataDiskURL, logical: 8 << 20, dataAt: [0])
        let fd = open(src.dataDiskURL.path, O_WRONLY)
        if fd >= 0 {
            let sb: [UInt8] = [0x53, 0xEF, 0x03, 0x00]   // ext4 magic, VALID_FS | ERROR_FS
            sb.withUnsafeBytes { _ = pwrite(fd, $0.baseAddress, 4, 1080) }
            close(fd)
        }
        var refusedClone = false
        do { _ = try WorkspaceStore.clone(id: src.id, newName: "Copy") }
        catch { refusedClone = true }
        check(refusedClone, "cloning a disk with recorded filesystem errors is refused")
    }
}

// MARK: Dispatch-source handler isolation

section("DispatchSource handlers from a @MainActor context")
@MainActor
final class CancelHandlerProbe {
    private var source: DispatchSourceRead?
    private(set) var cancelled = false

    /// Mirrors `EngineLogStore.attach` exactly. A cancel handler ALWAYS runs on the
    /// source's own queue, but written inline inside a `@MainActor` method it inherits
    /// `@MainActor` — which `@convention(block)` accepts silently and the runtime then traps
    /// on (`swift_task_isCurrentExecutor` → `dispatch_assert_queue`) when it fires. That is a
    /// hard SIGTRAP on every engine stop the process outlives, so if this regresses the
    /// self-test dies here rather than reporting a failure. That is the intended signal.
    func attach(_ fd0: Int32) {
        let fd = dup(fd0)
        let src = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: DispatchQueue(label: "velox.selftest.isolation"))
        let handler: @Sendable () -> Void = {
            var b = [UInt8](repeating: 0, count: 8); _ = read(fd, &b, 8)
        }
        src.setEventHandler(handler: handler)
        let onCancel: @Sendable () -> Void = { close(fd) }
        src.setCancelHandler(handler: onCancel)
        src.resume()
        source = src
    }

    func detach() { source?.cancel(); source = nil; cancelled = true }
}

do {
    let pipe = Pipe()
    let probe = CancelHandlerProbe()
    probe.attach(pipe.fileHandleForReading.fileDescriptor)
    usleep(150_000)
    probe.detach()          // fires the cancel handler on the source's queue
    usleep(300_000)         // give it time to run (and trap, if it ever regresses)
    check(probe.cancelled, "a @MainActor-formed cancel handler fires off-main without trapping")
}

section("Workspace.deleteConfirmationMatches")
do {
    let now = Date()
    let w = Workspace(id: "x", name: "Staging", diskGiB: 8, created: now, lastUsed: now)
    check(w.deleteConfirmationMatches("Staging"), "the exact name arms the delete")
    check(w.deleteConfirmationMatches("  staging  "), "case and surrounding space are forgiven")
    check(!w.deleteConfirmationMatches(""), "an EMPTY confirmation never arms it")
    check(!w.deleteConfirmationMatches("   "), "…nor whitespace only")
    check(!w.deleteConfirmationMatches("Stagin"), "a near miss does not arm it")
    check(!w.deleteConfirmationMatches("Staging2"), "a longer name does not arm it")
    let blank = Workspace(id: "y", name: "  ", diskGiB: 8, created: now, lastUsed: now)
    check(!blank.deleteConfirmationMatches(""),
          "a blank-named workspace can't be armed by an empty box")
}

section("Workspace.diskGiB clamping")
do {
    let now = Date()
    equal(Workspace.clampDiskGiB(4), 8, "below the range clamps up")
    equal(Workspace.clampDiskGiB(512), 256, "above the range clamps down")
    equal(Workspace.clampDiskGiB(64), 64, "inside the range is untouched")
    // A hand-edited or older manifest must not be able to put the Settings slider outside
    // its bounds, which is undefined behaviour for a SwiftUI Slider.
    let json = Data("""
    {"id":"z","name":"Huge","diskGiB":4096,"created":"2026-01-01T00:00:00Z",
     "lastUsed":"2026-01-01T00:00:00Z"}
    """.utf8)
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    if let decoded = try? d.decode(Workspace.self, from: json) {
        equal(decoded.diskGiB, 256, "decoding clamps an out-of-range size")
    } else { check(false, "decode failed") }
    _ = now
}

section("WorkspaceCapabilities")
do {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("velox-caps-\(getpid())")
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let now = Date()
    func ws(_ id: String, _ name: String, dir: URL) -> Workspace {
        Workspace(id: id, name: name, directory: dir.path, diskGiB: 8,
                  created: now, lastUsed: now, firstBootedAt: now)
    }
    let aDir = base.appendingPathComponent("a"), bDir = base.appendingPathComponent("b")
    let a = ws("a", "Alpha", dir: aDir), b = ws("b", "Beta", dir: bDir)
    try? Storage.createWorkspaceDisk(at: a.dataDiskURL, sizeGiB: 1)
    try? Storage.createWorkspaceDisk(at: b.dataDiskURL, sizeGiB: 1)

    func caps(_ w: Workspace, active: String?, count: Int = 2,
              busy: Bool = false, attached: URL? = nil) -> WorkspaceCapabilities {
        WorkspaceCapabilities(workspace: w, activeID: active, workspaceCount: count,
                              engineBusy: busy, attachedDiskURL: attached)
    }

    // The active workspace can't be deleted — that would hide an engine restart in a delete.
    let activeCaps = caps(a, active: "a")
    check(activeCaps.isActive, "the active workspace is marked active")
    check(!activeCaps.canDelete, "the active workspace can't be deleted")
    check(!activeCaps.canSwitch, "…and can't be switched to (already there)")
    check(activeCaps.canDuplicate, "…but CAN be duplicated (the op stops the engine first)")

    let idleCaps = caps(b, active: "a")
    check(idleCaps.canDelete && idleCaps.canSwitch, "an inactive workspace can be deleted and switched to")

    // The last workspace must survive.
    check(!caps(a, active: "a", count: 1).canDelete, "the last workspace can't be deleted")
    check(!caps(b, active: "a", count: 1).canDelete, "…even when it isn't the active one")

    // THE important one: a disk the VM actually has open is off limits, even when the
    // manifest says a different workspace is active (another process can rewrite activeID).
    let attachedButNotActive = caps(b, active: "a", attached: b.dataDiskURL)
    check(!attachedButNotActive.canDelete,
          "a disk the VM HAS OPEN can't be deleted even if activeID says otherwise")
    equal(attachedButNotActive.deleteBlockedReason ?? "",
          "This is the active workspace — switch to another first.",
          "…and says why")

    // Path comparison must survive a non-standardized URL.
    let messy = URL(fileURLWithPath: bDir.path + "/./data.img")
    check(!caps(b, active: "a", attached: messy).canDelete,
          "attachment matching standardizes the path first")

    // Busy engine locks everything down.
    let busy = caps(b, active: "a", busy: true)
    check(!busy.canDelete && !busy.canSwitch && !busy.canDuplicate && !busy.canRename,
          "nothing is offered while an operation owns the engine")

    // A workspace whose disk is gone can't be duplicated or revealed.
    let ghost = ws("g", "Ghost", dir: base.appendingPathComponent("gone"))
    let ghostCaps = caps(ghost, active: "a")
    check(!ghostCaps.canDuplicate, "a workspace with no disk can't be duplicated")
    check(!ghostCaps.canRevealInFinder, "…nor revealed in Finder")
    check(ghostCaps.canDelete, "…but can still be deleted (to clear a dead entry)")

    // A filesystem with recorded errors must not be propagated into a copy.
    let broken = ws("x", "Broken", dir: base.appendingPathComponent("x"))
    try? Storage.createWorkspaceDisk(at: broken.dataDiskURL, sizeGiB: 1)
    let fd = open(broken.dataDiskURL.path, O_WRONLY)
    if fd >= 0 {
        let sb: [UInt8] = [0x53, 0xEF, 0x03, 0x00]   // ext4 magic, VALID_FS | ERROR_FS
        sb.withUnsafeBytes { _ = pwrite(fd, $0.baseAddress, 4, 1080) }
        close(fd)
    }
    check(!caps(broken, active: "a").canDuplicate,
          "a filesystem with recorded errors can't be duplicated")
}

section("Review pass: symlink aliasing + .DS_Store cleanup")
do {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("velox-review-\(getpid())")
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let now = Date()

    // Two never-booted workspaces whose folders alias through a symlink: neither disk
    // exists, so the (st_dev, st_ino) cross-check can't see them — only path resolution can.
    let real = base.appendingPathComponent("real")
    try? fm.createDirectory(at: real, withIntermediateDirectories: true)
    let link = base.appendingPathComponent("link")
    try? fm.createSymbolicLink(at: link, withDestinationURL: real)
    let a = Workspace(id: "a", name: "A", directory: real.path, diskGiB: 8,
                      created: now, lastUsed: now)
    let b = Workspace(id: "b", name: "B", directory: link.path, diskGiB: 8,
                      created: now, lastUsed: now)
    var threw = false
    do { try WorkspaceStore.validateDiskPaths([a, b]) } catch { threw = true }
    check(threw, "two DISKLESS workspaces aliasing through a symlink are rejected")

    // Finder drops a .DS_Store into any folder it opens (the sidebar offers Show in
    // Finder), and that must not turn every delete into an orphaned slot directory.
    let sandbox = fm.temporaryDirectory.appendingPathComponent("velox-review-home-\(getpid())")
    try? fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
    setenv("VELOX_HOME", sandbox.path, 1)
    defer { unsetenv("VELOX_HOME"); try? fm.removeItem(at: sandbox) }
    let slot = Paths.workspaces.appendingPathComponent("some-id", isDirectory: true)
    let disk = slot.appendingPathComponent("data.img")
    try? Storage.createWorkspaceDisk(at: disk, sizeGiB: 1)
    fm.createFile(atPath: slot.appendingPathComponent(".DS_Store").path,
                  contents: Data([0x00]))
    try? Storage.deleteWorkspaceDisk(at: disk, mayRemoveDirectory: true)
    check(!fm.fileExists(atPath: slot.path),
          "an owned slot holding only .DS_Store is still removed on delete")

    // But real content beside the disk still blocks the directory removal.
    let slot2 = Paths.workspaces.appendingPathComponent("other-id", isDirectory: true)
    let disk2 = slot2.appendingPathComponent("data.img")
    try? Storage.createWorkspaceDisk(at: disk2, sizeGiB: 1)
    fm.createFile(atPath: slot2.appendingPathComponent("notes.txt").path,
                  contents: Data("mine".utf8))
    try? Storage.deleteWorkspaceDisk(at: disk2, mayRemoveDirectory: true)
    check(fm.fileExists(atPath: slot2.appendingPathComponent("notes.txt").path),
          "…while any real file beside the disk still blocks it")
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
        (2, -1),           // tcp6 bind → failure (asserts the v6 wire verb only)
        (2, -1),           // tcp any bind → failure (asserts the wildcard wire verb only)
        (2, -1),           // udp6 any bind → failure (wildcard + v6 compose)
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
        // ipv6:true selects the [::1] loopback bind (privileged-port localhost twin).
        check(PortHelperClient.requestListener(port: 80, proto: .tcp, ipv6: true) == nil, "tcp6 bind failure → nil")
        // wildcard:true appends the `any` argument — an all-interface bind, so a published
        // privileged port is reachable off-box. Absent it, the request MUST stay loopback.
        check(PortHelperClient.requestListener(port: 80, proto: .tcp, wildcard: true) == nil,
              "tcp any bind failure → nil")
        check(PortHelperClient.requestListener(port: 53, proto: .udp, ipv6: true, wildcard: true) == nil,
              "udp6 any bind failure → nil")

        // The wire format is the contract with the root daemon — assert it verbatim.
        equal(daemon.requests, ["tcp 80", "udp 81",
                                "route add 172.18.0.0/16 192.168.64.2",
                                "route del 172.18.0.0/16", "ipfwd", "tcp6 80",
                                "tcp 80 any", "udp6 53 any"],
              "request lines match the daemon protocol")
        daemon.stop()
        close(pipeFds[0])
        PortHelperClient.socketPath = PortHelperClient.productionSocketPath
    } else {
        check(false, "fake daemon failed to start")
    }

    // The upgrade path: a helper installed BEFORE the `any` verb rejects an all-interface
    // request with EINVAL. The manager must then retry the plain loopback verb so the port
    // still works host-locally, rather than dropping it. This runs exactly once per user —
    // on the release that introduces the verb — so it must be right without a second chance.
    var legacyPipe = [Int32](repeating: 0, count: 2)
    _ = pipe(&legacyPipe)
    var mark: UInt8 = 0x77
    _ = write(legacyPipe[1], &mark, 1)
    close(legacyPipe[1])
    if let legacy = FakeDaemon(script: [(UInt8(EINVAL & 0xff), -1),   // "tcp 80 any" → rejected
                                        (0, legacyPipe[0])]) {        // "tcp 80"     → accepted
        PortHelperClient.socketPath = legacy.path
        let mgr = PortHelperManager()
        let fd = mgr.boundListener(port: 80, proto: .tcp, ipv6: false, wildcard: true)
        check(fd != nil, "pre-`any` helper: wildcard rejected → falls back to loopback, port still bound")
        if let fd {
            var back: UInt8 = 0
            check(read(fd, &back, 1) == 1 && back == 0x77, "fallback returns the real descriptor")
            close(fd)
        }
        equal(legacy.requests, ["tcp 80 any", "tcp 80"],
              "fallback tried the wildcard verb FIRST, then the loopback verb")
        legacy.stop()
        close(legacyPipe[0])
    } else {
        check(false, "legacy fake daemon failed to start")
    }

    // Helper absent entirely (not installed, or the user declined the admin prompt):
    // every request must fail soft — nil, no crash, no hang.
    PortHelperClient.socketPath = "/tmp/velox-selftest-absent-\(getpid()).sock"
    let absent = PortHelperManager()
    check(absent.boundListener(port: 80, proto: .tcp, ipv6: false, wildcard: true) == nil,
          "helper absent: wildcard bind returns nil (degrades, never traps)")
    check(absent.boundListener(port: 80, proto: .tcp, ipv6: false, wildcard: false) == nil,
          "helper absent: loopback bind returns nil")
    check(!absent.route(add: true, subnet: "172.18.0.0/16", gateway: "192.168.64.2"),
          "helper absent: route add returns false")
    check(!absent.restoreIPForwarding(), "helper absent: ipfwd returns false")
    PortHelperClient.socketPath = PortHelperClient.productionSocketPath
}

// MARK: EventRelay — data integrity, backpressure re-arm, half-close
//
// This coverage moved here from `SocketPump`, which was a second implementation of the same
// job and has been deleted. The relay now carries BOTH the conduit fast path and the
// Docker-API proxy, so these assertions guard the one splice everything depends on. The
// lazy-buffer change makes the bulk case matter more, not less: the payload below is several
// times the buffer, so it exercises the 32 KiB→256 KiB growth and the drain-coupled re-arm.

// Wrapped in a sync function: top-level script code is an async context, where the
// blocking DispatchSemaphore.wait / NSLock used to drive the relay are unavailable.
@MainActor func socketPumpTest() {
    section("EventRelay")
    func makePair() -> (Int32, Int32) {
        var fds = [Int32](repeating: -1, count: 2)
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        return (fds[0], fds[1])
    }
    // pump splices pumpA <-> pumpB; the test drives testA/testB (the far ends).
    let (testA, pumpA) = makePair()
    let (testB, pumpB) = makePair()

    let closed = DispatchSemaphore(value: 0)
    // A dedicated relay (not `.shared`) so the test can't be disturbed by, or disturb, a
    // live engine's traffic.
    let relay = EventRelay(workerCount: 2)
    relay.relay(pumpA, pumpB) { closed.signal() }

    // A payload several times the relay buffer, so the read/write re-arm and the
    // backpressure drain-coupling are exercised across many chunks (not a single read).
    let count = 1_000_000
    var sent = [UInt8](repeating: 0, count: count)
    var x: UInt32 = 0x9E37_79B9
    for i in 0..<count { x = x &* 1_664_525 &+ 1_013_904_223; sent[i] = UInt8(truncatingIfNeeded: x >> 24) }

    // Reader: drain testB until EOF, then half-close so the reverse direction can finish.
    let readerDone = DispatchSemaphore(value: 0)
    let recvLock = NSLock()
    nonisolated(unsafe) var received = [UInt8]()
    DispatchQueue.global().async {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(testB, &buf, buf.count)
            if n <= 0 { break }
            recvLock.lock(); received.append(contentsOf: buf[0..<n]); recvLock.unlock()
        }
        shutdown(testB, SHUT_WR) // EOF for the B→A direction so the pump can fully close
        readerDone.signal()
    }

    // Writer: send the whole payload, then half-close the A→B direction.
    let sentCopy = sent
    DispatchQueue.global().async {
        var off = 0
        while off < count {
            let n = sentCopy[off...].withUnsafeBytes { write(testA, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            off += n
        }
        shutdown(testA, SHUT_WR)
    }

    check(readerDone.wait(timeout: .now() + 15) == .success, "reader reached EOF (half-close propagated A→B)")
    check(closed.wait(timeout: .now() + 15) == .success, "onClose fired once both directions closed")
    recvLock.lock(); let got = received; recvLock.unlock()
    equal(got.count, count, "every byte forwarded through the relay")
    check(got == sent, "payload survives the relay byte-for-byte across many buffers")

    close(testA); close(testB)
}
socketPumpTest()

// MARK: DockerEventHub — one upstream fanned out, finish-on-drop, reconnect

@MainActor func eventHubTest() {
    section("DockerEventHub")

    func mkEvent(_ action: String) -> DockerEvent {
        try! JSONDecoder().decode(DockerEvent.self,
            from: Data(#"{"Type":"container","Action":"\#(action)"}"#.utf8))
    }
    // The hub starts/stops its upstream task asynchronously — spin-wait for the state.
    func spin(_ cond: @escaping () -> Bool, _ secs: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(secs)
        while Date() < deadline { if cond() { return true }; Thread.sleep(forTimeInterval: 0.005) }
        return cond()
    }
    // A controllable upstream: counts connections, yields on demand, finishes on drop().
    final class Upstream: @unchecked Sendable {
        let lock = NSLock()
        var cont: AsyncStream<DockerEvent>.Continuation?
        var connects = 0
        func make() -> AsyncStream<DockerEvent> {
            AsyncStream { c in lock.lock(); cont = c; connects += 1; lock.unlock() }
        }
        func yield(_ e: DockerEvent) { lock.lock(); let c = cont; lock.unlock(); c?.yield(e) }
        func drop() { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.finish() }
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return connects }
    }
    final class Sink: @unchecked Sendable {
        let lock = NSLock()
        var got = [String](); var finished = false
        func add(_ s: String) { lock.lock(); got.append(s); lock.unlock() }
        func finish() { lock.lock(); finished = true; lock.unlock() }
        func has(_ s: String) -> Bool { lock.lock(); defer { lock.unlock() }; return got.contains(s) }
        func done() -> Bool { lock.lock(); defer { lock.unlock() }; return finished }
    }

    let up = Upstream()
    let hub = DockerEventHub { up.make() }

    let sinkA = Sink(); let sinkB = Sink()
    let taskA = Task.detached { for await e in hub.subscribe() { sinkA.add(e.action ?? "") }; sinkA.finish() }
    let taskB = Task.detached { for await e in hub.subscribe() { sinkB.add(e.action ?? "") }; sinkB.finish() }

    check(spin { up.count() == 1 }, "two subscribers share one upstream connection")
    up.yield(mkEvent("start"))
    check(spin { sinkA.has("start") && sinkB.has("start") }, "event fans out to every subscriber")
    equal(up.count(), 1, "still a single upstream connection after broadcast")

    up.drop() // dockerd restart
    check(spin { sinkA.done() && sinkB.done() },
          "subscriber streams finish on upstream drop (so consumers reconcile)")

    let sinkC = Sink()
    let taskC = Task.detached { for await e in hub.subscribe() { sinkC.add(e.action ?? "") }; sinkC.finish() }
    check(spin { up.count() == 2 }, "re-subscribe reconnects exactly one fresh upstream")
    up.yield(mkEvent("die"))
    check(spin { sinkC.has("die") }, "reconnected subscriber receives events")

    taskA.cancel(); taskB.cancel(); taskC.cancel()
}
eventHubTest()

// MARK: Published-port bind resolution (host-side reachability semantics)

section("PublishBind / PublishedPort")
do {
    // The config knob. An unparseable value must NOT resolve to the wildcard default:
    // the only reason to set this key is to restrict, so a typo has to fail closed.
    check(PublishBind.parse("0.0.0.0").isWildcard, "0.0.0.0 → wildcard")
    check(PublishBind.parse("").isWildcard, "empty → wildcard (the default)")
    check(!PublishBind.parse("127.0.0.1").isWildcard, "127.0.0.1 → host-only")
    check(!PublishBind.parse("192.168.5.243").isWildcard, "specific address → not wildcard")
    equal(PublishBind.parse("192.168.5.243").label, "192.168.5.243", "specific address kept verbatim")
    check(!PublishBind.parse("127.0.0.").isWildcard, "typo fails CLOSED (host-only), never wildcard")
    check(!PublishBind.parse("nonsense").isWildcard, "garbage fails CLOSED (host-only)")

    // isLoopback drives the privileged-port degradation path: the root helper can bind
    // loopback or all-interfaces only, so a *specific* publishHostIP below 1024 must be
    // detected and reported, never silently bound to loopback while logging the address.
    check(PublishBind.loopback.isLoopback, "loopback bind reports isLoopback")
    check(PublishBind.parse("localhost").isLoopback, "localhost normalises to the loopback bind")
    check(!PublishBind.wildcard.isLoopback, "wildcard is not loopback")
    check(!PublishBind.parse("192.168.5.243").isLoopback, "a specific address is neither")
    check(!PublishBind.parse("192.168.5.243").isWildcard, "…and not wildcard → the degraded case")

    // Loopback literals as dockerd reports them in the port list.
    check(PublishBind.isLoopbackLiteral("127.0.0.1"), "127.0.0.1 is a loopback literal")
    check(PublishBind.isLoopbackLiteral("::1"), "::1 is a loopback literal")
    check(!PublishBind.isLoopbackLiteral("0.0.0.0"), "0.0.0.0 is NOT loopback")
    check(!PublishBind.isLoopbackLiteral("::"), ":: is NOT loopback")
    check(!PublishBind.isLoopbackLiteral(nil), "absent IP is NOT loopback")

    // The regression this guards: a container that explicitly published on loopback
    // (`-p 127.0.0.1:5432:5432`) must stay host-only even when the global default is
    // all-interfaces — otherwise turning on Docker-compatible publishing silently
    // exposes every deliberately-private service (a database, an admin port) to the LAN.
    let pinned = PublishedPort(port: 5432, loopbackOnly: true)
    let plain = PublishedPort(port: 8080, loopbackOnly: false)
    check(!pinned.bind(default: .wildcard).isWildcard,
          "explicit -p 127.0.0.1 stays host-only under a wildcard default")
    check(plain.bind(default: .wildcard).isWildcard,
          "plain -p publishes on all interfaces under a wildcard default")
    check(!plain.bind(default: .loopback).isWildcard,
          "a host-only default still narrows a plain -p")

    // A port whose bind flips must compare unequal, or the forwarder's reconcile would
    // keep the stale listener (right port, wrong address) instead of rebinding.
    check(PublishedPort(port: 80, loopbackOnly: true) != PublishedPort(port: 80, loopbackOnly: false),
          "same port, different bind → distinct specs (forces a rebind)")
}


// MARK: Guest install stamp

/// The installed guest is refreshed from the app bundle only when this stamp changes.
/// Stamping on the VERSION ALONE silently kept a two-month-old guest across a rebuild and
/// downgraded the running kernel from 7.1.3 to 6.18.35 — invisible, because the versions
/// matched. These assertions pin the content-sensitivity that fixed it.
@MainActor func guestInstallStampTest() {
    section("GuestInstall stamp")
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("velox-stamp-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let kernel = dir.appendingPathComponent("kernel")
    let root = dir.appendingPathComponent("root.img")
    FileManager.default.createFile(atPath: kernel.path, contents: Data(repeating: 1, count: 64))
    FileManager.default.createFile(atPath: root.path, contents: Data(repeating: 2, count: 128))

    let base = GuestInstall.stamp(version: "1.0.0", kernel: kernel, root: root)
    check(base == GuestInstall.stamp(version: "1.0.0", kernel: kernel, root: root),
          "same version + same artifacts → identical stamp (no needless reinstall)")
    check(base != GuestInstall.stamp(version: "1.0.1", kernel: kernel, root: root),
          "a version bump alone changes the stamp")

    // The regression: same version, rebuilt artifact. Must NOT compare equal.
    try? Data(repeating: 9, count: 999).write(to: kernel)
    let rebuiltKernel = GuestInstall.stamp(version: "1.0.0", kernel: kernel, root: root)
    check(rebuiltKernel != base, "a rebuilt kernel at the SAME version changes the stamp")

    try? Data(repeating: 9, count: 4242).write(to: root)
    check(GuestInstall.stamp(version: "1.0.0", kernel: kernel, root: root) != rebuiltKernel,
          "a rebuilt rootfs at the SAME version changes the stamp")

    // A touched-but-identical file still changes mtime, so it re-installs — safe direction.
    let touched = dir.appendingPathComponent("missing")
    check(GuestInstall.stamp(version: "1.0.0", kernel: touched, root: root)
          != GuestInstall.stamp(version: "1.0.0", kernel: kernel, root: root),
          "a missing artifact never matches a real one")
}
guestInstallStampTest()

// MARK: Disk-usage error translation

/// One damaged container record fails the whole `/system/df` request, which used to reach
/// the user as a raw 500. It must arrive as something actionable instead.
@MainActor func diskUsageMessageTest() {
    section("Disk usage error")
    let raw = "docker API error 500: failed to retrieve container list: rw layer snapshot "
        + "not found for container 024c634c5abff50b7183208b307e0fbfe18eb96216d8fc4e6f10422d9b1485d5"
    let msg = DockerClient.diskUsageMessage(for: raw)
    check(msg.contains("024c634c5abf"), "names the damaged container (short id)")
    check(msg.contains("docker rm -f"), "tells the user how to fix it")
    check(!msg.contains("API error 500"), "the raw API error is not what the user reads")
    let other = "docker API error 500: something else entirely"
    check(DockerClient.diskUsageMessage(for: other) == other,
          "unrecognised failures pass through unchanged")
}
diskUsageMessageTest()

// MARK: Host routing table (named-access healing)

section("NamedAccessRouter.installedRoutes")
@MainActor func installedRoutesTest() {
    // Parses the raw `sysctl(NET_RT_DUMP)` route dump. It decides whether a route Velox
    // installed is still present, so a parser that silently returns nothing would make every
    // network path change re-apply every route (the churn + no-route window this replaced),
    // and one that returns garbage would make a genuinely flushed route look healthy —
    // silently killing `<name>.velox.local` after VPN churn. Loopback is on every Mac.
    let routes = NamedAccessRouter.installedRoutes()
    check(!routes.isEmpty, "the route dump parses to at least one network route")
    check(routes["127.0.0.0/8"] != nil, "the loopback network route is found")
    check(routes.keys.allSatisfy { r in
        let parts = r.split(separator: "/")
        guard parts.count == 2, let plen = Int(parts[1]), (0...32).contains(plen) else { return false }
        return parts[0].split(separator: ".").count == 4
    }, "every entry is a well-formed IPv4 CIDR")
    // The next hop is what distinguishes "our route is still installed" from "someone else
    // took the prefix", so it has to parse too: either a dotted quad or "" for a link route.
    check(routes.values.allSatisfy { hops in
        hops.allSatisfy { $0.isEmpty || $0.split(separator: ".").count == 4 }
    }, "every next hop is either empty (link route) or a dotted quad")
    // The default route reaches a gateway on any machine with network access, so it is the one
    // entry we can assert carries a real next hop — and it is also the prefix macOS most often
    // holds twice, which is why the value is a set.
    // If Velox is running, its container-subnet routes must carry the guest IP as their next
    // hop — that is exactly the fact `refresh()` uses to tell "our route survived" from
    // "someone else took this prefix", so a parser that lost the gateway would silently make
    // named-access healing a no-op.
    for (cidr, hops) in routes where cidr.hasPrefix("172.1") || cidr.hasPrefix("172.2") {
        check(hops.contains { $0.split(separator: ".").count == 4 },
              "container subnet \(cidr) records a real next hop (\(hops.sorted()))")
    }
    if let viaDefault = routes["0.0.0.0/0"] {
        check(viaDefault.contains { !$0.isEmpty },
              "the default route records a next hop (\(viaDefault.sorted()))")
    }
}
installedRoutesTest()

// MARK: Summary

print("\n----------------------------------------")
if failures == 0 {
    print("All self-tests passed.")
    exit(0)
} else {
    print("\(failures) self-test(s) FAILED.")
    exit(1)
}
