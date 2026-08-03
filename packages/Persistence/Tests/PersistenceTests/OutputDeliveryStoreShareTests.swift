import Foundation
import Testing
import Domain
@testable import Persistence

// OutputDeliveryStoreLive.completeShareのテスト（export-saga.md 7章「利用者への受け渡し」・
// 7.0末尾「共有には DeliveryAttempt を作らない」が正本）。

@Suite("OutputDeliveryStoreLive.completeShare")
struct OutputDeliveryStoreShareTests {
    @Test("completeShareはsettledAt != nilのgenerated出力をDeliveryAttemptを経由せずdeliveredにすること")
    func transitionsGeneratedToDeliveredWithoutDeliveryAttempt() async throws {
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
        }
        let store = makeOutputDeliveryStore(database: database)

        try await store.completeShare(ExportID(rawValue: exportID))

        let fields = try outputRecordFields(database, exportID: exportID)
        #expect(fields?.state == Int(OutputState.delivered.rawValue))
        #expect(try !deliveryAttemptExists(database, exportID: exportID))
    }

    @Test("completeShareはOutputRecordのsettledAtがnilならnotSettledをthrowすること")
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
            try await store.completeShare(ExportID(rawValue: exportID))
            Issue.record("settledAtがnilなのにcompleteShareが成功した")
        } catch let error as OutputDeliveryStoreError {
            #expect(error == .notSettled(exportID: ExportID(rawValue: exportID)))
        } catch {
            Issue.record("OutputDeliveryStoreError以外がthrowされた: \(error)")
        }
    }

    @Test("completeShareは対象OutputRecordが存在しなければoutputRecordNotFoundをthrowすること")
    func throwsOutputRecordNotFoundWhenMissing() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeOutputDeliveryStore(database: database)
        let exportID = ExportID(rawValue: UUID())

        do {
            try await store.completeShare(exportID)
            Issue.record("OutputRecordが存在しないのにcompleteShareが成功した")
        } catch let error as OutputDeliveryStoreError {
            #expect(error == .outputRecordNotFound(exportID: exportID))
        } catch {
            Issue.record("OutputDeliveryStoreError以外がthrowされた: \(error)")
        }
    }
}
