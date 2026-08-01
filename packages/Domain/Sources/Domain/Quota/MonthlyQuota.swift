import Foundation

// クォータ判定の純粋関数群（architecture.md 6.3「クォータとトライアル」の「判定」節と
// 「時間の扱い」節）。
//
// `evaluateMonthlyQuota` はこの関数自体が台帳を更新しない（architecture.md 6.3 本文
// 「認可時に評価するのは『消費できるか』だけであり、この関数自体は台帳を更新しない」）。
// 実際の period 更新と消費の計上は完了操作（単一トランザクション）でまとめて行う。
// test-plan.md 2.1 に「evaluateMonthlyQuota が更新後の UsageLedger を返すこと」という
// 記述があるが、architecture.md 本文の明記を正としてこの関数は MonthlyQuotaDecision の
// みを返す（`period` の切り替えは rollPeriod が別途、完了操作の中で担う）。

extension YearMonth {
    // 端末の現在時刻・現在タイムゾーンから年月を算出する（architecture.md 6.3「時間の扱い」）。
    // 端末ロケールのカレンダー種別（和暦等）に依存しないよう Gregorian 固定で算出する。
    public init(from date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month], from: date)

        // Gregorian カレンダーで .year / .month を要求した dateComponents(_:from:) は、
        // 有効な Date に対して常に両方を返す（Foundation の契約）。ここで nil になるのは
        // 呼び出し元の Date / TimeZone 自体が壊れている場合のみであり、0 埋めで誤った年月を
        // 静かに返すより早期にクラッシュさせたほうが原因特定しやすい
        // （Domain は Foundation 以外に依存できずログ機構を持たない）。
        guard let year = components.year, let month = components.month else {
            fatalError("YearMonth(from:in:): Calendar から year/month を取得できませんでした")
        }
        self.init(year: Int32(year), month: Int32(month))
    }
}

extension UsageLedger {
    // `trialConsumedExportIDs` を保持したまま `period` と `consumedExportIDs` だけ差し替える
    // （architecture.md 6.3「月初にリセットするのは consumedExportIDs だけ」）。
    public func with(period: YearMonth, consumedExportIDs: Set<ExportID>) -> UsageLedger {
        UsageLedger(
            period: period,
            consumedExportIDs: consumedExportIDs,
            trialConsumedExportIDs: trialConsumedExportIDs
        )
    }
}

// クォータ判定（architecture.md 6.3「判定」節、判定順序 1〜4 を一字一句反映）。
// この関数自体は台帳を更新しない（消費の計上は完了操作の単一トランザクションで行う）。
public func evaluateMonthlyQuota(
    ledger: UsageLedger,
    access: SingleExportAccess,
    monthlyLimit: Int,
    usageNow: Date,
    deviceTimeZone: TimeZone
) -> MonthlyQuotaDecision {
    if access == .unlimited {
        return .unlimited
    }

    // 端末の現在の年月が ledger.period と異なれば、消費数を 0 とみなして判定する
    // （実際の period 更新と消費の計上は完了操作でまとめて行う）。
    let currentPeriod = YearMonth(from: usageNow, in: deviceTimeZone)
    let consumed = currentPeriod == ledger.period ? ledger.consumed : 0

    if consumed < monthlyLimit {
        return .consumable
    }
    return .blocked(limit: monthlyLimit)
}

// architecture.md 6.3「時間の扱い」の疑似コードを転記。月初にリセットするのは
// consumedExportIDs だけで、trialConsumedExportIDs は月をまたいで保持する。
// period は端末の現在の年月と一致しない場合、前進・後退を問わず切り替える（ADR 0006）。
public func rollPeriod(_ ledger: UsageLedger, now: Date, deviceTimeZone: TimeZone) -> UsageLedger {
    let current = YearMonth(from: now, in: deviceTimeZone)
    if current != ledger.period {
        return ledger.with(period: current, consumedExportIDs: [])
    } else {
        return ledger
    }
}
