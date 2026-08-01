import Testing
@testable import Billing

/// Issue #4 時点のプレースホルダテスト。
/// `Billing` パッケージが解決・ビルドでき、`Domain` への依存が成立していることのみを確認する。
@Test("BillingPackageMarker.dependsOnPackageNameが'Domain'を返す")
func billingPackageMarkerDependsOnDomain() {
    #expect(BillingPackageMarker.dependsOnPackageName == "Domain")
}
