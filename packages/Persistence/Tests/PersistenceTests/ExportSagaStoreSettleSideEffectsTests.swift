import Foundation
import Testing
import Domain
@testable import Persistence

// ExportSagaStoreLive.settleExport/settleBatchが行う周辺副作用のテスト
// （`ExportSagaStore`のdocコメント「WorkingSourceRecordの削除」、export-saga.md 3章が正本）。

@Suite("ExportSagaStoreLive.settle 周辺副作用")
struct ExportSagaStoreSettleSideEffectsTests {
    @Test("settleExportがWorkingSourceRecordを削除しPendingFileDeletionへ登録すること")
    func deletesWorkingSourceRecordAndRegistersPendingFileDeletion() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID)
        let job = try await authorizeExportJob(store: store, projectID: projectID)
        let sourceFileID = UUID()
        try await database.dbQueue.write { connection in
            try insertWorkingSourceRecord(connection, projectID: projectID.rawValue, sourceFileID: sourceFileID)
        }
        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: job.exportID, outputFile: makeOutputFileRefFixture(), outputByteSize: 1_024,
            outputSHA256: Data(repeating: 0x70, count: 32)
        ))

        try await store.settleExport(job.exportID)

        #expect(try workingSourceRecordFields(database, projectID: projectID.rawValue) == nil)
        #expect(try pendingFileDeletionExists(
            database, kind: ManagedFileKind.processingTemporary.rawValue, fileID: sourceFileID
        ))
    }

    @Test("settleExportはWorkingSourceRecordが元から無ければ何もしないこと（冪等）")
    func doesNothingWhenWorkingSourceRecordAbsent() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID)
        let job = try await authorizeExportJob(store: store, projectID: projectID)
        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: job.exportID, outputFile: makeOutputFileRefFixture(), outputByteSize: 1_024,
            outputSHA256: Data(repeating: 0x72, count: 32)
        ))

        try await store.settleExport(job.exportID)

        #expect(try !exportJobExists(database, exportID: job.exportID.rawValue))
    }
}
