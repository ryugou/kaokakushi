import Foundation

// クォータ・トライアル台帳の型群（architecture.md 6.3「クォータとトライアル」）。
//
// 通常クォータとトライアル消費を、1 つの app.db テーブル行として原子的に置き換える
// （ADR 0005）。勘定の単位は「受け渡した成果物」であり、素材の同一性は使わない
// （ADR 0006）。判定関数 evaluateMonthlyQuota / rollPeriod は Task 6 の担当のため
// ここには置かない。

public struct UsageLedger: Sendable, Equatable {
    public let period: YearMonth
    public let consumedExportIDs: Set<ExportID>
    public let trialConsumedExportIDs: Set<ExportID>

    public init(period: YearMonth, consumedExportIDs: Set<ExportID>, trialConsumedExportIDs: Set<ExportID>) {
        self.period = period
        self.consumedExportIDs = consumedExportIDs
        self.trialConsumedExportIDs = trialConsumedExportIDs
    }
}

public extension UsageLedger {
    var consumed: Int { consumedExportIDs.count }
    var trialConsumed: Int { trialConsumedExportIDs.count }
}

/// 正常書き出しで確定した設定。「変更せず再書き出し」の比較対象（6.2）
public struct ExportedSettingsEntry: Sendable, Equatable {
    public let projectID: ProjectID
    public let settingsHash: ProjectSettingsHash
    public let exportedAt: Date

    public init(projectID: ProjectID, settingsHash: ProjectSettingsHash, exportedAt: Date) {
        self.projectID = projectID
        self.settingsHash = settingsHash
        self.exportedAt = exportedAt
    }
}

public enum MonthlyQuotaDecision: Sendable, Equatable {
    case unlimited
    case consumable
    case blocked(limit: Int)
}
