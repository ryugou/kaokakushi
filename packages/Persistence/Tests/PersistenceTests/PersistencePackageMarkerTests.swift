import Testing
@testable import Persistence

/// Issue #4 時点のプレースホルダテスト。
/// `Persistence` パッケージが解決・ビルドでき、`Domain` への依存が成立していることのみを確認する。
@Test("PersistencePackageMarker.dependsOnPackageNameが'Domain'を返す")
func persistencePackageMarkerDependsOnDomain() {
    #expect(PersistencePackageMarker.dependsOnPackageName == "Domain")
}
