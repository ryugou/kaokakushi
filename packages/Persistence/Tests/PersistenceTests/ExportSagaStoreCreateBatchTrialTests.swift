import Foundation
import Testing
import Domain
@testable import Persistence

// ExportSagaStoreLive.createBatchのtrial種別の勘定判定・UsageLedgerのBLOB破損検知の
// テスト（export-saga.md 1.4「勘定の使い分け」・architecture.md 6.3「クォータとトライアル」
// が正本。一括処理キュー簡素化 Issue #40 決定2。ExportSagaStoreCreateBatchTests.swiftから
// type_body_length対応で分離した。blocked/created基本契約・proBatchの勘定判定は
// そちらを参照）。
//
// トライアル残クレジット判定・hardMaxTrialCreditsクランプ・UsageLedgerのBLOB破損検知は
// startExportのバッチ経路からcreateBatchへ移設した（ExportSagaStoreLive+CreateBatch.swiftが
// resolveTrialAccountingMode〈+Accounting.swift〉を再利用する）。旧startExportバッチ経路が
// 検証していた同趣旨のテスト（ExportSagaStoreStartTests.swift /
// ExportSagaStoreStartValidationTests.swift）はここへ移設した。

@Suite("ExportSagaStoreLive.createBatch（trial・UsageLedger破損検知）")
struct ExportSagaStoreCreateBatchTrialTests {
    @Test("trial残0件で.blocked(.trialCreditsUnavailable, limit:)になること")
    func blocksTrialWhenCreditsExhausted() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try await database.dbQueue.write { connection in
            try insertSubscriptionStateRow(connection, plan: 1, status: 1)
            try insertUsageLedgerRow(connection, trialConsumedCount: 3)
        }
        let store = makeExportSagaStore(database: database)
        let policy = BatchPolicySnapshot(kind: .trial, batchSizeLimit: 50, trialCreditCount: 3, concurrencyLimit: 1)

        let decision = try await store.createBatch(
            CreateBatchInput(batchID: BatchID(rawValue: UUID()), policy: policy)
        )

