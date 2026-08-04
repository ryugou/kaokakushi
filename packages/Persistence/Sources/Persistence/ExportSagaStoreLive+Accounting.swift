import Foundation
import Domain
import GRDB

// startExportが使う勘定（ExportAccountingMode）の解決ロジック（export-saga.md 1.3
// 「権限とクォータ」・1.4「勘定の使い分け」・architecture.md 6.3「クォータとトライアル」
// 「判定」節が正本）。
//
// 判定は entitlement.plan を直接見ない。SubscriptionState から導出した
// ResolvedCapabilities（Domainの純粋関数resolveCapabilitiesの出力）だけを見る
// （オーケストレーター確定判断。差し戻し対応1番）。entitlement自体は
// ExportJob.authorization.entitlementSnapshotへ保存する認可時点の生スナップショット
// としてのみ使う。
//
// 月間枠（freeMonthlyConsumeのmonthlyLimitReached判定）はDomainの純粋関数
// evaluateMonthlyQuotaを用いる。ExportSagaStoreLiveの生成時にmonthlyLimit（設定定数）と
// now / deviceTimeZoneのプロバイダをコンストラクタ注入し（ポートのシグネチャは正本どおり
// 変えない）、UsageLedger行はここでconnection経由で読む（無ければ消費0件・
// period=呼び出し時点の年月として扱う。台帳自体の更新はしない。evaluateMonthlyQuotaの
// 契約どおり、実際の消費計上はsettle側の担当）。

extension ExportSagaStoreLive {
    enum AccountingModeDecision {
        case blocked(ExportStartBlock)
        case resolved(ExportAccountingMode)
    }

    /// resolveAccountingModeへの入力ひとそろい（lintの引数上限対応で束ねた入力。
    /// StampStoreLive.insertStampRowsと同じパターン）。
    struct AccountingModeContext {
        let input: StartExportInput
        let capabilities: ResolvedCapabilities
        /// Batch.trialCreditCount（DB由来）をクランプする上限（コンストラクタ注入。3番の修正）。
        let hardMaxTrialCredits: Int
        /// 月間上限（既定5。architecture.md 6.3。コンストラクタ注入）。
        let monthlyLimit: Int
        /// startExportのauthorizedAtをそのまま使う（evaluateMonthlyQuotaのusageNow）。
        let usageNow: Date
        let deviceTimeZone: TimeZone
    }

    static func resolveAccountingMode(
        _ connection: Database, context: AccountingModeContext
    ) throws -> AccountingModeDecision {
        guard let batchID = context.input.batchID else {
            return try Self.resolveSingleExportAccountingMode(connection, context: context)
        }

        guard let batch = try Self.loadBatch(connection, batchID: batchID) else {
            throw ExportSagaStoreError.batchNotFound(batchID: batchID)
        }

        switch batch.kind {
        case .proBatch:
            // 2番の修正: 開始時点でcanUseProBatchを失っていればブロックする
            // （proBatch自体はentitlementの能力に依存するため。1.5「開始後の権限変化」の
            // 対象はあくまで「開始済みの書き出し」であり、開始前のこの検査を免除しない）。
            guard context.capabilities.canUseProBatch else {
                return .blocked(ExportStartBlock(reason: .capabilityVerificationRequired, limit: nil))
            }
            return .resolved(.paidUnlimited)
        case .trial:
            return try Self.resolveTrialAccountingMode(
                connection, trialCreditCount: batch.trialCreditCount,
                hardMaxTrialCredits: context.hardMaxTrialCredits
            )
        }
    }

    /// 単体書き出しの勘定判定（1.3「権限とクォータ」）。unlimitedは即resolved、meteredは
    /// UsageLedgerを読みevaluateMonthlyQuota（Domain純粋関数）で月間枠を判定する。
    private static func resolveSingleExportAccountingMode(
        _ connection: Database, context: AccountingModeContext
    ) throws -> AccountingModeDecision {
        switch context.capabilities.singleExportAccess {
        case .unlimited:
            return .resolved(.paidUnlimited)
        case .metered:
            let ledger = try Self.loadUsageLedger(connection) ?? UsageLedger(
                period: YearMonth(from: context.usageNow, in: context.deviceTimeZone),
                consumedExportIDs: [], trialConsumedExportIDs: []
            )
            switch evaluateMonthlyQuota(
                ledger: ledger, access: .metered, monthlyLimit: context.monthlyLimit,
                usageNow: context.usageNow, deviceTimeZone: context.deviceTimeZone
            ) {
            case .blocked(let limit):
                return .blocked(ExportStartBlock(reason: .monthlyLimitReached, limit: limit))
            case .unlimited, .consumable:
                return .resolved(.freeMonthlyConsume)
            }
        }
    }

