import Foundation
import Domain
import GRDB

// loadRunningJobs / deleteRunningJobs / deleteUnsettledBatches（export-saga.md 5章
// 「起動時復旧」が正本）。deleteUnsettledBatchesは起動時復旧の手順2で、手順1
// （deleteRunningJobs）の完了後に呼ぶ契約（`ExportSagaStore`のdocコメント参照）。

extension ExportSagaStoreLive {
    /// 起動時復旧の入力（5章 手順1）。ExportJobの全行を読む。列リストはloadExportJobと
    /// 共有する（ExportSagaStoreLive+Mapping.swift）。
    public func loadRunningJobs() async throws -> [ExportJob] {
        let rows: [Row] = try await database.dbQueue.read { connection in
            try Row.fetchAll(connection, sql: "SELECT \(Self.exportJobColumns) FROM ExportJob")
        }
        return try rows.map(Self.makeExportJob)
    }

    /// 起動時復旧（5章 手順1）。ExportJob行と、対応する未確定（settledAt IS NULL）
    /// OutputRecordをまとめて削除する。孤児ファイルはGCが別途回収する設計のため
    /// （5章 手順3）、discardExportとは異なりPendingFileDeletionへは登録しない
    /// （オーケストレーター確定判断）。
    ///
    /// 削除はテーブルごとに1文（`WHERE exportID IN (...)`）へまとめる。exportIDが空の
    /// ときは何も削除するものが無いためSQLを発行しない（空の`IN ()`を組み立てない）。
    public func deleteRunningJobs(_ exportIDs: [ExportID]) async throws {
        guard !exportIDs.isEmpty else { return }
        try await database.dbQueue.write { connection in
            // プレースホルダのみを件数分並べる（値はarguments経由で渡すため、SQL文へ値を
            // 埋め込む経路は作らない）。2文とも同じexportID群を束縛する。
            let placeholders = databaseQuestionMarks(count: exportIDs.count)
            let arguments = StatementArguments(exportIDs.map(\.rawValue))
            try connection.execute(
                sql: "DELETE FROM OutputRecord WHERE exportID IN (\(placeholders)) AND settledAt IS NULL",
                arguments: arguments
            )
            try connection.execute(
                sql: "DELETE FROM ExportJob WHERE exportID IN (\(placeholders))",
                arguments: arguments
            )
        }
    }

    /// 起動時復旧の手順2（5章）。どのExportRecordからも参照されないBatch行（未settleのまま
    /// 中断されたバッチの残骸）を単一DBトランザクションで削除する。手順1（deleteRunningJobs）
    /// の完了後に呼ぶ契約（`ExportSagaStore`のdocコメント、export-saga.md 5章が正本）。
    /// 該当行が無ければ何もしない（NOT EXISTSが0件マッチのままDELETEが0行に作用するだけの
    /// 自然な冪等）。
    public func deleteUnsettledBatches() async throws {
        try await database.dbQueue.write { connection in
            try connection.execute(
                sql: """
                DELETE FROM Batch
                WHERE NOT EXISTS (SELECT 1 FROM ExportRecord WHERE ExportRecord.batchID = Batch.batchID)
                """
            )
        }
    }
}
