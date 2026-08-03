import Foundation
import Testing
import Domain
@testable import Persistence

// OutputDeliveryStoreLive.loadUnknownLibrarySaves/clearUnknownLibrarySaveのテスト
// （export-saga.md 7.0「写真ライブラリ保存の結果不明」が正本）。resolveOrphanedAttemptsが
// UnknownLibrarySaveをupsertする側はOutputDeliveryResolveOrphansTestsでカバー済みのため、
// ここではload/clear単体の素直なCRUDのみを検証する。

@Suite("OutputDeliveryStoreLive.loadUnknownLibrarySaves/clearUnknownLibrarySave")
struct OutputDeliveryStoreLibrarySaveTests {
    @Test("loadUnknownLibrarySavesは全件を返すこと")
    func loadsAllRows() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()
        let firstExportID = UUID()
        let secondExportID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID)
            try insertDeliveryOutputRecord(
                connection, exportID: firstExportID, projectID: projectID,
                state: Int(OutputState.delivered.rawValue), settledAt: schemaTestReferenceDate
            )
            try insertDeliveryOutputRecord(
                connection, exportID: secondExportID, projectID: projectID,
                state: Int(OutputState.delivered.rawValue), settledAt: schemaTestReferenceDate
            )
            try insertUnknownLibrarySaveRow(connection, exportID: firstExportID, occurredAt: schemaTestReferenceDate)
            try insertUnknownLibrarySaveRow(connection, exportID: secondExportID, occurredAt: schemaTestReferenceDate)
        }
        let store = makeOutputDeliveryStore(database: database)

        let saves = try await store.loadUnknownLibrarySaves()

        let exportIDs = Set(saves.map { $0.exportID.rawValue })
        #expect(exportIDs == [firstExportID, secondExportID])
    }

    @Test("clearUnknownLibrarySaveは対象行だけを削除し他は残すこと")
    func clearsOnlyTargetRow() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()
        let keepExportID = UUID()
        let removeExportID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID)
            try insertDeliveryOutputRecord(
                connection, exportID: keepExportID, projectID: projectID,
                state: Int(OutputState.delivered.rawValue), settledAt: schemaTestReferenceDate
            )
            try insertDeliveryOutputRecord(
                connection, exportID: removeExportID, projectID: projectID,
                state: Int(OutputState.delivered.rawValue), settledAt: schemaTestReferenceDate
            )
            try insertUnknownLibrarySaveRow(connection, exportID: keepExportID, occurredAt: schemaTestReferenceDate)
            try insertUnknownLibrarySaveRow(connection, exportID: removeExportID, occurredAt: schemaTestReferenceDate)
        }
        let store = makeOutputDeliveryStore(database: database)

        try await store.clearUnknownLibrarySave(ExportID(rawValue: removeExportID))

        #expect(try unknownLibrarySaveExists(database, exportID: keepExportID))
        #expect(try !unknownLibrarySaveExists(database, exportID: removeExportID))
    }

    @Test("clearUnknownLibrarySaveは対象行が無くてもthrowしないこと（冪等）")
    func clearIsIdempotentWhenRowMissing() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeOutputDeliveryStore(database: database)

        try await store.clearUnknownLibrarySave(ExportID(rawValue: UUID()))
    }
}
