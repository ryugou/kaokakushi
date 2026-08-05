import Foundation
import Testing
import Domain
import GRDB
@testable import Persistence

// OutputDeliveryStoreLive.deleteOutputのテスト（export-saga.md 7章「利用者への受け渡し」の
// 不変条件段落・7.0表「deleteOutputの行」、architecture.md「出力の削除経路」（7.5）が正本）。

@Suite("OutputDeliveryStoreLive.deleteOutput")
struct OutputDeliveryStoreDeleteTests {
    @Test("deleteOutputは対象exportIDが存在しなければ何もせず正常終了すること（冪等）")
    func idempotentWhenOutputRecordMissing() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeOutputDeliveryStore(database: database)

        try await store.deleteOutput(ExportID(rawValue: UUID()))
    }

    @Test("deleteOutputはOutputRecordを削除しoutputFileIDをPendingFileDeletionへ登録すること")
    func deletesOutputRecordAndRegistersPendingFileDeletion() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()
        let exportID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID)
            try insertDeliveryOutputRecord(
                connection, exportID: exportID, projectID: projectID,
                state: Int(OutputState.delivered.rawValue), settledAt: schemaTestReferenceDate
            )
        }
        let fields = try outputRecordFields(database, exportID: exportID)
        let outputFileID = try #require(fields?.outputFileID)
        let store = makeOutputDeliveryStore(database: database)

        try await store.deleteOutput(ExportID(rawValue: exportID))

        #expect(try outputRecordRowCount(database, exportID: exportID) == 0)
        #expect(try pendingFileDeletionExists(database, kind: ManagedFileKind.output.rawValue, fileID: outputFileID))
    }

    @Test("deleteOutputはUnknownLibrarySave行をFK CASCADEで削除すること")
    func cascadesUnknownLibrarySave() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()
        let exportID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID)
            try insertDeliveryOutputRecord(
                connection, exportID: exportID, projectID: projectID,
                state: Int(OutputState.delivered.rawValue), settledAt: schemaTestReferenceDate
            )
            try insertUnknownLibrarySaveRow(connection, exportID: exportID, occurredAt: schemaTestReferenceDate)
        }
        let store = makeOutputDeliveryStore(database: database)

        try await store.deleteOutput(ExportID(rawValue: exportID))

        #expect(try !unknownLibrarySaveExists(database, exportID: exportID))
    }

    @Test("deleteOutputはsettledAtがnilならnotSettledをthrowすること")
    func throwsNotSettledWhenSettledAtIsNil() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()
        let exportID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID)
            try insertDeliveryOutputRecord(
                connection, exportID: exportID, projectID: projectID,
                state: Int(OutputState.generated.rawValue), settledAt: nil
            )
        }
        let store = makeOutputDeliveryStore(database: database)

        do {
            try await store.deleteOutput(ExportID(rawValue: exportID))
            Issue.record("settledAtがnilなのにdeleteOutputが成功した")
        } catch let error as OutputDeliveryStoreError {
            #expect(error == .notSettled(exportID: ExportID(rawValue: exportID)))
        } catch {
            Issue.record("OutputDeliveryStoreError以外がthrowされた: \(error)")
        }
    }

    @Test("deleteOutputはDeliveryAttemptが存在すればdeliveryAttemptAlreadyInProgressをthrowすること")
    func throwsAlreadyInProgressWhenAttemptExists() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()
        let exportID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID)
            try insertDeliveryOutputRecord(
                connection, exportID: exportID, projectID: projectID,
                state: Int(OutputState.generated.rawValue), settledAt: schemaTestReferenceDate
            )
            try insertDeliveryAttemptRow(
                connection, exportID: exportID, startedAt: schemaTestReferenceDate,
                previousState: Int(OutputState.generated.rawValue)
            )
        }
        let store = makeOutputDeliveryStore(database: database)

        do {
            try await store.deleteOutput(ExportID(rawValue: exportID))
            Issue.record("DeliveryAttemptが存在するのにdeleteOutputが成功した")
        } catch let error as OutputDeliveryStoreError {
            #expect(error == .deliveryAttemptAlreadyInProgress(exportID: ExportID(rawValue: exportID)))
        } catch {
            Issue.record("OutputDeliveryStoreError以外がthrowされた: \(error)")
        }
    }

    @Test("OutputRecordを直接削除するとDeliveryAttemptがFK CASCADEで削除されること（スキーマ検証）")
    func schemaCascadesDeliveryAttemptOnOutputRecordDeletion() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()
        let exportID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID)
            try insertDeliveryOutputRecord(
                connection, exportID: exportID, projectID: projectID,
                state: Int(OutputState.generated.rawValue), settledAt: schemaTestReferenceDate
            )
            try insertDeliveryAttemptRow(
                connection, exportID: exportID, startedAt: schemaTestReferenceDate,
                previousState: Int(OutputState.generated.rawValue)
            )
            // deleteOutput経由ではDeliveryAttempt存在時に拒否されるため検証できない。
            // FK CASCADE自体はスキーマの責務のため生SQLで直接検証する。
            try connection.execute(sql: "DELETE FROM OutputRecord WHERE exportID = ?", arguments: [exportID])
        }

        #expect(try !deliveryAttemptExists(database, exportID: exportID))
    }
}
