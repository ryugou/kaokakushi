import Foundation
import Testing
import Domain
@testable import Persistence

// OutputDeliveryStoreLive.requireSettledのテスト（Issue #32 C-1。export-saga.md 7章
// 「利用者への受け渡し」不変条件が正本）。共有（外部提示）の開始前に呼ぶ検査専用APIであり、
// completeShareが使うrequireSettled（private static。OutputDeliveryStoreLive+Attempt.swift）と
// 同じ判定を再利用する。状態は変更しないため、呼び出し前後でOutputRecord.stateが変わらない
// ことも併せて確認する。
//
// このパッケージはCryptoKit依存でLinuxコンテナ内ではビルドできないため、この変更はホスト・CI
// での検証に委ねる（Issue #32 spec）。

@Suite("OutputDeliveryStoreLive.requireSettled")
struct OutputDeliveryStoreRequireSettledTests {
    @Test("requireSettledはsettledAt != nilなら何もthrowせず状態を変更しないこと")
    func succeedsWithoutMutationWhenSettled() async throws {
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

        try await store.requireSettled(ExportID(rawValue: exportID))

        let fields = try outputRecordFields(database, exportID: exportID)
        #expect(fields?.state == Int(OutputState.generated.rawValue))
        #expect(try !deliveryAttemptExists(database, exportID: exportID))
    }

    @Test("requireSettledはOutputRecordのsettledAtがnilならnotSettledをthrowすること")
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
            try await store.requireSettled(ExportID(rawValue: exportID))
            Issue.record("settledAtがnilなのにrequireSettledが成功した")
        } catch let error as OutputDeliveryStoreError {
            #expect(error == .notSettled(exportID: ExportID(rawValue: exportID)))
        } catch {
            Issue.record("OutputDeliveryStoreError以外がthrowされた: \(error)")
        }
    }

    @Test("requireSettledは対象OutputRecordが存在しなければoutputRecordNotFoundをthrowすること")
    func throwsOutputRecordNotFoundWhenMissing() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeOutputDeliveryStore(database: database)
        let exportID = ExportID(rawValue: UUID())

        do {
            try await store.requireSettled(exportID)
            Issue.record("OutputRecordが存在しないのにrequireSettledが成功した")
        } catch let error as OutputDeliveryStoreError {
            #expect(error == .outputRecordNotFound(exportID: exportID))
        } catch {
            Issue.record("OutputDeliveryStoreError以外がthrowされた: \(error)")
        }
    }
}
