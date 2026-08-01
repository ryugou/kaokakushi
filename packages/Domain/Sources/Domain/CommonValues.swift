import Foundation

// Domain の共通値型（architecture.md 6.3「クォータとトライアル」冒頭、6.5「ドメイン識別子」）。
//
// CustomStringConvertible には適合させない（architecture.md 6.5。文字列補間で自動的に
// ログや診断へ流れる経路を作らないため）。

/// クォータ・トライアルの集計単位となる年月（architecture.md 6.3）。
/// `month` は 1...12 を想定するが、正本にバリデーションは無いため実装しない
/// （範囲チェックが必要になった場合は正本の更新を待って追加する）。
public struct YearMonth: Sendable, Hashable, Comparable {
    public let year: Int32
    public let month: Int32        // 1...12。端末の TimeZone で算出する

    public init(year: Int32, month: Int32) {
        self.year = year
        self.month = month
    }

    // Swift は struct の Comparable を合成しない（tuple 比較相当が必要なため、
    // year を第一キー、month を第二キーとする素直な実装を書く）。
    public static func < (lhs: YearMonth, rhs: YearMonth) -> Bool {
        if lhs.year != rhs.year {
            return lhs.year < rhs.year
        }
        return lhs.month < rhs.month
    }
}

/// 認可用。出力へ影響する全設定の正準ハッシュ（正準スキーマ 5.2）
public struct ProjectSettingsHash: Sendable, Hashable {
    public let bytes: Data   // 32 バイト
    public init(bytes: Data) { self.bytes = bytes }
}

/// プレビュー確認用。見た目に影響する値だけ（正準スキーマ 5.2）
public struct PreviewRenderHash: Sendable, Hashable {
    public let bytes: Data     // 32 バイト
    public init(bytes: Data) { self.bytes = bytes }
}

public struct StampAssetHash: Sendable, Hashable {
    public let bytes: Data        // 32 バイト（正準スキーマ 5.3）
    public init(bytes: Data) { self.bytes = bytes }
}
