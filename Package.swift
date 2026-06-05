// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Velox",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "VeloxCore", targets: ["VeloxCore"]),
        .executable(name: "velox", targets: ["velox"]),
        .executable(name: "VeloxApp", targets: ["VeloxApp"])
    ],
    targets: [
        // C interop shim for the velox-net Rust staticlib (host userspace netstack).
        // Header-only; the implementation is libveloxnet.a, built by
        // Scripts/build-net.sh and linked into VeloxCore below.
        .target(name: "CVeloxNet", path: "Sources/CVeloxNet"),
        // Shared engine + Docker-API core. Links Virtualization.framework + the
        // velox-net staticlib; both the CLI and the GUI app depend on it.
        .target(
            name: "VeloxCore",
            dependencies: ["CVeloxNet"],
            path: "Sources/VeloxCore",
            linkerSettings: [
                .linkedFramework("Virtualization"),
                // Link the host netstack staticlib (build-net.sh must run first).
                // The host is aarch64-apple-darwin, so cargo's native release dir.
                .unsafeFlags([
                    "-Lhost/velox-net/target/release",
                    "-lveloxnet",
                    "-liconv",   // pulled in by the Rust std staticlib on macOS
                ])
            ]
        ),
        // The `velox` CLI (start/status/version/update). Was the old single target.
        .executableTarget(
            name: "velox",
            dependencies: ["VeloxCore"],
            path: "Sources/velox"
        ),
        // The native SwiftUI desktop app (menu bar + dashboards + settings).
        .executableTarget(
            name: "VeloxApp",
            dependencies: ["VeloxCore"],
            path: "Sources/VeloxApp"
        ),
        // Dependency-free test runner (the repo targets Command Line Tools, which
        // ships no XCTest). Run with `swift run velox-selftest`.
        .executableTarget(
            name: "velox-selftest",
            dependencies: ["VeloxCore"],
            path: "Tests/SelfTest"
        )
    ]
)
