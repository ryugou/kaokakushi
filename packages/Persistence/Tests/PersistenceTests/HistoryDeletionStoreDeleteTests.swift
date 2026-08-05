import Foundation
import Testing
import Domain
import GRDB
@testable import Persistence

// HistoryDeletionStoreLive.deleteHistoryUnitのテスト（architecture.md「Project削除Saga」・
// 「削除の可否判定」・「出力の削除経路」が正本）。

@Suite("HistoryDeletionStoreLive.deleteHistoryUnit")
struct HistoryDeletionStoreDeleteTests {
    @Test("許可される削除でProjectと関連8テーブルが全てCASCADEで消え、残存ファイルがPendingFileDeletionへ登録されること")
    func deletesProjectAndCascadesAllDependents() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let batchID = UUID()
        let outputExportID = UUID()
        let sourceFileID = UUID()
        let assetHash = schemaTestHash(seed: 0x30)
        try await seedProjectWithCascadingDependents(
            database, projectID: projectID.rawValue, batchID: batchID,
            sourceFileID: sourceFileID, assetHash: assetHash
        )
        try await database.dbQueue.write { connection in
            // 注記付きdeliveredのように、hasUndeliveredOutputRecordがfalseでも残存しうる行の
            // 代表としてdelivered状態のOutputRecordを1件用意する（正本コメント参照）。
            try insertDeliveryOutputRecord(
                connection, exportID: outputExportID, projectID: projectID.rawValue,
                state: Int(OutputState.delivered.rawValue), settledAt: schemaTestReferenceDate
            )
        }
        let outputFields = try outputRecordFields(database, exportID: outputExportID)
        let outputFileID = try #require(outputFields?.outputFileID)
        let store = makeHistoryDeletionStore(database: database)

        try await store.deleteHistoryUnit(
            .project(projectID),
            trigger: .userInitiated(confirmedOverrides: [.workingSource])
        )

        #expect(try !projectRowExists(database, projectID: projectID.rawValue))
        let counts = try cascadeRowCounts(database, projectID: projectID.rawValue)
        #expect(counts.faceTrack == 0)
        #expect(counts.effectSetting == 0)
        #expect(counts.exportSetting == 0)
        #expect(counts.workingSourceRecord == 0)
        #expect(counts.exportQueueItem == 0)
        #expect(counts.exportRecord == 0)
        #expect(counts.exportedSettingsEntry == 0)
        #expect(counts.projectStampAsset == 0)
        #expect(try outputRecordRowCount(database, exportID: outputExportID) == 0)
        #expect(
            try pendingFileDeletionExists(
                database, kind: ManagedFileKind.processingTemporary.rawValue, fileID: sourceFileID
            )
        )
        #expect(try pendingFileDeletionExists(database, kind: ManagedFileKind.output.rawValue, fileID: outputFileID))
    }

    @Test("未受け渡しのOutputRecordがあるとblockedByAbsoluteProtectionをthrowしProjectが消えないこと")
    func rejectsWhenUndeliveredOutputRecordExists() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertOutputRecord(
                connection, exportID: UUID(), projectID: projectID.rawValue, batchID: nil,
                settledAt: schemaTestReferenceDate
            )
        }
        let store = makeHistoryDeletionStore(database: database)

        do {
            try await store.deleteHistoryUnit(
            .project(projectID),
            trigger: .userInitiated(confirmedOverrides: [.workingSource])
        )
            Issue.record("未受け渡しのOutputRecordがあるのにdeleteHistoryUnitが成功した")
        } catch let error as HistoryDeletionStoreError {
            #expect(error == .blockedByAbsoluteProtection(unit: .project(projectID), reasons: [.undeliveredOutput]))
        } catch {
            Issue.record("HistoryDeletionStoreError以外がthrowされた: \(error)")
        }
        #expect(try projectRowExists(database, projectID: projectID.rawValue))
    }

    @Test("進行中のExportJobがあるとblockedByAbsoluteProtectionをthrowしProjectが消えないこと")
    func rejectsWhenExportJobIsRunning() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertExportJob(connection, exportID: UUID(), projectID: projectID.rawValue, batchID: nil)
        }
        let store = makeHistoryDeletionStore(database: database)

        do {
            try await store.deleteHistoryUnit(
            .project(projectID),
            trigger: .userInitiated(confirmedOverrides: [.workingSource])
        )
            Issue.record("進行中のExportJobがあるのにdeleteHistoryUnitが成功した")
        } catch let error as HistoryDeletionStoreError {
            #expect(error == .blockedByAbsoluteProtection(unit: .project(projectID), reasons: [.exportJobRunning]))
        } catch {
            Issue.record("HistoryDeletionStoreError以外がthrowされた: \(error)")
        }
        #expect(try projectRowExists(database, projectID: projectID.rawValue))
    }

    @Test("非終端のExportQueueItemがあるとblockedByAbsoluteProtectionをthrowしProjectが消えないこと")
    func rejectsWhenNonTerminalQueueItemExists() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let batchID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertBatch(connection, batchID: batchID)
            try insertExportQueueItemWithState(
                connection, queueItemID: UUID(), projectID: projectID.rawValue, batchID: batchID,
                state: ExportQueueStateColumn.exporting.rawValue
            )
        }
        let store = makeHistoryDeletionStore(database: database)

        do {
            try await store.deleteHistoryUnit(.project(projectID), trigger: .userInitiated(confirmedOverrides: []))
            Issue.record("非終端のExportQueueItemがあるのにdeleteHistoryUnitが成功した")
        } catch let error as HistoryDeletionStoreError {
            #expect(
                error == .blockedByAbsoluteProtection(unit: .project(projectID), reasons: [.nonTerminalQueueItem])
            )
        } catch {
            Issue.record("HistoryDeletionStoreError以外がthrowされた: \(error)")
        }
        #expect(try projectRowExists(database, projectID: projectID.rawValue))
    }

    @Test("試行中のDeliveryAttemptがあるとblockedByAbsoluteProtectionをthrowしProjectが消えないこと")
    func rejectsWhenDeliveryAttemptInProgressExists() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let outputExportID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            // delivered状態にしhasUndeliveredOutputRecordを発火させない
            // （このテストの関心はhasDeliveryAttemptInProgressのみに絞る）。
            try insertDeliveryOutputRecord(
                connection, exportID: outputExportID, projectID: projectID.rawValue,
                state: Int(OutputState.delivered.rawValue), settledAt: schemaTestReferenceDate
            )
            try insertDeliveryAttemptRow(
                connection, exportID: outputExportID, startedAt: schemaTestReferenceDate,
                previousState: Int(OutputState.generated.rawValue)
            )
        }
        let store = makeHistoryDeletionStore(database: database)

        do {
            try await store.deleteHistoryUnit(
            .project(projectID),
            trigger: .userInitiated(confirmedOverrides: [.workingSource])
        )
            Issue.record("試行中のDeliveryAttemptがあるのにdeleteHistoryUnitが成功した")
        } catch let error as HistoryDeletionStoreError {
            #expect(
                error
                    == .blockedByAbsoluteProtection(unit: .project(projectID), reasons: [.deliveryAttemptInProgress])
            )
        } catch {
            Issue.record("HistoryDeletionStoreError以外がthrowされた: \(error)")
        }
        #expect(try projectRowExists(database, projectID: projectID.rawValue))
    }
}
