// swift-tools-version: 5.10
import PackageDescription

// The parts of psyduck that aren't the Mac app's UI. They build on macOS and
// Linux; the app in PsyduckMac/ depends on PsyduckCore as a local package.
let package = Package(
    name: "psyduck",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PsyduckCore", targets: ["PsyduckCore"]),
        .executable(name: "psyduck", targets: ["psyduck"]),
    ],
    targets: [
        // The engine: repos, worktrees, claude turns, event logs, branch actions.
        .target(name: "PsyduckCore"),
        // The host side: `psyduck serve` runs an engine for remote clients,
        // `psyduck attach` is what a client's ssh command runs to reach it.
        .executableTarget(name: "psyduck", dependencies: ["PsyduckCore"]),
        .testTarget(name: "PsyduckCoreTests", dependencies: ["PsyduckCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
