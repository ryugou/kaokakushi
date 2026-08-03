import Foundation
import Testing
import Domain
@testable import Persistence

// ExportSagaStoreLive.loadRunningJobs / deleteRunningJobsのテスト（export-saga.md 5章
// 「起動時復旧」が正本）。

@Suite("ExportSagaStoreLive.loadRunningJobs/deleteRunningJobs")
struct ExportSagaStoreRecoveryTests {
    @Test("loadRunningJobsが全ExportJob行をExportJobとして返すこと")
    func returnsAllExportJobRows() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let firstProjectID = ProjectID(rawValue: UUID())
        let secondProjectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: firstProjectID)
        try await seedAuthorizedProject(database, projectID: secondProjectID)
        let firstJob = try await authorizeExportJob(store: store, projectID: firstProjectID)
        let secondJob = try await authorizeExportJob(store: store, projectID: secondProjectID)

        let runningJobs = try await store.loadRunningJobs()

        let runningExportIDs = Set(runningJobs.map(\.exportID))
        #expect(runningExportIDs == Set([firstJob.exportID, secondJob.exportID]))
    }

    @Test("loadRunningJobsが挿入したExportJobの全フィールドを一致させて返すこと")
    func returnsExportJobWithAllFieldsRoundTripped() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let batchID = BatchID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            // plan 3 = pro（active）。proBatchが認可されるための能力を持たせる。
            try insertSubscriptionStateRow(connection, plan: 3, status: 1)
            try insertBatchRow(connection, batchID: batchID.rawValue, kind: 1, trialCreditCount: 0)
        }
        let createdJob = try await authorizeExportJob(store: store, projectID: projectID, batchID: batchID)

        let runningJobs = try await store.loadRunningJobs()

        guard let loadedJob = runningJobs.first(where: { $0.exportID == createdJob.exportID }) else {
            Issue.record("loadRunningJobsが挿入したExportJobを返さなかった")
            return
        }
        #expect(loadedJob.projectID == createdJob.projectID)
        #expect(loadedJob.batchID == createdJob.batchID)
        #expect(loadedJob.queueItemID == createdJob.queueItemID)
        #expect(loadedJob.authorization.accountingMode == createdJob.authorization.accountingMode)
        #expect(loadedJob.authorization.authorizedAt == createdJob.authorization.authorizedAt)
        #expect(loadedJob.authorization.entitlementSnapshot == createdJob.authorization.entitlementSnapshot)
        #expect(loadedJob.delivery.format == createdJob.delivery.format)
        #expect(loadedJob.delivery.suggestedCreationDate == createdJob.delivery.suggestedCreationDate)
    }

    @Test("deleteRunningJobsはsettledAtが非NULLのOutputRecordを削除せず残すこと")
    func deleteRunningJobsPreservesSettledOutputRecord() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID)
        let job = try await authorizeExportJob(store: store, projectID: projectID)
        try await database.dbQueue.write { connection in
            try insertOutputRecord(
                connection, exportID: job.exportID.rawValue, projectID: projectID.rawValue,
                batchID: nil, settledAt: schemaTestReferenceDate
            )
        }

        try await store.deleteRunningJobs([job.exportID])

        #expect(try !exportJobExists(database, exportID: job.exportID.rawValue))
        #expect(try outputRecordRowCount(database, exportID: job.exportID.rawValue) == 1)
    }

    @Test("deleteRunningJobsがExportJobと未確定OutputRecordを削除しPendingFileDeletionを登録しないこと")
    func deletesExportJobAndUnsettledOutputRecordWithoutRegisteringPendingFileDeletion() async throws {
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
            outputSHA256: Data(repeating: 0x04, count: 32)
        ))

        try await store.deleteRunningJobs([job.exportID])

        #expect(try !exportJobExists(database, exportID: job.exportID.rawValue))
        #expect(try outputRecordRowCount(database, exportID: job.exportID.rawValue) == 0)
        #expect(try !pendingFileDeletionExists(database, kind: ManagedFileKind.output.rawValue, fileID: outputFileID))
    }
}
