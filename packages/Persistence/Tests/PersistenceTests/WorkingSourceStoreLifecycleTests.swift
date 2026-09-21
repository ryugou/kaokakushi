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
