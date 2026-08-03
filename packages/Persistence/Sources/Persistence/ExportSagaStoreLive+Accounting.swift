import Foundation
import Domain
import GRDB

// startExportが使う勘定（ExportAccountingMode）の解決ロジック（export-saga.md 1.3
// 「権限とクォータ」・1.4「勘定の使い分け」が正本）。
//
// 判定は entitlement.plan を直接見ない。SubscriptionState から導出した
// ResolvedCapabilities（Domainの純粋関数resolveCapabilitiesの出力）だけを見る
// （オーケストレーター確定判断。差し戻し対応1番）。entitlement自体は
// ExportJob.authorization.entitlementSnapshotへ保存する認可時点の生スナップショット
// としてのみ使う。
//
// 月間枠（freeMonthlyConsumeのmonthlyLimitReached判定）は後半セッションで実装する。
// 注入経路はオーケストレーターが確定済み: ExportSagaStoreLive の生成時に
// monthlyLimit（設定定数）と now / deviceTimeZone のプロバイダをコンストラクタ注入し、
// Domain の evaluateMonthlyQuota を用いる（ポートのシグネチャは正本どおり変えない。
// evaluateMonthlyQuota への monthlyLimit 注入と同型のパターン）。

extension ExportSagaStoreLive {
    enum AccountingModeDecision {
        case blocked(ExportStartBlock)
        case resolved(ExportAccountingMode)
    }

    /// capabilitiesはstartExportがSubscriptionState由来のResolvedCapabilitiesを
    /// 解決した結果（entitlement.plan/.statusを直接は見ない。1番の修正）。
    /// hardMaxTrialCreditsはBatch.trialCreditCount（DB由来）をクランプする上限
    /// （コンストラクタ注入。3番の修正）。
    static func resolveAccountingMode(
        _ connection: Database, input: StartExportInput, capabilities: ResolvedCapabilities, hardMaxTrialCredits: Int
    ) throws -> AccountingModeDecision {
        guard let batchID = input.batchID else {
            // 単体書き出し。
            // 未実装（後半セッション担当）: コンストラクタ注入の monthlyLimit / now / deviceTimeZone で
            // Domain の evaluateMonthlyQuota による月間枠チェックを実装する（ファイル冒頭コメント参照）。
            switch capabilities.singleExportAccess {
            case .unlimited:
                return .resolved(.paidUnlimited)
            case .metered:
                return .resolved(.freeMonthlyConsume)
            }
        }

        guard let batch = try Self.loadBatch(connection, batchID: batchID) else {
            throw ExportSagaStoreError.batchNotFound(batchID: batchID)
        }

        switch batch.kind {
        case .proBatch:
            // 2番の修正: 開始時点でcanUseProBatchを失っていればブロックする
            // （proBatch自体はentitlementの能力に依存するため。1.5「開始後の権限変化」の
            // 対象はあくまで「開始済みの書き出し」であり、開始前のこの検査を免除しない）。
            guard capabilities.canUseProBatch else {
                return .blocked(ExportStartBlock(reason: .capabilityVerificationRequired, limit: nil))
            }
            return .resolved(.paidUnlimited)
        case .trial:
            return try Self.resolveTrialAccountingMode(
                connection, trialCreditCount: batch.trialCreditCount, hardMaxTrialCredits: hardMaxTrialCredits
            )
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

    /// UsageLedger.trialConsumedExportIDsのBLOB形式（このタスクで確定。次セッションの
    /// settleBatchが書き込む際も同じ形式を使うこと）: Set<ExportID>の各要素をUUIDの
    /// 16バイト表現のまま連結する（順序はSetのため意味を持たない）。**このBLOBはユニーク
    /// なExportIDの集合であり、重複を許さない契約**（同一ExportIDが2回記録される状態は
    /// 「同じ出力を2回消費した」という不正な状態を意味するため）。後半セッションの
    /// settleBatchがこのBLOBへ追記する際も、この一意性契約を維持すること（追記前に
    /// 重複チェックを行う、またはSetに格納してから連結する等）。UsageLedger行が無ければ
    /// トライアル消費0件とみなす（オーケストレーター確定判断）。
    private static let exportIDByteLength = 16

    /// UsageLedger行はApplication層が単一行であることを保証する契約
    /// （Schema+Accounting.swiftのコメント参照）。行が2件以上あれば契約違反として
    /// fail-closedでthrowする（5番・7番の修正。先頭行だけを暗黙に使わない）。
    private static func loadTrialConsumedCount(_ connection: Database) throws -> Int {
        let blobs = try Data.fetchAll(connection, sql: "SELECT trialConsumedExportIDs FROM UsageLedger")
        guard blobs.count <= 1 else {
            throw ExportSagaStoreError.multipleSingletonRows(table: "UsageLedger", count: blobs.count)
        }
        guard let blob = blobs.first else {
            return 0
        }
        guard blob.count % exportIDByteLength == 0 else {
            throw ExportSagaStoreError.corruptUsageLedgerBlob(byteCount: blob.count)
        }
        return try Self.splitIntoUniqueChunks(blob).count
    }

    /// blobを16バイトずつに分割し、重複が無いことを検査しながらSetへ集める。重複する
    /// チャンクが1つでもあればfail-closedでthrowする（黙って丸めない。5番の修正）。
    private static func splitIntoUniqueChunks(_ blob: Data) throws -> Set<Data> {
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
