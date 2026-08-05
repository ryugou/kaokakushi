import Foundation
import Testing
import GRDB
import Domain
@testable import Persistence

// OutputDeliveryStoreの適合スイート（Issue #6 Task 7・test-plan.md 4.1が正本。
// 設計方針の詳細はConformanceSuites.swiftのファイル先頭コメントを参照）。
//
// OutputDeliveryStoreは書き込み専用ポートで、exportIDから現在の状態を直接読み戻す
// メソッドを持たない。そのためverifyAbandonDeliveryAttemptKeepsDeliveredStateだけは、
// 呼び出し側が用意した読み取りクロージャ（Domain公開型のOutputStateを返す）を介して
// 結果を確認する。クロージャの中身（GRDBでの読み取り）は呼び出し側テストファイルの
// 責務であり、検証関数の本体はクロージャを呼ぶだけでPersistence内部型に触れない。

// MARK: - OutputDeliveryStore: 検証関数

/// abandonDeliveryAttemptは「現在がdeliveredなら維持する」（OutputDeliveryStore.swift doc
/// コメント原文）ことを検証する。
func verifyAbandonDeliveryAttemptKeepsDeliveredState(
    _ store: some OutputDeliveryStore,
    exportID: ExportID,
    currentState: @Sendable () async throws -> OutputState
) async throws {
    try await store.abandonDeliveryAttempt(exportID)
    let state = try await currentState()
    #expect(state == .delivered, "abandonDeliveryAttemptはdeliveredを後退させてはならない")
}

/// beginDeliveryAttempt / completeShareの事前条件（`settledAt != nil`。
/// OutputDeliveryStore.swift doc コメント原文。nilならthrow）をプロトコル経由で確認する。
/// エラー型はLive/Fakeで異なりうるため、具体的なcase一致ではなく「何らかのエラーが
/// throwされること」だけを確認する（プロトコル契約が保証するのはthrowすることまで）。
func verifyDeliveryPreconditionsRejectUnsettledOutput(
    _ store: some OutputDeliveryStore,
    exportID: ExportID
) async throws {
    await #expect(throws: (any Error).self) {
        try await store.beginDeliveryAttempt(exportID)
    }
    await #expect(throws: (any Error).self) {
        try await store.completeShare(exportID)
    }
}

// MARK: - OutputDeliveryStore: Liveへの適用

@Suite("ConformanceSuites: OutputDeliveryStore (Live)")
struct OutputDeliveryStoreConformanceTests {
    @Test("abandonDeliveryAttemptはdeliveredな出力を後退させないこと")
    func abandonKeepsDeliveredStateThroughProtocol() async throws {
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

        try await verifyAbandonDeliveryAttemptKeepsDeliveredState(store, exportID: ExportID(rawValue: exportID)) {
            try Self.readOutputState(database, exportID: exportID)
        }
    }

    @Test("beginDeliveryAttempt/completeShareはsettledAtがnilならthrowすること")
    func rejectsUnsettledOutputThroughProtocol() async throws {
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

        try await verifyDeliveryPreconditionsRejectUnsettledOutput(store, exportID: ExportID(rawValue: exportID))
    }

    /// OutputRecord.stateをDomainのOutputStateへ変換して読む
    /// （verifyAbandonDeliveryAttemptKeepsDeliveredStateへ渡すクロージャの中身）。
    private static func readOutputState(_ database: AppDatabase, exportID: UUID) throws -> OutputState {
        guard let rawState = try outputRecordFields(database, exportID: exportID)?.state else {
            fatalError("test fixture invariant violated: OutputRecord row must exist after seeding")
        }
        guard let state = OutputState(rawValue: UInt32(rawState)) else {
            fatalError("test fixture invariant violated: unknown OutputState raw value \(rawState)")
        }
        return state
    }
}
