import Foundation
import Testing
import Domain
@testable import Application

// StartupRecoveryCoordinator と RecoveryGate の統合（Issue #7 Task 12）。
//
// 正本: docs/superpowers/specs/2026-08-10-issue7-task12.md。
// - 復旧手順の変更系操作（deleteRunningJobs・孤児ファイルGCの削除）が共有 SerialTaskQueue を
//   経由すること（キューが外部の操作で埋まっていれば、その完了まで足止めされることで示す。
//   SerialTaskQueueTests.swift の FIFO 検証と同じ手法）。
// - Task 11 で導入した「GCの失敗は復旧全体を止めずゲートを開く」非対称性が、
//   StartupRecoveryCoordinator を RecoveryGate として ExportCoordinator へ注入した経路でも
//   保たれること（GCが失敗しても後続の書き出し開始が可能であること）。

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

@Test(
    "復旧手順の変更系操作は共有SerialTaskQueue経由であり、キューが埋まっていれば完了まで足止めされる",
    .timeLimit(.minutes(1))
)
private func recoveryMutationsGoThroughSharedQueueAndWaitTheirTurn() async throws {
    let queue = SerialTaskQueue()
    let gate = OneShotGate()
    let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
    var startedIterator = startedStream.makeAsyncIterator()

    let blocking = Task<Void, Error> {
        try await queue.run {
            startedContinuation.yield(())
            await gate.wait()
        }
    }
    _ = await startedIterator.next()

    let job = makeExportJob(exportID: makeExportID())
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    await maintenanceStore.seedPendingFileDeletion(ref)
    await managedFileStore.seedExistingFile(ref)
    let coordinator = StartupRecoveryCoordinator(
        exportSagaStore: exportSagaStore,
        outputDeliveryStore: outputDeliveryStore,
        maintenanceStore: maintenanceStore,
        managedFileStore: managedFileStore,
        queue: queue
    )

    let recovery = Task { try await coordinator.runStartupRecovery() }
    for _ in 0..<5 { await Task.yield() }
    // loadRunningJobsは読み取りのためキューを経由せず即座に呼ばれる。
    #expect(await exportSagaStore.loadRunningJobsCallCount == 1)
    // deleteRunningJobsとGCのdeleteはキュー経由のため、queueを占有するblockingの完了を
    // 待って足止めされる（自己デッドロックしていないことは、その後gateを開けて
    // recoveryが完走することで確認する）。
    #expect(await exportSagaStore.deleteRunningJobsCalls.isEmpty)
    #expect(await managedFileStore.deleteCalls.isEmpty)

    await gate.open()
    _ = try await blocking.value
    let report = try await recovery.value

    #expect(await exportSagaStore.deleteRunningJobsCalls == [[job.exportID]])
    #expect(await managedFileStore.deleteCalls == [ref])
    #expect(report.deletedFileCount == 1)
}

/// 1.1・1.2 を必ず通過する（renderSpec は regions 無し）標準リクエスト
/// （ExportCoordinatorStartTests.swift の makeFullyConsistentRequest と同じ定義）。
private func makeExportRequest(projectID: ProjectID) throws -> SingleExportRequest {
    let hash = try makePreviewRenderHash()
    let confirmation = PreviewConfirmation(projectID: projectID, detectionRevision: 5, previewRenderHash: hash)
    return SingleExportRequest(
        projectID: projectID,
        renderSpec: try makeRenderSpec(),
        exportSetting: makeExportSetting(),
        previewConfirmation: confirmation,
        currentDetectionRevision: 5,
        currentPreviewRenderHash: hash,
        isReviewed: true,
        expectedProjectRevision: 0
    )
}

/// 実体ファイルまで揃った WorkingSourceRecord を作り、指定した偽ストアへ seed する
/// （ExportCoordinatorBatchTests.swift の seedWorkingSource と同じ定義）。
private func seedWorkingSource(
    projectID: ProjectID, workingSourceStore: FakeWorkingSourceStore, managedFileStore: FakeManagedFileStore
) async throws {
    let sourceFileRef = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))
    let workingSourceFileRef = try #require(WorkingSourceFileRef(sourceFileRef))
    await workingSourceStore.seedWorkingSource(
        WorkingSourceRecord(
            projectID: projectID,
            sourceFile: workingSourceFileRef,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    )
    await managedFileStore.seedExistingFile(sourceFileRef)
}

