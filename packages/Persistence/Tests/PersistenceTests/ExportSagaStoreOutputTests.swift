import Foundation
import Testing
import Domain
@testable import Persistence

// ExportSagaStoreLive.recordGeneratedOutput / discardExportのテスト（export-saga.md 3章
// 「手順」手順4・4章「中断・やり直し・破棄」が正本）。

@Suite("ExportSagaStoreLive.recordGeneratedOutput/discardExport")
struct ExportSagaStoreOutputTests {
    @Test("recordGeneratedOutputがExportJobから導出したフィールドを持つOutputRecordを作成すること")
    func createsOutputRecordWithFieldsDerivedFromExportJob() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID)
        let job = try await authorizeExportJob(store: store, projectID: projectID)
        let outputFileID = UUID()
        let input = RecordOutputInput(
            exportID: job.exportID,
            outputFile: makeOutputFileRefFixture(fileID: outputFileID),
            outputByteSize: 2_048,
            outputSHA256: Data(repeating: 0xAB, count: 32)
        )

        try await store.recordGeneratedOutput(input)

        let fields = try outputRecordFields(database, exportID: job.exportID.rawValue)
        #expect(fields?.state == 1)
        #expect(fields?.settledAt == nil)
        #expect(fields?.format == ImageFormatColumn(job.delivery.format).rawValue)
        #expect(fields?.outputFileID == outputFileID)
    }

    @Test("同一projectIDに未確定OutputRecordが既にある場合recordGeneratedOutputInsertFailedでthrowすること")
    func rejectsSecondPendingOutputRecordForSameProject() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID)
        let firstJob = try await authorizeExportJob(store: store, projectID: projectID)
        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: firstJob.exportID,
            outputFile: makeOutputFileRefFixture(),
            outputByteSize: 1_024,
            outputSHA256: Data(repeating: 0x01, count: 32)
        ))
        let secondJob = try await authorizeExportJob(store: store, projectID: projectID)

        do {
            try await store.recordGeneratedOutput(RecordOutputInput(
                exportID: secondJob.exportID,
                outputFile: makeOutputFileRefFixture(),
                outputByteSize: 1_024,
                outputSHA256: Data(repeating: 0x02, count: 32)
            ))
            Issue.record("未確定OutputRecordが既にあるのにrecordGeneratedOutputが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .recordGeneratedOutputInsertFailed = error else {
                Issue.record("期待したエラーケース(recordGeneratedOutputInsertFailed)ではない: \(error)")
                return
            }
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }
    }

    @Test("同一exportIDへの二重INSERTがPRIMARY KEY違反としてrecordGeneratedOutputInsertFailedでthrowすること")
    func rejectsDuplicateExportIDInsertAsPrimaryKeyViolation() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID)
        let job = try await authorizeExportJob(store: store, projectID: projectID)
        // settledAt != nilの行を同一exportIDで先に用意する。部分UNIQUEインデックス
        // （where settledAt IS NULL）には抵触しないが、exportID列のPRIMARY KEY制約には
        // 抵触するため、後続のrecordGeneratedOutputはPRIMARY KEY違反で失敗するはず。
        try await database.dbQueue.write { connection in
            try insertOutputRecord(
                connection, exportID: job.exportID.rawValue, projectID: projectID.rawValue,
                batchID: nil, settledAt: schemaTestReferenceDate
            )
        }

        do {
            try await store.recordGeneratedOutput(RecordOutputInput(
                exportID: job.exportID,
                outputFile: makeOutputFileRefFixture(),
                outputByteSize: 1_024,
                outputSHA256: Data(repeating: 0x04, count: 32)
            ))
            Issue.record("同一exportIDのOutputRecordが既にあるのにrecordGeneratedOutputが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .recordGeneratedOutputInsertFailed = error else {
                Issue.record("期待したエラーケース(recordGeneratedOutputInsertFailed)ではない: \(error)")
                return
            }
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }
    }

    @Test("discardExportがOutputRecord不在のExportJob行を削除しPendingFileDeletionを登録しないこと")
    func discardsExportJobOnlyWithoutOutputRecord() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID)
        let job = try await authorizeExportJob(store: store, projectID: projectID)

        try await store.discardExport(job.exportID, temporaryFiles: [])

        #expect(try !exportJobExists(database, exportID: job.exportID.rawValue))
        #expect(try outputRecordRowCount(database, exportID: job.exportID.rawValue) == 0)
    }

    @Test("discardExportがExportJobとOutputRecordを同一トランザクションで削除しPendingFileDeletionを登録すること")
    func discardsExportJobAndOutputRecordAndRegistersPendingFileDeletion() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID)
        let job = try await authorizeExportJob(store: store, projectID: projectID)
        let outputFileID = UUID()
        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: job.exportID,
            outputFile: makeOutputFileRefFixture(fileID: outputFileID),
            outputByteSize: 1_024,
            outputSHA256: Data(repeating: 0x03, count: 32)
        ))

        try await store.discardExport(job.exportID, temporaryFiles: [])

        #expect(try !exportJobExists(database, exportID: job.exportID.rawValue))
        #expect(try outputRecordRowCount(database, exportID: job.exportID.rawValue) == 0)
        #expect(try pendingFileDeletionExists(database, kind: ManagedFileKind.output.rawValue, fileID: outputFileID))
    }

    @Test("discardExportがtemporaryFilesの各要素をPendingFileDeletionへ登録すること")
    func discardExportRegistersTemporaryFilesForDeletion() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID)
        let job = try await authorizeExportJob(store: store, projectID: projectID)
        let firstTemporaryFileID = UUID()
        let secondTemporaryFileID = UUID()
        let temporaryFiles = [
            ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: firstTemporaryFileID)),
            ManagedFileRef(kind: .rasterTemporary, fileID: ManagedFileID(rawValue: secondTemporaryFileID))
        ]

        try await store.discardExport(job.exportID, temporaryFiles: temporaryFiles)

        #expect(try !exportJobExists(database, exportID: job.exportID.rawValue))
        #expect(try pendingFileDeletionExists(
            database, kind: ManagedFileKind.processingTemporary.rawValue, fileID: firstTemporaryFileID
        ))
        #expect(try pendingFileDeletionExists(
            database, kind: ManagedFileKind.rasterTemporary.rawValue, fileID: secondTemporaryFileID
        ))
    }

    @Test("discardExportは存在しないexportIDに対して冪等に何もしないこと")
    func discardExportIsIdempotentForUnknownExportID() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)

        try await store.discardExport(ExportID(rawValue: UUID()), temporaryFiles: [])
    }
}
