// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SyncPlayer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "SyncPlayer", path: "Sources/SyncPlayer")
    ]
)
