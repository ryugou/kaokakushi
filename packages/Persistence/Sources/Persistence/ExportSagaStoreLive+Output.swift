import Foundation
import Domain
import GRDB

// recordGeneratedOutput / discardExport（export-saga.md 3章「手順」手順4・4章
// 「中断・やり直し・破棄」が正本）。

extension ExportSagaStoreLive {
    /// 確認用のOutputRecord(settledAt: nil)を作成する（3章 手順4）。台帳・ExportRecord・
    /// キュー・WorkingSourceRecordには触れない。projectID/batchID/format/
    /// suggestedCreationDateはExportJobから導出する（RecordOutputInputのdocコメント
    /// どおり、ExportJobから導出できない値だけを入力として受け取る）。
    public func recordGeneratedOutput(_ input: RecordOutputInput) async throws {
        let generatedAt = now()
        try await database.dbQueue.write { connection in
            guard let loaded = try Self.loadExportJob(connection, exportID: input.exportID) else {
                throw ExportSagaStoreError.exportJobNotFound(exportID: input.exportID)
            }
            try Self.insertOutputRecord(connection, job: loaded.job, input: input, generatedAt: generatedAt)
        }
    }

    /// OutputRecordのINSERT本体。同一projectIDの未確定OutputRecordが既に存在する場合、
    /// 部分UNIQUEインデックス`OutputRecord_on_projectID_where_pending`
    /// （Schema+Accounting.swift）がDatabaseErrorを送出する。また、同一exportIDへの
    /// 二重INSERTはexportID列のPRIMARY KEY制約（Schema+Accounting.swift）違反として
    /// 送出される。GRDBのDatabaseError.extendedResultCodeで真にUNIQUE制約違反・PRIMARY
    /// KEY制約違反のいずれかどうかを確定的に判定し、該当すればrecordGeneratedOutput
    /// InsertFailedへ、それ以外のDBエラーはrecordOutputInsertUnexpectedFailureへ区別して
    /// ラップする（握りつぶさずrethrow。7番の修正）。
    private static func insertOutputRecord(
        _ connection: Database, job: ExportJob, input: RecordOutputInput, generatedAt: Date
    ) throws {
        do {
            try connection.execute(
                sql: """
                INSERT INTO OutputRecord (
                    exportID, projectID, batchID, outputFileID, outputByteSize, outputSHA256,
                    state, generatedAt, settledAt, expiresAt, format, suggestedCreationDate
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    input.exportID.rawValue, job.projectID.rawValue, job.batchID?.rawValue,
                    input.outputFile.ref.fileID.rawValue, input.outputByteSize, input.outputSHA256,
                    OutputState.generated.rawValue, generatedAt, nil, nil,
                    ImageFormatColumn(job.delivery.format).rawValue, job.delivery.suggestedCreationDate
                ]
            )
        } catch let error as DatabaseError
        where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE
            || error.extendedResultCode == .SQLITE_CONSTRAINT_PRIMARYKEY {
            throw ExportSagaStoreError.recordGeneratedOutputInsertFailed(
                exportID: input.exportID,
                projectID: job.projectID,
                underlyingMessage: error.message ?? "\(error)"
            )
        } catch let error as DatabaseError {
            throw ExportSagaStoreError.recordOutputInsertUnexpectedFailure(
                exportID: input.exportID,
                projectID: job.projectID,
                underlyingMessage: error.message ?? "\(error)"
            )
        }
    }

    /// 失敗・キャンセル・やり直し・中断（4章）。ExportJob行を削除する。対応する
    /// OutputRecordが存在すれば同一トランザクションで削除し、その出力ファイルを
    /// PendingFileDeletionへ登録する。temporaryFiles（手順1〜3で生成した一時ファイル。
    /// 呼び出し元の生成パイプラインが保持する参照）も同一トランザクションでPending
    /// FileDeletionへ登録する（4番の修正。実削除はコミット後、削除経路の正本は
    /// アーキテクチャ設計7.5）。ExportJob行が無ければ何もしない（4章「discardExportは
    /// 冪等」。この場合temporaryFilesの登録も行わない——ExportJob行の存在を「まだ後始末
    /// していない中断」の唯一の判定材料として扱う設計を維持するため）。
    public func discardExport(_ exportID: ExportID, temporaryFiles: [ManagedFileRef]) async throws {
        try await database.dbQueue.write { connection in
            let jobCount = try Int.fetchOne(
                connection,
                sql: "SELECT count(*) FROM ExportJob WHERE exportID = ?",
                arguments: [exportID.rawValue]
            ) ?? 0
            guard jobCount > 0 else {
                return
            }

            try Self.deletePendingOutputRecordIfPresent(connection, exportID: exportID)
            // temporaryFilesは1文（複数行VALUES）でまとめて登録する。INSERT OR IGNOREのため、
            // 同じ参照が複数回渡されても安全（冪等）。
            try registerPendingFileDeletions(connection, files: temporaryFiles)

            try connection.execute(sql: "DELETE FROM ExportJob WHERE exportID = ?", arguments: [exportID.rawValue])
        }
    }

    /// settledAt IS NULL（未確定）のOutputRecordだけを対象にする（7番の修正。確定済み
    /// （settledAt != nil）の行はsettle操作でのみ扱われるべきで、discardExportが誤って
    /// 削除しないようにする防御）。
    private static func deletePendingOutputRecordIfPresent(_ connection: Database, exportID: ExportID) throws {
        guard let outputFileID = try UUID.fetchOne(
            connection,
            sql: "SELECT outputFileID FROM OutputRecord WHERE exportID = ? AND settledAt IS NULL",
            arguments: [exportID.rawValue]
        ) else {
            return
        }
        try connection.execute(
            sql: "DELETE FROM OutputRecord WHERE exportID = ? AND settledAt IS NULL", arguments: [exportID.rawValue]
        )
        try registerPendingFileDeletion(connection, kind: .output, fileID: outputFileID)
    }
}
