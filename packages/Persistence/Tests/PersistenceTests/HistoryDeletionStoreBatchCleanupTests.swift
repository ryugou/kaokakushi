import Foundation
import Testing
import Domain
import GRDB
@testable import Persistence

// HistoryDeletionStoreLive.deleteHistoryUnitによるBatch自動削除のテスト（architecture.md
// 「`Project` 削除 Saga」節の手順3・直後の解説が正本。Batch行の削除は利用者操作の対象では
// なくProject削除の副次的な後始末）。判定基準は「その`batchID`を参照する`ExportRecord`/
// `OutputRecord`/`ExportJob`の残数が合計0」（手順3。旧`ExportQueueItem`ベースの判定は
// Issue #40でDomainから削除されたため、このファイルは全面的に書き直した）。

@Suite("HistoryDeletionStoreLive.deleteHistoryUnit Batch自動削除")
struct HistoryDeletionStoreBatchCleanupTests {
    @Test("削除対象ProjectのExportRecordが参照するbatchIDを他のExportRecord/OutputRecord/ExportJobが1件も参照しなければBatch行が消えること")
    func deletesBatchWhenNoOtherRowsReferenceBatchID() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let batchID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertBatch(connection, batchID: batchID)
            try insertExportRecord(connection, exportID: UUID(), projectID: projectID.rawValue, batchID: batchID)
        }
        let store = makeHistoryDeletionStore(database: database)

        try await store.deleteHistoryUnit(.project(projectID), trigger: .storagePressure)

        #expect(try !batchRowExists(database, batchID: batchID))
    }

    @Test("同じbatchIDを参照するExportRecordが他のProjectに残る場合はBatch行が消えないこと")
    func keepsBatchWhenOtherProjectExportRecordRemains() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let deletedProjectID = ProjectID(rawValue: UUID())
        let remainingProjectID = ProjectID(rawValue: UUID())
        let batchID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: deletedProjectID.rawValue)
            try insertProject(connection, projectID: remainingProjectID.rawValue)
            try insertBatch(connection, batchID: batchID)
            try insertExportRecord(
                connection, exportID: UUID(), projectID: deletedProjectID.rawValue, batchID: batchID
            )
            try insertExportRecord(
                connection, exportID: UUID(), projectID: remainingProjectID.rawValue, batchID: batchID
            )
        }
        let store = makeHistoryDeletionStore(database: database)

        try await store.deleteHistoryUnit(.project(deletedProjectID), trigger: .storagePressure)

        #expect(try batchRowExists(database, batchID: batchID))
    }

    @Test("同じバッチの他のProjectがまだ未settle（ExportJobがbatchIDを参照中）の場合、settle済みProjectを削除してもBatch行が消えないこと")
    func keepsBatchWhenAnotherProjectHasUnsettledRowsReferencingBatchID() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let settledProjectID = ProjectID(rawValue: UUID())
        let unsettledProjectID = ProjectID(rawValue: UUID())
        let batchID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: settledProjectID.rawValue)
            try insertProject(connection, projectID: unsettledProjectID.rawValue)
            try insertBatch(connection, batchID: batchID)
            // settledProjectIDはExportRecordのみを持つ（settle済み・絶対保護に抵触しない）。
            try insertExportRecord(
                connection, exportID: UUID(), projectID: settledProjectID.rawValue, batchID: batchID
            )
            // unsettledProjectIDは進行中のExportJob（未settle）を持つ。これはunsettledProjectID
            // 自身への絶対保護であり、settledProjectIDの削除可否には影響しない（絶対保護は
            // projectIDスコープ。architecture.md「Project削除Saga」直後の解説）。
            try insertExportJob(
                connection, exportID: UUID(), projectID: unsettledProjectID.rawValue, batchID: batchID
            )
        }
        let store = makeHistoryDeletionStore(database: database)

        try await store.deleteHistoryUnit(.project(settledProjectID), trigger: .storagePressure)

        #expect(try !projectRowExists(database, projectID: settledProjectID.rawValue))
        #expect(try batchRowExists(database, batchID: batchID))
    }

    @Test("同じバッチの他のProjectがまだ未settle（OutputRecordがbatchIDを参照中）の場合、settle済みProjectを削除してもBatch行が消えないこと")
    func keepsBatchWhenAnotherProjectHasUnsettledOutputRecordReferencingBatchID() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let settledProjectID = ProjectID(rawValue: UUID())
        let unsettledProjectID = ProjectID(rawValue: UUID())
        let batchID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: settledProjectID.rawValue)
            try insertProject(connection, projectID: unsettledProjectID.rawValue)
            try insertBatch(connection, batchID: batchID)
            // settledProjectIDはExportRecordのみを持つ（settle済み・絶対保護に抵触しない）。
            try insertExportRecord(
                connection, exportID: UUID(), projectID: settledProjectID.rawValue, batchID: batchID
            )
            // unsettledProjectIDは未確定（settledAt: nil）のOutputRecordを持つ。これは
            // unsettledProjectID自身への絶対保護であり、settledProjectIDの削除可否には
            // 影響しない（絶対保護はprojectIDスコープ。architecture.md「Project削除Saga」
            // 直後の解説）。
            try insertOutputRecord(
                connection, exportID: UUID(), projectID: unsettledProjectID.rawValue, batchID: batchID,
                settledAt: nil
            )
        }
        let store = makeHistoryDeletionStore(database: database)

        try await store.deleteHistoryUnit(.project(settledProjectID), trigger: .storagePressure)

        #expect(try !projectRowExists(database, projectID: settledProjectID.rawValue))
        #expect(try batchRowExists(database, batchID: batchID))
    }

    @Test("ExportRecordを一度も持たないProjectを削除してもBatch行の自動削除は発生しないこと")
    func doesNotTouchUnrelatedBatchWhenDeletingProjectWithoutExportRecord() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let unrelatedBatchID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertBatch(connection, batchID: unrelatedBatchID)
        }
        let store = makeHistoryDeletionStore(database: database)

        try await store.deleteHistoryUnit(.project(projectID), trigger: .storagePressure)

        #expect(try !projectRowExists(database, projectID: projectID.rawValue))
        #expect(try batchRowExists(database, batchID: unrelatedBatchID))
    }
}
