import Domain

/// パッケージ骨格の存在確認用マーカー（Issue #4: プロジェクト基盤）。
///
/// `Persistence` は GRDB・ファイル管理の実装置き場。GRDB 依存の追加は Issue #6 の範囲
/// であり、このIssue（#4）ではまだ追加しない。
public enum PersistencePackageMarker {

    /// Domain への依存が解決されていることを示す（architecture.md 3.1）。
    public static let dependsOnPackageName = DomainPackageMarker.packageName
}
