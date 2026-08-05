import Foundation
import Testing
import Domain
@testable import Persistence

// ExportSagaStoreLive.settleBatchのテスト（export-saga.md 3章「手順」手順5が正本）。
// queueItem事前条件のstate/projectID不一致は、job.batchIDが非nilである場合にのみ意味を成す
// （validateQueueItemForSettleはjob.batchIDがnilなら先にbatchID不一致でthrowするため）。
// settleExportは単体専用でjob.batchID == nilが前提のため、この2ケースはsettleBatch側で
// 検証する（ExportSagaStoreSettleTests.swiftのコメント参照）。

@Suite("ExportSagaStoreLive.settleBatch")
struct ExportSagaStoreSettleBatchTests {
    @Test("複数projectIDにまたがるバッチの全OutputRecordが同一settledAtで確定されること")
    func settlesAllPendingOutputRecordsInBatchWithUniformSettledAt() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let batchID = BatchID(rawValue: UUID())
        let firstProjectID = ProjectID(rawValue: UUID())
        let secondProjectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: firstProjectID)
        try await seedAuthorizedProject(database, projectID: secondProjectID)
        try await database.dbQueue.write { connection in
            try insertBatchRow(connection, batchID: batchID.rawValue, kind: 2, trialCreditCount: 10)
        }
        let firstJob = try await authorizeExportJob(store: store, projectID: firstProjectID, batchID: batchID)
        let secondJob = try await authorizeExportJob(store: store, projectID: secondProjectID, batchID: batchID)
        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: firstJob.exportID, outputFile: makeOutputFileRefFixture(), outputByteSize: 1_000,
            outputSHA256: Data(repeating: 0x40, count: 32)
        ))
        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: secondJob.exportID, outputFile: makeOutputFileRefFixture(), outputByteSize: 2_000,
            outputSHA256: Data(repeating: 0x41, count: 32)
        ))
        let settledAt = schemaTestReferenceDate.addingTimeInterval(3_600)

        try await store.settleBatch(batchID, settledAt: settledAt)

        #expect(try !exportJobExists(database, exportID: firstJob.exportID.rawValue))
        #expect(try !exportJobExists(database, exportID: secondJob.exportID.rawValue))
        let firstFields = try outputRecordFields(database, exportID: firstJob.exportID.rawValue)
        let secondFields = try outputRecordFields(database, exportID: secondJob.exportID.rawValue)
        #expect(firstFields?.settledAt == settledAt)
        #expect(secondFields?.settledAt == settledAt)
        let ledger = try usageLedgerFields(database)
        #expect(ledger?.trialConsumedExportIDs == Set([firstJob.exportID, secondJob.exportID]))
        #expect(ledger?.consumedExportIDs.isEmpty == true)
    }

    @Test("OutputRecordを持たないExportJobが同一バッチに残っていてもsettleBatchが残りを確定すること")
    func settlesRemainingRecordsWhenABatchJobHasNoOutputRecord() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let batchID = BatchID(rawValue: UUID())
        let pendingProjectID = ProjectID(rawValue: UUID())
        let noOutputProjectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: pendingProjectID)
        try await seedAuthorizedProject(database, projectID: noOutputProjectID)
        try await database.dbQueue.write { connection in
            try insertBatchRow(connection, batchID: batchID.rawValue, kind: 2, trialCreditCount: 10)
        }
        let pendingJob = try await authorizeExportJob(store: store, projectID: pendingProjectID, batchID: batchID)
        let noOutputJob = try await authorizeExportJob(store: store, projectID: noOutputProjectID, batchID: batchID)
        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: pendingJob.exportID, outputFile: makeOutputFileRefFixture(), outputByteSize: 1_500,
            outputSHA256: Data(repeating: 0x44, count: 32)
        ))
        // noOutputJobはrecordGeneratedOutputを呼ばない
        // （failed/paused/生成前のいずれかでOutputRecordを持たない状態を再現する）。

        try await store.settleBatch(batchID, settledAt: schemaTestReferenceDate)

        #expect(try !exportJobExists(database, exportID: pendingJob.exportID.rawValue))
        let settledFields = try outputRecordFields(database, exportID: pendingJob.exportID.rawValue)
        #expect(settledFields?.settledAt == schemaTestReferenceDate)
        #expect(try exportJobExists(database, exportID: noOutputJob.exportID.rawValue))
        #expect(try outputRecordRowCount(database, exportID: noOutputJob.exportID.rawValue) == 0)
        let ledger = try usageLedgerFields(database)
        #expect(ledger?.trialConsumedExportIDs == Set([pendingJob.exportID]))
    }

    @Test("台帳の消費件数不一致(settleConsumptionMismatch)を検知しトランザクション全体をロールバックすること")
    func rejectsConsumptionMismatch() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let batchID = BatchID(rawValue: UUID())
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID)
        try await database.dbQueue.write { connection in
            try insertBatchRow(connection, batchID: batchID.rawValue, kind: 2, trialCreditCount: 10)
        }
        let job = try await authorizeExportJob(store: store, projectID: projectID, batchID: batchID)
        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: job.exportID, outputFile: makeOutputFileRefFixture(), outputByteSize: 1_500,
            outputSHA256: Data(repeating: 0x42, count: 32)
        ))
        // 破損状態を再現する: このexportIDが既にtrialConsumedExportIDsに記録されている状態
        // （通常のAPI経路では発生し得ない。安全弁の動作を確認するための意図的な不整合注入）。
        try await database.dbQueue.write { connection in
            try insertUsageLedgerRowWithIDs(
                connection, periodYear: 2_023, periodMonth: 11,
                consumedExportIDs: [], trialConsumedExportIDs: [job.exportID]
            )
        }

        do {
            try await store.settleBatch(batchID, settledAt: schemaTestReferenceDate)
            Issue.record("消費件数が不一致なのにsettleBatchが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .settleConsumptionMismatch = error else {
                Issue.record("期待したエラーケース(settleConsumptionMismatch)ではない: \(error)")
                return
            }
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }

        #expect(try exportJobExists(database, exportID: job.exportID.rawValue))
        let fields = try outputRecordFields(database, exportID: job.exportID.rawValue)
        #expect(fields?.settledAt == nil)
    }

    @Test("OutputRecord.batchIDに対応するExportJob.batchIDが異なればsettleBatchJobBatchIDMismatchでthrowしDB状態を変えないこと")
    func rejectsWhenOutputRecordBatchIDDoesNotMatchJobBatchID() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let targetBatchID = BatchID(rawValue: UUID())
        let exportID = ExportID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertBatch(connection, batchID: targetBatchID.rawValue)
            // ExportJob.batchIDはnil（単体書き出しのつもり）だが、OutputRecord.batchIDだけが
            // targetBatchIDを指す不整合を直接作る（通常のAPI経路〈recordGeneratedOutputは
            // job.batchIDをそのままコピーする〉では起こり得ないデータ不整合の再現）。
            try insertExportJob(connection, exportID: exportID.rawValue, projectID: projectID.rawValue, batchID: nil)
            try insertOutputRecord(
                connection, exportID: exportID.rawValue, projectID: projectID.rawValue,
                batchID: targetBatchID.rawValue, settledAt: nil
            )
        }

        do {
            try await store.settleBatch(targetBatchID, settledAt: schemaTestReferenceDate)
            Issue.record("ExportJob.batchIDが不一致なのにsettleBatchが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .settleBatchJobBatchIDMismatch = error else {
                Issue.record("期待したエラーケース(settleBatchJobBatchIDMismatch)ではない: \(error)")
                return
            }
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }

        #expect(try exportJobExists(database, exportID: exportID.rawValue))
        let fields = try outputRecordFields(database, exportID: exportID.rawValue)
        #expect(fields?.settledAt == nil)
    }

    @Test("バッチ内のqueueItemのstateがexportingでなければsettleQueueItemPreconditionFailedでthrowすること")
    func rejectsWhenQueueItemStateNotExporting() async throws {
        try await assertQueueItemPreconditionRejectedViaSettleBatch(mismatch: .wrongState)
    }

    @Test("バッチ内のqueueItemのprojectIDが一致しなければsettleQueueItemPreconditionFailedでthrowすること")
    func rejectsWhenQueueItemProjectIDMismatch() async throws {
        try await assertQueueItemPreconditionRejectedViaSettleBatch(mismatch: .wrongProjectID)
    }

    private enum QueueItemMismatch {
        case wrongState
        case wrongProjectID
    }

    /// assertQueueItemPreconditionRejectedViaSettleBatchのセットアップ部分（proBatch
    /// 〈paidUnlimited〉でqueueItemID付きのジョブを認可し、OutputRecordまで作る）を分離した
    /// （関数50行制限）。startExportが失敗した場合はテスト前提の破損としてfatalErrorする
    /// （authorizeExportJobと同じ方針。テスト対象の挙動ではないため#expect/Issue.recordでは
    /// なく即座に落とす）。
    private func authorizeProBatchJobWithQueueItem(
        store: ExportSagaStoreLive, database: AppDatabase,
        projectID: ProjectID, batchID: BatchID, queueItemID: ExportQueueItemID
    ) async throws -> ExportJob {
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertSubscriptionStateRow(connection, plan: 3, status: 1)
            try insertBatchRow(connection, batchID: batchID.rawValue, kind: 1, trialCreditCount: 0)
        }
        let decision = try await store.startExport(
            try makeStartExportInputFixture(projectID: projectID, batchID: batchID, queueItemID: queueItemID),
            expectedProjectRevision: 0
        )
        guard case let .authorized(job) = decision else {
            fatalError("test setup invariant violated: startExport should authorize a freshly seeded proBatch project")
        }
        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: job.exportID, outputFile: makeOutputFileRefFixture(), outputByteSize: 1_024,
            outputSHA256: Data(repeating: 0x50, count: 32)
        ))
        return job
    }

    /// rejectsWhenQueueItemStateNotExporting / rejectsWhenQueueItemProjectIDMismatchが共有する
    /// セットアップ。ExportQueueItem行をstate/projectIDのいずれかだけ不一致にして直接挿入する。
    private func assertQueueItemPreconditionRejectedViaSettleBatch(mismatch: QueueItemMismatch) async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let batchID = BatchID(rawValue: UUID())
        let queueItemID = ExportQueueItemID(rawValue: UUID())
        let job = try await authorizeProBatchJobWithQueueItem(
            store: store, database: database, projectID: projectID, batchID: batchID, queueItemID: queueItemID
        )
        try await database.dbQueue.write { connection in
            switch mismatch {
            case .wrongState:
                try insertExportQueueItemWithState(
                    connection, queueItemID: queueItemID.rawValue, projectID: projectID.rawValue,
                    batchID: batchID.rawValue, state: 1
                )
            case .wrongProjectID:
                let unrelatedProjectID = UUID()
                try insertProject(connection, projectID: unrelatedProjectID)
                try insertExportQueueItemWithState(
                    connection, queueItemID: queueItemID.rawValue, projectID: unrelatedProjectID,
                    batchID: batchID.rawValue, state: 4
                )
            }
        }

        do {
            try await store.settleBatch(batchID, settledAt: schemaTestReferenceDate)
            Issue.record("キュー項目の事前条件が満たされていないのにsettleBatchが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .settleQueueItemPreconditionFailed = error else {
                Issue.record("期待したエラーケース(settleQueueItemPreconditionFailed)ではない: \(error)")
                return
            }
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }

        #expect(try exportJobExists(database, exportID: job.exportID.rawValue))
    }
}
