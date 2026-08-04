import Foundation
import Testing
import Domain
@testable import Persistence

// 単一行キー（id INTEGER PRIMARY KEY CHECK(id = 1)。Schema+Delivery.swift /
// Schema+Accounting.swift）を意図的に無効化して2行状態を作る。v2以降のマイグレーションで
// 制約が落ちた場合や外部改変DBでも`fetchSingletonRow`（ExportSagaStoreLive+Mapping.swift）が
// fail-closedすることを検証する二重担保（CHECK制約そのものの拒否は
// SchemaSingletonKeyTests.swiftが検証する。通常のINSERT経路の異常系は
// ExportSagaStoreStartValidationTests.swift参照）。

@Suite("ExportSagaStoreLive.startExport(単一行契約)")
struct ExportSagaStoreSingletonContractTests {
    @Test("SubscriptionStateが2件以上ある場合multipleSingletonRowsでthrowすること")
    func throwsWhenSubscriptionStateHasMultipleRows() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertSubscriptionStateRow(connection, plan: 1, status: 1)
            // 単一行キーのCHECK制約を一時的に無効化し、通常経路では作れない2件目の行を
            // 直接作る（この無効化はこのdbQueue.writeブロック内でのみ有効）。
            try connection.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try insertSubscriptionStateRow(connection, plan: 2, status: 1)
            try connection.execute(sql: "PRAGMA ignore_check_constraints = OFF")
        }
        let store = makeExportSagaStore(database: database)

        do {
            _ = try await store.startExport(
                try makeStartExportInputFixture(projectID: projectID), expectedProjectRevision: 0
            )
            Issue.record("SubscriptionStateが2件あるのにstartExportが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .multipleSingletonRows(let table, let count) = error else {
                Issue.record("期待したエラーケース(multipleSingletonRows)ではない: \(error)")
                return
            }
            #expect(table == "SubscriptionState")
            #expect(count == 2)
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }
    }

    @Test("UsageLedgerが2件以上ある場合multipleSingletonRowsでthrowすること")
    func throwsWhenUsageLedgerHasMultipleRows() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let batchID = BatchID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertSubscriptionStateRow(connection, plan: 1, status: 1)
            try insertBatchRow(connection, batchID: batchID.rawValue, kind: 2, trialCreditCount: 5)
            try insertUsageLedgerRow(connection, trialConsumedCount: 1)
            // 単一行キーのCHECK制約を一時的に無効化し、通常経路では作れない2件目の行を
            // 直接作る（この無効化はこのdbQueue.writeブロック内でのみ有効）。
            try connection.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try insertUsageLedgerRow(connection, trialConsumedCount: 2)
            try connection.execute(sql: "PRAGMA ignore_check_constraints = OFF")
        }
        let store = makeExportSagaStore(database: database)

        do {
            _ = try await store.startExport(
                try makeStartExportInputFixture(projectID: projectID, batchID: batchID), expectedProjectRevision: 0
            )
            Issue.record("UsageLedgerが2件あるのにstartExportが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .multipleSingletonRows(let table, let count) = error else {
                Issue.record("期待したエラーケース(multipleSingletonRows)ではない: \(error)")
                return
            }
            #expect(table == "UsageLedger")
            #expect(count == 2)
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }
    }
}
