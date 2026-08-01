import Foundation

/// パッケージ骨格の存在確認用マーカー（Issue #4: プロジェクト基盤）。
///
/// `Domain` は純粋 Swift の型・判定ロジックの置き場所であり、`Foundation` 以外の
/// フレームワークに依存しない（architecture.md 3.3）。実際のドメイン型
/// （`RenderSpec` 等）は後続 Issue で追加する。
public enum DomainPackageMarker {
    public static let packageName = "Domain"
}
