// swift-tools-version: 5.10
import PackageDescription

// The parts of psyduck that aren't the Mac app's UI. They build on macOS and
// Linux; the app in PsyduckMac/ depends on PsyduckCore as a local package.
let package = Package(
    name: "psyduck",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PsyduckCore", targets: ["PsyduckCore"]),
    ],
    targets: [
        // The engine: repos, worktrees, claude turns, event logs, branch actions.
        .target(name: "PsyduckCore"),
        .testTarget(name: "PsyduckCoreTests", dependencies: ["PsyduckCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
