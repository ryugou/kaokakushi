import Testing
@testable import Domain
import Foundation

/// Task 3: クォータ・トライアル台帳の型群（architecture.md 6.3）。
///
/// `UsageLedger` の消費件数の導出（`consumed` / `trialConsumed`）、`ExportedSettingsEntry` の
/// フィールド保持、`MonthlyQuotaDecision` の3ケースを検証する。

@Test("UsageLedgerがconsumedExportIDsとtrialConsumedExportIDsの件数をconsumed/trialConsumedとして導出する")
func usageLedgerDerivesConsumedCounts() {
    let period = YearMonth(year: 2026, month: 8)
    let consumed: Set<ExportID> = [ExportID(rawValue: UUID()), ExportID(rawValue: UUID())]
    let trialConsumed: Set<ExportID> = [ExportID(rawValue: UUID())]
    let subject = assertSendableEquatable(UsageLedger(
        period: period,
        consumedExportIDs: consumed,
        trialConsumedExportIDs: trialConsumed
    ))
    #expect(subject.period == period)
    #expect(subject.consumed == 2)
    #expect(subject.trialConsumed == 1)
}

@Test("UsageLedgerは消費が0件のときconsumed/trialConsumedが0になる")
func usageLedgerDerivesZeroWhenEmpty() {
    let subject = UsageLedger(
        period: YearMonth(year: 2026, month: 1), consumedExportIDs: [], trialConsumedExportIDs: [])
    #expect(subject.consumed == 0)
    #expect(subject.trialConsumed == 0)
}

@Test("ExportedSettingsEntryが全フィールドを保持する")
func exportedSettingsEntryHoldsFields() throws {
    let projectID = ProjectID(rawValue: UUID())
    let hash = try ProjectSettingsHash(bytes: Data(repeating: 0xAB, count: 32))
    let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let subject = assertSendableEquatable(ExportedSettingsEntry(
        projectID: projectID,
        settingsHash: hash,
        exportedAt: exportedAt
    ))
    #expect(subject.projectID == projectID)
    #expect(subject.settingsHash == hash)
    #expect(subject.exportedAt == exportedAt)
}

@Test(
    "MonthlyQuotaDecisionはunlimited/consumable/blockedの3ケースを持つ",
    arguments: [
        (MonthlyQuotaDecision.unlimited, MonthlyQuotaDecision.unlimited, true),
        (MonthlyQuotaDecision.consumable, MonthlyQuotaDecision.consumable, true),
        (MonthlyQuotaDecision.blocked(limit: 5), MonthlyQuotaDecision.blocked(limit: 5), true),
        (MonthlyQuotaDecision.blocked(limit: 5), MonthlyQuotaDecision.blocked(limit: 6), false),
        (MonthlyQuotaDecision.unlimited, MonthlyQuotaDecision.consumable, false)
    ]
)
func monthlyQuotaDecisionEquatability(lhs: MonthlyQuotaDecision, rhs: MonthlyQuotaDecision, expectedEqual: Bool) {
    #expect((lhs == rhs) == expectedEqual)
}
