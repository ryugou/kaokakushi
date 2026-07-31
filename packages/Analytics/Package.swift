// swift-tools-version: 6.0
import PackageDescription

// Analytics は CrashReporter（Sentry のみへ送る）の置き場所。Domain にのみ依存する
// （architecture.md 3.1 / 3.2）。Sentry SDK の追加は後続 Issue の範囲であり、
// このIssue（#4）ではまだ追加しない。
let package = Package(
    name: "Analytics",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "Analytics", targets: ["Analytics"])
    ],
    dependencies: [
        .package(path: "../Domain")
    ],
    targets: [
        .target(name: "Analytics", dependencies: ["Domain"]),
        .testTarget(name: "AnalyticsTests", dependencies: ["Analytics"])
    ]
)
