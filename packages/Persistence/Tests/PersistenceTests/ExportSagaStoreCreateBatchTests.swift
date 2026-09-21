import Foundation
import Testing
import GRDB
import Domain
@testable import Persistence

// ExportSagaStoreLive.createBatchのテスト（Domain/Ports/ExportSagaStore.swift docコメント・
// export-saga.md 1.3「権限とクォータ」・1.5「バッチ開始時の認可スナップショットで全項目を
// 完了させる」が正本。一括処理キュー簡素化 Issue #40 決定2）。
//
// このファイルは blocked/created の基本契約（Batch行の挿入有無・認可列の往復一致・
// 認可評価とINSERTの原子性）とproBatch種別の勘定判定を検証する。trial種別の勘定判定
// （残クレジット判定・hardMaxTrialCreditsクランプ・Pro加入済みバイパス）とUsageLedgerの
// BLOB破損検知は type_body_length 対応で ExportSagaStoreCreateBatchTrialTests.swift へ
// 分離した。
//
// バッチの勘定解決（trial残クレジット・proBatch資格・UsageLedgerのBLOB破損検知）は
// startExportのバッチ経路からcreateBatchへ移設した。旧startExportバッチ経路が検証して
// いた同趣旨のテスト（ExportSagaStoreStartTests.swift /
// ExportSagaStoreStartValidationTests.swift）はここへ移設した。startExportのバッチ経路は
// Batch行に固定済みの認可を読むだけで、これらの評価ロジックを一切呼ばない
// （ExportSagaStoreLive+Start.swiftのloadBatchAuthorization参照。固定された認可の再利用
// 自体はExportSagaStoreStartSnapshotTests.swiftが検証する）。

@Suite("ExportSagaStoreLive.createBatch")
struct ExportSagaStoreCreateBatchTests {
    // MARK: - blocked / created の基本契約

    @Test("blockedのときBatch行が挿入されないこと")
    func doesNotInsertBatchRowWhenBlocked() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        // plan 2 = standard（active）。canUseProBatch == falseのためproBatchはblockedになる。
        try await database.dbQueue.write { connection in
            try insertSubscriptionStateRow(connection, plan: 2, status: 1)
        }
        let store = makeExportSagaStore(database: database)
        let batchID = BatchID(rawValue: UUID())
        let policy = BatchPolicySnapshot(kind: .proBatch, batchSizeLimit: 50, trialCreditCount: 0, concurrencyLimit: 1)

        let decision = try await store.createBatch(
            CreateBatchInput(batchID: batchID, policy: policy, createdAt: schemaTestReferenceDate)
        )

