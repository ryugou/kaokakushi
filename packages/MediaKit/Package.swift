// swift-tools-version: 6.0
import PackageDescription

// MediaKit は Vision / Image I/O / Core Image / PhotoKit の置き場所。Domain にのみ依存する
// （architecture.md 3.1 / 3.2）。
let package = Package(
    name: "MediaKit",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "MediaKit", targets: ["MediaKit"])
    ],
    dependencies: [
        .package(path: "../Domain")
    ],
    targets: [
        .target(name: "MediaKit", dependencies: ["Domain"]),
        .testTarget(name: "MediaKitTests", dependencies: ["MediaKit"])
    ]
)
