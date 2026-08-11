import Foundation
import Testing
import Domain
@testable import Application

// StartupRecoveryCoordinator（Issue #7 Task 9「起動時復旧」）。
//
// 正本: export-saga.md 5章「起動時復旧」、architecture.md 4.3「起動時に1回のみ実行し、
// 完了まで他のすべてを開始させない」、test-plan.md 3.5「起動時復旧」・3.6「出力の寿命と
// 履歴」の復旧案内項目。
//
// 偽ストア（FakeExportSagaStore / FakeOutputDeliveryStore）だけを注入し、手順の実行順序・
// throw の伝播・previousState による解決・「1回のみ実行」・完了ゲートを検証する。
// 孤児ファイルGCの詳細（削除経路・登録経路・失敗時の扱い）は StartupRecoveryFileGCTests.swift
// が担当し、本ファイルは deleteRunningJobs → GC → resolveOrphanedAttempts の順序と
// throw の伝播だけを担当する（Task 11 レビュー W-6）。

private struct Boom: Error, Equatable {}

// OneShotGate は TestSupport.swift へ集約した（Issue #7 レビュー第2ラウンド S-2）。

// makeCoordinator は TestSupport.swift の共有ヘルパーを使う（Task 11 で maintenanceStore /
// managedFileStore を追加し、StartupRecoveryFileGCTests.swift と共有するため一本化した）。

// MARK: - 実行順序とreport生成

@Test("起動時復旧はloadRunningJobs→deleteRunningJobs→resolveOrphanedAttempts→loadUnknownLibrarySavesの順で実行されreportへ反映する")
private func recoveryExecutesStoreCallsInOrderAndBuildsReport() async throws {
    let job = makeExportJob(exportID: makeExportID())
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    let unknownSaveExportID = makeExportID()
    await outputDeliveryStore.seedUnknownLibrarySave(
        UnknownLibrarySave(exportID: unknownSaveExportID, occurredAt: makeFixedClock()())
    )
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore, outputDeliveryStore: outputDeliveryStore)

    let report = try await coordinator.runStartupRecovery()

    #expect(await exportSagaStore.loadRunningJobsCallCount == 1)
    #expect(await exportSagaStore.deleteRunningJobsCalls == [[job.exportID]])
    #expect(await outputDeliveryStore.resolveOrphanedAttemptsCallCount == 1)
    #expect(await outputDeliveryStore.loadUnknownLibrarySavesCallCount == 1)
    #expect(report.deletedRunningJobCount == 1)
    #expect(report.unknownLibrarySaves.map(\.exportID) == [unknownSaveExportID])
}

@Test("loadRunningJobsのthrowは以降の手順を実行させずそのまま伝播する")
private func loadRunningJobsFailurePropagatesAndStopsSubsequentSteps() async throws {
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.setLoadRunningJobsFailure(Boom())
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore, outputDeliveryStore: outputDeliveryStore)

    await #expect(throws: Boom.self) {
        try await coordinator.runStartupRecovery()
    }

    #expect(await exportSagaStore.deleteRunningJobsCalls.isEmpty)
    #expect(await outputDeliveryStore.resolveOrphanedAttemptsCallCount == 0)
    #expect(await outputDeliveryStore.loadUnknownLibrarySavesCallCount == 0)
}

@Test("deleteRunningJobsのthrowは以降の手順を実行させずそのまま伝播する（孤児ファイルGCも呼ばれない）")
private func deleteRunningJobsFailurePropagatesAndStopsSubsequentSteps() async throws {
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.setDeleteRunningJobsFailure(Boom())
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        outputDeliveryStore: outputDeliveryStore,
        maintenanceStore: maintenanceStore,
        managedFileStore: managedFileStore
    )

    await #expect(throws: Boom.self) {
        try await coordinator.runStartupRecovery()
    }

    // export-saga.md 5章の順序では孤児ファイルGCはdeleteRunningJobsの後に実行される
    // ため、deleteRunningJobsが伝播した時点でGCはまだ呼ばれていない（Task 11 レビュー W-4）。
    #expect(await maintenanceStore.loadPendingFileDeletionsCallCount == 0)
    #expect(await outputDeliveryStore.resolveOrphanedAttemptsCallCount == 0)
    #expect(await outputDeliveryStore.loadUnknownLibrarySavesCallCount == 0)
}

