import Foundation
import Testing
import Domain
import GRDB
@testable import Persistence

// HistoryDeletionStoreLive.deleteHistoryUnitによるBatch自動削除のテスト（architecture.md
// 「Project削除Saga」手順3・「削除の可否判定」直後の解説（1729行目付近）が正本。Batch行の
// 削除は利用者操作の対象ではなくProject削除の副次的な後始末）。

@Suite("HistoryDeletionStoreLive.deleteHistoryUnit Batch自動削除")
struct HistoryDeletionStoreBatchCleanupTests {
    @Test("バッチ内最後のProjectを削除するとBatch行が消えること")
    func deletesBatchWhenLastProjectIsRemoved() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let batchID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertBatch(connection, batchID: batchID)
            try insertExportQueueItemWithState(
                connection, queueItemID: UUID(), projectID: projectID.rawValue, batchID: batchID,
                state: ExportQueueStateColumn.completed.rawValue
            )
        }
        let store = makeHistoryDeletionStore(database: database)

        try await store.deleteHistoryUnit(.project(projectID), trigger: .storagePressure)

        #expect(try !batchRowExists(database, batchID: batchID))
    }

    @Test("バッチに他のProjectが残っている場合はBatch行が消えないこと")
    func keepsBatchWhenOtherProjectRemains() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let deletedProjectID = ProjectID(rawValue: UUID())
        let remainingProjectID = ProjectID(rawValue: UUID())
        let batchID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: deletedProjectID.rawValue)
            try insertProject(connection, projectID: remainingProjectID.rawValue)
            try insertBatch(connection, batchID: batchID)
            try insertExportQueueItemWithState(
                connection, queueItemID: UUID(), projectID: deletedProjectID.rawValue, batchID: batchID,
                state: ExportQueueStateColumn.completed.rawValue
            )
            try insertExportQueueItemWithState(
                connection, queueItemID: UUID(), projectID: remainingProjectID.rawValue, batchID: batchID,
                state: ExportQueueStateColumn.completed.rawValue
            )
        }
        let store = makeHistoryDeletionStore(database: database)

        try await store.deleteHistoryUnit(.project(deletedProjectID), trigger: .storagePressure)

        #expect(try batchRowExists(database, batchID: batchID))
    }
}