        guard case let .blocked(block) = decision else {
            Issue.record("blockedであるべき")
            return
        }
        #expect(block.reason == .trialCreditsUnavailable)
        #expect(block.limit == 3)
    }

    @Test("残クレジットがあるtrialは.created(.batchTrial)になること")
    func createsTrialWithRemainingCreditsAsBatchTrial() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try await database.dbQueue.write { connection in
            try insertSubscriptionStateRow(connection, plan: 1, status: 1)
            try insertUsageLedgerRow(connection, trialConsumedCount: 2)
        }
        let store = makeExportSagaStore(database: database)
        let policy = BatchPolicySnapshot(kind: .trial, batchSizeLimit: 50, trialCreditCount: 5, concurrencyLimit: 1)

        let decision = try await store.createBatch(
            CreateBatchInput(batchID: BatchID(rawValue: UUID()), policy: policy)
        )

        guard case let .created(authorization) = decision else {
            Issue.record("createdであるべき")
            return
        }
        #expect(authorization.accountingMode == .batchTrial)
    }

    @Test("トライアルクレジット上限はhardMaxTrialCreditsでクランプされDB由来のtrialCreditCountを無条件に信頼しないこと")
    func clampsTrialCreditLimitToHardMaximum() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try await database.dbQueue.write { connection in
            try insertSubscriptionStateRow(connection, plan: 1, status: 1)
            try insertUsageLedgerRow(connection, trialConsumedCount: 5)
        }
        let store = makeExportSagaStore(database: database, hardMaxTrialCredits: 5)
        // policy.trialCreditCount=100だが、hardMaxTrialCredits=5でクランプされるため、
        // 消費済み5件で上限に達したものとしてブロックされるはず。
        let policy = BatchPolicySnapshot(kind: .trial, batchSizeLimit: 50, trialCreditCount: 100, concurrencyLimit: 1)

        let decision = try await store.createBatch(
            CreateBatchInput(batchID: BatchID(rawValue: UUID()), policy: policy)
        )

        guard case let .blocked(block) = decision else {
            Issue.record("hardMaxTrialCreditsでクランプされずcreatedになった")
            return
        }
        #expect(block.reason == .trialCreditsUnavailable)
        #expect(block.limit == 5)
    }

    @Test("Pro加入済み利用者のtrialはクレジット状態に関わらず.created(.paidUnlimited)になりトライアル台帳を消費しないこと")
    func createsTrialForProSubscriberAsPaidUnlimitedWithoutConsumingTrialLedger() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try await database.dbQueue.write { connection in
            // plan 3 = pro（active）。canUseProBatch == true。
            try insertSubscriptionStateRow(connection, plan: 3, status: 1)
            // trialCreditCount=3・trialConsumedCount=3で通常なら使い切り状態
            // （blocksTrialWhenCreditsExhaustedと同条件）。Pro加入済みならこの状態でも
            // ブロックされないことを検証する（architecture.md 6.3「Pro へ加入済みの場合は
            // 消費しない」）。
            try insertUsageLedgerRow(connection, trialConsumedCount: 3)
        }
        let ledgerBefore = try usageLedgerFields(database)
        let store = makeExportSagaStore(database: database)
        let policy = BatchPolicySnapshot(kind: .trial, batchSizeLimit: 50, trialCreditCount: 3, concurrencyLimit: 1)

        let decision = try await store.createBatch(
            CreateBatchInput(batchID: BatchID(rawValue: UUID()), policy: policy)
        )

        guard case let .created(authorization) = decision else {
            Issue.record("Pro加入済みのtrialはcreatedであるべき")
            return
        }
        #expect(authorization.accountingMode == .paidUnlimited)
        // createBatchはUsageLedgerへ一切書き込まない（トライアル消費はsettle側の担当）ため、
        // 台帳の内容は不変のはず。将来の実装変更でここに書き込みが混入する退行を検知する。
        let ledgerAfter = try usageLedgerFields(database)
        #expect(ledgerAfter?.trialConsumedExportIDs == ledgerBefore?.trialConsumedExportIDs)
    }

    @Test("UsageLedgerのBLOB長が16の倍数でない場合corruptUsageLedgerBlobでthrowすること")
    func throwsWhenUsageLedgerBlobLengthIsNotAMultipleOf16() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try await database.dbQueue.write { connection in
            try insertSubscriptionStateRow(connection, plan: 1, status: 1)
            try connection.execute(
                sql: """
                INSERT INTO UsageLedger (periodYear, periodMonth, consumedExportIDs, trialConsumedExportIDs)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [2023, 11, Data(), Data(repeating: 0, count: 17)]
            )
        }
        let store = makeExportSagaStore(database: database)
        let policy = BatchPolicySnapshot(kind: .trial, batchSizeLimit: 50, trialCreditCount: 5, concurrencyLimit: 1)

        do {
            _ = try await store.createBatch(
                CreateBatchInput(batchID: BatchID(rawValue: UUID()), policy: policy)
            )
            Issue.record("BLOB長が16の倍数でないのにcreateBatchが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .corruptUsageLedgerBlob(let byteCount) = error else {
                Issue.record("期待したエラーケース(corruptUsageLedgerBlob)ではない: \(error)")
                return
            }
            #expect(byteCount == 17)
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }
    }

    @Test("UsageLedgerのBLOBに重複するExportIDチャンクがある場合corruptUsageLedgerBlobでthrowすること")
    func throwsWhenUsageLedgerBlobHasDuplicateChunks() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let duplicatedChunk = Data(repeating: 0xAA, count: 16)
        try await database.dbQueue.write { connection in
            try insertSubscriptionStateRow(connection, plan: 1, status: 1)
            try connection.execute(
                sql: """
                INSERT INTO UsageLedger (periodYear, periodMonth, consumedExportIDs, trialConsumedExportIDs)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [2023, 11, Data(), duplicatedChunk + duplicatedChunk]
            )
        }
        let store = makeExportSagaStore(database: database)
        let policy = BatchPolicySnapshot(kind: .trial, batchSizeLimit: 50, trialCreditCount: 5, concurrencyLimit: 1)

        do {
            _ = try await store.createBatch(
                CreateBatchInput(batchID: BatchID(rawValue: UUID()), policy: policy)
            )
            Issue.record("重複するExportIDチャンクがあるのにcreateBatchが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .corruptUsageLedgerBlob(let byteCount) = error else {
                Issue.record("期待したエラーケース(corruptUsageLedgerBlob)ではない: \(error)")
                return
            }
            #expect(byteCount == 32)
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }
    }
}
