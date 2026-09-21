import Foundation
import Testing
import Domain
@testable import Persistence

// ExportSagaStoreLive.loadRunningJobs / deleteRunningJobs / deleteUnsettledBatchesの
// テスト（export-saga.md 5章「起動時復旧」が正本）。

@Suite("ExportSagaStoreLive.loadRunningJobs/deleteRunningJobs/deleteUnsettledBatches")
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
        }
        _ = try await createAuthorizedBatch(store: store, batchID: batchID, kind: .proBatch, trialCreditCount: 0)
        let createdJob = try await authorizeExportJob(store: store, projectID: projectID, batchID: batchID)

        let runningJobs = try await store.loadRunningJobs()

        guard let loadedJob = runningJobs.first(where: { $0.exportID == createdJob.exportID }) else {
            Issue.record("loadRunningJobsが挿入したExportJobを返さなかった")
            return
        }
        #expect(loadedJob.projectID == createdJob.projectID)
        #expect(loadedJob.batchID == createdJob.batchID)
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

    @Test("どのExportRecordからも参照されないBatch行がdeleteUnsettledBatchesで削除されること")
    func deletesBatchNotReferencedByAnyExportRecord() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let batchID = UUID()
        try await database.dbQueue.write { connection in
            try insertBatch(connection, batchID: batchID)
        }

        try await store.deleteUnsettledBatches()

        #expect(try !batchRowExists(database, batchID: batchID))
    }

    @Test("ExportRecordが存在するBatch行はdeleteUnsettledBatchesで削除されないこと")
    func keepsBatchReferencedByExportRecord() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let batchID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertBatch(connection, batchID: batchID)
            try insertExportRecord(connection, exportID: UUID(), projectID: projectID.rawValue, batchID: batchID)
        }

        try await store.deleteUnsettledBatches()

        #expect(try batchRowExists(database, batchID: batchID))
    }

    @Test("deleteUnsettledBatchesを連続で2回実行しても2回目が成功し、settle済みのBatchと関連記録に変化がないこと（冪等）")
    func deleteUnsettledBatchesIsIdempotent() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let settledBatchID = UUID()
        let unsettledBatchID = UUID()
        try await seedIdempotencyFixture(
            database, projectID: projectID, settledBatchID: settledBatchID, unsettledBatchID: unsettledBatchID
        )

        // 1回目: 未settle Batch（ExportRecordを持たない）が削除され、settle済みBatchと
        // その関連記録（Project/ExportRecord）は不変であること。
        try await store.deleteUnsettledBatches()
        try assertUnsettledBatchDeletedAndSettledStateUnchanged(
            database, projectID: projectID, settledBatchID: settledBatchID, unsettledBatchID: unsettledBatchID
        )

        // 2回目: 1回目で既に消えた未settle Batchに対する再実行が成功し、結果が変わらないこと
        // （冪等性の本体）。
        try await store.deleteUnsettledBatches()
        try assertUnsettledBatchDeletedAndSettledStateUnchanged(
            database, projectID: projectID, settledBatchID: settledBatchID, unsettledBatchID: unsettledBatchID
        )
    }

    /// deleteUnsettledBatchesIsIdempotentのセットアップ: 削除対象の未settle Batch
    /// （ExportRecordを持たない）と、保護対象の settle済み Batch（Project + batchID付き
    /// ExportRecord）を1件ずつ用意する。
    private func seedIdempotencyFixture(
        _ database: AppDatabase, projectID: ProjectID, settledBatchID: UUID, unsettledBatchID: UUID
    ) async throws {
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertBatch(connection, batchID: settledBatchID)
            try insertBatch(connection, batchID: unsettledBatchID)
            try insertExportRecord(
                connection, exportID: UUID(), projectID: projectID.rawValue, batchID: settledBatchID
            )
        }
    }

    /// deleteUnsettledBatches実行後に共通して確認する3点: 未settle Batchが消えていること、
    /// settle済みBatchと関連記録（Project/ExportRecord）が不変であること。
    private func assertUnsettledBatchDeletedAndSettledStateUnchanged(
        _ database: AppDatabase, projectID: ProjectID, settledBatchID: UUID, unsettledBatchID: UUID
    ) throws {
        #expect(try !batchRowExists(database, batchID: unsettledBatchID))
        #expect(try batchRowExists(database, batchID: settledBatchID))
        #expect(try projectRowExists(database, projectID: projectID.rawValue))
        let exportRecordCount = try database.dbQueue.read { connection in
            try countExportRecordRows(connection, projectID: projectID.rawValue)
        }
        #expect(exportRecordCount == 1)
    }
}