    /// トライアルバッチの残クレジットを検査する（1.4「勘定の使い分け」）。
    /// `UsageLedger.trialConsumedExportIDs`の件数が上限以上なら`.blocked`を返す。
    /// 上限はDB由来のtrialCreditCountをhardMaxTrialCreditsでクランプした値
    /// （3番の修正。DB改変等でtrialCreditCountが異常値になっていても無制限に信頼しない）。
    private static func resolveTrialAccountingMode(
        _ connection: Database, trialCreditCount: Int32, hardMaxTrialCredits: Int
    ) throws -> AccountingModeDecision {
        let trialConsumedCount = try Self.loadTrialConsumedCount(connection)
        let clampedLimit = min(max(Int(trialCreditCount), 0), hardMaxTrialCredits)
        guard trialConsumedCount < clampedLimit else {
            return .blocked(ExportStartBlock(reason: .trialCreditsUnavailable, limit: clampedLimit))
        }
        return .resolved(.batchTrial)
    }

    private struct BatchSnapshot {
        let kind: BatchKind
        let trialCreditCount: Int32
    }

    private static func loadBatch(_ connection: Database, batchID: BatchID) throws -> BatchSnapshot? {
        guard let row = try Row.fetchOne(
            connection,
            sql: "SELECT kind, trialCreditCount FROM Batch WHERE batchID = ?",
            arguments: [batchID.rawValue]
        ) else {
            return nil
        }
        let kindRaw: Int = row["kind"]
        guard let kind32 = UInt32(exactly: kindRaw), let kind = BatchKind(rawValue: kind32) else {
            throw ExportSagaStoreError.invalidColumnValue(table: "Batch", column: "kind", rawValue: kindRaw)
        }
        return BatchSnapshot(kind: kind, trialCreditCount: row["trialCreditCount"])
    }

    /// UsageLedger.consumedExportIDs / trialConsumedExportIDsのBLOB形式（このタスクで確定。
    /// ExportSagaStoreLive+Ledger.swiftのencodeExportIDSet/decodeExportIDSetが読み書き両方で
    /// この形式を使う）: Set<ExportID>の各要素をUUIDの16バイト表現のまま連結する（順序は
    /// Setのため意味を持たない）。**このBLOBはユニークなExportIDの集合であり、重複を許さない
    /// 契約**（同一ExportIDが2回記録される状態は「同じ出力を2回消費した」という不正な状態を
    /// 意味するため）。settleExport/settleBatchがこのBLOBへ書き込む際もこの一意性契約を
    /// 維持する（+Ledger.swift参照）。UsageLedger行が無ければトライアル消費0件とみなす
    /// （オーケストレーター確定判断）。プライベートにしていない理由: +Ledger.swiftの
    /// decodeExportIDSetが同一モジュール内から参照するため（他のstatic funcと同じ流儀）。
    static let exportIDByteLength = 16

    /// UsageLedger行はApplication層が単一行であることを保証する契約
    /// （Schema+Accounting.swiftのコメント参照）。行が2件以上あれば契約違反として
    /// fail-closedでthrowする（5番・7番の修正。先頭行だけを暗黙に使わない）。この検査は
    /// fetchSingletonRow（+Mapping.swift）に集約している。
    private static func loadTrialConsumedCount(_ connection: Database) throws -> Int {
        guard let row = try Self.fetchSingletonRow(
            connection, table: "UsageLedger", sql: "SELECT trialConsumedExportIDs FROM UsageLedger"
        ) else {
            return 0
        }
        // trialConsumedExportIDsはNOT NULL列（Schema+Accounting.swift）のため非Optionalで
        // デコードする。
        let blob: Data = row["trialConsumedExportIDs"]
        guard blob.count % exportIDByteLength == 0 else {
            throw ExportSagaStoreError.corruptUsageLedgerBlob(byteCount: blob.count)
        }
        return try Self.splitIntoUniqueChunks(blob).count
    }

    /// blobを16バイトずつに分割し、重複が無いことを検査しながらSetへ集める。重複する
    /// チャンクが1つでもあればfail-closedでthrowする（黙って丸めない。5番の修正）。
    /// +Ledger.swiftのdecodeExportIDSetが再利用するためprivateにしていない。
    static func splitIntoUniqueChunks(_ blob: Data) throws -> Set<Data> {
        var uniqueChunks = Set<Data>()
        var chunkStart = blob.startIndex
        while chunkStart < blob.endIndex {
            let chunkEnd = blob.index(chunkStart, offsetBy: exportIDByteLength)
            let chunk = Data(blob[chunkStart..<chunkEnd])
            guard uniqueChunks.insert(chunk).inserted else {
                throw ExportSagaStoreError.corruptUsageLedgerBlob(byteCount: blob.count)
            }
            chunkStart = chunkEnd
        }
        return uniqueChunks
    }
}