        guard case .blocked = decision else {
            Issue.record("blockedであるべき")
            return
        }
        #expect(try readBatchRow(database, batchID: batchID.rawValue) == nil)
        let batchCount: Int = try await database.dbQueue.read { connection in
            try Int.fetchOne(connection, sql: "SELECT count(*) FROM Batch") ?? -1
        }
        #expect(batchCount == 0)
    }

    @Test("createdのとき、認可列がINSERTした値と読み戻した値で一致すること（往復一致）")
    func roundTripsAuthorizationColumnsOnCreated() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let batchID = BatchID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            // plan 3 = pro（active, sandbox）。expiresAtを持たせentitlementExpiresAtの
            // nullable往復も確認する。
            try insertSubscriptionStateRow(
                connection, plan: 3, status: 1, isSandbox: true,
                expiresAt: schemaTestReferenceDate.addingTimeInterval(86_400)
            )
        }
        let store = makeExportSagaStore(database: database)
        let policy = BatchPolicySnapshot(kind: .proBatch, batchSizeLimit: 42, trialCreditCount: 7, concurrencyLimit: 3)

        let decision = try await store.createBatch(
            CreateBatchInput(batchID: batchID, policy: policy, createdAt: schemaTestReferenceDate)
        )

        guard case let .created(authorization) = decision else {
            Issue.record("createdであるべき")
            return
        }
        guard let row = try readBatchRow(database, batchID: batchID.rawValue) else {
            Issue.record("Batch行が読み戻せなかった")
            return
        }
        #expect(row.kind == Int(BatchKind.proBatch.rawValue))
        #expect(row.batchSizeLimit == 42)
        #expect(row.trialCreditCount == 7)
        #expect(row.concurrencyLimit == 3)
        #expect(row.authorizedAt == authorization.authorizedAt)
        #expect(row.accountingMode == ExportAccountingModeColumn(authorization.accountingMode).rawValue)
        #expect(row.entitlementPlan == Int(authorization.entitlementSnapshot.plan.rawValue))
        #expect(row.entitlementStatus == Int(authorization.entitlementSnapshot.status.rawValue))
        #expect(row.entitlementExpiresAt == authorization.entitlementSnapshot.expiresAt)
        #expect(row.entitlementLastVerifiedAt == authorization.entitlementSnapshot.lastVerifiedAt)
        #expect(row.entitlementIsSandbox == authorization.entitlementSnapshot.isSandbox)
    }

    @Test("認可評価とINSERTは原子的であり、blockedのとき既存の他のBatch行に変化がないこと")
    func doesNotMutateOtherBatchRowsWhenBlocked() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try await database.dbQueue.write { connection in
            try insertSubscriptionStateRow(connection, plan: 3, status: 1)
        }
        let store = makeExportSagaStore(database: database)
        let existingBatchID = BatchID(rawValue: UUID())
        _ = try await createAuthorizedBatch(store: store, batchID: existingBatchID, kind: .proBatch)
        let beforeRow = try readBatchRow(database, batchID: existingBatchID.rawValue)

        // 契約を失効させ、以降のcreateBatchがproBatch不成立でblockedになるようにする。
        try await database.dbQueue.write { connection in
            try connection.execute(sql: "UPDATE SubscriptionState SET status = ?", arguments: [4])
        }
        let blockedBatchID = BatchID(rawValue: UUID())
        let policy = BatchPolicySnapshot(kind: .proBatch, batchSizeLimit: 50, trialCreditCount: 0, concurrencyLimit: 1)

        let decision = try await store.createBatch(
            CreateBatchInput(batchID: blockedBatchID, policy: policy, createdAt: schemaTestReferenceDate)
        )

        guard case .blocked = decision else {
            Issue.record("blockedであるべき")
            return
        }
        #expect(try readBatchRow(database, batchID: blockedBatchID.rawValue) == nil)
        #expect(try readBatchRow(database, batchID: existingBatchID.rawValue) == beforeRow)
    }

    // MARK: - proBatch

    @Test("proBatchでcanUseProBatchが成立するなら.created(.paidUnlimited)になること")
    func createsProBatchWhenCapableAsPaidUnlimited() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        // plan 3 = pro（active）。canUseProBatch == true。
        try await database.dbQueue.write { connection in
            try insertSubscriptionStateRow(connection, plan: 3, status: 1)
        }
        let store = makeExportSagaStore(database: database)
        let policy = BatchPolicySnapshot(kind: .proBatch, batchSizeLimit: 50, trialCreditCount: 0, concurrencyLimit: 1)

        let decision = try await store.createBatch(
            CreateBatchInput(batchID: BatchID(rawValue: UUID()), policy: policy, createdAt: schemaTestReferenceDate)
        )

        guard case let .created(authorization) = decision else {
            Issue.record("createdであるべき")
            return
        }
        #expect(authorization.accountingMode == .paidUnlimited)
    }

    @Test("proBatchでcanUseProBatchが不成立なら.blocked(.capabilityVerificationRequired)になること")
    func blocksProBatchWhenIncapable() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        // plan 2 = standard（active）。capabilities(forPlan: .standard)はcanUseProBatch
        // == falseを返す。
        try await database.dbQueue.write { connection in
            try insertSubscriptionStateRow(connection, plan: 2, status: 1)
        }
        let store = makeExportSagaStore(database: database)
        let policy = BatchPolicySnapshot(kind: .proBatch, batchSizeLimit: 50, trialCreditCount: 0, concurrencyLimit: 1)

        let decision = try await store.createBatch(
            CreateBatchInput(batchID: BatchID(rawValue: UUID()), policy: policy, createdAt: schemaTestReferenceDate)
        )

        guard case let .blocked(block) = decision else {
            Issue.record("blockedであるべき")
            return
        }
        #expect(block.reason == .capabilityVerificationRequired)
    }

    // MARK: - usageNow（評価時刻）とauthorizedAt（記録時刻）の分離（レビュー指摘Warning 1対応）

    @Test("認可評価には注入時計now()を使い、input.createdAtでは失効を回避できないこと（fail-closed）")
    func evaluatesExpirationWithInjectedClockNotCreatedAt() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        // plan 3 = pro（active）。expiresAtはcreatedAtより1_000秒後 = createdAt時点では
        // 未失効、now()の時点では失効済みという状況を作る。
        try await database.dbQueue.write { connection in
            try insertSubscriptionStateRow(
                connection, plan: 3, status: 1, expiresAt: schemaTestReferenceDate.addingTimeInterval(1_000)
            )
        }
        // now()はexpiresAtの後（失効後）を返す。input.createdAtが評価に使われる実装だと
        // ここが失効前と判定され誤って.created(.paidUnlimited)になってしまう
        // （ResolveCapabilities.swiftのisExpired判定はusageNow >= expiresAtで行われる）。
        let store = makeExportSagaStore(
            database: database, now: { schemaTestReferenceDate.addingTimeInterval(5_000) }
        )
        let policy = BatchPolicySnapshot(kind: .proBatch, batchSizeLimit: 50, trialCreditCount: 0, concurrencyLimit: 1)
        let batchID = BatchID(rawValue: UUID())

        // createdAtはexpiresAtより前（失効前）の古い値を渡す。評価がinput.createdAtを
        // 使ってしまう退行を検知するのが本テストの目的。
        let decision = try await store.createBatch(
            CreateBatchInput(batchID: batchID, policy: policy, createdAt: schemaTestReferenceDate)
        )

        guard case let .blocked(block) = decision else {
            Issue.record("失効済みentitlementはblockedであるべき（fail-closedが崩れている）")
            return
        }
        #expect(block.reason == .capabilityVerificationRequired)
        #expect(try readBatchRow(database, batchID: batchID.rawValue) == nil)
    }

    @Test("Batch行のauthorizedAt列はinput.createdAtを記録し、注入時計now()の値は記録されないこと")
    func recordsAuthorizedAtFromInputCreatedAtNotInjectedClock() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        // expiresAtはnil（無期限）にして、now()とcreatedAtの差が失効判定に影響しないように
        // 切り分ける（このテストの関心はauthorizedAt列の記録元だけ）。
        try await database.dbQueue.write { connection in
            try insertSubscriptionStateRow(connection, plan: 3, status: 1)
        }
        // now()はcreatedAtとは異なる値を注入し、authorizedAt列がどちらの値を記録するかを
        // 区別できるようにする。
        let injectedNow = schemaTestReferenceDate.addingTimeInterval(9_000)
        let store = makeExportSagaStore(database: database, now: { injectedNow })
        let policy = BatchPolicySnapshot(kind: .proBatch, batchSizeLimit: 50, trialCreditCount: 0, concurrencyLimit: 1)
        let batchID = BatchID(rawValue: UUID())

        let decision = try await store.createBatch(
            CreateBatchInput(batchID: batchID, policy: policy, createdAt: schemaTestReferenceDate)
        )

        guard case let .created(authorization) = decision else {
            Issue.record("createdであるべき")
            return
        }
        #expect(authorization.authorizedAt == schemaTestReferenceDate)
        #expect(authorization.authorizedAt != injectedNow)
        guard let row = try readBatchRow(database, batchID: batchID.rawValue) else {
            Issue.record("Batch行が読み戻せなかった")
            return
        }
        #expect(row.authorizedAt == schemaTestReferenceDate)
    }
}

