// swift-tools-version: 6.0
import PackageDescription

// Billing は RevenueCat ラッパと権限解決の置き場所。Domain にのみ依存する
// （architecture.md 3.1 / 3.2）。RevenueCat SDK の追加は Issue #10 の範囲であり、
// このIssue（#4）ではまだ追加しない。
let package = Package(
    name: "Billing",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "Billing", targets: ["Billing"])
    ],
    dependencies: [
        .package(path: "../Domain")
    ],
    targets: [
        .target(name: "Billing", dependencies: ["Domain"]),
        .testTarget(name: "BillingTests", dependencies: ["Billing"])
    ]
)
