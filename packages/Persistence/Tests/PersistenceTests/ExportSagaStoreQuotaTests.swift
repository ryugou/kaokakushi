import Foundation
import Testing
import Domain
@testable import Persistence

// startExportの月間枠チェック（monthlyLimitReached）のテスト（architecture.md 6.3
// 「クォータとトライアル」「判定」節、export-saga.md 1.3が正本）。ExportSagaStoreStartTests.
// swiftのコメントどおり、専用ファイルへ分離した（400行制限）。

@Suite("ExportSagaStoreLive.startExport 月間枠")
struct ExportSagaStoreQuotaTests {
    @Test("当月のconsumedExportIDsがmonthlyLimitに達しているfree planの単体書き出しはmonthlyLimitReachedでblockedになること")
    func blocksSingleExportWhenMonthlyLimitReached() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID, plan: 1, status: 1)
        // schemaTestReferenceDateは2023-11-14T22:13:20Z（UTC）。makeExportSagaStoreの
        // deviceTimeZone既定はUTCのため、currentPeriod = (2023, 11)と一致させる。
        try await database.dbQueue.write { connection in
            try insertUsageLedgerRowWithIDs(
                connection, periodYear: 2_023, periodMonth: 11,
                consumedExportIDs: makeExportIDs(count: 5), trialConsumedExportIDs: []
            )
        }

        let decision = try await store.startExport(
            try makeStartExportInputFixture(projectID: projectID), expectedProjectRevision: 0
        )

        guard case let .blocked(block) = decision else {
            Issue.record("blockedであるべき")
            return
        }
        #expect(block.reason == .monthlyLimitReached)
        #expect(block.limit == 5)
        let jobCount: Int = try await database.dbQueue.read { connection in
            try Int.fetchOne(connection, sql: "SELECT count(*) FROM ExportJob") ?? -1
        }
        #expect(jobCount == 0)
    }

    @Test("当月のconsumedExportIDsがmonthlyLimit未満のfree planの単体書き出しはfreeMonthlyConsumeで認可されること")
    func authorizesSingleExportWhenBelowMonthlyLimit() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID, plan: 1, status: 1)
        try await database.dbQueue.write { connection in
            try insertUsageLedgerRowWithIDs(
                connection, periodYear: 2_023, periodMonth: 11,
                consumedExportIDs: makeExportIDs(count: 4), trialConsumedExportIDs: []
            )
        }

        let decision = try await store.startExport(
            try makeStartExportInputFixture(projectID: projectID), expectedProjectRevision: 0
        )

        guard case let .authorized(job) = decision else {
            Issue.record("authorizedであるべき")
            return
        }
        #expect(job.authorization.accountingMode == .freeMonthlyConsume)
    }

    @Test("前月のconsumedExportIDsがmonthlyLimitに達していても当月扱いではblockedにならないこと")
    func doesNotBlockWhenLimitReachedOnlyInPreviousPeriod() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID, plan: 1, status: 1)
        try await database.dbQueue.write { connection in
            try insertUsageLedgerRowWithIDs(
                connection, periodYear: 2_023, periodMonth: 10,
                consumedExportIDs: makeExportIDs(count: 5), trialConsumedExportIDs: []
            )
        }

        let decision = try await store.startExport(
            try makeStartExportInputFixture(projectID: projectID), expectedProjectRevision: 0
        )

        guard case let .authorized(job) = decision else {
            Issue.record("authorizedであるべき")
            return
        }
        #expect(job.authorization.accountingMode == .freeMonthlyConsume)
    }
}
