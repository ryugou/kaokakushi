import Foundation
import Domain
import GRDB

// settleSingleExportRecord（ExportSagaStoreLive+Settle.swift）が呼ぶ個々のステップの実装
// （export-saga.md 3章「手順」手順5が正本）。400行制限のため+Settle.swiftから分割する。

extension ExportSagaStoreLive {
    /// settledAt IS NULLのOutputRecordから、ExportRecord作成に必要な値だけを読む。
    struct PendingOutputSnapshot {
        let outputByteSize: Int64
        let format: ImageFormat
    }

    /// 対応する未確定OutputRecordが存在しなければsettlePendingOutputRecordNotFoundで
    /// throwする（3章「対応するOutputRecordが存在しsettledAt IS NULLである」）。
    static func loadPendingOutputRecord(_ connection: Database, exportID: ExportID) throws -> PendingOutputSnapshot {
        guard let row = try Row.fetchOne(
            connection,
            sql: "SELECT outputByteSize, format FROM OutputRecord WHERE exportID = ? AND settledAt IS NULL",
            arguments: [exportID.rawValue]
        ) else {
            throw ExportSagaStoreError.settlePendingOutputRecordNotFound(exportID: exportID)
        }
        let formatRaw: Int = row["format"]
        guard let formatColumn = ImageFormatColumn(rawValue: formatRaw) else {
            throw ExportSagaStoreError.invalidColumnValue(table: "OutputRecord", column: "format", rawValue: formatRaw)
        }
        return PendingOutputSnapshot(outputByteSize: row["outputByteSize"], format: formatColumn.domainValue)
    }

    /// queueItemIDが指定されていれば、対応するキュー項目が存在しprojectID/batchIDが一致し
    /// state == .exportingであることを検査する（無関係なキュー項目をcompletedにしないため。
    /// 3章）。queueItemIDがnil（単体書き出し・キュー経路を通らない書き出し）なら何もしない。
    static func validateQueueItemForSettle(_ connection: Database, job: ExportJob) throws {
        guard let queueItemID = job.queueItemID else { return }
        guard let row = try Row.fetchOne(
            connection,
            sql: "SELECT projectID, batchID, state FROM ExportQueueItem WHERE queueItemID = ?",
            arguments: [queueItemID.rawValue]
        ) else {
            throw ExportSagaStoreError.settleQueueItemPreconditionFailed(
                exportID: job.exportID, queueItemID: queueItemID, detail: "キュー項目が存在しません"
            )
        }
        let rowProjectID: UUID = row["projectID"]
        let rowBatchID: UUID = row["batchID"]
        let stateRaw: Int = row["state"]
        // ExportQueueItem.batchIDはNOT NULL制約（Schema+Queue.swift）のため常に実値を持つ。
        // job.batchIDがnil（キュー経路のはずが単体書き出しとして認可された等の不整合）なら
        // 一致し得ないため、この時点で不一致として扱う（Optionalの暗黙比較に頼らず明示する）。
        guard let jobBatchID = job.batchID,
              rowProjectID == job.projectID.rawValue,
              rowBatchID == jobBatchID.rawValue,
              stateRaw == ExportQueueStateColumn.exporting.rawValue else {
            throw ExportSagaStoreError.settleQueueItemPreconditionFailed(
                exportID: job.exportID, queueItemID: queueItemID,
                detail: "projectID/batchIDの不一致、またはstate(\(stateRaw))がexportingではありません"
            )
        }
    }

    /// OutputRecordのsettledAt/expiresAtを確定する。影響行数が1件であることを確認し、
    /// 不一致ならthrowする（オーケストレーター確定判断4番。TOCTOUに対する防御であり、
    /// 単一のdbQueue.write呼び出し内では通常発生しないが、事前条件検査との一貫性を
    /// 明示的に保証する）。
    static func confirmOutputRecord(_ connection: Database, exportID: ExportID, settledAt: Date) throws {
        let expiresAt = settledAt.addingTimeInterval(settledOutputRecordLifetimeSeconds)
        try connection.execute(
            sql: "UPDATE OutputRecord SET settledAt = ?, expiresAt = ? WHERE exportID = ? AND settledAt IS NULL",
            arguments: [settledAt, expiresAt, exportID.rawValue]
        )
        guard connection.changesCount == 1 else {
            throw ExportSagaStoreError.settlePendingOutputRecordNotFound(exportID: exportID)
        }
    }

    /// expiresAt = settledAt + 24h（3章「手順5」）。
    private static var settledOutputRecordLifetimeSeconds: TimeInterval { 24 * 60 * 60 }

