import Testing
@testable import Domain

/// Issue #4 時点のプレースホルダテスト。
/// `Domain` パッケージが解決・ビルドでき、マーカー値を参照できることのみを確認する。
@Test("DomainPackageMarker.packageNameが'Domain'を返す")
func domainPackageMarkerHasExpectedName() {
    #expect(DomainPackageMarker.packageName == "Domain")
}
