import Domain

/// パッケージ骨格の存在確認用マーカー（Issue #4: プロジェクト基盤）。
///
/// `Analytics` は `CrashReporter`（Sentry のみへ送る）の実装置き場（architecture.md 9.1）。
/// Sentry SDK の追加は後続 Issue の範囲であり、このIssue（#4）ではまだ追加しない。
public enum AnalyticsPackageMarker {

    /// Domain への依存が解決されていることを示す（architecture.md 3.1）。
    public static let dependsOnPackageName = DomainPackageMarker.packageName
}
