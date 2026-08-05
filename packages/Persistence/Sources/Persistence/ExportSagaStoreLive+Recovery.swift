import Foundation
import Domain
import GRDB

// loadRunningJobs / deleteRunningJobs（export-saga.md 5章「起動時復旧」が正本）。

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
    /// （5章 手順2）、discardExportとは異なりPendingFileDeletionへは登録しない
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
}
