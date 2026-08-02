import Foundation
import Testing
import GRDB
import Domain
@testable import Persistence

// WorkingSourceStoreLive.loadWorkingSource / deleteWorkingSource / invalidateWorkingSourceの
// テスト（image-pipeline.md 5章「実装の所在」「実体の存在確認」が正本）。

@Suite("WorkingSourceStoreLive lifecycle")
struct WorkingSourceStoreLifecycleTests {
    @Test("loadWorkingSourceが存在する行を返すこと")
    func loadWorkingSourceReturnsRecordWhenExists() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let fileID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertWorkingSourceRecord(connection, projectID: projectID.rawValue, sourceFileID: fileID)
        }

        let record = try await store.loadWorkingSource(for: projectID)

        #expect(record?.projectID == projectID)
        #expect(record?.sourceFile.ref.fileID.rawValue == fileID)
        #expect(record?.createdAt == schemaTestReferenceDate)
    }

    @Test("loadWorkingSourceが存在しないprojectIDに対してnilを返すこと")
    func loadWorkingSourceReturnsNilWhenMissing() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)

        let record = try await store.loadWorkingSource(for: ProjectID(rawValue: UUID()))

        #expect(record == nil)
    }

    @Test("deleteWorkingSourceが行を削除しPendingFileDeletionへ登録すること")
    func deleteWorkingSourceRegistersPendingDeletion() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let fileID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertWorkingSourceRecord(connection, projectID: projectID.rawValue, sourceFileID: fileID)
        }

        try await store.deleteWorkingSource(projectID)

        #expect(try workingSourceRecordFields(database, projectID: projectID.rawValue) == nil)
        let kind = ManagedFileKind.processingTemporary.rawValue
        #expect(try pendingFileDeletionExists(database, kind: kind, fileID: fileID))
    }

    @Test("deleteWorkingSourceが存在しないprojectIDに対して冪等に成功すること")
    func deleteWorkingSourceIsIdempotentForMissingProject() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)

        try await store.deleteWorkingSource(ProjectID(rawValue: UUID()))
    }

    @Test("invalidateWorkingSourceが非終端ExportQueueItemのみpausedへ遷移させ終端状態は変化させないこと")
    func invalidateWorkingSourcePausesOnlyNonTerminalQueueItems() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)
        let projectID = ProjectID(rawValue: UUID())
        // ExportQueueItem(batchID, projectID) は複合 UNIQUE（architecture.md 7.1）のため、
        // 同一プロジェクトの「終端＋非終端」は別バッチとして再現する（過去バッチで完了済み・
        // 現行バッチで書き出し中、という正当なシナリオ）。
        let currentBatchID = UUID()
        let pastBatchID = UUID()
        let exportingItemID = UUID()
        let completedItemID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertWorkingSourceRecord(connection, projectID: projectID.rawValue, sourceFileID: UUID())
            try insertBatch(connection, batchID: currentBatchID)
            try insertBatch(connection, batchID: pastBatchID)
            try insertExportQueueItemWithState(
                connection, queueItemID: exportingItemID, projectID: projectID.rawValue, batchID: currentBatchID,
                state: ExportQueueStateColumn.exporting.rawValue
            )
            try insertExportQueueItemWithState(
                connection, queueItemID: completedItemID, projectID: projectID.rawValue, batchID: pastBatchID,
                state: ExportQueueStateColumn.completed.rawValue
            )
        }

        try await store.invalidateWorkingSource(projectID)

        let exportingItem = try exportQueueItemStateAndPauseReason(database, queueItemID: exportingItemID)
        #expect(exportingItem?.state == ExportQueueStateColumn.paused.rawValue)
        #expect(exportingItem?.pauseReason == QueuePauseReasonColumn.sourceReselectionRequired.rawValue)
        let completedItem = try exportQueueItemStateAndPauseReason(database, queueItemID: completedItemID)
        #expect(completedItem?.state == ExportQueueStateColumn.completed.rawValue)
        #expect(completedItem?.pauseReason == nil)
    }

    @Test("invalidateWorkingSourceがWorkingSourceRecordを削除しPendingFileDeletionへ登録すること")
    func invalidateWorkingSourceDeletesRecordAndRegistersPendingDeletion() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let fileID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertWorkingSourceRecord(connection, projectID: projectID.rawValue, sourceFileID: fileID)
        }

        try await store.invalidateWorkingSource(projectID)

        #expect(try workingSourceRecordFields(database, projectID: projectID.rawValue) == nil)
        let kind = ManagedFileKind.processingTemporary.rawValue
        #expect(try pendingFileDeletionExists(database, kind: kind, fileID: fileID))
    }
}