/// createBatchがBatch行へ固定したauthorization7列＋構造4列を読み戻す（往復一致・
/// 原子性テスト専用。ExportSagaStoreTestSupport.swiftへ共有化するほどの再利用先が
/// 無いためこのファイルに留める）。
struct BatchRowSnapshot: Equatable {
    let kind: Int
    let batchSizeLimit: Int32
    let trialCreditCount: Int32
    let concurrencyLimit: Int32
    let authorizedAt: Date
    let accountingMode: Int
    let entitlementPlan: Int
    let entitlementStatus: Int
    let entitlementExpiresAt: Date?
    let entitlementLastVerifiedAt: Date
    let entitlementIsSandbox: Bool
}

func readBatchRow(_ database: AppDatabase, batchID: UUID) throws -> BatchRowSnapshot? {
    try database.dbQueue.read { connection in
        guard let row = try Row.fetchOne(
            connection,
            sql: """
            SELECT kind, batchSizeLimit, trialCreditCount, concurrencyLimit, authorizedAt, accountingMode,
                entitlementPlan, entitlementStatus, entitlementExpiresAt, entitlementLastVerifiedAt,
                entitlementIsSandbox
            FROM Batch WHERE batchID = ?
            """,
            arguments: [batchID]
        ) else {
            return nil
        }
        return BatchRowSnapshot(
            kind: row["kind"], batchSizeLimit: row["batchSizeLimit"], trialCreditCount: row["trialCreditCount"],
            concurrencyLimit: row["concurrencyLimit"], authorizedAt: row["authorizedAt"],
            accountingMode: row["accountingMode"], entitlementPlan: row["entitlementPlan"],
            entitlementStatus: row["entitlementStatus"], entitlementExpiresAt: row["entitlementExpiresAt"],
            entitlementLastVerifiedAt: row["entitlementLastVerifiedAt"],
            entitlementIsSandbox: row["entitlementIsSandbox"]
        )
    }
}
