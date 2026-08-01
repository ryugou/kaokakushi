// swift-tools-version: 6.0
import PackageDescription

// Persistence は GRDB・ファイル管理の置き場所。Domain にのみ依存する
// （architecture.md 3.1 / 3.2）。GRDB の追加は Issue #6 の範囲であり、
// このIssue（#4: プロジェクト基盤）では追加しない。
let package = Package(
    name: "Persistence",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "Persistence", targets: ["Persistence"])
    ],
    dependencies: [
        .package(path: "../Domain")
    ],
    targets: [
        .target(name: "Persistence", dependencies: ["Domain"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"])
    ]
)
