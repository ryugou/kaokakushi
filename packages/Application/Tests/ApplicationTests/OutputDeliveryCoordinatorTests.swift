import Foundation
import Testing
import Domain
@testable import Application

// OutputDeliveryCoordinator（Issue #7 Task 8「利用者への受け渡し」）。
//
// 正本: export-saga.md 7章「利用者への受け渡し」・7.0「写真ライブラリ保存の結果不明」、
// test-plan.md 3.2「完了」の受け渡し項目・3.6「出力の寿命と履歴」の受け渡し状態項目。
//
// 偽ストア（FakeOutputDeliveryStore）・偽 MediaSaver・偽 SharePresenter だけを注入し、
// 保存の DeliveryAttempt ライフサイクル・共有の ShareResult 写像・破棄の委譲と、
// いずれも store の throw を握りつぶさず伝播することを検証する。

private struct SaveBoom: Error, Equatable {}
private struct StoreBoom: Error, Equatable {}

private func makeCoordinator(
    outputDeliveryStore: FakeOutputDeliveryStore,
    mediaSaver: FakeMediaSaver = FakeMediaSaver(),
    sharePresenter: FakeSharePresenter
) -> OutputDeliveryCoordinator {
    OutputDeliveryCoordinator(
        outputDeliveryStore: outputDeliveryStore,
        mediaSaver: mediaSaver,
        sharePresenter: sharePresenter,
        queue: SerialTaskQueue(),
        recoveryGate: FakeRecoveryGate()
    )
}

// MARK: - 保存（写真ライブラリ）

@Test("保存に成功するとbegin・save・completeLibrarySaveの順で呼ばれ状態がdeliveredになる")
private func saveSucceedsAndTransitionsToDelivered() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let mediaSaver = FakeMediaSaver()
    let sharePresenter = await FakeSharePresenter()
    let coordinator = makeCoordinator(
        outputDeliveryStore: outputDeliveryStore, mediaSaver: mediaSaver, sharePresenter: sharePresenter
    )

    try await coordinator.saveToPhotoLibrary(output)

    #expect(await outputDeliveryStore.beginDeliveryAttemptCalls == [exportID])
    #expect(await mediaSaver.calls.map(\.exportID) == [exportID])
    #expect(await outputDeliveryStore.completeLibrarySaveCalls == [exportID])
    #expect(await outputDeliveryStore.abandonDeliveryAttemptCalls.isEmpty)
    #expect(await outputDeliveryStore.outputSnapshot(for: exportID)?.state == .delivered)
}

@Test("保存に失敗するとabandonDeliveryAttemptでprevious Stateへ戻りMediaSaverのエラーが伝播する")
private func saveFailurePropagatesAndRestoresPreviousState() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let mediaSaver = FakeMediaSaver()
    await mediaSaver.setFailure(SaveBoom())
    let sharePresenter = await FakeSharePresenter()
    let coordinator = makeCoordinator(
        outputDeliveryStore: outputDeliveryStore, mediaSaver: mediaSaver, sharePresenter: sharePresenter
    )

    await #expect(throws: SaveBoom.self) {
        try await coordinator.saveToPhotoLibrary(output)
    }

    #expect(await outputDeliveryStore.abandonDeliveryAttemptCalls == [exportID])
    #expect(await outputDeliveryStore.completeLibrarySaveCalls.isEmpty)
    #expect(await outputDeliveryStore.outputSnapshot(for: exportID)?.state == .generated)
}

@Test("保存は失敗後も追加消費なく再試行でき、再試行が成功すること")
private func saveIsRetryableAfterFailure() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let mediaSaver = FakeMediaSaver()
    await mediaSaver.setFailure(SaveBoom())
    let sharePresenter = await FakeSharePresenter()
    let coordinator = makeCoordinator(
        outputDeliveryStore: outputDeliveryStore, mediaSaver: mediaSaver, sharePresenter: sharePresenter
    )
    await #expect(throws: SaveBoom.self) {
        try await coordinator.saveToPhotoLibrary(output)
    }

    await mediaSaver.setFailure(nil)
    try await coordinator.saveToPhotoLibrary(output)

    #expect(await outputDeliveryStore.outputSnapshot(for: exportID)?.state == .delivered)
    #expect(await mediaSaver.calls.count == 2)
}

@Test("settledAtがnilの出力への保存はストアの事前条件throwが伝播しMediaSaverは呼ばれない")
private func saveToUnsettledOutputPropagatesStoreRejection() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated, settledAt: nil)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let mediaSaver = FakeMediaSaver()
    let sharePresenter = await FakeSharePresenter()
    let coordinator = makeCoordinator(
        outputDeliveryStore: outputDeliveryStore, mediaSaver: mediaSaver, sharePresenter: sharePresenter
    )

    await #expect(throws: FakeOutputDeliveryStoreError.outputNotSettled(exportID)) {
        try await coordinator.saveToPhotoLibrary(output)
    }

    #expect(await mediaSaver.calls.isEmpty)
}

