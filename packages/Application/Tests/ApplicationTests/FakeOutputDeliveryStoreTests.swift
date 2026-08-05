import Foundation
import Testing
import Domain

// FakeOutputDeliveryStore.resolveOrphanedAttempts の挙動が正本（export-saga.md 7.0 表）と
// 一致することを検証する。実 Persistence の対応実装は
// Persistence/Sources/Persistence/OutputDeliveryStoreLive+Recovery.swift の3分岐が正本。
//
// Task 3 レビュー Critical 1 の再発防止テスト: 修正前は abandonDeliveryAttempt と同じ
// restorePreviousState を共有していたため、previousState == .generated でも状態を
// generated へ戻すだけで deliveryUnknown へ更新されず、previousState == .delivered でも
// UnknownLibrarySave が作られなかった（このテストは修正前のコードでは失敗する）。

@Suite("FakeOutputDeliveryStore.resolveOrphanedAttempts")
struct ResolveOrphanedAttemptsTests {
    @Test("previousStateがgeneratedならOutputRecordをdeliveryUnknownへ更新する")
    func updatesToDeliveryUnknownWhenPreviousStateWasGenerated() async throws {
        let exportID = makeExportID()
        let resolvedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let store = FakeOutputDeliveryStore(now: { resolvedAt })
        await store.seedOutput(makeOutputRecord(exportID: exportID, state: .generated))
        try await store.beginDeliveryAttempt(exportID)

        let snapshots = try await store.resolveOrphanedAttempts()
        let snapshot = snapshots.first { $0.output.exportID == exportID }

        #expect(snapshot?.output.state == .deliveryUnknown)
        #expect(snapshot?.hasUnknownLibrarySave == false)
        #expect(await store.hasActiveAttempt(for: exportID) == false)
    }

    @Test("previousStateがdeliveredなら状態を維持しUnknownLibrarySaveをupsertする")
    func preservesDeliveredAndRecordsUnknownLibrarySave() async throws {
        let exportID = makeExportID()
        let resolvedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let store = FakeOutputDeliveryStore(now: { resolvedAt })
        await store.seedOutput(makeOutputRecord(exportID: exportID, state: .delivered))
        try await store.beginDeliveryAttempt(exportID)

        let snapshots = try await store.resolveOrphanedAttempts()
        let snapshot = snapshots.first { $0.output.exportID == exportID }

        #expect(snapshot?.output.state == .delivered)
        #expect(snapshot?.hasUnknownLibrarySave == true)
        let saves = try await store.loadUnknownLibrarySaves()
        #expect(saves.first { $0.exportID == exportID }?.occurredAt == resolvedAt)
        #expect(await store.hasActiveAttempt(for: exportID) == false)
    }

    @Test("previousStateがdeliveryUnknownなら状態を維持しUnknownLibrarySaveは作らない")
    func keepsDeliveryUnknownWithoutRecordingUnknownLibrarySave() async throws {
        let exportID = makeExportID()
        let resolvedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let store = FakeOutputDeliveryStore(now: { resolvedAt })
        await store.seedOutput(makeOutputRecord(exportID: exportID, state: .deliveryUnknown))
        try await store.beginDeliveryAttempt(exportID)

        let snapshots = try await store.resolveOrphanedAttempts()
        let snapshot = snapshots.first { $0.output.exportID == exportID }

        #expect(snapshot?.output.state == .deliveryUnknown)
        #expect(snapshot?.hasUnknownLibrarySave == false)
        #expect(await store.hasActiveAttempt(for: exportID) == false)
    }
}