@Test("resolveOrphanedAttemptsのthrowは以降の手順を実行させずそのまま伝播する（孤児ファイルGCは既に呼ばれている）")
private func resolveOrphanedAttemptsFailurePropagatesAndStopsSubsequentSteps() async throws {
    let exportSagaStore = FakeExportSagaStore()
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.setResolveOrphanedAttemptsFailure(Boom())
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        outputDeliveryStore: outputDeliveryStore,
        maintenanceStore: maintenanceStore,
        managedFileStore: managedFileStore
    )

    await #expect(throws: Boom.self) {
        try await coordinator.runStartupRecovery()
    }

    // 孤児ファイルGCはresolveOrphanedAttemptsより前に実行される設計のため、
    // resolveOrphanedAttemptsが伝播した時点でGCは既に呼ばれている（Task 11 レビュー W-4。
    // runOrphanFileGC()をresolveOrphanedAttemptsの後ろへ移動する回帰をこちらが検出する）。
    #expect(await maintenanceStore.loadPendingFileDeletionsCallCount == 1)
    #expect(await outputDeliveryStore.loadUnknownLibrarySavesCallCount == 0)
}

@Test("loadUnknownLibrarySavesのthrowがそのまま伝播する")
private func loadUnknownLibrarySavesFailurePropagates() async throws {
    let exportSagaStore = FakeExportSagaStore()
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.setLoadUnknownLibrarySavesFailure(Boom())
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore, outputDeliveryStore: outputDeliveryStore)

    await #expect(throws: Boom.self) {
        try await coordinator.runStartupRecovery()
    }
}

// MARK: - 完了済み出力・previousStateによる解決

@Test("完了済みの出力には触れず、他のストア操作を呼ばない")
private func settledOutputsAreNotTouchedByRecovery() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .delivered)
    let exportSagaStore = FakeExportSagaStore()
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore, outputDeliveryStore: outputDeliveryStore)

    _ = try await coordinator.runStartupRecovery()

    #expect(await outputDeliveryStore.deleteOutputCalls.isEmpty)
    #expect(await outputDeliveryStore.completeShareCalls.isEmpty)
    #expect(await outputDeliveryStore.completeLibrarySaveCalls.isEmpty)
    #expect(await exportSagaStore.settleExportCalls.isEmpty)
    #expect(await exportSagaStore.discardExportCalls.isEmpty)
    #expect(await outputDeliveryStore.outputSnapshot(for: exportID)?.state == .delivered)
}

@Test("previousStateがgeneratedの残存DeliveryAttemptはdeliveryUnknownへ解決されreportへ反映される")
private func orphanedAttemptWithGeneratedPreviousStateResolvesToDeliveryUnknown() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    try await outputDeliveryStore.beginDeliveryAttempt(exportID)
    let coordinator = makeCoordinator(outputDeliveryStore: outputDeliveryStore)

    let report = try await coordinator.runStartupRecovery()

    let snapshot = report.outputDeliverySnapshots.first { $0.output.exportID == exportID }
    #expect(snapshot?.output.state == .deliveryUnknown)
    #expect(await outputDeliveryStore.outputSnapshot(for: exportID)?.state == .deliveryUnknown)
}

@Test("previousStateがdeliveredの残存DeliveryAttemptはdeliveredを維持しUnknownLibrarySaveの注記が付く")
private func orphanedAttemptWithDeliveredPreviousStateKeepsDeliveredWithNote() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .delivered)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    try await outputDeliveryStore.beginDeliveryAttempt(exportID)
    let coordinator = makeCoordinator(outputDeliveryStore: outputDeliveryStore)

    let report = try await coordinator.runStartupRecovery()

    let snapshot = report.outputDeliverySnapshots.first { $0.output.exportID == exportID }
    #expect(snapshot?.output.state == .delivered)
    #expect(snapshot?.hasUnknownLibrarySave == true)
}

