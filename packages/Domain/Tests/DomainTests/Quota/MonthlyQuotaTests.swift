import Testing
@testable import Domain
import Foundation

/// Task 6: クォータ判定の純粋関数（architecture.md 6.3「判定」「時間の扱い」節）。
///
/// `evaluateMonthlyQuota` の判定順序（unlimited優先・period不一致時の0件みなし・
/// consumed対limit比較）、`rollPeriod` のtrialConsumedExportIDs保持、
/// `YearMonth(from:in:)` の月またぎ・タイムゾーン依存性を検証する。

private func utc() -> TimeZone {
    // 既知の有効な識別子のみを渡すテスト専用ヘルパーのため force unwrap を許容する。
    TimeZone(identifier: "UTC")!
}

private func jst() -> TimeZone {
    TimeZone(identifier: "Asia/Tokyo")!
}

private func date(year: Int, month: Int, day: Int, hour: Int, timeZone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = DateComponents(year: year, month: month, day: day, hour: hour)
    // テスト専用ヘルパー。渡す値はすべてテストコード内で完全に決定的なため
    // Calendar.date(from:) が nil を返すことはない。
    return calendar.date(from: components)!
}

private func exportIDs(_ count: Int) -> Set<ExportID> {
    Set((0..<count).map { _ in ExportID(rawValue: UUID()) })
}

private func makeLedger(period: YearMonth, consumedCount: Int, trialConsumedCount: Int = 0) -> UsageLedger {
    UsageLedger(
        period: period,
        consumedExportIDs: exportIDs(consumedCount),
        trialConsumedExportIDs: exportIDs(trialConsumedCount)
    )
}

// MARK: - evaluateMonthlyQuota

@Test(
    "accessがunlimitedならconsumed件数やlimitに関わらず常にunlimitedを返す",
    arguments: [0, 3, 100]
)
func evaluateMonthlyQuotaUnlimitedAccessIgnoresConsumedCount(consumedCount: Int) {
    let period = YearMonth(year: 2026, month: 8)
    let ledger = makeLedger(period: period, consumedCount: consumedCount)
    let usageNow = date(year: 2026, month: 8, day: 15, hour: 12, timeZone: utc())

    let decision = evaluateMonthlyQuota(
        ledger: ledger,
        access: .unlimited,
        monthlyLimit: 5,
        usageNow: usageNow,
        deviceTimeZone: utc()
    )

    #expect(decision == .unlimited)
}

@Test(
    "accessがmeteredでperiodが一致するときconsumedとmonthlyLimitの大小でconsumable/blockedが決まる",
    arguments: [
        (4, 5, MonthlyQuotaDecision.consumable),
        (5, 5, MonthlyQuotaDecision.blocked(limit: 5)),
        (6, 5, MonthlyQuotaDecision.blocked(limit: 5)),
        (0, 0, MonthlyQuotaDecision.blocked(limit: 0))
    ]
)
func evaluateMonthlyQuotaMeteredComparesConsumedAgainstLimit(
    consumedCount: Int,
    monthlyLimit: Int,
    expected: MonthlyQuotaDecision
) {
    let period = YearMonth(year: 2026, month: 8)
    let ledger = makeLedger(period: period, consumedCount: consumedCount)
    let usageNow = date(year: 2026, month: 8, day: 15, hour: 12, timeZone: utc())

    let decision = evaluateMonthlyQuota(
        ledger: ledger,
        access: .metered,
        monthlyLimit: monthlyLimit,
        usageNow: usageNow,
        deviceTimeZone: utc()
    )

    #expect(decision == expected)
}

@Test(
    "ledger.periodが現在の年月と異なる場合consumedExportIDsの実件数を無視し0件とみなす（前進・後退どちらも）",
    arguments: [
        YearMonth(year: 2026, month: 7),
        YearMonth(year: 2026, month: 9)
    ]
)
func evaluateMonthlyQuotaTreatsMismatchedPeriodAsZeroConsumed(ledgerPeriod: YearMonth) {
    // consumedCount はmonthlyLimitを超えているが、period不一致のため無視されconsumableになる。
    let ledger = makeLedger(period: ledgerPeriod, consumedCount: 10)
    let usageNow = date(year: 2026, month: 8, day: 15, hour: 12, timeZone: utc())

    let decision = evaluateMonthlyQuota(
        ledger: ledger,
        access: .metered,
        monthlyLimit: 5,
        usageNow: usageNow,
        deviceTimeZone: utc()
    )

    #expect(decision == .consumable)
}

// MARK: - rollPeriod

@Test("currentがledger.periodと一致する場合ledgerをそのまま返す")
func rollPeriodReturnsSameLedgerWhenPeriodMatches() {
    let period = YearMonth(year: 2026, month: 8)
    let ledger = makeLedger(period: period, consumedCount: 3, trialConsumedCount: 2)
    let now = date(year: 2026, month: 8, day: 20, hour: 9, timeZone: utc())

    let rolled = rollPeriod(ledger, now: now, deviceTimeZone: utc())

    #expect(rolled == ledger)
}

@Test(
    "currentがledger.periodと異なる場合periodを切り替えconsumedExportIDsを空にしtrialConsumedExportIDsは保持する（前進・後退どちらも）",
    arguments: [
        YearMonth(year: 2026, month: 7),
        YearMonth(year: 2026, month: 9)
    ]
)
func rollPeriodSwitchesPeriodAndClearsConsumedOnly(ledgerPeriod: YearMonth) {
    let trial = exportIDs(2)
    let ledger = UsageLedger(period: ledgerPeriod, consumedExportIDs: exportIDs(4), trialConsumedExportIDs: trial)
    let now = date(year: 2026, month: 8, day: 20, hour: 9, timeZone: utc())

    let rolled = rollPeriod(ledger, now: now, deviceTimeZone: utc())

    #expect(rolled.period == YearMonth(year: 2026, month: 8))
    #expect(rolled.consumedExportIDs.isEmpty)
    #expect(rolled.trialConsumedExportIDs == trial)
}

// MARK: - YearMonth(from:in:)

@Test("UTCで月末23時の日時をJST(+9)から見ると翌月へ繰り上がる")
func yearMonthFromDateCrossesMonthBoundaryAcrossTimeZones() {
    // 2026-01-31 23:00 UTC は 2026-02-01 08:00 JST。
    let instant = date(year: 2026, month: 1, day: 31, hour: 23, timeZone: utc())

    let inUTC = YearMonth(from: instant, in: utc())
    let inJST = YearMonth(from: instant, in: jst())

    #expect(inUTC == YearMonth(year: 2026, month: 1))
    #expect(inJST == YearMonth(year: 2026, month: 2))
}

@Test("同じDateでも異なるTimeZoneを渡すと異なるYearMonthになりうる")
func yearMonthFromDateDependsOnTimeZoneNotJustInstant() {
    let instant = date(year: 2026, month: 8, day: 1, hour: 2, timeZone: utc())
    guard let pacific = TimeZone(identifier: "America/Los_Angeles") else {
        Issue.record("America/Los_Angeles が解決できない環境です")
        return
    }

    let inUTC = YearMonth(from: instant, in: utc())
    let inPacific = YearMonth(from: instant, in: pacific)

    // UTC 2026-08-01 02:00 は PDT(UTC-7) では 2026-07-31 19:00。
    #expect(inUTC == YearMonth(year: 2026, month: 8))
    #expect(inPacific == YearMonth(year: 2026, month: 7))
}