@Test("deliveredな出力への保存が失敗してもdeliveredのまま後退しない")
private func saveFailureOnDeliveredOutputDoesNotRegress() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .delivered)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let mediaSaver = FakeMediaSaver()
    await mediaSaver.setFailure(SaveBoom())
    let sharePresenter = await FakeSharePresenter()
    let coordinator = makeCoordinator(
        outputDeliveryStore: outputDeliveryStore, mediaSaver: mediaSaver, sharePresenter: sharePresenter
    )

    await #expect(throws: SaveBoom.self) {
        try await coordinator.saveToPhotoLibrary(output)
    }

    #expect(await outputDeliveryStore.outputSnapshot(for: exportID)?.state == .delivered)
}

@Test("beginDeliveryAttemptのthrowはMediaSaverを呼ばずそのまま伝播する")
private func beginFailurePropagatesWithoutCallingMediaSaver() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    await outputDeliveryStore.setBeginDeliveryAttemptFailure(StoreBoom())
    let mediaSaver = FakeMediaSaver()
    let sharePresenter = await FakeSharePresenter()
    let coordinator = makeCoordinator(
        outputDeliveryStore: outputDeliveryStore, mediaSaver: mediaSaver, sharePresenter: sharePresenter
    )

    await #expect(throws: StoreBoom.self) {
        try await coordinator.saveToPhotoLibrary(output)
    }

    #expect(await mediaSaver.calls.isEmpty)
}

@Test("completeLibrarySaveのthrowはabandonを呼ばずそのまま伝播する")
private func completeLibrarySaveFailurePropagatesWithoutAbandon() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    await outputDeliveryStore.setCompleteLibrarySaveFailure(StoreBoom())
    let mediaSaver = FakeMediaSaver()
    let sharePresenter = await FakeSharePresenter()
    let coordinator = makeCoordinator(
        outputDeliveryStore: outputDeliveryStore, mediaSaver: mediaSaver, sharePresenter: sharePresenter
    )

    await #expect(throws: StoreBoom.self) {
        try await coordinator.saveToPhotoLibrary(output)
    }

    #expect(await mediaSaver.calls.map(\.exportID) == [exportID])
    #expect(await outputDeliveryStore.abandonDeliveryAttemptCalls.isEmpty)
}

@Test("保存に失敗しabandonDeliveryAttemptも失敗すると、保存失敗の真因がCleanupPreservingError.causeとして伝播する")
private func saveFailureSurvivesAbandonFailure() async throws {
    struct AbandonBoom: Error, Equatable {}
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    await outputDeliveryStore.setAbandonDeliveryAttemptFailure(AbandonBoom())
    let mediaSaver = FakeMediaSaver()
    await mediaSaver.setFailure(SaveBoom())
    let sharePresenter = await FakeSharePresenter()
    let coordinator = makeCoordinator(
        outputDeliveryStore: outputDeliveryStore, mediaSaver: mediaSaver, sharePresenter: sharePresenter
    )

    do {
        try await coordinator.saveToPhotoLibrary(output)
        Issue.record("エラーが送出されるはず")
    } catch let error as CleanupPreservingError {
        #expect(error.cause is SaveBoom)
        #expect(error.cleanupFailure is AbandonBoom)
    } catch {
        Issue.record("CleanupPreservingErrorが期待されたが\(error)が送出された")
    }

    #expect(await outputDeliveryStore.completeLibrarySaveCalls.isEmpty)
}

@Test(
    "保存中に呼び出し元がキャンセルされてもabandonDeliveryAttemptはシールドされ完走しDeliveryAttemptが残らない",
    .timeLimit(.minutes(1))
)
private func saveCancellationDuringMediaSaverStillAbandonsAttemptAndPropagatesSaveFailure() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    await outputDeliveryStore.setAbandonDeliveryAttemptChecksCancellation(true)
    let mediaSaver = FakeMediaSaver()
    await mediaSaver.setFailure(SaveBoom())
    // saveToPhotoLibrary呼び出し中（gate.wait()で中断している間）に外側のTaskをキャンセルしてから
    // ゲートを開ける。gate.wait()はキャンセルの影響を受けないため、cancel()が必ず先に届く
    // （Task.sleepの固定時間待ちに依存しない決定的な手法。Issue #7 レビュー第2ラウンド S-1）。
    let gate = OneShotGate()
    await mediaSaver.setGate(gate)
    let sharePresenter = await FakeSharePresenter()
    let coordinator = makeCoordinator(
        outputDeliveryStore: outputDeliveryStore, mediaSaver: mediaSaver, sharePresenter: sharePresenter
    )

    let saveTask = Task<Void, Error> {
        try await coordinator.saveToPhotoLibrary(output)
    }
    while await mediaSaver.calls.isEmpty {
        await Task.yield()
    }
    saveTask.cancel()
    await gate.open()

    await #expect(throws: SaveBoom.self) {
        try await saveTask.value
    }

    #expect(await outputDeliveryStore.abandonDeliveryAttemptCalls == [exportID])
    #expect(await outputDeliveryStore.hasActiveAttempt(for: exportID) == false)
    #expect(await outputDeliveryStore.outputSnapshot(for: exportID)?.state == .generated)
}

