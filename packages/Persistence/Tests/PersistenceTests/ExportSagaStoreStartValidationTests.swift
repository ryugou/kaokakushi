import Foundation
import Testing
import Domain
@testable import Persistence

// ExportSagaStoreLive.startExportの入力検証・データ整合性検査のテスト
// （export-saga.md 0章 discardExport付近のPendingFileDeletion契約とは無関係。
// ExportSagaStoreStartTests.swiftから分離: 400行制限のため、勘定モードの解決結果を
// 検証するテスト〈ExportSagaStoreStartTests.swift〉と、入力検証・DB破損検知を検証する
// テスト〈このファイル〉に分割する）。
//
// 1.1（確認の一致）・1.2（能力）の検査と月間枠チェック（monthlyLimitReached）は
// Persistenceのスコープ外（オーケストレーター確定判断）のため、ここでは検証しない。
// previewConfirmation.projectIDとinput.projectIDの整合検査だけは差し戻し対応7番で
// store側のゲートとして追加されたため、ここで検証する。

@Suite("ExportSagaStoreLive.startExport(検証・データ整合性)")
struct ExportSagaStoreStartValidationTests {
    @Test("previewConfirmation.projectIDがinput.projectIDと異なる場合previewConfirmationProjectMismatchでthrowすること")
    func throwsWhenPreviewConfirmationProjectIDMismatches() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let otherProjectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertSubscriptionStateRow(connection, plan: 1, status: 1)
        }
        let store = makeExportSagaStore(database: database)
        let mismatchedInput = try makeStartExportInputFixture(
            projectID: projectID, previewConfirmationProjectID: otherProjectID
        )

        do {
            _ = try await store.startExport(mismatchedInput, expectedProjectRevision: 0)
            Issue.record("previewConfirmation.projectID不一致なのにstartExportが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .previewConfirmationProjectMismatch(let subjectProjectID, let previewProjectID) = error else {
                Issue.record("期待したエラーケース(previewConfirmationProjectMismatch)ではない: \(error)")
                return
            }
            #expect(subjectProjectID == projectID)
            #expect(previewProjectID == otherProjectID)
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }
    }

    @Test("SubscriptionStateが2件以上ある場合multipleSingletonRowsでthrowすること")
    func throwsWhenSubscriptionStateHasMultipleRows() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertSubscriptionStateRow(connection, plan: 1, status: 1)
            try insertSubscriptionStateRow(connection, plan: 2, status: 1)
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
            try insertUsageLedgerRow(connection, trialConsumedCount: 2)
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

    @Test("UsageLedgerのBLOB長が16の倍数でない場合corruptUsageLedgerBlobでthrowすること")
    func throwsWhenUsageLedgerBlobLengthIsNotAMultipleOf16() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let batchID = BatchID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertSubscriptionStateRow(connection, plan: 1, status: 1)
            try insertBatchRow(connection, batchID: batchID.rawValue, kind: 2, trialCreditCount: 5)
            try connection.execute(
                sql: """
                INSERT INTO UsageLedger (periodYear, periodMonth, consumedExportIDs, trialConsumedExportIDs)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [2023, 11, Data(), Data(repeating: 0, count: 17)]
            )
        }
        let store = makeExportSagaStore(database: database)

        do {
            _ = try await store.startExport(
                try makeStartExportInputFixture(projectID: projectID, batchID: batchID), expectedProjectRevision: 0
            )
            Issue.record("BLOB長が16の倍数でないのにstartExportが成功した")
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
        let projectID = ProjectID(rawValue: UUID())
        let batchID = BatchID(rawValue: UUID())
        let duplicatedChunk = Data(repeating: 0xAA, count: 16)
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertSubscriptionStateRow(connection, plan: 1, status: 1)
            try insertBatchRow(connection, batchID: batchID.rawValue, kind: 2, trialCreditCount: 5)
            try connection.execute(
                sql: """
                INSERT INTO UsageLedger (periodYear, periodMonth, consumedExportIDs, trialConsumedExportIDs)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [2023, 11, Data(), duplicatedChunk + duplicatedChunk]
            )
        }
        let store = makeExportSagaStore(database: database)

        do {
            _ = try await store.startExport(
                try makeStartExportInputFixture(projectID: projectID, batchID: batchID), expectedProjectRevision: 0
            )
            Issue.record("重複するExportIDチャンクがあるのにstartExportが成功した")
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

    @Test("expectedProjectRevisionが実際のprojectRevisionと不一致ならprojectRevisionMismatchでthrowすること")
    func throwsWhenProjectRevisionMismatches() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertSubscriptionStateRow(connection, plan: 1, status: 1)
        }
        let store = makeExportSagaStore(database: database)

        do {
            _ = try await store.startExport(
                try makeStartExportInputFixture(projectID: projectID), expectedProjectRevision: 999
            )
            Issue.record("projectRevision不一致なのにstartExportが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .projectRevisionMismatch(let mismatchedProjectID, let expected, let actual) = error else {
                Issue.record("期待したエラーケース(projectRevisionMismatch)ではない: \(error)")
                return
            }
            #expect(mismatchedProjectID == projectID)
            #expect(expected == 999)
            #expect(actual == 0)
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }
    }

    @Test("queueItemIDが指定されbatchIDがnilの場合queueItemIDRequiresBatchIDでthrowすること")
    func throwsWhenQueueItemIDPresentWithoutBatchID() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let queueItemID = ExportQueueItemID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertSubscriptionStateRow(connection, plan: 1, status: 1)
        }
        let store = makeExportSagaStore(database: database)
        let input = try makeStartExportInputFixture(projectID: projectID, batchID: nil, queueItemID: queueItemID)

        do {
            _ = try await store.startExport(input, expectedProjectRevision: 0)
            Issue.record("queueItemIDが指定されbatchIDがnilなのにstartExportが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .queueItemIDRequiresBatchID(let mismatchedQueueItemID) = error else {
                Issue.record("期待したエラーケース(queueItemIDRequiresBatchID)ではない: \(error)")
                return
            }
            #expect(mismatchedQueueItemID == queueItemID)
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }
    }
}
