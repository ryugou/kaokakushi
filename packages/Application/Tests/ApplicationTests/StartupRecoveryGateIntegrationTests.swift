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
    let exportCoordinator = ExportCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        stampCatalog: FakeStampCatalog(),
        imageEffectRenderer: FakeImageEffectRenderer(),
        imageEncoder: FakeImageEncoder(),
        outputFileVerifier: FakeOutputFileVerifier(defaultOutcome: .success(makeVerifiedOutputMeasurement())),
        outputDeliveryStore: outputDeliveryStore,
        now: makeFixedClock(),
        queue: SerialTaskQueue(),
        exportedSettingsEntryStore: FakeExportedSettingsEntryStore(),
        settingsHashDigest: FakeSha256Digest(),
        recoveryGate: recoveryCoordinator
    )

    let outcome = try await exportCoordinator.startExport(request, capabilities: makeResolvedCapabilities())

    guard case .started(let job) = outcome else {
        Issue.record("expected .started but got \(outcome)")
        return
    }
    #expect(job.exportID == expectedJob.exportID)
}
