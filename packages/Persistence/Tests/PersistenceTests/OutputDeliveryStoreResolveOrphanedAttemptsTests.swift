import Foundation
import Testing
import Domain
@testable import Persistence

// OutputDeliveryStoreLive.resolveOrphanedAttemptsのテスト（export-saga.md 7.0
// 「起動時に DeliveryAttempt が残っていれば…」の解決表、および「resolveOrphanedAttemptsで
// deliveredを維持したときupsertする」が正本）。

/// resolveOrphanedAttemptsのテストが対象にする3つのexportID
/// （previousState=generated/deliveryUnknown/deliveredをそれぞれ1件ずつ用意する）。
private struct OrphanedAttemptFixture {
    let generatedExportID: UUID
    let deliveryUnknownExportID: UUID
    let deliveredExportID: UUID
}

/// previousStateが異なる3件のDeliveryAttempt（および対応するOutputRecord）を用意する。
/// OutputRecord.stateは各previousStateに対応する現実的な値（該当するattemptが始まった
/// 時点でOutputRecordが取り得る値）に揃える。
private func seedOrphanedAttempts(_ database: AppDatabase, projectID: UUID) async throws -> OrphanedAttemptFixture {
    let generatedExportID = UUID()
    let deliveryUnknownExportID = UUID()
    let deliveredExportID = UUID()
    try await database.dbQueue.write { connection in
        try insertProject(connection, projectID: projectID)

        try insertDeliveryOutputRecord(
            connection, exportID: generatedExportID, projectID: projectID,
            state: Int(OutputState.generated.rawValue), settledAt: schemaTestReferenceDate
        )
        try insertDeliveryAttemptRow(
            connection, exportID: generatedExportID, startedAt: schemaTestReferenceDate,
            previousState: Int(OutputState.generated.rawValue)
        )

        try insertDeliveryOutputRecord(
            connection, exportID: deliveryUnknownExportID, projectID: projectID,
            state: Int(OutputState.deliveryUnknown.rawValue), settledAt: schemaTestReferenceDate
        )
        try insertDeliveryAttemptRow(
            connection, exportID: deliveryUnknownExportID, startedAt: schemaTestReferenceDate,
            previousState: Int(OutputState.deliveryUnknown.rawValue)
        )

        try insertDeliveryOutputRecord(
            connection, exportID: deliveredExportID, projectID: projectID,
            state: Int(OutputState.delivered.rawValue), settledAt: schemaTestReferenceDate
        )
        try insertDeliveryAttemptRow(
            connection, exportID: deliveredExportID, startedAt: schemaTestReferenceDate,
            previousState: Int(OutputState.delivered.rawValue)
        )
    }
    return OrphanedAttemptFixture(
        generatedExportID: generatedExportID,
        deliveryUnknownExportID: deliveryUnknownExportID,
        deliveredExportID: deliveredExportID
    )
}

@Suite("OutputDeliveryStoreLive.resolveOrphanedAttempts")
struct OutputDeliveryStoreResolveOrphanedAttemptsTests {
    @Test("previousState=generatedのattemptをdeliveryUnknownへ解決すること")
    func resolvesGeneratedPreviousStateToDeliveryUnknown() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try await seedOrphanedAttempts(database, projectID: UUID())
        let store = makeOutputDeliveryStore(database: database)

        _ = try await store.resolveOrphanedAttempts()

        let fields = try outputRecordFields(database, exportID: fixture.generatedExportID)
        #expect(fields?.state == Int(OutputState.deliveryUnknown.rawValue))
    }

    @Test("previousState=deliveryUnknownのattemptはOutputRecord.stateをそのままにすること")
    func resolvesDeliveryUnknownPreviousStateUnchanged() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try await seedOrphanedAttempts(database, projectID: UUID())
        let store = makeOutputDeliveryStore(database: database)

        _ = try await store.resolveOrphanedAttempts()

        let fields = try outputRecordFields(database, exportID: fixture.deliveryUnknownExportID)
        #expect(fields?.state == Int(OutputState.deliveryUnknown.rawValue))
    }

    @Test("previousState=deliveredのattemptはdeliveredを維持しUnknownLibrarySaveをupsertすること")
    func resolvesDeliveredPreviousStateUpsertsUnknownLibrarySave() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try await seedOrphanedAttempts(database, projectID: UUID())
        let store = makeOutputDeliveryStore(database: database)

        _ = try await store.resolveOrphanedAttempts()

        let fields = try outputRecordFields(database, exportID: fixture.deliveredExportID)
        #expect(fields?.state == Int(OutputState.delivered.rawValue))
        #expect(try unknownLibrarySaveExists(database, exportID: fixture.deliveredExportID))
    }

    @Test("resolveOrphanedAttempts実行後、全DeliveryAttempt行が削除されていること")
    func deletesAllDeliveryAttemptRowsAfterResolution() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try await seedOrphanedAttempts(database, projectID: UUID())
        let store = makeOutputDeliveryStore(database: database)

        _ = try await store.resolveOrphanedAttempts()

        #expect(try !deliveryAttemptExists(database, exportID: fixture.generatedExportID))
        #expect(try !deliveryAttemptExists(database, exportID: fixture.deliveryUnknownExportID))
        #expect(try !deliveryAttemptExists(database, exportID: fixture.deliveredExportID))
    }

    @Test("戻り値のOutputDeliverySnapshotに全OutputRecordが含まれhasUnknownLibrarySaveが正しいこと")
    func returnsSnapshotsWithCorrectHasUnknownLibrarySave() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try await seedOrphanedAttempts(database, projectID: UUID())
        let store = makeOutputDeliveryStore(database: database)

        let snapshots = try await store.resolveOrphanedAttempts()

        let byExportID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.output.exportID.rawValue, $0) })
        #expect(byExportID.count == 3)
        #expect(byExportID[fixture.generatedExportID]?.hasUnknownLibrarySave == false)
        #expect(byExportID[fixture.deliveryUnknownExportID]?.hasUnknownLibrarySave == false)
        #expect(byExportID[fixture.deliveredExportID]?.hasUnknownLibrarySave == true)
    }
}
