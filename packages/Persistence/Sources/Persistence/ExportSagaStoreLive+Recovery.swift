import Foundation
import Domain
import GRDB

// loadRunningJobs / deleteRunningJobs（export-saga.md 5章「起動時復旧」が正本）。

extension ExportSagaStoreLive {
    /// 起動時復旧の入力（5章 手順1）。ExportJobの全行を読む。
    public func loadRunningJobs() async throws -> [ExportJob] {
        let rows = try await database.dbQueue.read { connection in
            try Row.fetchAll(
                connection,
                sql: """
                SELECT exportID, projectID, batchID, queueItemID, authorizedAt, accountingMode,
                    entitlementPlan, entitlementStatus, entitlementExpiresAt,
                    entitlementLastVerifiedAt, entitlementIsSandbox, deliveryFormat,
                    deliverySuggestedCreationDate
                FROM ExportJob
                """
            )
        }
        return try rows.map(Self.makeExportJob)
    }

    /// 起動時復旧（5章 手順1）。ExportJob行と、対応する未確定（settledAt IS NULL）
    /// OutputRecordをまとめて削除する。孤児ファイルはGCが別途回収する設計のため
    /// （5章 手順2）、discardExportとは異なりPendingFileDeletionへは登録しない
    /// （オーケストレーター確定判断）。
    public func deleteRunningJobs(_ exportIDs: [ExportID]) async throws {
        try await database.dbQueue.write { connection in
            for exportID in exportIDs {
                try connection.execute(
                    sql: "DELETE FROM OutputRecord WHERE exportID = ? AND settledAt IS NULL",
                    arguments: [exportID.rawValue]
                )
                try connection.execute(
                    sql: "DELETE FROM ExportJob WHERE exportID = ?",
                    arguments: [exportID.rawValue]
                )
            }
        }
    }
}
