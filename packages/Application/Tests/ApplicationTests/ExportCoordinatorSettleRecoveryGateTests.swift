import Foundation
import Testing
import Domain
@testable import Application

// ExportCoordinator.settleExport / settleBatch が起動時復旧ゲートを待つこと（Issue #32 C-2）。
//
// 正本: architecture.md 4.3「起動時に1回のみ実行し、完了まで他のすべてを開始させない」、
// export-saga.md 5章「起動時復旧」。cold start では前回異常終了で残った ExportJob・未確定
// OutputRecord が、復旧の deleteRunningJobs より先に settle されうる（開始経路
// startExport/startBatchItem のゲート済みは同一セッション内の前提であり、前回セッションで
// 作られた行には及ばない）。settleExport/settleBatch も他の変更系操作と同じく、
// queue.run へ投入する前にゲートを待つ。

private func makeCoordinator(
    exportSagaStore: FakeExportSagaStore = FakeExportSagaStore(),
    queue: SerialTaskQueue = SerialTaskQueue(),
    recoveryGate: RecoveryGate = FakeRecoveryGate()
) -> ExportCoordinator {
    ExportCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: FakeWorkingSourceStore(),
        managedFileStore: FakeManagedFileStore(),
        stampCatalog: FakeStampCatalog(),
        imageEffectRenderer: FakeImageEffectRenderer(),
        imageEncoder: FakeImageEncoder(),
        outputFileVerifier: FakeOutputFileVerifier(defaultOutcome: .success(makeVerifiedOutputMeasurement())),
        outputDeliveryStore: FakeOutputDeliveryStore(now: makeFixedClock()),
        now: makeFixedClock(),
        queue: queue,
        exportedSettingsEntryStore: FakeExportedSettingsEntryStore(),
        settingsHashDigest: FakeSha256Digest(),
        recoveryGate: recoveryGate
    )
}

// MARK: - 復旧未完了の間は開始されず、完了後に開始できる

@Test("復旧未完了の間はsettleExportがstoreへ進まず、完了後に確定できる", .timeLimit(.minutes(1)))
private func settleExportWaitsForRecoveryGateThenProceeds() async throws {
    let exportID = makeExportID()
    let job = makeExportJob(exportID: exportID)
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    await exportSagaStore.seedPendingOutput(makeRecordOutputInput(exportID: exportID))
    let gate = FakeRecoveryGate(isOpen: false)
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore, recoveryGate: gate)

    let task = Task { try await coordinator.settleExport(exportID) }
    for _ in 0..<5 { await Task.yield() }
    #expect(await exportSagaStore.settleExportCalls.isEmpty)

    await gate.open()
    try await task.value

    #expect(await exportSagaStore.settleExportCalls == [exportID])
}

@Test("復旧未完了の間はsettleBatchがstoreへ進まず、完了後に確定できる", .timeLimit(.minutes(1)))
private func settleBatchWaitsForRecoveryGateThenProceeds() async throws {
    let batchID = makeBatchID()
    let exportID = makeExportID()
    let job = makeExportJob(exportID: exportID, batchID: batchID)
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    await exportSagaStore.seedPendingOutput(makeRecordOutputInput(exportID: exportID))
    let gate = FakeRecoveryGate(isOpen: false)
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore, recoveryGate: gate)

    let task = Task { try await coordinator.settleBatch(batchID) }
    for _ in 0..<5 { await Task.yield() }
    #expect(await exportSagaStore.settleBatchCalls.isEmpty)

    await gate.open()
    try await task.value

    #expect(await exportSagaStore.settleBatchCalls.count == 1)
}

// MARK: - 復旧が失敗で確定している場合はエラーで返る（既存のゲートの性質）

@Test("復旧が失敗で確定した後にsettleExportを呼ぶと、待たずにStartupRecoveryFailedErrorで返る")
private func settleExportAfterRecoveryFailureReturnsErrorWithoutWaiting() async throws {
    struct Boom: Error, Equatable {}
    let gate = FakeRecoveryGate(isOpen: false)
    await gate.fail(Boom())
    let coordinator = makeCoordinator(recoveryGate: gate)

    do {
        try await coordinator.settleExport(makeExportID())
        Issue.record("StartupRecoveryFailedErrorが投げられるはずだった")
    } catch let error as StartupRecoveryFailedError {
        #expect(error.cause is Boom)
    } catch {
        Issue.record("想定外のエラー: \(error)")
    }
}

@Test("復旧が失敗で確定した後にsettleBatchを呼ぶと、待たずにStartupRecoveryFailedErrorで返る")
private func settleBatchAfterRecoveryFailureReturnsErrorWithoutWaiting() async throws {
    struct Boom: Error, Equatable {}
    let gate = FakeRecoveryGate(isOpen: false)
    await gate.fail(Boom())
    let coordinator = makeCoordinator(recoveryGate: gate)

    do {
        try await coordinator.settleBatch(makeBatchID())
        Issue.record("StartupRecoveryFailedErrorが投げられるはずだった")
    } catch let error as StartupRecoveryFailedError {
        #expect(error.cause is Boom)
    } catch {
        Issue.record("想定外のエラー: \(error)")
    }
}

