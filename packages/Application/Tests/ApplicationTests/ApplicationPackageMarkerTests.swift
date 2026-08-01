import Testing
@testable import Application

/// Issue #4 時点のプレースホルダテスト。
/// `Application` パッケージが解決・ビルドでき、`Domain` への依存が成立していることのみを確認する。
@Test("ApplicationPackageMarker.dependsOnPackageNameが'Domain'を返す")
func applicationPackageMarkerDependsOnDomain() {
    #expect(ApplicationPackageMarker.dependsOnPackageName == "Domain")
}
