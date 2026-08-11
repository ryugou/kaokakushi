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
        // ApplicationTests は Fakes/*.swift で Domain のポート（ExportSagaStore 等）へ
        // 直接準拠するため、Domain を明示的なテスト依存に加える（Issue #7 Task 3。
        // オーケストレーター確定判断: check-imports.sh は packages/Application/Sources のみを
        // 検査対象にしており Tests ディレクトリは対象外のため、許可リスト制約に抵触しない）。
        .testTarget(name: "ApplicationTests", dependencies: ["Application", "Domain"])
    ]
)
