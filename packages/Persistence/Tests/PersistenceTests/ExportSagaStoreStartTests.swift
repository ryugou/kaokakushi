import Foundation
import Testing
import Domain
@testable import Persistence

// ExportSagaStoreLive.startExportのテスト（export-saga.md 1章「認可」・1.6「開始の順序」
// 手順4〜5が正本）。ここでは単体書き出し（batchID == nil）の勘定モード
// （ExportAccountingMode）の解決結果を検証する。入力検証・DB破損検知のテストは
// ExportSagaStoreStartValidationTests.swiftへ分離した（400行制限のため）。
//
// 1.1（確認の一致）・1.2（能力）の検査はPersistenceのスコープ外（オーケストレーター確定
// 判断。ExportSagaStoreLive+Start.swiftのコメント参照）のため、ここでは検証しない。
// 月間枠チェック（monthlyLimitReached）はTask 5後半で実装済み。専用テストは
// ExportSagaStoreQuotaTests.swiftへ分離した（400行制限）。
//
// バッチの勘定解決（trial残クレジット・proBatch資格）はcreateBatchへ移設した
// （一括処理キュー簡素化 Issue #40 決定2）。startExportのバッチ経路はBatch行に
// 固定済みの認可を読むだけで再評価しないため、旧来ここにあったバッチ経路の
// 勘定解決テストはExportSagaStoreCreateBatchTests.swiftへ移設した。

@Suite("ExportSagaStoreLive.startExport")
struct ExportSagaStoreStartTests {
    @Test("standard planの単体書き出しはpaidUnlimitedで認可されExportJob行が作られること")
    func authorizesStandardPlanSingleExportAsPaidUnlimited() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertSubscriptionStateRow(connection, plan: 2, status: 1)
        }
        let store = makeExportSagaStore(database: database)

        let decision = try await store.startExport(
            try makeStartExportInputFixture(projectID: projectID), expectedProjectRevision: 0
        )

        guard case let .authorized(job) = decision else {
            Issue.record("authorizedであるべき")
            return
        }
        #expect(job.authorization.accountingMode == .paidUnlimited)
        #expect(job.projectID == projectID)
        #expect(job.batchID == nil)
        #expect(try exportJobExists(database, exportID: job.exportID.rawValue))
    }

    @Test("free planの単体書き出しはfreeMonthlyConsumeで認可されること")
    func authorizesFreePlanSingleExportAsFreeMonthlyConsume() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertSubscriptionStateRow(connection, plan: 1, status: 1)
        }
        let store = makeExportSagaStore(database: database)

        let decision = try await store.startExport(
            try makeStartExportInputFixture(projectID: projectID), expectedProjectRevision: 0
        )

        guard case let .authorized(job) = decision else {
            Issue.record("authorizedであるべき")
            return
        }
        #expect(job.authorization.accountingMode == .freeMonthlyConsume)
    }

    @Test("SubscriptionState行が無い場合capabilityVerificationRequiredでblockedになること")
    func blocksWhenSubscriptionStateMissing() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in try insertProject(connection, projectID: projectID.rawValue) }
        let store = makeExportSagaStore(database: database)

        let decision = try await store.startExport(
            try makeStartExportInputFixture(projectID: projectID), expectedProjectRevision: 0
        )

        guard case let .blocked(block) = decision else {
            Issue.record("blockedであるべき")
            return
        }
        #expect(block.reason == .capabilityVerificationRequired)
        let jobCount: Int = try await database.dbQueue.read { connection in
            try Int.fetchOne(connection, sql: "SELECT count(*) FROM ExportJob") ?? -1
        }
        #expect(jobCount == 0)
    }

    @Test("entitlement.statusがpendingの場合freeEquivalentとしてfreeMonthlyConsumeで認可されること")
    func authorizesWhenEntitlementStatusPendingAsFreeMonthlyConsume() async throws {
        // pendingはもはやcapabilityVerificationRequiredのblocked理由ではない（差し戻し
        // 対応1番）。resolveCapabilities（Domain）がpendingをfreeEquivalentCapabilities
        // （singleExportAccess == .metered）へ写像するため、単体書き出しは
        // freeMonthlyConsumeとして認可される。
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertSubscriptionStateRow(connection, plan: 1, status: 3)
        }
        let store = makeExportSagaStore(database: database)

        let decision = try await store.startExport(
            try makeStartExportInputFixture(projectID: projectID), expectedProjectRevision: 0
        )

        guard case let .authorized(job) = decision else {
            Issue.record("authorizedであるべき")
            return
        }
        #expect(job.authorization.accountingMode == .freeMonthlyConsume)
    }

    // 元 Critical（失効した有料契約が paidUnlimited 認可される）の退行を store 統合レベルで
    // 固定する2本（再レビュー W1）。plan ベース判定へ退行すると paidUnlimited になり落ちる。
    @Test("有料plan×expiredのSubscriptionStateはfreeMonthlyConsumeで認可されること")
    func authorizesExpiredPaidPlanAsFreeMonthlyConsume() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            // plan 2 = standard、status 4 = expired。
            try insertSubscriptionStateRow(connection, plan: 2, status: 4)
        }
        let store = makeExportSagaStore(database: database)

        let decision = try await store.startExport(
            try makeStartExportInputFixture(projectID: projectID), expectedProjectRevision: 0
        )

        guard case let .authorized(job) = decision else {
            Issue.record("authorizedであるべき")
            return
        }
        #expect(job.authorization.accountingMode == .freeMonthlyConsume)
    }

    @Test("有料plan×activeでもexpiresAt超過ならfreeMonthlyConsumeで認可されること")
    func authorizesPaidPlanPastExpiryAsFreeMonthlyConsume() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            // plan 3 = pro、status 1 = active だが expiresAt が注入 now（schemaTestReferenceDate）
            // より過去 → resolveCapabilities の失効判定で Free 相当になる。
            try insertSubscriptionStateRow(
                connection, plan: 3, status: 1,
                expiresAt: schemaTestReferenceDate.addingTimeInterval(-1)
            )
        }
        let store = makeExportSagaStore(database: database)

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
