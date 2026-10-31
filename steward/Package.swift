// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "steward",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "StewardCore"),
        .executableTarget(name: "steward", dependencies: ["StewardCore"]),
        .testTarget(name: "StewardCoreTests", dependencies: ["StewardCore"]),
    ]
)
