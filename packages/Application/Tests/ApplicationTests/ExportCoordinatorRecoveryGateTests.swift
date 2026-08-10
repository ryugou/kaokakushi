import Foundation
import Testing
import Domain
@testable import Application

// ExportCoordinator の開始経路（startExport / startBatchItem）が起動時復旧ゲートを待つこと
// （Issue #7 Task 12）。
//
// 正本: export-saga.md 5章「復旧が完了するまで新しい書き出しを開始させない」、
// architecture.md 4.3「起動時に1回のみ実行し、完了まで他のすべてを開始させない」。
// ゲート待機は SerialTaskQueue へ投入する前に行う（キュー内で待つと復旧側の操作がキューを
// 取れず自己デッドロックするため。docs/superpowers/specs/2026-08-10-issue7-task12.md 警告1）。
// FakeRecoveryGate で復旧未完了を模し、start系メソッドが store 呼び出しへ進まないことを
// 検証する（StartupRecoveryTests.swift の awaitRecoveryCompletedBlocksUntilRecoveryFinishes と
// 同じ「Task.yield で進行猶予を与えて未達を確認する」方針）。

private func makeCoordinator(
    exportSagaStore: ExportSagaStore,
    workingSourceStore: WorkingSourceStore = FakeWorkingSourceStore(),
    managedFileStore: ManagedFileStore = FakeManagedFileStore(),
    recoveryGate: RecoveryGate = FakeRecoveryGate()
) -> ExportCoordinator {
    ExportCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        stampCatalog: FakeStampCatalog(),
        imageEffectRenderer: FakeImageEffectRenderer(),
        imageEncoder: FakeImageEncoder(),
        outputFileVerifier: FakeOutputFileVerifier(defaultOutcome: .success(makeVerifiedOutputMeasurement())),
        outputDeliveryStore: FakeOutputDeliveryStore(now: makeFixedClock()),
        now: makeFixedClock(),
        queue: SerialTaskQueue(),
        exportedSettingsEntryStore: FakeExportedSettingsEntryStore(),
        settingsHashDigest: FakeSha256Digest(),
        recoveryGate: recoveryGate
    )
}

private func makeWorkingSourceFileRef() throws -> WorkingSourceFileRef {
    let ref = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))
    return try #require(WorkingSourceFileRef(ref))
}

private func startedJob(_ outcome: ExportStartOutcome) -> ExportJob? {
    if case .started(let job) = outcome { return job }
    return nil
}

private func startedBatchJob(_ outcome: BatchItemStartOutcome) -> ExportJob? {
    if case .started(let job) = outcome { return job }
    return nil
}

/// 1.1・1.2 の両方を必ず通過する（renderSpec は regions 無しで能力を要求しない）標準リクエスト
/// （ExportCoordinatorStartTests.swift の makeFullyConsistentRequest と同じ定義。private のため
/// ファイル間で共有できず、ここでも定義する）。
private func makeFullyConsistentRequest() throws -> (request: SingleExportRequest, capabilities: ResolvedCapabilities) {
    let projectID = makeProjectID()
    let hash = try makePreviewRenderHash()
    let confirmation = PreviewConfirmation(projectID: projectID, detectionRevision: 5, previewRenderHash: hash)
    let request = SingleExportRequest(
        projectID: projectID,
        renderSpec: try makeRenderSpec(),
        exportSetting: makeExportSetting(),
        previewConfirmation: confirmation,
        currentDetectionRevision: 5,
        currentPreviewRenderHash: hash,
        isReviewed: true,
        expectedProjectRevision: 0
    )
    return (request, makeResolvedCapabilities())
}

