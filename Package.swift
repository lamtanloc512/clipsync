// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipSync",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(name: "ClipSync", path: "Sources/ClipSync")
    ]
)
