// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PBSTimekeeper",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that does not need AppKit/SwiftUI: configuration, command lines for
        // proxmox-backup-client, snapshot parsing, scheduling. Covered by the tests.
        .target(name: "TimekeeperCore"),
        // The menu bar app.
        .executableTarget(name: "PBSTimekeeper", dependencies: ["TimekeeperCore"]),
        .testTarget(name: "TimekeeperCoreTests", dependencies: ["TimekeeperCore"]),
    ]
)