@Test("復旧未完了の間はstartExportがstoreへ進まず、完了後に開始できる", .timeLimit(.minutes(1)))
private func startExportWaitsForRecoveryGateThenProceeds() async throws {
    let (request, capabilities) = try makeFullyConsistentRequest()
    let sourceFileRef = try makeWorkingSourceFileRef()
    let workingSourceStore = FakeWorkingSourceStore()
    await workingSourceStore.seedWorkingSource(
        WorkingSourceRecord(
            projectID: request.projectID,
            sourceFile: sourceFileRef,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    )
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.seedExistingFile(sourceFileRef.ref)
    let exportID = makeExportID()
    let expectedJob = makeExportJob(exportID: exportID, projectID: request.projectID)
    let exportSagaStore = FakeExportSagaStore(startExportHandler: { _, _ in .authorized(expectedJob) })
    let gate = FakeRecoveryGate(isOpen: false)
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        recoveryGate: gate
    )

    let task = Task { try await coordinator.startExport(request, capabilities: capabilities) }
    for _ in 0..<5 { await Task.yield() }
    #expect(await exportSagaStore.startExportCalls.isEmpty)
    #expect(await workingSourceStore.loadWorkingSourceCalls.isEmpty)

    await gate.open()
    let outcome = try await task.value

    #expect(startedJob(outcome)?.exportID == exportID)
}

// S-3（Task 12 再レビュー）: FakeRecoveryGate は withCheckedContinuation（非 throwing・
// キャンセルハンドラ無し）のままで、キャンセルにも失敗確定にも応答しなかった。そのため
// 「ゲート待ち中にタスクがキャンセルされたとき、変更系操作が CancellationError で正しく抜けるか」
// がどのテストでも検証されていなかった。本物の StartupRecoveryCoordinator と同じ契約に
// 合わせた FakeRecoveryGate（withCheckedThrowingContinuation + withTaskCancellationHandler）を
// 使い、startExport 経路で最低限この挙動を固定する。
@Test(
    "ゲート待ち中にstartExportがキャンセルされると、待たされたままにならずCancellationErrorで抜ける",
    .timeLimit(.minutes(1))
)
private func startExportCancelledWhileWaitingForGateThrowsCancellationError() async throws {
    let (request, capabilities) = try makeFullyConsistentRequest()
    let exportSagaStore = FakeExportSagaStore()
    let gate = FakeRecoveryGate(isOpen: false)
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore, recoveryGate: gate)

    let task = Task { try await coordinator.startExport(request, capabilities: capabilities) }
    for _ in 0..<5 { await Task.yield() }
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    #expect(await exportSagaStore.startExportCalls.isEmpty)
}

@Test("復旧未完了の間はstartBatchItemがstoreへ進まず、完了後に開始できる", .timeLimit(.minutes(1)))
private func startBatchItemWaitsForRecoveryGateThenProceeds() async throws {
    let batchID = makeBatchID()
    let projectID = makeProjectID()
    let hash = try makePreviewRenderHash()
    let confirmation = PreviewConfirmation(projectID: projectID, detectionRevision: 5, previewRenderHash: hash)
    let request = SingleExportRequest(
        projectID: projectID,
        renderSpec: try makeRenderSpec(),
        exportSetting: makeExportSetting(),
        previewConfirmation: confirmation,
        currentDetectionRevision: 5,
        currentPreviewRenderHash: hash,
        isReviewed: true,
        expectedProjectRevision: 0
    )
    let item = BatchExportItemRequest(
        batchID: batchID,
        queueItemID: ExportQueueItemID(rawValue: UUID()),
        mode: .perPhoto,
        batchReviewState: BatchReviewState(batchID: batchID, overviewConfirmed: true),
        request: request
    )
    let sourceFileRef = try makeWorkingSourceFileRef()
    let workingSourceStore = FakeWorkingSourceStore()
    await workingSourceStore.seedWorkingSource(
        WorkingSourceRecord(
            projectID: projectID, sourceFile: sourceFileRef, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    )
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.seedExistingFile(sourceFileRef.ref)
    let expectedJob = makeExportJob(exportID: makeExportID(), projectID: projectID, batchID: batchID)
    let exportSagaStore = FakeExportSagaStore(startExportHandler: { _, _ in .authorized(expectedJob) })
    let gate = FakeRecoveryGate(isOpen: false)
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        recoveryGate: gate
    )

    let task = Task { try await coordinator.startBatchItem(item, capabilities: makeResolvedCapabilities()) }
    for _ in 0..<5 { await Task.yield() }
    #expect(await exportSagaStore.startExportCalls.isEmpty)
    #expect(await workingSourceStore.loadWorkingSourceCalls.isEmpty)

    await gate.open()
    let outcome = try await task.value

    #expect(startedBatchJob(outcome)?.exportID == expectedJob.exportID)
}
