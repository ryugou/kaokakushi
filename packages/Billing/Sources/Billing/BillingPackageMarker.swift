import Domain

/// パッケージ骨格の存在確認用マーカー（Issue #4: プロジェクト基盤）。
///
/// `Billing` は RevenueCat ラッパと権限解決の実装置き場。RevenueCat SDK の追加は
/// Issue #10 の範囲であり、このIssue（#4）ではまだ追加しない。
public enum BillingPackageMarker {

    /// Domain への依存が解決されていることを示す（architecture.md 3.1）。
    public static let dependsOnPackageName = DomainPackageMarker.packageName
}
