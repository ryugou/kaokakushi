import Foundation
import Testing
import Domain
@testable import Application

// SourceImportCoordinator.importPickedPhoto のうち、SerialTaskQueue.run 自身のキャンセル
// チェック（投入前・取り出し直前。architecture.md 4.2）に特化した検証（Issue #8
// サブプロジェクト5 A2 Task 2 reviewer 再レビュー Critical）。
//
// SourceImportCoordinatorImportTests.swift / SourceImportCoordinatorImportCleanupTests.swift の
// 既存キャンセルテストは performImport（手順1〜3）の内側 catch を通る経路しか固定していない。
// importPickedPhoto の外側 catch（132〜145行目。queue.run 自身のキャンセルチェックで
// performImport が一度も走らない窓の安全網）はどのテストからも実行されておらず、catch 節の
// 中身を `throw error`（registerOrphan を経由しない素通し）に置き換えても swift test は
// 147/147 全緑のままだった（reviewer が変異テストで確認済み）。この外側 catch は、
// SourceImportCoordinator.swift 84〜86行目の private 型 `ImportFailureAlreadyHandled`
// （「performImport が実行済みで後始末済み」と「performImport が未実行」を型で区別する機構）が
// 存在する唯一の理由でもあり、その経路そのものが未検証という状態だった。
//
// 雛形: ExportCoordinatorGenerateResilienceTests.swift（ExportCoordinator.generateOutput 側の
// 同型の外側 catch を先行して固定したファイル）。「先行 op でキューを占有して queue.run を
// 必ず『直前 op の完了待ち』で止める」フィクスチャ（occupyQueueWithBlockingOp）をそのまま
// 移植する。ただし SourceImportCoordinator.queue は private であり ExportCoordinator.queue
// （internal）のように coordinator 経由でキューへ触れられないため、SerialTaskQueue を直接
// 組み立てて占有してから makeSourceImportCoordinator(queue:) へ注入する
// （SourceImportCoordinatorRecoveryGateTests.swift の ImportDeadlockFixture /
// setUpImportDeadlockFixture と同じ理由）。

/// 先行 op で共有キューを占有し、`importPickedPhoto` 内部の `queue.run`（performImport）が
/// 必ず「直前 op の完了待ち」（4.2 の2つ目の checkCancellation の手前）を経由する状況を
/// 組み立てる（ExportCoordinatorGenerateResilienceTests.swift の occupyQueueWithBlockingOp と
/// 同じ手法。coordinator ではなく SerialTaskQueue を直接受け取る点だけが異なる）。
private func occupyQueueWithBlockingOp(
    _ queue: SerialTaskQueue
) async -> (blocking: Task<Void, Error>, gate: OneShotGate) {
    let (startedStream, startedContinuation) = AsyncStream<Int>.makeStream()
    var startedIterator = startedStream.makeAsyncIterator()
    let gate = OneShotGate()

    let blocking = Task<Void, Error> {
        try await queue.run {
            startedContinuation.yield(1)
            await gate.wait()
        }
    }
    _ = await startedIterator.next()
    startedContinuation.finish()
    return (blocking, gate)
}

@Test(
    "queue.run投入前後のキャンセルでperformImportが一度も走らない場合も、外側catchが後始末しCancellationErrorが伝播する",
    .timeLimit(.minutes(1))
)
private func queueLevelCancellationBeforeImportStartsStillRegistersOrphanAndPropagatesCancellationError() async throws {
    let queue = SerialTaskQueue()
    let (blocking, blockingGate) = await occupyQueueWithBlockingOp(queue)

    let loader = FakePickedPhotoLoader()
    let store = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore,
        queue: queue
    )
    let input = makePickedPhotoInput()

    let importTask = Task<ProjectID, Error> {
        try await coordinator.importPickedPhoto(input)
    }
    await Task.yield()
    importTask.cancel()

    // blockingを完了させ、importTask側のqueue.runがcheckCancellationへ到達できるようにする。
    await blockingGate.open()
    _ = try? await blocking.value

    await #expect(throws: CancellationError.self) {
        try await importTask.value
    }

    // performImportが一度も走らなかったことをloader/storeが一度も呼ばれていないことで直接
    // 確認する（これが無いと「performImportが走って後始末した」ケースと弁別できない）。
    #expect(await loader.loadCalls.isEmpty)
    #expect(await store.createProjectWithWorkingSourceCalls.isEmpty)
    // 2件になっていたら二重登録（ImportFailureAlreadyHandledでの区別が壊れている）なので
    // 件数まで厳密に照合する。
    #expect(await maintenanceStore.registerOrphanCalls == [input.importedFile])
}

@Test(
    "外側catch: queue.run投入前後のキャンセルでも後始末のregisterOrphanはシールドされ完走する",
    .timeLimit(.minutes(1))
)
private func queueLevelCancellationRegisterOrphanIsShieldedFromCancellation() async throws {
    let queue = SerialTaskQueue()
    let (blocking, blockingGate) = await occupyQueueWithBlockingOp(queue)

    let loader = FakePickedPhotoLoader()
    let store = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    // registerOrphanChecksCancellationを立てて初めて、シールドを外すとregisterOrphanの最初の
    // 呼び出しがcheckCancellationで即throwし失敗することを検出できる
    // （deleteImportedFileRegisterOrphanIsShieldedFromCancellationと同じ理由。これを立てないと
    // runShieldedFromCancellationを外してもテストが緑のままになり弁別力が無い）。
    await maintenanceStore.setRegisterOrphanChecksCancellation(true)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore,
        queue: queue
    )
    let input = makePickedPhotoInput()

    let importTask = Task<ProjectID, Error> {
        try await coordinator.importPickedPhoto(input)
    }
    await Task.yield()
    importTask.cancel()

    await blockingGate.open()
    _ = try? await blocking.value

    await #expect(throws: CancellationError.self) {
        try await importTask.value
    }

    #expect(await loader.loadCalls.isEmpty)
    #expect(await store.createProjectWithWorkingSourceCalls.isEmpty)
    // シールドが効いていれば、呼び出し元がキャンセル済みの文脈でもregisterOrphanは完走する。
    #expect(await maintenanceStore.registerOrphanCalls == [input.importedFile])
}