// MARK: - 1回のみ実行・完了ゲート

@Test("起動時復旧を2回呼んでもストア操作は1回だけ実行される")
private func runningRecoveryTwiceOnlyExecutesStoreCallsOnce() async throws {
    let job = makeExportJob(exportID: makeExportID())
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore, outputDeliveryStore: outputDeliveryStore)

    let firstReport = try await coordinator.runStartupRecovery()
    let secondReport = try await coordinator.runStartupRecovery()

    #expect(await exportSagaStore.loadRunningJobsCallCount == 1)
    #expect(await exportSagaStore.deleteRunningJobsCalls.count == 1)
    #expect(await outputDeliveryStore.resolveOrphanedAttemptsCallCount == 1)
    #expect(await outputDeliveryStore.loadUnknownLibrarySavesCallCount == 1)
    #expect(firstReport.deletedRunningJobCount == secondReport.deletedRunningJobCount)
}

@Test("復旧完了までawaitRecoveryCompletedが待機し、完了後に解放される", .timeLimit(.minutes(1)))
private func awaitRecoveryCompletedBlocksUntilRecoveryFinishes() async throws {
    let exportSagaStore = FakeExportSagaStore()
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    let gate = OneShotGate()
    let (reachedHookStream, reachedHookContinuation) = AsyncStream<Void>.makeStream()
    var reachedHookIterator = reachedHookStream.makeAsyncIterator()
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        outputDeliveryStore: outputDeliveryStore,
        updateGuidanceHook: {
            reachedHookContinuation.yield(())
            await gate.wait()
        }
    )

    let recovery = Task { try await coordinator.runStartupRecovery() }
    _ = await reachedHookIterator.next()
    #expect(await exportSagaStore.loadRunningJobsCallCount == 1)
    #expect(await outputDeliveryStore.loadUnknownLibrarySavesCallCount == 1)

    let (waiterSignal, waiterContinuation) = AsyncStream<Void>.makeStream()
    var waiterIterator = waiterSignal.makeAsyncIterator()
    let waiter = Task {
        try await coordinator.awaitRecoveryCompleted()
        waiterContinuation.yield(())
    }
    for _ in 0..<5 { await Task.yield() }
    waiterContinuation.finish()
    #expect(await waiterIterator.next() == nil)

    await gate.open()
    _ = try await recovery.value
    try await waiter.value
}

// C-1（Task 12 レビュー）: 復旧が失敗で確定した後、awaitRecoveryCompleted は待たせず
// StartupRecoveryFailedError で即座に返る。「復旧が失敗したら書き出しを開始させない」という
// 本質（ゲートが開かないこと）は、この専用エラーで throw することで維持する。
@Test("復旧がthrowした場合、以後のawaitRecoveryCompletedは待たずStartupRecoveryFailedErrorで返る", .timeLimit(.minutes(1)))
private func recoveryFailureLeavesGateClosed() async throws {
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.setLoadRunningJobsFailure(Boom())
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore, outputDeliveryStore: outputDeliveryStore)

    await #expect(throws: Boom.self) {
        try await coordinator.runStartupRecovery()
    }

    do {
        try await coordinator.awaitRecoveryCompleted()
        Issue.record("StartupRecoveryFailedErrorが投げられるはずだった")
    } catch let error as StartupRecoveryFailedError {
        #expect(error.cause is Boom)
    } catch {
        Issue.record("想定外のエラー: \(error)")
    }
}