/// makeExportCoordinatorSharingQueue へ渡す store 一式（function_parameter_count 回避のため
/// struct にまとめる。TestSupport.swift の SucceedingGenerationPipeline と同じ方針）。
private struct SharedQueueStores {
    let exportSagaStore: ExportSagaStore
    let workingSourceStore: WorkingSourceStore
    let managedFileStore: ManagedFileStore
    let outputDeliveryStore: OutputDeliveryStore
}

/// 指定した queue / recoveryGate を共有する ExportCoordinator を組み立てる
/// （W-2: StartupRecoveryCoordinator と同一の SerialTaskQueue を注入するテスト用）。
private func makeExportCoordinatorSharingQueue(
    _ stores: SharedQueueStores, queue: SerialTaskQueue, recoveryGate: RecoveryGate
) -> ExportCoordinator {
    ExportCoordinator(
        exportSagaStore: stores.exportSagaStore,
        workingSourceStore: stores.workingSourceStore,
        managedFileStore: stores.managedFileStore,
        stampCatalog: FakeStampCatalog(),
        imageEffectRenderer: FakeImageEffectRenderer(),
        imageEncoder: FakeImageEncoder(),
        outputFileVerifier: FakeOutputFileVerifier(defaultOutcome: .success(makeVerifiedOutputMeasurement())),
        outputDeliveryStore: stores.outputDeliveryStore,
        now: makeFixedClock(),
        queue: queue,
        exportedSettingsEntryStore: FakeExportedSettingsEntryStore(),
        settingsHashDigest: FakeSha256Digest(),
        recoveryGate: recoveryGate
    )
}

@Test(
    "GCが失敗してもゲートが開き、RecoveryGateとして注入したExportCoordinator.startExportが後続で開始できる",
    .timeLimit(.minutes(1))
)
private func gcFailureStillOpensGateForSubsequentExports() async throws {
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    await maintenanceStore.setLoadPendingFileDeletionsFailure(Boom())
    let projectID = makeProjectID()
    let expectedJob = makeExportJob(exportID: makeExportID(), projectID: projectID)
    let exportSagaStore = FakeExportSagaStore(startExportHandler: { _, _ in .authorized(expectedJob) })
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    let recoveryCoordinator = StartupRecoveryCoordinator(
        exportSagaStore: exportSagaStore,
        outputDeliveryStore: outputDeliveryStore,
        maintenanceStore: maintenanceStore,
        managedFileStore: managedFileStore,
        queue: SerialTaskQueue()
    )

    let report = try await recoveryCoordinator.runStartupRecovery()
    #expect((report.fileGCFailure as? Boom) == Boom())

    let workingSourceStore = FakeWorkingSourceStore()
    try await seedWorkingSource(
        projectID: projectID, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )
    let request = try makeExportRequest(projectID: projectID)
    let stores = SharedQueueStores(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        outputDeliveryStore: outputDeliveryStore
    )
    let exportCoordinator = makeExportCoordinatorSharingQueue(
        stores, queue: SerialTaskQueue(), recoveryGate: recoveryCoordinator
    )

    let outcome = try await exportCoordinator.startExport(request, capabilities: makeResolvedCapabilities())

    guard case .started(let job) = outcome else {
        Issue.record("expected .started but got \(outcome)")
        return
    }
    #expect(job.exportID == expectedJob.exportID)
}

