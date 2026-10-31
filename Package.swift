// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipSync",
    platforms: [.macOS(.v11)],
    targets: [
        // Web Push encryption + VAPID, kept separate so it can be unit-tested against RFC 8291.
        .target(name: "WebPushCrypto", path: "Sources/WebPushCrypto"),
        .executableTarget(name: "ClipSync", dependencies: ["WebPushCrypto"], path: "Sources/ClipSync"),
        .testTarget(name: "WebPushCryptoTests", dependencies: ["WebPushCrypto"], path: "Tests/WebPushCryptoTests"),
    ]
)
