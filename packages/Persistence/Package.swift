// swift-tools-version: 6.0
import PackageDescription

// Persistence は GRDB・ファイル管理の置き場所。Domain と GRDB.swift にのみ依存する
// （architecture.md 3.1 / 3.2）。GRDB.swift はこのプロジェクト初の外部SwiftPM依存
// （Issue #6 Task 1）。GRDB（SQLite）を採用する理由は ADR 0002 を参照。
let package = Package(
    name: "Persistence",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "Persistence", targets: ["Persistence"])
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "Persistence",
            dependencies: [
                "Domain",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: [
                "Persistence",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
