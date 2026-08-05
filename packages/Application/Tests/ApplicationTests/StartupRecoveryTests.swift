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
// throw の伝播・previousState による解決・「1回のみ実行」・完了ゲートを検証する
// （孤児ファイルGCはこの Coordinator が呼び出さない設計のため対象外。
// StartupRecoveryCoordinator.swift 冒頭コメント参照）。

private struct Boom: Error, Equatable {}

/// テスト専用の一回限りの非同期ゲート（SerialTaskQueueTests.swift と同じ方針の複製）。
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

private func makeCoordinator(
    exportSagaStore: FakeExportSagaStore = FakeExportSagaStore(),
    outputDeliveryStore: FakeOutputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock()),
    updateGuidanceHook: @escaping @Sendable () async -> Void = {}
) -> StartupRecoveryCoordinator {
    StartupRecoveryCoordinator(
        exportSagaStore: exportSagaStore,
        outputDeliveryStore: outputDeliveryStore,
        updateGuidanceHook: updateGuidanceHook
    )
}

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

@Test("deleteRunningJobsのthrowは以降の手順を実行させずそのまま伝播する")
private func deleteRunningJobsFailurePropagatesAndStopsSubsequentSteps() async throws {
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.setDeleteRunningJobsFailure(Boom())
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore, outputDeliveryStore: outputDeliveryStore)

    await #expect(throws: Boom.self) {
        try await coordinator.runStartupRecovery()
    }

    #expect(await outputDeliveryStore.resolveOrphanedAttemptsCallCount == 0)
    #expect(await outputDeliveryStore.loadUnknownLibrarySavesCallCount == 0)
}

@Test("resolveOrphanedAttemptsのthrowは以降の手順を実行させずそのまま伝播する")
private func resolveOrphanedAttemptsFailurePropagatesAndStopsSubsequentSteps() async throws {
    let exportSagaStore = FakeExportSagaStore()
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.setResolveOrphanedAttemptsFailure(Boom())
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore, outputDeliveryStore: outputDeliveryStore)

    await #expect(throws: Boom.self) {
        try await coordinator.runStartupRecovery()
    }

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
        await coordinator.awaitRecoveryCompleted()
        waiterContinuation.yield(())
    }
    for _ in 0..<5 { await Task.yield() }
    waiterContinuation.finish()
    #expect(await waiterIterator.next() == nil)

    await gate.open()
    _ = try await recovery.value
    await waiter.value
}
