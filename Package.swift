// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Velox",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "Velox",
            path: "Sources/Velox",
            linkerSettings: [
                .linkedFramework("Virtualization")
            ]
        )
    ]
)
