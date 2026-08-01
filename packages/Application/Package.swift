// swift-tools-version: 6.0
import PackageDescription

// Application は書き出し Saga・起動時復旧・ロールバック等の Coordinator の置き場所。
// Domain のプロトコルのみに依存し、Persistence には依存しない
// （ポートは Domain のプロトコル、実装は App 組み立て時に注入。architecture.md 3.2 / 4.3）。
let package = Package(
    name: "Application",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "Application", targets: ["Application"])
    ],
    dependencies: [
        .package(path: "../Domain")
    ],
    targets: [
        .target(name: "Application", dependencies: ["Domain"]),
        .testTarget(name: "ApplicationTests", dependencies: ["Application"])
    ]
)
