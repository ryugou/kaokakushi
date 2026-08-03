import Foundation
import Testing
import Domain
@testable import Persistence

// ExportSagaStoreLive.settleExportのテスト（export-saga.md 3章「手順」手順5が正本）。
// 事前条件違反のテストは、テストの意図が「その条件だけ」を検証するように、raw SQL挿入
// ヘルパー（SchemaTestSupport.swift）でExportJob/OutputRecord/ExportQueueItemの行を直接
// 組み立てるものと、実際のstartExport→recordGeneratedOutputパイプラインを通すものを
// 使い分ける（queueItemIDの事前条件はExportJob.batchIDが非nilである必要があるため、
// 判定ロジックを正しく通すには後者が必要）。settleBatch固有のテストは
// ExportSagaStoreSettleBatchTests.swiftへ分離した（400行制限）。

@Suite("ExportSagaStoreLive.settleExport")
struct ExportSagaStoreSettleTests {
    @Test("成功時にsettledAt確定・ExportRecord作成・ExportJob削除が同一トランザクションで観測できること")
    func settlesSingleExportAtomically() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID)
        let job = try await authorizeExportJob(store: store, projectID: projectID)
        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: job.exportID,
            outputFile: makeOutputFileRefFixture(),
            outputByteSize: 4_096,
            outputSHA256: Data(repeating: 0x10, count: 32)
        ))

        try await store.settleExport(job.exportID)

        #expect(try !exportJobExists(database, exportID: job.exportID.rawValue))
        let outputFields = try outputRecordFields(database, exportID: job.exportID.rawValue)
        #expect(outputFields?.settledAt != nil)
        let record = try exportRecordFields(database, exportID: job.exportID.rawValue)
        #expect(record?.outputByteSize == 4_096)
        #expect(record?.accountingMode == ExportAccountingModeColumn(job.authorization.accountingMode).rawValue)
        #expect(record?.format == ImageFormatColumn(job.delivery.format).rawValue)
    }

    @Test("ExportJob.batchIDが非nilならsettleExportBatchIDNotNilでthrowしDB状態を変えないこと")
    func rejectsWhenExportJobHasBatchID() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let batchID = BatchID(rawValue: UUID())
        let exportID = ExportID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertBatch(connection, batchID: batchID.rawValue)
            try insertExportJob(
                connection, exportID: exportID.rawValue, projectID: projectID.rawValue, batchID: batchID.rawValue
            )
            try insertOutputRecord(
                connection, exportID: exportID.rawValue, projectID: projectID.rawValue,
                batchID: batchID.rawValue, settledAt: nil
            )
        }

        do {
            try await store.settleExport(exportID)
            Issue.record("batchIDが非nilなのにsettleExportが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .settleExportBatchIDNotNil = error else {
                Issue.record("期待したエラーケース(settleExportBatchIDNotNil)ではない: \(error)")
                return
            }
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }

        #expect(try exportJobExists(database, exportID: exportID.rawValue))
        let fields = try outputRecordFields(database, exportID: exportID.rawValue)
        #expect(fields?.settledAt == nil)
    }

    @Test("対応するOutputRecordが存在しなければsettlePendingOutputRecordNotFoundでthrowしDB状態を変えないこと")
    func rejectsWhenNoOutputRecordExists() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let exportID = ExportID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertExportJob(connection, exportID: exportID.rawValue, projectID: projectID.rawValue, batchID: nil)
        }

        do {
            try await store.settleExport(exportID)
            Issue.record("OutputRecordが無いのにsettleExportが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .settlePendingOutputRecordNotFound = error else {
                Issue.record("期待したエラーケース(settlePendingOutputRecordNotFound)ではない: \(error)")
                return
            }
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }

        #expect(try exportJobExists(database, exportID: exportID.rawValue))
        #expect(try outputRecordRowCount(database, exportID: exportID.rawValue) == 0)
    }

    @Test("対応するOutputRecordのsettledAtが既に非NULLならsettlePendingOutputRecordNotFoundでthrowしDB状態を変えないこと")
    func rejectsWhenOutputRecordAlreadySettled() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let exportID = ExportID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertExportJob(connection, exportID: exportID.rawValue, projectID: projectID.rawValue, batchID: nil)
            try insertOutputRecord(
                connection, exportID: exportID.rawValue, projectID: projectID.rawValue,
                batchID: nil, settledAt: schemaTestReferenceDate
            )
        }

        do {
            try await store.settleExport(exportID)
            Issue.record("settle済みのOutputRecordしか無いのにsettleExportが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .settlePendingOutputRecordNotFound = error else {
                Issue.record("期待したエラーケース(settlePendingOutputRecordNotFound)ではない: \(error)")
                return
            }
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }

        #expect(try exportJobExists(database, exportID: exportID.rawValue))
        let fields = try outputRecordFields(database, exportID: exportID.rawValue)
        #expect(fields?.settledAt == schemaTestReferenceDate)
    }

    @Test("queueItemIDに対応するExportQueueItem行が無ければsettleQueueItemPreconditionFailedでthrowすること")
    func rejectsWhenQueueItemMissing() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let exportID = ExportID(rawValue: UUID())
        let queueItemID = ExportQueueItemID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertQueueBackedExportJobWithoutBatch(
                connection, exportID: exportID.rawValue, projectID: projectID.rawValue,
                queueItemID: queueItemID.rawValue
            )
        }
        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: exportID, outputFile: makeOutputFileRefFixture(), outputByteSize: 1_024,
            outputSHA256: Data(repeating: 0x21, count: 32)
        ))

        do {
            try await store.settleExport(exportID)
            Issue.record("対応するExportQueueItemが無いのにsettleExportが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .settleQueueItemPreconditionFailed = error else {
                Issue.record("期待したエラーケース(settleQueueItemPreconditionFailed)ではない: \(error)")
                return
            }
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }

        #expect(try exportJobExists(database, exportID: exportID.rawValue))
    }

    // queueItemのstate不一致・projectID不一致は、job.batchIDが非nilでなければ意味を成さない
    // （validateQueueItemForSettleはjob.batchIDがnilならstate/projectIDを見るより前に
    // 「batchIDが一致し得ない」でthrowする。ExportQueueItem.batchIDはNOT NULL制約のため）。
    // settleExportはExportJob.batchID == nilが事前条件のため、これらの個別ケースは
    // job.batchIDが非nilになり得るsettleBatch側で検証する
    // （ExportSagaStoreSettleBatchTests.swift）。

    @Test("settle済みのexportIDへ再度settleExportを呼ぶとExportJob不在(settleExportJobNotFound)でthrowすること")
    func rejectsReapplyOnAlreadySettledExportID() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID)
        let job = try await authorizeExportJob(store: store, projectID: projectID)
        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: job.exportID, outputFile: makeOutputFileRefFixture(), outputByteSize: 1_024,
            outputSHA256: Data(repeating: 0x30, count: 32)
        ))
        try await store.settleExport(job.exportID)

        do {
            try await store.settleExport(job.exportID)
            Issue.record("settle済みのexportIDへの再settleが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .settleExportJobNotFound = error else {
                Issue.record("期待したエラーケース(settleExportJobNotFound)ではない: \(error)")
                return
            }
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }
    }
}
