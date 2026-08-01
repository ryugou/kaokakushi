// swift-tools-version: 6.0
import PackageDescription

// Domain は純粋 Swift。Foundation 以外に依存しない（architecture.md 3.3）。
// 依存パッケージを持たないため `dependencies` は空。
let package = Package(
    name: "Domain",
    // 文字列オーバーロード（`SupportedPlatform.IOSVersion` の
    // ExpressibleByStringLiteral）を使い、enum ケースの実在に依存せず
    // iOS 26 系を指定する。`.macOS` は `swift test` がホスト（マクロ実行環境）
    // 向けにビルドされる分の下限として付与する。
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "Domain", targets: ["Domain"])
    ],
    targets: [
        .target(name: "Domain"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"])
    ]
)