    /// ExportJobの値だけからExportRecordを導出して挿入する（3章の導出表どおり:
    /// exportedAt=settledAt、accountingMode=job.authorization.accountingMode、
    /// format/outputByteSizeは既存のOutputRecordから）。
    static func insertExportRecordRow(
        _ connection: Database, job: ExportJob, settledAt: Date, output: PendingOutputSnapshot
    ) throws {
        try connection.execute(
            sql: """
            INSERT INTO ExportRecord (
                exportID, projectID, batchID, exportedAt, accountingMode, format, outputByteSize
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                job.exportID.rawValue, job.projectID.rawValue, job.batchID?.rawValue, settledAt,
                ExportAccountingModeColumn(job.authorization.accountingMode).rawValue,
                ImageFormatColumn(output.format).rawValue, output.outputByteSize
            ]
        )
    }

    /// ExportJob.settingsHash列（Schema+Accounting.swift。startExport時点で計算済み）を
    /// 読む。ここに到達する時点でloadExportJobが既に同じexportIDの行を読めているため
    /// 行が無いことは通常起こらないが、防御的にsettleExportJobNotFoundでthrowする。
    private static func loadSettingsHash(_ connection: Database, exportID: ExportID) throws -> Data {
        guard let hash = try Data.fetchOne(
            connection, sql: "SELECT settingsHash FROM ExportJob WHERE exportID = ?", arguments: [exportID.rawValue]
        ) else {
            throw ExportSagaStoreError.settleExportJobNotFound(exportID: exportID)
        }
        return hash
    }

    /// confirmed設定エントリ（ExportedSettingsEntry）をUPSERTする（3章「confirmed設定
    /// エントリの更新」）。PRIMARY KEYはprojectIDのため、同一projectIDへの2回目以降の
    /// settleは既存行を上書きする。
    static func upsertExportedSettingsEntryRow(_ connection: Database, job: ExportJob, settledAt: Date) throws {
        let settingsHash = try Self.loadSettingsHash(connection, exportID: job.exportID)
        try connection.execute(
            sql: """
            INSERT INTO ExportedSettingsEntry (projectID, settingsHash, exportedAt) VALUES (?, ?, ?)
            ON CONFLICT(projectID) DO UPDATE SET settingsHash = excluded.settingsHash, exportedAt = excluded.exportedAt
            """,
            arguments: [job.projectID.rawValue, settingsHash, settledAt]
        )
    }

    /// queueItemIDがあればExportQueueItem.stateをcompletedへ更新する（3章「キュー項目の
    /// completed更新」）。queueItemIDがnilなら何もしない。
    static func completeQueueItemIfPresent(_ connection: Database, queueItemID: ExportQueueItemID?) throws {
        guard let queueItemID else { return }
        try connection.execute(
            sql: "UPDATE ExportQueueItem SET state = ? WHERE queueItemID = ?",
            arguments: [ExportQueueStateColumn.completed.rawValue, queueItemID.rawValue]
        )
    }

    /// WorkingSourceRecordを削除しPendingFileDeletionへ登録する（`ExportSagaStore`の
    /// docコメント「削除するWorkingSourceRecordのWorkingSourceFileRefは同一トランザクション
    /// でPendingFileDeletionへ登録する」）。ExportSagaStoreは他のStoreを呼び出せない
    /// （各Storeは自分のトランザクション境界内で完結する設計）ため、
    /// WorkingSourceStoreLive.deleteWorkingSourceと同じロジックをここへインラインする
    /// （コードの重複は許容される。discardExportの実装と同じ判断）。対象行が無ければ
    /// 何もしない（settle対象プロジェクトに処理用素材が残っていないケースを許容する）。
    static func deleteWorkingSourceRecordForSettle(_ connection: Database, projectID: ProjectID) throws {
        guard let sourceFileID = try UUID.fetchOne(
            connection, sql: "SELECT sourceFileID FROM WorkingSourceRecord WHERE projectID = ?",
            arguments: [projectID.rawValue]
        ) else {
            return
        }
        try connection.execute(
            sql: "DELETE FROM WorkingSourceRecord WHERE projectID = ?", arguments: [projectID.rawValue]
        )
        try connection.execute(
            sql: "INSERT OR IGNORE INTO PendingFileDeletion (kind, fileID) VALUES (?, ?)",
            arguments: [ManagedFileKind.processingTemporary.rawValue, sourceFileID]
        )
    }
}
