import Domain

/// パッケージ骨格の存在確認用マーカー（Issue #4: プロジェクト基盤）。
///
/// `Ads` は `AdPresenter`（Google Mobile Ads）の実装置き場。AdMob SDK の追加は
/// Issue #11 の範囲であり、このIssue（#4）ではまだ追加しない。
public enum AdsPackageMarker {

    /// Domain への依存が解決されていることを示す（architecture.md 3.1）。
    public static let dependsOnPackageName = DomainPackageMarker.packageName
}
