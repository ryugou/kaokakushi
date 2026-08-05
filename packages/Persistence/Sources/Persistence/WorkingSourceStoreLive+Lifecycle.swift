import Foundation
import Domain
import GRDB

// loadWorkingSource / deleteWorkingSource / invalidateWorkingSource（image-pipeline.md
// 5章「実装の所在」「実体の存在確認」が正本）。

extension WorkingSourceStoreLive {
    /// projectIDの処理用素材を返す（無ければnil）。再選択後の分岐と実体の存在確認に使う
    /// （image-pipeline.md 5章）。
    public func loadWorkingSource(for projectID: ProjectID) async throws -> WorkingSourceRecord? {
        try await database.dbQueue.read { connection in
            guard let row = try Row.fetchOne(
                connection,
                sql: "SELECT sourceFileID, createdAt FROM WorkingSourceRecord WHERE projectID = ?",
                arguments: [projectID.rawValue]
            ) else {
                return nil
            }
            let sourceFileID: UUID = row["sourceFileID"]
            let createdAt: Date = row["createdAt"]
            // kindを.processingTemporaryに固定して構築するため、WorkingSourceFileRef.init(_:)の
            // guard（kindが一致しない場合のみnilを返す）は必ず通る。force unwrapは不変条件に
            // 基づく安全なもの（ManagedFileRef.swift参照）。
            let sourceFile = WorkingSourceFileRef(
                ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: sourceFileID))
            )!
            return WorkingSourceRecord(projectID: projectID, sourceFile: sourceFile, createdAt: createdAt)
        }
    }

    /// 破棄。呼び出し契機は完了操作（settle）とプロジェクト破棄の2つ（image-pipeline.md
    /// 5章）。対象行が存在すれば削除しPendingFileDeletionへ登録する。存在しなければ
    /// 冪等に成功する（no-op。呼び出し元が再試行等で複数回呼びうるため）。
    public func deleteWorkingSource(_ projectID: ProjectID) async throws {
        try await database.dbQueue.write { connection in
            guard let sourceFileID = try Self.loadSourceFileID(connection, projectID: projectID) else {
                return
            }
            try connection.execute(
                sql: "DELETE FROM WorkingSourceRecord WHERE projectID = ?",
                arguments: [projectID.rawValue]
            )
            try registerPendingFileDeletion(
                connection, kind: .processingTemporary, fileID: sourceFileID.rawValue
            )
        }
    }

    /// 実体欠損時の無効化。doc コメント(a)(b)(c)の順で実行する（image-pipeline.md 5章
    /// 「実装の所在」`WorkingSourceStore.invalidateWorkingSource`、「実体の存在確認」）。
    public func invalidateWorkingSource(_ projectID: ProjectID) async throws {
        try await database.dbQueue.write { connection in
            // (a) WorkingSourceRecordを削除する。削除前にfileIDを読む（無くてもエラーに
            // しない。呼び出し契機は起動時・書き出し開始時の2回であり、既に無効化済みの
            // projectIDへ再度呼ばれても冪等に完了する必要があるため）。
            let sourceFileID = try Self.loadSourceFileID(connection, projectID: projectID)
            try connection.execute(
                sql: "DELETE FROM WorkingSourceRecord WHERE projectID = ?",
                arguments: [projectID.rawValue]
            )

            // (b) 同じprojectIDの非終端ExportQueueItemをpaused(.sourceReselectionRequired)へ
            // 更新する。終端状態（completed/failed/canceled）の行は対象外とし変化させない
            // （終わった項目を無効化理由で上書きしない）。
            try connection.execute(
                sql: """
                UPDATE ExportQueueItem SET
                    state = ?,
                    pauseReason = ?
                WHERE projectID = ? AND state NOT IN (?, ?, ?)
                """,
                arguments: [
                    ExportQueueStateColumn.paused.rawValue,
                    QueuePauseReasonColumn.sourceReselectionRequired.rawValue,
                    projectID.rawValue,
                    ExportQueueStateColumn.completed.rawValue,
                    ExportQueueStateColumn.failed.rawValue,
                    ExportQueueStateColumn.canceled.rawValue
                ]
            )

            // (c) 欠損したファイル参照をPendingFileDeletionへ登録する。実体が無くても
            // 行ってよい（参照の掃除であり、孤児GCが空振りで行を消すだけで無害。
            // architecture.md 7.5「出力の削除経路」と同じ単一経路に揃える）。fileIDが
            // 取れなかった場合（WorkingSourceRecordが元から無かった場合）は登録しない。
            if let sourceFileID {
                try registerPendingFileDeletion(
                    connection, kind: .processingTemporary, fileID: sourceFileID.rawValue
                )
            }
        }
    }
}
