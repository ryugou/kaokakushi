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
        // exact ピン: XcodeGen 生成の xcodeproj は独自にパッケージ解決するため（その
        // Package.resolved はコミットされない）、範囲指定だと CI だけが新しい GRDB を
        // 解決してビルドが割れる（実際に 7.11.1 と最新版の型推論差で発生）。更新は
        // このピンを上げる PR で明示的に行う。
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
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
                "Domain",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
