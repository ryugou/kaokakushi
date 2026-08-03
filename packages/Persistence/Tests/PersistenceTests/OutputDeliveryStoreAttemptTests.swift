import Foundation
import Testing
import Domain
@testable import Persistence

// OutputDeliveryStoreLive.beginDeliveryAttempt/completeLibrarySaveのテスト
// （export-saga.md 7章「利用者への受け渡し」・7.0「写真ライブラリ保存の結果不明」が正本）。

@Suite("OutputDeliveryStoreLive.beginDeliveryAttempt/completeLibrarySave")
struct OutputDeliveryStoreAttemptTests {
    @Test("beginDeliveryAttempt後completeLibrarySaveでstateがdeliveredになりattempt行が削除されること")
    func beginThenCompleteLibrarySaveTransitionsToDeliveredAndRemovesAttempt() async throws {
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

        try await store.beginDeliveryAttempt(ExportID(rawValue: exportID))
        try await store.completeLibrarySave(ExportID(rawValue: exportID))

        let fields = try outputRecordFields(database, exportID: exportID)
        #expect(fields?.state == Int(OutputState.delivered.rawValue))
        #expect(try !deliveryAttemptExists(database, exportID: exportID))
    }

    @Test("beginDeliveryAttemptはOutputRecordのsettledAtがnilならnotSettledをthrowすること")
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
            try await store.beginDeliveryAttempt(ExportID(rawValue: exportID))
            Issue.record("settledAtがnilなのにbeginDeliveryAttemptが成功した")
        } catch let error as OutputDeliveryStoreError {
            #expect(error == .notSettled(exportID: ExportID(rawValue: exportID)))
        } catch {
            Issue.record("OutputDeliveryStoreError以外がthrowされた: \(error)")
        }
    }

    @Test("beginDeliveryAttemptは対象OutputRecordが存在しなければoutputRecordNotFoundをthrowすること")
    func throwsOutputRecordNotFoundWhenMissing() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeOutputDeliveryStore(database: database)
        let exportID = ExportID(rawValue: UUID())

        do {
            try await store.beginDeliveryAttempt(exportID)
            Issue.record("OutputRecordが存在しないのにbeginDeliveryAttemptが成功した")
        } catch let error as OutputDeliveryStoreError {
            #expect(error == .outputRecordNotFound(exportID: exportID))
        } catch {
            Issue.record("OutputDeliveryStoreError以外がthrowされた: \(error)")
        }
    }

    @Test("beginDeliveryAttemptは既存attemptがあればdeliveryAttemptAlreadyInProgressをthrowすること")
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
            try await store.beginDeliveryAttempt(ExportID(rawValue: exportID))
            Issue.record("既存attemptがあるのにbeginDeliveryAttemptが成功した")
        } catch let error as OutputDeliveryStoreError {
            #expect(error == .deliveryAttemptAlreadyInProgress(exportID: ExportID(rawValue: exportID)))
        } catch {
            Issue.record("OutputDeliveryStoreError以外がthrowされた: \(error)")
        }
    }

    @Test("beginDeliveryAttemptはOutputRecord.stateをそのままDeliveryAttempt.previousStateへ書き込むこと")
    func writesCurrentStateAsPreviousState() async throws {
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
        }
        let store = makeOutputDeliveryStore(database: database)

        try await store.beginDeliveryAttempt(ExportID(rawValue: exportID))

        let previousState = try deliveryAttemptPreviousState(database, exportID: exportID)
        #expect(previousState == Int(OutputState.deliveryUnknown.rawValue))
    }

    @Test("completeLibrarySaveは対応するattemptが無ければdeliveryAttemptNotFoundをthrowすること")
    func completeLibrarySaveThrowsNotFoundWhenAttemptMissing() async throws {
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
            try await store.completeLibrarySave(ExportID(rawValue: exportID))
            Issue.record("対応するattemptが無いのにcompleteLibrarySaveが成功した")
        } catch let error as OutputDeliveryStoreError {
            #expect(error == .deliveryAttemptNotFound(exportID: ExportID(rawValue: exportID)))
        } catch {
            Issue.record("OutputDeliveryStoreError以外がthrowされた: \(error)")
        }
    }
}