// W-2（Task 12 レビュー）: 復旧用と書き出し用が別インスタンスのキューを使うテストだけでは、
// awaitRecoveryCompleted() の呼び出しを将来 queue.run の中へ移す改変が入っても検出できない。
// StartupRecoveryCoordinator と ExportCoordinator に同一の SerialTaskQueue を注入し、
// updateGuidanceHook で復旧を保留したまま startExport を呼んでも自己デッドロックせず、
// フック解放後に両者が完走することを固定する。
@Test(
    "共有SerialTaskQueue上でupdateGuidanceHookが復旧を保留している間もstartExportはゲートを待ち、フック解放後に両方完走する",
    .timeLimit(.minutes(1))
)
private func sharedQueueAvoidsSelfDeadlockBetweenRecoveryAndExportStart() async throws {
    let sharedQueue = SerialTaskQueue()
    let hookGate = OneShotGate()
    let (reachedHookStream, reachedHookContinuation) = AsyncStream<Void>.makeStream()
    var reachedHookIterator = reachedHookStream.makeAsyncIterator()

    let projectID = makeProjectID()
    let expectedJob = makeExportJob(exportID: makeExportID(), projectID: projectID)
    let exportSagaStore = FakeExportSagaStore(startExportHandler: { _, _ in .authorized(expectedJob) })
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let recoveryCoordinator = StartupRecoveryCoordinator(
        exportSagaStore: exportSagaStore,
        outputDeliveryStore: outputDeliveryStore,
        maintenanceStore: maintenanceStore,
        managedFileStore: managedFileStore,
        queue: sharedQueue,
        updateGuidanceHook: {
            reachedHookContinuation.yield(())
            await hookGate.wait()
        }
    )

    let workingSourceStore = FakeWorkingSourceStore()
    let request = try makeExportRequest(projectID: projectID)
    let stores = SharedQueueStores(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        outputDeliveryStore: outputDeliveryStore
    )
    let exportCoordinator = makeExportCoordinatorSharingQueue(
        stores, queue: sharedQueue, recoveryGate: recoveryCoordinator
    )

    let recovery = Task { try await recoveryCoordinator.runStartupRecovery() }
    _ = await reachedHookIterator.next()
    // GC（孤児ファイルの差集合判定）は updateGuidanceHook より前の手順のため、hook到達後に
    // 実体を seed すれば GC に孤児として拾われず削除されない（recoveryCoordinator と
    // exportCoordinator は managedFileStore を共有しているため、先に seed すると GC 対象に
    // なってしまう）。
    try await seedWorkingSource(
        projectID: projectID, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )

    let startTask = Task { try await exportCoordinator.startExport(request, capabilities: makeResolvedCapabilities()) }
    for _ in 0..<5 { await Task.yield() }
    #expect(await exportSagaStore.startExportCalls.isEmpty)

    await hookGate.open()
    let report = try await recovery.value
    let outcome = try await startTask.value

    guard case .started(let job) = outcome else {
        Issue.record("expected .started but got \(outcome)")
        return
    }
    #expect(job.exportID == expectedJob.exportID)
    #expect(report.deletedRunningJobCount == 0)
}

// C-1（Task 12 レビュー）: 復旧が失敗で確定した後は、以後の変更系操作を待たせたままにせず
// StartupRecoveryFailedError で即座に返す。RecoveryGate として注入した本物の
// StartupRecoveryCoordinator が失敗したケースで、ExportCoordinator.startExport 側からも
// 同じ挙動になることを固定する（FakeRecoveryGate では検出できない、実装同士の配線を検証する）。
@Test(
    "復旧が失敗で確定した後にstartExportを呼ぶと、待たずにStartupRecoveryFailedErrorで返る",
    .timeLimit(.minutes(1))
)
private func startExportAfterRecoveryFailureReturnsErrorWithoutWaiting() async throws {
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.setLoadRunningJobsFailure(Boom())
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let recoveryCoordinator = StartupRecoveryCoordinator(
        exportSagaStore: exportSagaStore,
        outputDeliveryStore: outputDeliveryStore,
        maintenanceStore: maintenanceStore,
        managedFileStore: managedFileStore,
        queue: SerialTaskQueue()
    )
    await #expect(throws: Boom.self) {
        try await recoveryCoordinator.runStartupRecovery()
    }

    let projectID = makeProjectID()
    let workingSourceStore = FakeWorkingSourceStore()
    try await seedWorkingSource(
        projectID: projectID, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )
    let request = try makeExportRequest(projectID: projectID)
    let stores = SharedQueueStores(
        exportSagaStore: FakeExportSagaStore(),
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        outputDeliveryStore: outputDeliveryStore
    )
    let exportCoordinator = makeExportCoordinatorSharingQueue(
        stores, queue: SerialTaskQueue(), recoveryGate: recoveryCoordinator
    )

    do {
        _ = try await exportCoordinator.startExport(request, capabilities: makeResolvedCapabilities())
        Issue.record("StartupRecoveryFailedErrorが投げられるはずだった")
    } catch let error as StartupRecoveryFailedError {
        #expect(error.cause is Boom)
    } catch {
        Issue.record("想定外のエラー: \(error)")
    }
}
