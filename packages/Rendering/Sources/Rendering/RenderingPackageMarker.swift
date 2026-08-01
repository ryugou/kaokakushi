import Domain

/// パッケージ骨格の存在確認用マーカー（Issue #4: プロジェクト基盤）。
///
/// `Rendering` は `StampRasterizer`（Core Graphics によるラスタライズ）の実装置き場。
/// 実際の実装は画像処理アーキテクチャ（image-pipeline.md）に沿って後続 Issue で追加する。
public enum RenderingPackageMarker {
    public static let packageName = "Rendering"

    /// Domain への依存が解決されていることを示す（architecture.md 3.1）。
    public static let dependsOnPackageName = DomainPackageMarker.packageName
}
