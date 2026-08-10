import Foundation
import Testing
import Domain
@testable import Application

// OutputDeliveryCoordinator の変更系操作（saveToPhotoLibrary / share / deleteOutput）が
// 起動時復旧ゲートを待つこと（Issue #7 Task 12）。
//
// 正本: architecture.md 4.3「起動時に1回のみ実行し、完了まで他のすべてを開始させない」。
// ゲート待機は SerialTaskQueue へ投入する前に行う（spec 警告1）。share は提示自体（結果が
// completed になるまで）はキューを保持しない（architecture.md 4.2）ため、ゲート待機も
// completeShare 呼び出しの直前（completed 確定後）に置く。OutputDeliveryCoordinatorTests.swift
// と同じ偽実装だけを注入し、FakeRecoveryGate で復旧未完了を模す。

private func makeCoordinator(
    outputDeliveryStore: FakeOutputDeliveryStore,
    mediaSaver: FakeMediaSaver = FakeMediaSaver(),
    sharePresenter: FakeSharePresenter,
    recoveryGate: RecoveryGate = FakeRecoveryGate()
) -> OutputDeliveryCoordinator {
    OutputDeliveryCoordinator(
        outputDeliveryStore: outputDeliveryStore,
        mediaSaver: mediaSaver,
        sharePresenter: sharePresenter,
        queue: SerialTaskQueue(),
        recoveryGate: recoveryGate
    )
}

@Test("復旧未完了の間はsaveToPhotoLibraryがstoreへ進まず、完了後に保存できる", .timeLimit(.minutes(1)))
private func saveToPhotoLibraryWaitsForRecoveryGateThenProceeds() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let mediaSaver = FakeMediaSaver()
    let sharePresenter = await FakeSharePresenter()
    let gate = FakeRecoveryGate(isOpen: false)
    let coordinator = makeCoordinator(
        outputDeliveryStore: outputDeliveryStore, mediaSaver: mediaSaver, sharePresenter: sharePresenter,
        recoveryGate: gate
    )

    let task = Task { try await coordinator.saveToPhotoLibrary(output) }
    for _ in 0..<5 { await Task.yield() }
    #expect(await outputDeliveryStore.beginDeliveryAttemptCalls.isEmpty)
    #expect(await mediaSaver.calls.isEmpty)

    await gate.open()
    try await task.value

    #expect(await outputDeliveryStore.outputSnapshot(for: exportID)?.state == .delivered)
}

@Test("復旧未完了の間はcompleteShareへ進まず、完了後に共有を確定できる", .timeLimit(.minutes(1)))
private func shareWaitsForRecoveryGateThenProceeds() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let sharePresenter = await FakeSharePresenter()
    await MainActor.run { sharePresenter.result = .completed }
    let gate = FakeRecoveryGate(isOpen: false)
    let coordinator = makeCoordinator(
        outputDeliveryStore: outputDeliveryStore, sharePresenter: sharePresenter, recoveryGate: gate
    )

    let task = Task { try await coordinator.share(output) }
    for _ in 0..<5 { await Task.yield() }
    // 提示自体（SharePresenter.share）はゲートを待たずに進む（architecture.md 4.2）ため、
    // completeShareだけが未達であることを確認する。
    #expect(await outputDeliveryStore.completeShareCalls.isEmpty)

    await gate.open()
    let result = try await task.value

    #expect(result == .completed)
    #expect(await outputDeliveryStore.outputSnapshot(for: exportID)?.state == .delivered)
}

@Test("復旧未完了の間はdeleteOutputがstoreへ進まず、完了後に破棄できる", .timeLimit(.minutes(1)))
private func deleteOutputWaitsForRecoveryGateThenProceeds() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .delivered)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let sharePresenter = await FakeSharePresenter()
    let gate = FakeRecoveryGate(isOpen: false)
    let coordinator = makeCoordinator(
        outputDeliveryStore: outputDeliveryStore, sharePresenter: sharePresenter, recoveryGate: gate
    )

    let task = Task { try await coordinator.deleteOutput(exportID) }
    for _ in 0..<5 { await Task.yield() }
    #expect(await outputDeliveryStore.deleteOutputCalls.isEmpty)

    await gate.open()
    try await task.value

    #expect(await outputDeliveryStore.deleteOutputCalls == [exportID])
}
