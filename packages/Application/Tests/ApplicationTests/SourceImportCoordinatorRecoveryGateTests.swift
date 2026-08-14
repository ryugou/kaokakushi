import Foundation
import Testing
import Domain
@testable import Application

// SourceImportCoordinator.importPickedPhoto が起動時復旧ゲートを待つこと（Issue #8
// サブプロジェクト5 A2 Task 2 reviewer 一次レビュー Critical 1）。
//
// 正本: architecture.md 4.3「起動時に1回のみ実行し、完了まで他のすべてを開始させない」、
// image-pipeline.md 5章「インポートSaga」。ゲート待機は SerialTaskQueue へ投入する前に行う
// （ExportCoordinatorGenerateRecoveryGateTests.swift / OutputDeliveryCoordinatorRecoveryGateTests.swift
// と同じ様式）。
//
// Critical 1: `SourceImportCoordinator.importPickedPhoto` は `recoveryGate.awaitRecoveryCompleted()`
// を呼んではいるが、`makeSourceImportCoordinator`（SourceImportTestSupport.swift）の既定
// `FakeRecoveryGate()` が常に `isOpen: true` であるため、この呼び出しをコメントアウトしても
// 既存の全テストが緑のまま通ってしまっていた（reviewer が実際に確認済みの変異）。ここで
// 復旧未完了時に変更系操作へ進まないことを固定する。

@Test("復旧未完了の間はimportPickedPhotoがstoreへ進まず、完了後に取り込める", .timeLimit(.minutes(1)))
private func importPickedPhotoWaitsForRecoveryGateThenProceeds() async throws {
    let loader = FakePickedPhotoLoader()
    let store = FakeWorkingSourceStore()
    let gate = FakeRecoveryGate(isOpen: false)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        recoveryGate: gate
    )
    let input = makePickedPhotoInput()

    let task = Task { try await coordinator.importPickedPhoto(input) }
    for _ in 0..<5 { await Task.yield() }
    // ゲートが閉じている間は queue.run（performImport）へ到達しないため、load にも
    // createProjectWithWorkingSource にも到達しない。
    #expect(await loader.loadCalls.isEmpty)
    #expect(await store.createProjectWithWorkingSourceCalls.isEmpty)

    await gate.open()
    _ = try await task.value

    #expect(await store.createProjectWithWorkingSourceCalls.count == 1)
}

// W（他 Coordinator と同型）: 共有キューを外部opが占有し、復旧がそのキューへ操作を積んだまま
// 保留されている状態で importPickedPhoto を投入しても、占有解放後に両方完走することを確認する
// （自己デッドロック非発生）。OutputDeliveryCoordinatorRecoveryGateTests.swift の
// sharedQueueAvoidsSelfDeadlockForDeliveryRoutes と同型。fixture 組み立てを分離するのも
// 同ファイルの DeliveryRouteDeadlockFixture / setUpDeliveryRouteFixture と同じ理由
// （function_body_length を50行以内に収めるため）。

/// デッドロック検出テストに必要な非構造化 `Task` 一式（関数長を50行以内に収めるための分割。
/// OutputDeliveryCoordinatorRecoveryGateTests.swift の DeliveryRouteDeadlockFixture と同型）。
private struct ImportDeadlockFixture: Sendable {
    let blocking: Task<Void, Error>
    let occupancyGate: OneShotGate
    let recovery: Task<StartupRecoveryReport, Error>
    let importTask: Task<ProjectID, Error>
}

/// 外部opによる共有キュー占有→復旧開始→importPickedPhoto投入までを行い、占有解放前の状態まで
/// 整えたフィクスチャを返す。
private func setUpImportDeadlockFixture() async throws -> ImportDeadlockFixture {
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

    let exportSagaStore = FakeExportSagaStore()
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let recoveryCoordinator = StartupRecoveryCoordinator(
        exportSagaStore: exportSagaStore,
        outputDeliveryStore: outputDeliveryStore,
        maintenanceStore: maintenanceStore,
        managedFileStore: managedFileStore,
        queue: sharedQueue
    )

    let loader = FakePickedPhotoLoader()
    let store = FakeWorkingSourceStore()
    let coordinator = SourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore,
        now: makeFixedClock(),
        queue: sharedQueue,
        recoveryGate: recoveryCoordinator
    )
    let input = makePickedPhotoInput()

    let recovery = Task { try await recoveryCoordinator.runStartupRecovery() }
    for _ in 0..<5 { await Task.yield() }
    #expect(await exportSagaStore.loadRunningJobsCallCount == 1)

    let importTask = Task { try await coordinator.importPickedPhoto(input) }
    for _ in 0..<5 { await Task.yield() }
    #expect(await store.createProjectWithWorkingSourceCalls.isEmpty)

    return ImportDeadlockFixture(
        blocking: blocking, occupancyGate: occupancyGate, recovery: recovery, importTask: importTask
    )
}

@Test(
    "共有キューを外部opが占有し復旧がキュー操作を残した状態でimportPickedPhotoを投入しても占有解放後に完走する",
    .timeLimit(.minutes(1))
)
private func importPickedPhotoAvoidsSelfDeadlockWithSharedQueue() async throws {
    let fixture = try await setUpImportDeadlockFixture()

    await fixture.occupancyGate.open()

    try await awaitOrRecordDeadlock(
        cancelOnTimeout: {
            fixture.blocking.cancel()
            fixture.recovery.cancel()
            fixture.importTask.cancel()
        },
        operation: {
            _ = try await fixture.blocking.value
            _ = try await fixture.recovery.value
            _ = try await fixture.importTask.value
        }
    )
}
