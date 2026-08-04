import Foundation
import Domain
import GRDB

// settleExport / settleBatch（export-saga.md 3章「手順」手順5が正本。`ExportSagaStore`の
// docコメント〈Domain側、確定済みで変更不可〉も参照）。
//
// GRDBのDatabaseWriter.write(_:)はupdatesクロージャをGRDB内部のdb.inTransactionで包み、
// throwすればロールバックしてエラーを再送出する（GRDB本体の契約。WorkingSourceStoreLive.
// swift冒頭コメント参照）。よって settleSingleExportRecord / applyLedgerConsumption の
// どこでthrowしても、それ以前の書き込みも含め一切コミットされない。
//
// 手順表の「Projectの最終更新時刻の更新」は実装対象に含めない
// （ExportSagaStoreLive.swift冒頭コメント参照。列がスキーマに存在しないため）。

extension ExportSagaStoreLive {
    /// 完了（単体専用）。単一トランザクションでExportJob.batchID == nilを検査したうえで
    /// settleSingleExportRecordを1回だけ呼び、続けて台帳を更新する。
    public func settleExport(_ exportID: ExportID) async throws {
        let settledAt = now()
        let zone = deviceTimeZone()
        try await database.dbQueue.write { connection in
            let outcome = try Self.settleSingleExportRecord(
                connection, exportID: exportID, settledAt: settledAt, scope: .single
            )
            try Self.applyLedgerConsumption(connection, outcomes: [outcome], settledAt: settledAt, deviceTimeZone: zone)
        }
    }

    /// 完了（バッチ）。対象batchIDの未確定OutputRecordを全件取得し、それぞれへ
    /// settleSingleExportRecordを適用したうえで、台帳更新を最後に1回だけ行う。
    /// settledAtは呼び出し側が渡した時刻で全件に統一する（正本どおり）。
    public func settleBatch(_ batchID: BatchID, settledAt: Date) async throws {
        let zone = deviceTimeZone()
        try await database.dbQueue.write { connection in
            let exportIDs = try Self.loadPendingOutputExportIDs(connection, batchID: batchID)
            guard !exportIDs.isEmpty else {
                throw ExportSagaStoreError.settleBatchNothingToSettle(batchID: batchID)
            }
            let outcomes = try exportIDs.map { exportID in
                try Self.settleSingleExportRecord(
                    connection, exportID: exportID, settledAt: settledAt, scope: .batch(batchID)
                )
            }
            try Self.applyLedgerConsumption(connection, outcomes: outcomes, settledAt: settledAt, deviceTimeZone: zone)
        }
    }
}

/// settleExport（単体）とsettleBatch（batchID指定）で事前条件の検査内容が変わる箇所を
/// 表す（job.batchIDと比較する期待値）。ExportSagaStoreLive+SettleSteps.swiftからは
/// 参照しないためfile-scope privateで足りるが、settleSingleExportRecord自体が
/// このファイルとSettleSteps.swiftの両方から見える必要は無い（呼び出し元はこのファイル
/// 内のsettleExport/settleBatchのみ）ため、型はこのファイルに閉じる。
private enum SettleScope {
    case single
    case batch(BatchID)
}

/// settleSingleExportRecordの戻り値。台帳更新（ExportSagaStoreLive+Ledger.swiftの
/// applyLedgerConsumption）へ渡す最小限の情報だけを持つ（projectID等、台帳更新に不要な
/// 情報は含めない）。+Ledger.swiftからも参照するためinternal（モジュール内既定アクセス）。
struct SettleOutcome {
    let exportID: ExportID
    let accountingMode: ExportAccountingMode
}

extension ExportSagaStoreLive {
    /// 1件のexportIDを確定する（事前条件検査 → OutputRecord確定 → ExportRecord作成 →
    /// ExportedSettingsEntry UPSERT → キュー項目completed更新 → WorkingSourceRecord削除 →
    /// ExportJob削除）。個々のステップの実装はExportSagaStoreLive+SettleSteps.swiftに
    /// 分割する（400行制限）。台帳の更新はここでは行わない（呼び出し元がoutcomeをまとめて
    /// applyLedgerConsumptionへ渡す。3章「台帳の書き込みは...最後に1回だけ書き込む」）。
    fileprivate static func settleSingleExportRecord(
        _ connection: Database, exportID: ExportID, settledAt: Date, scope: SettleScope
    ) throws -> SettleOutcome {
        guard let loaded = try Self.loadExportJob(connection, exportID: exportID) else {
            throw ExportSagaStoreError.settleExportJobNotFound(exportID: exportID)
        }
        let job = loaded.job
        try Self.validateJobBatchScope(job: job, exportID: exportID, scope: scope)
        let pendingOutput = try Self.loadPendingOutputRecord(connection, exportID: exportID)
        try Self.validateQueueItemForSettle(connection, job: job)

        try Self.confirmOutputRecord(connection, exportID: exportID, settledAt: settledAt)
        try Self.insertExportRecordRow(connection, job: job, settledAt: settledAt, output: pendingOutput)
        try Self.upsertExportedSettingsEntryRow(
            connection, job: job, settledAt: settledAt, settingsHash: loaded.settingsHash
        )
        try Self.completeQueueItemIfPresent(connection, queueItemID: job.queueItemID)
        try Self.deleteWorkingSourceRecordForSettle(connection, projectID: job.projectID)
        try connection.execute(sql: "DELETE FROM ExportJob WHERE exportID = ?", arguments: [exportID.rawValue])

        return SettleOutcome(exportID: exportID, accountingMode: job.authorization.accountingMode)
    }

    /// settleBatchの対象exportID一覧（対象batchIDに一致しsettledAt IS NULLの
    /// OutputRecordすべて。3章）。
    fileprivate static func loadPendingOutputExportIDs(_ connection: Database, batchID: BatchID) throws -> [ExportID] {
        let rawIDs = try UUID.fetchAll(
            connection,
            sql: "SELECT exportID FROM OutputRecord WHERE batchID = ? AND settledAt IS NULL",
            arguments: [batchID.rawValue]
        )
        return rawIDs.map(ExportID.init(rawValue:))
    }

    /// settleExportは`job.batchID == nil`、settleBatchは`job.batchID == 対象batchID`
    /// （nilチェックではない）を検査する（3章・オーケストレーター確定判断4番）。
    private static func validateJobBatchScope(job: ExportJob, exportID: ExportID, scope: SettleScope) throws {
        switch scope {
        case .single:
            if let batchID = job.batchID {
                throw ExportSagaStoreError.settleExportBatchIDNotNil(exportID: exportID, batchID: batchID)
            }
        case .batch(let batchID):
            guard job.batchID == batchID else {
                throw ExportSagaStoreError.settleBatchJobBatchIDMismatch(
                    exportID: exportID, expectedBatchID: batchID, actualBatchID: job.batchID
                )
            }
        }
    }
}
