import Testing
@testable import Analytics

/// Issue #4 時点のプレースホルダテスト。
/// `Analytics` パッケージが解決・ビルドでき、`Domain` への依存が成立していることのみを確認する。
@Test("AnalyticsPackageMarker.dependsOnPackageNameが'Domain'を返す")
func analyticsPackageMarkerDependsOnDomain() {
    #expect(AnalyticsPackageMarker.dependsOnPackageName == "Domain")
}
