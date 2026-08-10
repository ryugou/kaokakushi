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

/// テスト専用の一回限りの非同期ゲート（SerialTaskQueueTests.swift と同じ方針の複製。
/// private 型のためファイル間で共有できず、ここへ複製する）。
private actor OneShotGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
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

// W（Task 12 再レビュー）: C-1 と同じ設計（外部opによる共有キュー占有→復旧開始→変更系操作の
// 投入→占有解放）を OutputDeliveryCoordinator 側にも置く。上のテスト群は Coordinator 専用の
// 新規 SerialTaskQueue を使っており、共有キュー上の順序（ゲート待ちが queue.run の中へ移る
// 改変が入っても検出できるか）を検証していない。経路をパラメタライズし1テストで
// saveToPhotoLibrary / share / deleteOutput の3経路を回す。

private enum DeliveryRoute: CaseIterable, Sendable {
    case saveToPhotoLibrary
    case share
    case deleteOutput
}

/// route ごとの OutputDeliveryCoordinator 呼び出し（Coordinator は actor のため Sendable）。
private func performDeliveryRoute(
    _ route: DeliveryRoute, _ coordinator: OutputDeliveryCoordinator, output: OutputRecord
) async throws {
    switch route {
    case .saveToPhotoLibrary:
        try await coordinator.saveToPhotoLibrary(output)
    case .share:
        _ = try await coordinator.share(output)
    case .deleteOutput:
        try await coordinator.deleteOutput(output.exportID)
    }
}

/// デッドロック検出テストに必要な非構造化 `Task` 一式（関数長を50行以内に収めるための分割）。
private struct DeliveryRouteDeadlockFixture: Sendable {
    let blocking: Task<Void, Error>
    let occupancyGate: OneShotGate
    let recovery: Task<StartupRecoveryReport, Error>
    let routeTask: Task<Void, Error>
}

/// 外部opによる共有キュー占有→復旧開始→route投入までを行い、占有解放前の状態まで
/// 整えたフィクスチャを返す。
private func setUpDeliveryRouteFixture(route: DeliveryRoute) async throws -> DeliveryRouteDeadlockFixture {
    let sharedQueue = SerialTaskQueue()
    let occupancyGate = OneShotGate()
    let (occupiedStream, occupiedContinuation) = AsyncStream<Void>.makeStream()
    var occupiedIterator = occupiedStream.makeAsyncIterator()

    let blocking = Task<Void, Error> {
        try await sharedQueue.run {
            occupiedContinuation.yield(())
            await occupancyGate.wait()
        }
    }
    _ = await occupiedIterator.next()

    let output = makeOutputRecord(exportID: makeExportID(), state: route == .deleteOutput ? .delivered : .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let sharePresenter = await FakeSharePresenter()
    if route == .share {
        await MainActor.run { sharePresenter.result = .completed }
    }
    let exportSagaStore = FakeExportSagaStore()
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let recoveryCoordinator = StartupRecoveryCoordinator(
        exportSagaStore: exportSagaStore,
        outputDeliveryStore: outputDeliveryStore,
        maintenanceStore: maintenanceStore,
        managedFileStore: managedFileStore,
        queue: sharedQueue
    )
    let deliveryCoordinator = OutputDeliveryCoordinator(
        outputDeliveryStore: outputDeliveryStore,
        mediaSaver: FakeMediaSaver(),
        sharePresenter: sharePresenter,
        queue: sharedQueue,
        recoveryGate: recoveryCoordinator
    )

    let recovery = Task { try await recoveryCoordinator.runStartupRecovery() }
    for _ in 0..<5 { await Task.yield() }
    #expect(await exportSagaStore.loadRunningJobsCallCount == 1)

    let routeTask = Task { try await performDeliveryRoute(route, deliveryCoordinator, output: output) }
    for _ in 0..<5 { await Task.yield() }
    #expect(await outputDeliveryStore.beginDeliveryAttemptCalls.isEmpty)
    #expect(await outputDeliveryStore.completeShareCalls.isEmpty)
    #expect(await outputDeliveryStore.deleteOutputCalls.isEmpty)

    return DeliveryRouteDeadlockFixture(
        blocking: blocking, occupancyGate: occupancyGate, recovery: recovery, routeTask: routeTask
    )
}

@Test(
    "共有キューを外部opが占有し復旧がキュー操作を残した状態で変更系操作を投入しても占有解放後に両方完走する",
    arguments: DeliveryRoute.allCases
)
private func sharedQueueAvoidsSelfDeadlockForDeliveryRoutes(_ route: DeliveryRoute) async throws {
    let fixture = try await setUpDeliveryRouteFixture(route: route)

    await fixture.occupancyGate.open()

    try await awaitOrRecordDeadlock(
        cancelOnTimeout: {
            fixture.blocking.cancel()
            fixture.recovery.cancel()
            fixture.routeTask.cancel()
        },
        operation: {
            _ = try await fixture.blocking.value
            _ = try await fixture.recovery.value
            try await fixture.routeTask.value
        }
    )
}
