import Testing
@testable import Rendering

/// Issue #4 時点のプレースホルダテスト。
/// `Rendering` パッケージが解決・ビルドでき、`Domain` への依存が成立していることのみを確認する。
@Test("RenderingPackageMarker.dependsOnPackageNameが'Domain'を返す")
func renderingPackageMarkerDependsOnDomain() {
    #expect(RenderingPackageMarker.dependsOnPackageName == "Domain")
}
