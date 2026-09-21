import Foundation
import Domain
import GRDB

// startExport（単体書き出し）が使う勘定（ExportAccountingMode）の解決ロジック
// （export-saga.md 1.3「権限とクォータ」・1.4「勘定の使い分け」・architecture.md 6.3
// 「クォータとトライアル」「判定」節が正本）。
//
// バッチの勘定解決（proBatch/trial）はExportSagaStoreLive+CreateBatch.swiftのcreateBatchへ
// 移設した（一括処理キュー簡素化 Issue #40 決定2）。startExportのバッチ経路は
// createBatchが固定した認可をそのまま読むだけで、ここで定義する関数群を一切呼ばない
// （+Start.swiftのloadBatchAuthorization参照）。このファイルは単体書き出し専用になった。
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
    /// StampStoreLive.insertStampRowsと同じパターン）。単体書き出し専用に単純化したため
    /// StartExportInput全体は保持しない（バッチ分岐が無くなりinput.batchIDを見る箇所が
    /// 消えたため。オーケストレーター確定判断）。
    struct AccountingModeContext {
        let capabilities: ResolvedCapabilities
        /// 月間上限（既定5。architecture.md 6.3。コンストラクタ注入）。
        let monthlyLimit: Int
        /// startExportのauthorizedAtをそのまま使う（evaluateMonthlyQuotaのusageNow）。
        let usageNow: Date
        let deviceTimeZone: TimeZone
    }

    /// 単体書き出しの勘定判定（1.3「権限とクォータ」）。unlimitedは即resolved、meteredは
    /// UsageLedgerを読みevaluateMonthlyQuota（Domain純粋関数）で月間枠を判定する。
    static func resolveAccountingMode(
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
    /// createBatch（ExportSagaStoreLive+CreateBatch.swift）が.trial種別のバッチ作成時に
    /// 再利用するためprivateにしていない（他のstatic funcと同じ流儀）。
    static func resolveTrialAccountingMode(
        _ connection: Database, trialCreditCount: Int32, hardMaxTrialCredits: Int
    ) throws -> AccountingModeDecision {
        let trialConsumedCount = try Self.loadTrialConsumedCount(connection)
        let clampedLimit = min(max(Int(trialCreditCount), 0), hardMaxTrialCredits)
        guard trialConsumedCount < clampedLimit else {
            return .blocked(ExportStartBlock(reason: .trialCreditsUnavailable, limit: clampedLimit))
        }
        return .resolved(.batchTrial)
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

    /// UsageLedger行の単一行はDBの単一行キー（Schema+Accounting.swiftのコメント参照）で
    /// 強制される。行が2件以上あれば契約違反としてfail-closedでthrowする（5番・7番の修正。
    /// 先頭行だけを暗黙に使わない）。この検査はDB制約に対する二重担保として
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
