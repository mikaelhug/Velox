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

// MARK: Summary

print("\n----------------------------------------")
if failures == 0 {
    print("All self-tests passed.")
    exit(0)
} else {
    print("\(failures) self-test(s) FAILED.")
    exit(1)
}
