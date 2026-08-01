import Testing
@testable import Ads

/// Issue #4 時点のプレースホルダテスト。
/// `Ads` パッケージが解決・ビルドでき、`Domain` への依存が成立していることのみを確認する。
@Test("AdsPackageMarker.dependsOnPackageNameが'Domain'を返す")
func adsPackageMarkerDependsOnDomain() {
    #expect(AdsPackageMarker.dependsOnPackageName == "Domain")
}
