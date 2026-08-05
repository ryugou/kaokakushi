import Foundation
import Testing
import Domain
import GRDB
@testable import Persistence

// settleBatch の確定対象0件エッジケース（export-saga.md 3章「確定対象が 0 件なら throw」。
// ExportSagaStoreSettleBatchTests.swift から type_body_length 対応で分離）。

@Suite("ExportSagaStoreLive.settleBatch（確定対象0件）")
struct ExportSagaStoreSettleBatchEdgeTests {

    @Test("不明なbatchIDを指定した場合settleBatchNothingToSettleでthrowすること")
    func rejectsUnknownBatchIDWithNothingToSettle() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let unknownBatchID = BatchID(rawValue: UUID())

        do {
            try await store.settleBatch(unknownBatchID, settledAt: schemaTestReferenceDate)
            Issue.record("不明なbatchIDなのにsettleBatchが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .settleBatchNothingToSettle(let mismatchedBatchID) = error else {
                Issue.record("期待したエラーケース(settleBatchNothingToSettle)ではない: \(error)")
                return
            }
            #expect(mismatchedBatchID == unknownBatchID)
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }
    }

    @Test("対象batchID内の全OutputRecordが確定済みの場合settleBatchNothingToSettleでthrowすること")
    func rejectsAlreadySettledBatchWithNothingToSettle() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let batchID = BatchID(rawValue: UUID())
        let exportID = ExportID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertBatch(connection, batchID: batchID.rawValue)
            try insertOutputRecord(
                connection, exportID: exportID.rawValue, projectID: projectID.rawValue,
                batchID: batchID.rawValue, settledAt: schemaTestReferenceDate
            )
        }

        do {
            try await store.settleBatch(batchID, settledAt: schemaTestReferenceDate.addingTimeInterval(3_600))
            Issue.record("全確定済みのバッチなのにsettleBatchが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .settleBatchNothingToSettle(let mismatchedBatchID) = error else {
                Issue.record("期待したエラーケース(settleBatchNothingToSettle)ではない: \(error)")
                return
            }
            #expect(mismatchedBatchID == batchID)
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }
    }
}
