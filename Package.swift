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
        // Shared engine + Docker-API core. Links Virtualization.framework; both
        // the CLI and the GUI app depend on it.
        .target(
            name: "VeloxCore",
            path: "Sources/VeloxCore",
            linkerSettings: [
                .linkedFramework("Virtualization")
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
