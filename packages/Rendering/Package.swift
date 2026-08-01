// swift-tools-version: 6.0
import PackageDescription

// Rendering は StampRasterizer 実装（Core Graphics）の置き場所。Domain にのみ依存する
// （architecture.md 3.1 / 3.2）。
let package = Package(
    name: "Rendering",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "Rendering", targets: ["Rendering"])
    ],
    dependencies: [
        .package(path: "../Domain")
    ],
    targets: [
        .target(name: "Rendering", dependencies: ["Domain"]),
        .testTarget(name: "RenderingTests", dependencies: ["Rendering"])
    ]
)
