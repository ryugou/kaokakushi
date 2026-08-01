import Domain

/// パッケージ骨格の存在確認用マーカー（Issue #4: プロジェクト基盤）。
///
/// `MediaKit` は Vision（顔検出）/ Image I/O / Core Image / PhotoKit のプラットフォーム
/// API を扱う実装置き場。比率計算は行わず、絶対ピクセルの `RenderPlan` の実行のみを担う
/// （architecture.md 5章）。実際の実装は後続 Issue で追加する。
public enum MediaKitPackageMarker {
    public static let packageName = "MediaKit"

    /// Domain への依存が解決されていることを示す（architecture.md 3.1）。
    public static let dependsOnPackageName = DomainPackageMarker.packageName
}