@Test(
    "保存成功直後に呼び出し元がキャンセルされてもcompleteLibrarySaveはシールドされ完走しdeliveredへ遷移する",
    .timeLimit(.minutes(1))
)
private func saveCancellationAfterMediaSaverSuccessStillCompletesLibrarySave() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    await outputDeliveryStore.setCompleteLibrarySaveChecksCancellation(true)
    let mediaSaver = FakeMediaSaver()
    // failureは注入しない: MediaSaver.saveToPhotoLibrary自体は成功させ、gate.open()直後の
    // completeLibrarySaveがキャンセル済み文脈でも完走することを検証する（Issue #7 レビュー
    // 第2ラウンド W-1）。
    let gate = OneShotGate()
    await mediaSaver.setGate(gate)
    let sharePresenter = await FakeSharePresenter()
    let coordinator = makeCoordinator(
        outputDeliveryStore: outputDeliveryStore, mediaSaver: mediaSaver, sharePresenter: sharePresenter
    )

    let saveTask = Task<Void, Error> {
        try await coordinator.saveToPhotoLibrary(output)
    }
    while await mediaSaver.calls.isEmpty {
        await Task.yield()
    }
    saveTask.cancel()
    await gate.open()

    try await saveTask.value

    #expect(await outputDeliveryStore.completeLibrarySaveCalls == [exportID])
    #expect(await outputDeliveryStore.hasActiveAttempt(for: exportID) == false)
    #expect(await outputDeliveryStore.outputSnapshot(for: exportID)?.state == .delivered)
}

// MARK: - 共有

@Test("共有がcompletedならcompleteShareを呼びdeliveredへ写像しattemptは作らない")
private func shareCompletedMapsToDeliveredWithoutAttempt() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let sharePresenter = await FakeSharePresenter()
    await MainActor.run { sharePresenter.result = .completed }
    let coordinator = makeCoordinator(outputDeliveryStore: outputDeliveryStore, sharePresenter: sharePresenter)

    let result = try await coordinator.share(output)

    #expect(result == .completed)
    #expect(await outputDeliveryStore.completeShareCalls == [exportID])
    #expect(await outputDeliveryStore.beginDeliveryAttemptCalls.isEmpty)
    #expect(await outputDeliveryStore.outputSnapshot(for: exportID)?.state == .delivered)
}

@Test(
    "共有がcanceled/failed/unknownならcompleteShareを呼ばず状態を維持する",
    arguments: [ShareResult.canceled, .failed, .unknown]
)
private func shareNonCompletedKeepsCurrentState(_ shareResult: ShareResult) async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let sharePresenter = await FakeSharePresenter()
    await MainActor.run { sharePresenter.result = shareResult }
    let coordinator = makeCoordinator(outputDeliveryStore: outputDeliveryStore, sharePresenter: sharePresenter)

    let result = try await coordinator.share(output)

    #expect(result == shareResult)
    #expect(await outputDeliveryStore.completeShareCalls.isEmpty)
    #expect(await outputDeliveryStore.outputSnapshot(for: exportID)?.state == .generated)
}

@Test("settledAtがnilの出力への共有完了はストアの事前条件throwが伝播する")
private func shareCompletedOnUnsettledOutputPropagatesStoreRejection() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated, settledAt: nil)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let sharePresenter = await FakeSharePresenter()
    await MainActor.run { sharePresenter.result = .completed }
    let coordinator = makeCoordinator(outputDeliveryStore: outputDeliveryStore, sharePresenter: sharePresenter)

    await #expect(throws: FakeOutputDeliveryStoreError.outputNotSettled(exportID)) {
        try await coordinator.share(output)
    }
}

@Test("completeShareのthrowが伝播する")
private func completeShareFailurePropagates() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    await outputDeliveryStore.setCompleteShareFailure(StoreBoom())
    let sharePresenter = await FakeSharePresenter()
    await MainActor.run { sharePresenter.result = .completed }
    let coordinator = makeCoordinator(outputDeliveryStore: outputDeliveryStore, sharePresenter: sharePresenter)

    await #expect(throws: StoreBoom.self) {
        try await coordinator.share(output)
    }
}

// MARK: - 破棄

@Test("deleteOutputはストアへ委譲する")
private func deleteOutputDelegatesToStore() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .delivered)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let sharePresenter = await FakeSharePresenter()
    let coordinator = makeCoordinator(outputDeliveryStore: outputDeliveryStore, sharePresenter: sharePresenter)

    try await coordinator.deleteOutput(exportID)

    #expect(await outputDeliveryStore.deleteOutputCalls == [exportID])
}

@Test("deleteOutputのthrow(事前条件違反を含む)はそのまま伝播する")
private func deleteOutputPropagatesStoreRejection() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .delivered)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    await outputDeliveryStore.setDeleteOutputFailure(StoreBoom())
    let sharePresenter = await FakeSharePresenter()
    let coordinator = makeCoordinator(outputDeliveryStore: outputDeliveryStore, sharePresenter: sharePresenter)

    await #expect(throws: StoreBoom.self) {
        try await coordinator.deleteOutput(exportID)
    }
}
