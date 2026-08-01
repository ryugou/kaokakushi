// swift-tools-version: 6.0
import PackageDescription

// Ads は AdPresenter（Google Mobile Ads）の置き場所。Domain にのみ依存する
// （architecture.md 3.1 / 3.2）。AdMob SDK の追加は Issue #11 の範囲であり、
// このIssue（#4）ではまだ追加しない。
let package = Package(
    name: "Ads",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "Ads", targets: ["Ads"])
    ],
    dependencies: [
        .package(path: "../Domain")
    ],
    targets: [
        .target(name: "Ads", dependencies: ["Domain"]),
        .testTarget(name: "AdsTests", dependencies: ["Ads"])
    ]
)
