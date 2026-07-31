import Testing
@testable import MediaKit

/// Issue #4 時点のプレースホルダテスト。
/// `MediaKit` パッケージが解決・ビルドでき、`Domain` への依存が成立していることのみを確認する。
@Test("MediaKitPackageMarker.dependsOnPackageNameが'Domain'を返す")
func mediaKitPackageMarkerDependsOnDomain() {
    #expect(MediaKitPackageMarker.dependsOnPackageName == "Domain")
}
