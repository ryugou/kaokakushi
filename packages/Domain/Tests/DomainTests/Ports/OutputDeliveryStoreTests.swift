import Testing
@testable import Domain
import Foundation

/// Task 4: 受け渡しの永続化ポート（export-saga.md 7 章・7.0、architecture.md
/// 「未受け渡し出力の状態」）。
///
/// `DeliveryAttempt` / `UnknownLibrarySave` のフィールド保持、`OutputDeliverySnapshot.
/// requiresDeliveryAttention`（isUndelivered とは別の軸で hasUnknownLibrarySave も見る）、
/// `OutputDeliveryStore` への最小準拠を検証する。

private func makeOutputRecord(state: OutputState) -> OutputRecord {
    OutputRecord(
        exportID: ExportID(rawValue: UUID()),
        projectID: ProjectID(rawValue: UUID()),
        batchID: nil,
        outputFile: makeOutputFileRef(),
        outputByteSize: 1024,
        outputSHA256: Data(repeating: 0x11, count: 32),
        state: state,
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        settledAt: Date(timeIntervalSince1970: 1_700_000_100),
        expiresAt: Date(timeIntervalSince1970: 1_700_086_500),
        format: .heic,
        suggestedCreationDate: nil
    )
}

// MARK: - DeliveryAttempt / UnknownLibrarySave のフィールド保持

@Test("DeliveryAttemptが全フィールドを保持する")
func deliveryAttemptHoldsAllFields() {
    let exportID = ExportID(rawValue: UUID())
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let subject = DeliveryAttempt(exportID: exportID, startedAt: startedAt, previousState: .generated)
    #expect(subject.exportID == exportID)
    #expect(subject.startedAt == startedAt)
    #expect(subject.previousState == .generated)
}

@Test("UnknownLibrarySaveが全フィールドを保持する")
func unknownLibrarySaveHoldsAllFields() {
    let exportID = ExportID(rawValue: UUID())
    let occurredAt = Date(timeIntervalSince1970: 1_700_000_050)
    let subject = UnknownLibrarySave(exportID: exportID, occurredAt: occurredAt)
    #expect(subject.exportID == exportID)
    #expect(subject.occurredAt == occurredAt)
}

// MARK: - OutputDeliverySnapshot.requiresDeliveryAttention（isUndelivered とは別の軸）

@Test(
    "requiresDeliveryAttentionはisUndeliveredかhasUnknownLibrarySaveのいずれかでtrue",
    arguments: [
        (OutputState.generated, false, true),
        (OutputState.deliveryUnknown, false, true),
        (OutputState.delivered, false, false),
        (OutputState.delivered, true, true)
    ]
)
func requiresDeliveryAttentionCombinesBothAxes(state: OutputState, hasUnknownLibrarySave: Bool, expected: Bool) {
    let subject = OutputDeliverySnapshot(
        output: makeOutputRecord(state: state),
        hasUnknownLibrarySave: hasUnknownLibrarySave
    )
    #expect(subject.requiresDeliveryAttention == expected)
}

// MARK: - OutputDeliveryStore への最小準拠

private actor FakeOutputDeliveryStore: OutputDeliveryStore {
    private(set) var beginDeliveryAttemptCalls: [ExportID] = []
    private(set) var completeLibrarySaveCalls: [ExportID] = []
    private(set) var requireSettledCalls: [ExportID] = []
    private(set) var completeShareCalls: [ExportID] = []
    private(set) var abandonDeliveryAttemptCalls: [ExportID] = []
    private(set) var resolveOrphanedAttemptsCallCount = 0
    private(set) var loadUnknownLibrarySavesCallCount = 0
    private(set) var clearUnknownLibrarySaveCalls: [ExportID] = []
    private(set) var deleteOutputCalls: [ExportID] = []

    var resolveOrphanedAttemptsResult: [OutputDeliverySnapshot] = []
    var loadUnknownLibrarySavesResult: [UnknownLibrarySave] = []

    func beginDeliveryAttempt(_ exportID: ExportID) async throws {
        beginDeliveryAttemptCalls.append(exportID)
    }

    func completeLibrarySave(_ exportID: ExportID) async throws {
        completeLibrarySaveCalls.append(exportID)
    }

    func requireSettled(_ exportID: ExportID) async throws {
        requireSettledCalls.append(exportID)
    }

    func completeShare(_ exportID: ExportID) async throws {
        completeShareCalls.append(exportID)
    }

    func abandonDeliveryAttempt(_ exportID: ExportID) async throws {
        abandonDeliveryAttemptCalls.append(exportID)
    }

    func resolveOrphanedAttempts() async throws -> [OutputDeliverySnapshot] {
        resolveOrphanedAttemptsCallCount += 1
        return resolveOrphanedAttemptsResult
    }

    func loadUnknownLibrarySaves() async throws -> [UnknownLibrarySave] {
        loadUnknownLibrarySavesCallCount += 1
        return loadUnknownLibrarySavesResult
    }

    func clearUnknownLibrarySave(_ exportID: ExportID) async throws {
        clearUnknownLibrarySaveCalls.append(exportID)
    }

    func deleteOutput(_ exportID: ExportID) async throws {
        deleteOutputCalls.append(exportID)
    }
}

@Test("OutputDeliveryStoreへの最小準拠が全メソッドの引数を渡された値どおりに記録する")
func fakeOutputDeliveryStoreForwardsArguments() async throws {
    let store = FakeOutputDeliveryStore()

    let beginID = ExportID(rawValue: UUID())
    try await store.beginDeliveryAttempt(beginID)

    let librarySaveID = ExportID(rawValue: UUID())
    try await store.completeLibrarySave(librarySaveID)

    let requireSettledID = ExportID(rawValue: UUID())
    try await store.requireSettled(requireSettledID)

    let shareID = ExportID(rawValue: UUID())
    try await store.completeShare(shareID)

    let abandonID = ExportID(rawValue: UUID())
    try await store.abandonDeliveryAttempt(abandonID)

    _ = try await store.resolveOrphanedAttempts()
    _ = try await store.loadUnknownLibrarySaves()

    let clearID = ExportID(rawValue: UUID())
    try await store.clearUnknownLibrarySave(clearID)

    let deleteID = ExportID(rawValue: UUID())
    try await store.deleteOutput(deleteID)

    #expect(await store.beginDeliveryAttemptCalls == [beginID])
    #expect(await store.completeLibrarySaveCalls == [librarySaveID])
    #expect(await store.completeShareCalls == [shareID])
    #expect(await store.abandonDeliveryAttemptCalls == [abandonID])
    #expect(await store.resolveOrphanedAttemptsCallCount == 1)
    #expect(await store.loadUnknownLibrarySavesCallCount == 1)
    #expect(await store.clearUnknownLibrarySaveCalls == [clearID])
    #expect(await store.deleteOutputCalls == [deleteID])
}