// MARK: - 自己デッドロックが無いこと（StartupRecoveryGateIntegrationTests.swiftと同じ手法）

private enum SettleRoute: CaseIterable, Sendable {
    case settleExport
    case settleBatch
}

/// route ごとの ExportCoordinator 呼び出し（Coordinator は actor のため Sendable）。
private func performSettleRoute(
    _ route: SettleRoute, _ coordinator: ExportCoordinator, exportID: ExportID, batchID: BatchID
) async throws {
    switch route {
    case .settleExport:
        try await coordinator.settleExport(exportID)
    case .settleBatch:
        try await coordinator.settleBatch(batchID)
    }
}

/// デッドロック検出テストに必要な非構造化 `Task` 一式（関数長を50行以内に収めるための分割）。
private struct SettleRouteDeadlockFixture: Sendable {
    let route: SettleRoute
    let blocking: Task<Void, Error>
    let occupancyGate: OneShotGate
    let recovery: Task<StartupRecoveryReport, Error>
    let routeTask: Task<Void, Error>
    let exportSagaStore: FakeExportSagaStore
    let exportID: ExportID
    let batchID: BatchID
}

/// 外部opによる共有キュー占有→復旧開始→route投入までを行い、占有解放前の状態まで整えた
/// フィクスチャを返す。exportSagaStore は settle 対象の ExportJob を loadRunningJobs にも
/// 見せる（recovery の deleteRunningJobs が同じ行を削除しうる。cold start の残存ジョブと
/// 同じ状況を再現するため、意図的に共有する）。
private func setUpSettleRouteFixture(route: SettleRoute) async throws -> SettleRouteDeadlockFixture {
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

    let batchID = makeBatchID()
    let exportID = makeExportID()
    let job = makeExportJob(
        exportID: exportID, batchID: route == .settleBatch ? batchID : nil, accountingMode: .freeMonthlyConsume
    )
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    await exportSagaStore.seedPendingOutput(makeRecordOutputInput(exportID: exportID))
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
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore, queue: sharedQueue, recoveryGate: recoveryCoordinator
    )

    let recovery = Task { try await recoveryCoordinator.runStartupRecovery() }
    for _ in 0..<5 { await Task.yield() }
    #expect(await exportSagaStore.loadRunningJobsCallCount == 1)

    let routeTask = Task {
        try await performSettleRoute(route, coordinator, exportID: exportID, batchID: batchID)
    }
    for _ in 0..<5 { await Task.yield() }
    #expect(await exportSagaStore.settleExportCalls.isEmpty)
    #expect(await exportSagaStore.settleBatchCalls.isEmpty)

    return SettleRouteDeadlockFixture(
        route: route, blocking: blocking, occupancyGate: occupancyGate, recovery: recovery,
        routeTask: routeTask, exportSagaStore: exportSagaStore, exportID: exportID, batchID: batchID
    )
}

@Test(
    "共有キューを外部opが占有し復旧がキュー操作を残した状態でsettleExport/settleBatchを投入しても占有解放後に両方完走する",
    .timeLimit(.minutes(1)),
    arguments: SettleRoute.allCases
)
private func sharedQueueAvoidsSelfDeadlockForSettleRoutes(_ route: SettleRoute) async throws {
    let fixture = try await setUpSettleRouteFixture(route: route)

    await fixture.occupancyGate.open()

    try await awaitOrRecordDeadlock(
        cancelOnTimeout: {
            fixture.blocking.cancel()
            fixture.recovery.cancel()
            fixture.routeTask.cancel()
        },
        operation: {
            _ = try await fixture.blocking.value
            let report = try await fixture.recovery.value
            // 復旧がゲートより先に完走し、残存ジョブ（cold start の想定）を削除している
            // ことがこのテストの核心（Issue #32 C-2 が無ければ settle が先に到達し確定・
            // 消費まで進んでしまう）。
            #expect(report.deletedRunningJobCount == 1)
            // settle はゲートを待つため、routeTask は復旧完了後にのみ queue.run へ進む。
            // 対象ジョブは既に削除済みのため事前条件違反で拒否される（正しい挙動。誤って
            // 確定・消費されていないことをこの後のカウンタ検査で確認する）。
            switch fixture.route {
            case .settleExport:
                await #expect(throws: FakeExportSagaStoreError.exportJobNotFound(fixture.exportID)) {
                    try await fixture.routeTask.value
                }
            case .settleBatch:
                await #expect(throws: FakeExportSagaStoreError.noPendingOutputToSettleForBatch(fixture.batchID)) {
                    try await fixture.routeTask.value
                }
            }
            #expect(await fixture.exportSagaStore.meteredConsumedCount == 0)
        }
    )
}
