// swift-tools-version:5.9
import PackageDescription

// OpenWebUIKit — the reusable core for talking to an Open WebUI server.
// Pure Foundation, zero third-party deps, so the second app (a real-time voice
// companion) can depend on the exact same networking/streaming/models without
// dragging in any UI. The host app supplies the SwiftUI on top.
let package = Package(
    name: "OpenWebUIKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "OpenWebUIKit", targets: ["OpenWebUIKit"]),
    ],
    targets: [
        .target(name: "OpenWebUIKit"),
        .testTarget(name: "OpenWebUIKitTests", dependencies: ["OpenWebUIKit"]),
    ]
)
