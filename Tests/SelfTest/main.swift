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

// MARK: Summary

print("\n----------------------------------------")
if failures == 0 {
    print("All self-tests passed.")
    exit(0)
} else {
    print("\(failures) self-test(s) FAILED.")
    exit(1)
}
