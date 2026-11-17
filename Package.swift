// swift-tools-version: 5.10
import PackageDescription

// The command-line side of psyduck. The Mac app is built separately, from
// PsyduckMac/project.yml.
let package = Package(
    name: "psyduck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "psyduck", targets: ["psyduck"]),
        .library(name: "PsyduckHost", targets: ["PsyduckHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // `psyduck host …`: provisions and manages EC2 hosts by shelling out
        // to `aws` and `ssh`. Foundation only, so it builds on Linux too.
        .target(name: "PsyduckHost"),
        .executableTarget(
            name: "psyduck",
            dependencies: [
                "PsyduckHost",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "PsyduckHostTests", dependencies: ["PsyduckHost"]),
    ],
    swiftLanguageVersions: [.v5]
)
