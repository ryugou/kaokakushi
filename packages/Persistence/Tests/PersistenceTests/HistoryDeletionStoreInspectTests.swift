import Foundation
import Testing
import Domain
import GRDB
@testable import Persistence

// HistoryDeletionStoreLive.inspectDeletionのテスト（HistoryStores.swiftの正本docコメント
// 「確認画面の表示用」・architecture.md「削除の可否判定」の3絶対保護・3上書き可能保護が
// 正本）。inspectDeletionはtriggerに関わらず値をそのまま報告するだけのため、全テストで
// trigger = .storagePressureを使う（判定分岐の検証はdeleteHistoryUnit側のテストで行う）。

@Suite("HistoryDeletionStoreLive.inspectDeletion")
struct HistoryDeletionStoreInspectTests {
    @Test("非終端のExportQueueItemがあるとblockedByAbsoluteProtectionにnonTerminalQueueItemが入ること")
    func reportsNonTerminalQueueItem() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let batchID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertBatch(connection, batchID: batchID)
            try insertExportQueueItemWithState(
                connection, queueItemID: UUID(), projectID: projectID.rawValue, batchID: batchID,
                state: ExportQueueStateColumn.waiting.rawValue
            )
        }
        let store = makeHistoryDeletionStore(database: database)

        let inspection = try await store.inspectDeletion(.project(projectID), trigger: .storagePressure)

        #expect(inspection.blockedByAbsoluteProtection == [.nonTerminalQueueItem])
    }

    @Test("進行中のExportJobがあるとblockedByAbsoluteProtectionにexportJobRunningが入ること")
    func reportsRunningExportJob() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertExportJob(connection, exportID: UUID(), projectID: projectID.rawValue, batchID: nil)
        }
        let store = makeHistoryDeletionStore(database: database)

        let inspection = try await store.inspectDeletion(.project(projectID), trigger: .storagePressure)

        #expect(inspection.blockedByAbsoluteProtection == [.exportJobRunning])
    }

    @Test("未受け渡しのOutputRecordがあるとblockedByAbsoluteProtectionにundeliveredOutputが入ること")
    func reportsUndeliveredOutput() async throws {
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

        let inspection = try await store.inspectDeletion(.project(projectID), trigger: .storagePressure)

        #expect(inspection.blockedByAbsoluteProtection == [.undeliveredOutput])
    }

    @Test("WorkingSourceRecordがあるとoverridableProtectionsにworkingSourceが入ること")
    func reportsWorkingSourceOverridableProtection() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertWorkingSourceRecord(connection, projectID: projectID.rawValue, sourceFileID: UUID())
        }
        let store = makeHistoryDeletionStore(database: database)

        let inspection = try await store.inspectDeletion(.project(projectID), trigger: .storagePressure)

        #expect(inspection.overridableProtections == [.workingSource])
        #expect(inspection.blockedByAbsoluteProtection.isEmpty)
    }

    @Test("何も参照が無ければ絶対保護・上書き可能保護のどちらも空であること")
    func reportsNoProtectionsWhenNothingReferencesProject() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
        }
        let store = makeHistoryDeletionStore(database: database)

        let inspection = try await store.inspectDeletion(.project(projectID), trigger: .storagePressure)

        #expect(inspection.blockedByAbsoluteProtection.isEmpty)
        #expect(inspection.overridableProtections.isEmpty)
        #expect(inspection.reclaimableBytes == 0)
    }

    @Test("OutputRecordのoutputByteSizeのみがreclaimableBytesへ反映されExportRecordは含まれないこと")
    func reclaimableBytesSumsOnlyOutputRecordSizes() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            // ExportRecord は DB 行であり実体ファイルではないため見積りに含めない
            // （含めると settle 後24時間は同一ファイルの二重計上になる。一次レビュー指摘）。
            // insertExportRecordはoutputByteSize = 1_024固定（SchemaTestSupport.swift）。
            try insertExportRecord(connection, exportID: UUID(), projectID: projectID.rawValue, batchID: nil)
            // insertDeliveryOutputRecordはoutputByteSize = 2_048固定（OutputDeliveryStoreTestSupport.swift）。
            try insertDeliveryOutputRecord(
                connection, exportID: UUID(), projectID: projectID.rawValue,
                state: Int(OutputState.delivered.rawValue), settledAt: schemaTestReferenceDate
            )
        }
        let store = makeHistoryDeletionStore(database: database)

        let inspection = try await store.inspectDeletion(.project(projectID), trigger: .storagePressure)

        #expect(inspection.reclaimableBytes == 2_048)
    }
}
