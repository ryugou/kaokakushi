import Foundation
import Testing
import Domain
@testable import Persistence

// OutputDeliveryStoreLive.abandonDeliveryAttemptのテスト（export-saga.md 7章「利用者への
// 受け渡し」7.0表「previousStateへ戻す（現在がdeliveredなら維持）」が正本）。

@Suite("OutputDeliveryStoreLive.abandonDeliveryAttempt")
struct OutputDeliveryStoreAbandonTests {
    @Test("abandonDeliveryAttemptはpreviousState=generatedのときstateをgeneratedへ戻すこと")
    func restoresGeneratedPreviousState() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()
        let exportID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID)
            try insertDeliveryOutputRecord(
                connection, exportID: exportID, projectID: projectID,
                state: Int(OutputState.deliveryUnknown.rawValue), settledAt: schemaTestReferenceDate
            )
            try insertDeliveryAttemptRow(
                connection, exportID: exportID, startedAt: schemaTestReferenceDate,
                previousState: Int(OutputState.generated.rawValue)
            )
        }
        let store = makeOutputDeliveryStore(database: database)

        try await store.abandonDeliveryAttempt(ExportID(rawValue: exportID))

        let fields = try outputRecordFields(database, exportID: exportID)
        #expect(fields?.state == Int(OutputState.generated.rawValue))
        #expect(try !deliveryAttemptExists(database, exportID: exportID))
    }

    @Test("abandonDeliveryAttemptはpreviousState=deliveryUnknownのときstateをdeliveryUnknownへ戻すこと")
    func restoresDeliveryUnknownPreviousState() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()
        let exportID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID)
            try insertDeliveryOutputRecord(
                connection, exportID: exportID, projectID: projectID,
                state: Int(OutputState.deliveryUnknown.rawValue), settledAt: schemaTestReferenceDate
            )
            try insertDeliveryAttemptRow(
                connection, exportID: exportID, startedAt: schemaTestReferenceDate,
                previousState: Int(OutputState.deliveryUnknown.rawValue)
            )
        }
        let store = makeOutputDeliveryStore(database: database)

        try await store.abandonDeliveryAttempt(ExportID(rawValue: exportID))

        let fields = try outputRecordFields(database, exportID: exportID)
        #expect(fields?.state == Int(OutputState.deliveryUnknown.rawValue))
        #expect(try !deliveryAttemptExists(database, exportID: exportID))
    }

    @Test("abandonDeliveryAttemptは現在deliveredなら後退させずdeliveredを維持すること")
    func keepsDeliveredStateWhenAlreadyDelivered() async throws {
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
            try insertDeliveryAttemptRow(
                connection, exportID: exportID, startedAt: schemaTestReferenceDate,
                previousState: Int(OutputState.generated.rawValue)
            )
        }
        let store = makeOutputDeliveryStore(database: database)

        try await store.abandonDeliveryAttempt(ExportID(rawValue: exportID))

        let fields = try outputRecordFields(database, exportID: exportID)
        #expect(fields?.state == Int(OutputState.delivered.rawValue))
        #expect(try !deliveryAttemptExists(database, exportID: exportID))
    }

    @Test("abandonDeliveryAttemptは対応するattemptが無ければdeliveryAttemptNotFoundをthrowすること")
    func throwsNotFoundWhenAttemptMissing() async throws {
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

        do {
            try await store.abandonDeliveryAttempt(ExportID(rawValue: exportID))
            Issue.record("対応するattemptが無いのにabandonDeliveryAttemptが成功した")
        } catch let error as OutputDeliveryStoreError {
            #expect(error == .deliveryAttemptNotFound(exportID: ExportID(rawValue: exportID)))
        } catch {
            Issue.record("OutputDeliveryStoreError以外がthrowされた: \(error)")
        }
    }
}
