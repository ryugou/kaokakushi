import Domain

/// パッケージ骨格の存在確認用マーカー（Issue #4: プロジェクト基盤）。
///
/// `Application` は書き出し Saga・起動時復旧・出力の受け渡しを担う Coordinator の実装置き場
/// （architecture.md 4.3）。`Domain` のプロトコルのみを通してアダプタを操作し、
/// `Persistence` には直接依存しない。実際の Coordinator は後続 Issue で追加する。
public enum ApplicationPackageMarker {
    public static let packageName = "Application"

    /// Domain への依存が解決されていることを示す（architecture.md 3.1）。
    public static let dependsOnPackageName = DomainPackageMarker.packageName
}
