// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "familiar",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "FamiliarCore"),
        .executableTarget(name: "familiar", dependencies: ["FamiliarCore"]),
        .testTarget(name: "FamiliarCoreTests", dependencies: ["FamiliarCore"]),
    ]
)