// C-1: ゲート待ち中にキャンセルされた呼び出しはCancellationErrorで抜け、waitersから除去される。
// 除去されずに残ると、後で復旧が完了した際にcompleteGateがそのCheckedContinuationを二重resume
// しようとしクラッシュする（CheckedContinuationは二重resumeで停止する）。他の待機者（キャンセル
// されていないもの）が正常に完了することも合わせて確認し、除去が他の待機者へ影響しないことを示す。
@Test(
    "ゲート待ち中にキャンセルされた呼び出しはCancellationErrorで抜け、他の待機者には影響しない",
    .timeLimit(.minutes(1))
)
private func awaitRecoveryCompletedCancellationDoesNotAffectOtherWaiters() async throws {
    let exportSagaStore = FakeExportSagaStore()
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    let gate = OneShotGate()
    let (reachedHookStream, reachedHookContinuation) = AsyncStream<Void>.makeStream()
    var reachedHookIterator = reachedHookStream.makeAsyncIterator()
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        outputDeliveryStore: outputDeliveryStore,
        updateGuidanceHook: {
            reachedHookContinuation.yield(())
            await gate.wait()
        }
    )

    let recovery = Task { try await coordinator.runStartupRecovery() }
    _ = await reachedHookIterator.next()

    let cancelledWaiter = Task { try await coordinator.awaitRecoveryCompleted() }
    let survivingWaiter = Task { try await coordinator.awaitRecoveryCompleted() }
    for _ in 0..<5 { await Task.yield() }
    cancelledWaiter.cancel()

    await #expect(throws: CancellationError.self) {
        try await cancelledWaiter.value
    }

    await gate.open()
    _ = try await recovery.value
    try await survivingWaiter.value
}

// あわせて対応（Issue #7 受け渡し後始末のキャンセルシールド横展開 spec）: 上のテストは
// 「待機に入ってからキャンセルされた」経路しか見ていない。ここでは「awaitRecoveryCompleted
// の呼び出し自体が既にキャンセル済みのタスクから行われた」経路を検証する。
// withTaskCancellationHandler は、operation（withCheckedThrowingContinuation）の実行前に
// 既にタスクがキャンセル済みなら、onCancel ハンドラを operation の前に呼びうる。この場合
// onCancel は cancelWaiter(waiterID) を非構造化 Task で起動するが、waiters[waiterID] への
// 登録自体はまだ行われていない可能性がある。現行実装が waiters 登録より前に cancelWaiter が
// 先着しても安全（登録側が actor の排他により必ず後から追いつき、その後キャンセルが解決される）
// なのは、cancelWaiter が actor-isolated であり、登録処理（withCheckedThrowingContinuation の
// クロージャ）自体が既に actor の排他区間の中で同期的に実行されるためである。
@Test(
    "呼び出し時点で既にキャンセル済みならCancellationErrorで即座に抜け、他の待機者には影響しない",
    .timeLimit(.minutes(1))
)
private func awaitRecoveryCompletedAlreadyCancelledAtEntryThrowsImmediately() async throws {
    let exportSagaStore = FakeExportSagaStore()
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    let gate = OneShotGate()
    let (reachedHookStream, reachedHookContinuation) = AsyncStream<Void>.makeStream()
    var reachedHookIterator = reachedHookStream.makeAsyncIterator()
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        outputDeliveryStore: outputDeliveryStore,
        updateGuidanceHook: {
            reachedHookContinuation.yield(())
            await gate.wait()
        }
    )

    let recovery = Task { try await coordinator.runStartupRecovery() }
    _ = await reachedHookIterator.next()

    // Task生成直後、本体（awaitRecoveryCompletedの呼び出し）が実行を始める前にcancel()する
    // ことで、「呼び出し時点で既にキャンセル済み」を再現する。
    let alreadyCancelledWaiter = Task { try await coordinator.awaitRecoveryCompleted() }
    alreadyCancelledWaiter.cancel()

    await #expect(throws: CancellationError.self) {
        try await alreadyCancelledWaiter.value
    }

    let survivingWaiter = Task { try await coordinator.awaitRecoveryCompleted() }
    for _ in 0..<5 { await Task.yield() }

    await gate.open()
    _ = try await recovery.value
    try await survivingWaiter.value
}
