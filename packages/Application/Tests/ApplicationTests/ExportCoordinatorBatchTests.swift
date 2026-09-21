import Foundation
import Testing
import Domain
@testable import Application

// ExportCoordinator.startBatchItem（Issue #7 Task 7「バッチ進行」+ 追補: batch-progression spec、
// 一括処理キュー簡素化 Issue #40 決定1）。
//
// 正本: export-saga.md 1.1（バッチの開始条件: BatchReviewState と モード別条件）・
// 1.5（開始後の権限変化: 有料契約の失効・月間上限への到達・昇格が起きても無視し、バッチ開始時の
// 認可スナップショットで全項目を完了させる）、architecture.md 6.4「一枚の失敗でバッチ全体を
// 停止しない」、test-plan.md 2.4 / 3.1 / :206。
//
// startBatchItem 自身は1写真分の認可・開始のみを担う（ExportCoordinator+Batch.swift 冒頭
// コメント参照）。「バッチ進行」は呼び出し元が写真を順番に呼ぶループのため、そのループを
// 模してテストする。itemFailed / itemPaused が次の写真の開始を妨げないことの検証は
// ファイル行数制約（Global Constraints）のため ExportCoordinatorBatchProgressionTests.swift
// に分離する（ExportCoordinatorStartTests.swift / StartBlockedTests.swift と同じ方針）。

// MARK: - BatchItemStartOutcome の判別ヘルパー（StartTests.swift と同じ方針）

private func isItemFailed(_ outcome: BatchItemStartOutcome) -> Bool {
    if case .itemFailed = outcome { return true }
    return false
}

private func startedJob(_ outcome: BatchItemStartOutcome) -> ExportJob? {
    if case .started(let job) = outcome { return job }
    return nil
}

// MARK: - フィクスチャ組み立て

private func makeCoordinator(
    exportSagaStore: ExportSagaStore,
    workingSourceStore: WorkingSourceStore = FakeWorkingSourceStore(),
    managedFileStore: ManagedFileStore = FakeManagedFileStore(),
    imageEffectRenderer: FakeImageEffectRenderer = FakeImageEffectRenderer(),
    imageEncoder: FakeImageEncoder = FakeImageEncoder(),
    outputFileVerifier: FakeOutputFileVerifier =
        FakeOutputFileVerifier(defaultOutcome: .success(makeVerifiedOutputMeasurement()))
) -> ExportCoordinator {
    ExportCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        stampCatalog: FakeStampCatalog(),
        imageEffectRenderer: imageEffectRenderer,
        imageEncoder: imageEncoder,
        outputFileVerifier: outputFileVerifier,
        outputDeliveryStore: FakeOutputDeliveryStore(now: makeFixedClock()),
        now: makeFixedClock(),
        queue: SerialTaskQueue(),
        exportedSettingsEntryStore: FakeExportedSettingsEntryStore(),
        settingsHashDigest: FakeSha256Digest(),
        recoveryGate: FakeRecoveryGate()
    )
}

/// processingTemporary 種別の WorkingSourceFileRef フィクスチャ（StartTests.swift と同じ定義。
/// private のためファイル間で共有できず、ここでも定義する）。
private func makeWorkingSourceFileRef() throws -> WorkingSourceFileRef {
    let ref = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))
    return try #require(WorkingSourceFileRef(ref))
}

/// 実体ファイルまで揃った WorkingSourceRecord を作り、指定した偽ストアへ seed する。
private func seedWorkingSource(
    projectID: ProjectID, workingSourceStore: FakeWorkingSourceStore, managedFileStore: FakeManagedFileStore
) async throws {
    let sourceFileRef = try makeWorkingSourceFileRef()
    await workingSourceStore.seedWorkingSource(
        WorkingSourceRecord(
            projectID: projectID, sourceFile: sourceFileRef, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    )
    await managedFileStore.seedExistingFile(sourceFileRef.ref)
}

/// 1.1・1.2 を通過する（renderSpec は regions 無し）標準のバッチ項目を組み立てる。
/// mode / overviewConfirmed / isReviewed / batchReviewState の batchID をテストごとに差し替える。
private func makeBatchItem(
    batchID: BatchID,
    mode: BatchReviewMode,
    reviewStateBatchID: BatchID? = nil,
    overviewConfirmed: Bool = true,
    isReviewed: Bool = true,
    renderSpec: RenderSpec? = nil
) throws -> BatchExportItemRequest {
    let projectID = makeProjectID()
    let hash = try makePreviewRenderHash()
    let confirmation = PreviewConfirmation(projectID: projectID, detectionRevision: 5, previewRenderHash: hash)
    let request = SingleExportRequest(
        projectID: projectID,
        renderSpec: try renderSpec ?? makeRenderSpec(),
        exportSetting: makeExportSetting(),
        previewConfirmation: confirmation,
        currentDetectionRevision: 5,
        currentPreviewRenderHash: hash,
        isReviewed: isReviewed,
        expectedProjectRevision: 0
    )
    let reviewState = BatchReviewState(
        batchID: reviewStateBatchID ?? batchID, overviewConfirmed: overviewConfirmed
    )
    return BatchExportItemRequest(
        batchID: batchID,
        mode: mode,
        batchReviewState: reviewState,
        request: request
    )
}

// MARK: - 1.1 モード別の開始条件

@Test("おまかせ一括はoverviewConfirmed==trueなら開始する（isReviewedはfalseでもよい）")
private func overviewModeStartsWhenOverviewConfirmedTrue() async throws {
    let batchID = makeBatchID()
    let item = try makeBatchItem(batchID: batchID, mode: .overview, overviewConfirmed: true, isReviewed: false)
    let workingSourceStore = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    try await seedWorkingSource(
        projectID: item.request.projectID, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )
    let exportSagaStore = FakeExportSagaStore()
    _ = try await createAuthorizedBatch(exportSagaStore, batchID: batchID)
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )

    let outcome = try await coordinator.startBatchItem(item, capabilities: makeResolvedCapabilities())

    #expect(startedJob(outcome)?.batchID == batchID)
}

@Test("おまかせ一括はoverviewConfirmed==falseならconfirmationMismatchで開始しない")
private func overviewModeBlocksWhenOverviewConfirmedFalse() async throws {
    let batchID = makeBatchID()
    let item = try makeBatchItem(batchID: batchID, mode: .overview, overviewConfirmed: false, isReviewed: true)
    let exportSagaStore = FakeExportSagaStore()
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore)

    let outcome = try await coordinator.startBatchItem(item, capabilities: makeResolvedCapabilities())

    #expect(isItemFailed(outcome))
    let startExportCalls = await exportSagaStore.startExportCalls
    #expect(startExportCalls.isEmpty)
}

@Test("1枚ずつ確認はisReviewed==trueなら開始する（overviewConfirmedはfalseでもよい）")
private func perPhotoModeStartsWhenIsReviewedTrue() async throws {
    let batchID = makeBatchID()
    let item = try makeBatchItem(batchID: batchID, mode: .perPhoto, overviewConfirmed: false, isReviewed: true)
    let workingSourceStore = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    try await seedWorkingSource(
        projectID: item.request.projectID, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )
    let exportSagaStore = FakeExportSagaStore()
    _ = try await createAuthorizedBatch(exportSagaStore, batchID: batchID)
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )

    let outcome = try await coordinator.startBatchItem(item, capabilities: makeResolvedCapabilities())

    #expect(startedJob(outcome)?.batchID == batchID)
}

@Test("1枚ずつ確認はisReviewed==falseならconfirmationMismatchで開始しない（reviewRequired かつ unreviewed）")
private func perPhotoModeBlocksWhenIsReviewedFalse() async throws {
    let batchID = makeBatchID()
    let item = try makeBatchItem(batchID: batchID, mode: .perPhoto, overviewConfirmed: true, isReviewed: false)
    let exportSagaStore = FakeExportSagaStore()
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore)

    let outcome = try await coordinator.startBatchItem(item, capabilities: makeResolvedCapabilities())

    #expect(isItemFailed(outcome))
    let startExportCalls = await exportSagaStore.startExportCalls
    #expect(startExportCalls.isEmpty)
}

@Test("BatchReviewState.batchIDが対象バッチと不一致なら、モードに関わらずconfirmationMismatchになる")
private func batchReviewStateBatchIDMismatchBlocksRegardlessOfMode() async throws {
    let batchID = makeBatchID()
    let otherBatchID = makeBatchID()
    let item = try makeBatchItem(
        batchID: batchID, mode: .overview, reviewStateBatchID: otherBatchID, overviewConfirmed: true
    )
    let exportSagaStore = FakeExportSagaStore()
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore)

    let outcome = try await coordinator.startBatchItem(item, capabilities: makeResolvedCapabilities())

    #expect(isItemFailed(outcome))
    let startExportCalls = await exportSagaStore.startExportCalls
    #expect(startExportCalls.isEmpty)
}

// MARK: - 1.2 能力検査・batchID の受け渡し
//
// itemFailed / itemPaused / confirmationMismatch がバッチを止めないことの検証は
// ExportCoordinatorBatchProgressionTests.swift に分離する（ファイル行数制約）。

@Test("全条件が成立する場合、StartExportInputへbatchIDが渡りExportJobを挿入する")
private func fullyAuthorizedBatchItemPassesBatchID() async throws {
    let batchID = makeBatchID()
    let item = try makeBatchItem(batchID: batchID, mode: .perPhoto, isReviewed: true)
    let workingSourceStore = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    try await seedWorkingSource(
        projectID: item.request.projectID, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )
    let exportSagaStore = FakeExportSagaStore()
    _ = try await createAuthorizedBatch(exportSagaStore, batchID: batchID)
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )

    let outcome = try await coordinator.startBatchItem(item, capabilities: makeResolvedCapabilities())

    #expect(startedJob(outcome)?.batchID == batchID)
    let startExportCalls = await exportSagaStore.startExportCalls
    #expect(startExportCalls.count == 1)
    #expect(startExportCalls.first?.input.batchID == batchID)
}

// MARK: - 直列1件（ADR 0005）・1.5 開始後の権限変化

@Test(
    "並列に処理した複数のバッチ項目でも、同時に処理中のExportJobは常に1件までである",
    .timeLimit(.minutes(1))
)
private func concurrentBatchItemsNeverOverlapInProcessing() async throws {
    let batchID = makeBatchID()
    let workingSourceStore = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    let items = try (0..<5).map { _ -> BatchExportItemRequest in
        try makeBatchItem(batchID: batchID, mode: .perPhoto, isReviewed: true)
    }
    for item in items {
        try await seedWorkingSource(
            projectID: item.request.projectID,
            workingSourceStore: workingSourceStore,
            managedFileStore: managedFileStore
        )
    }
    let exportSagaStore = FakeExportSagaStore()
    _ = try await createAuthorizedBatch(exportSagaStore, batchID: batchID)
    let pipeline = makeSucceedingGenerationPipeline()
    await pipeline.renderer.setResult(pipeline.rendered)
    await pipeline.renderer.setDelayNanoseconds(2_000_000)
    await pipeline.encoder.setResult(pipeline.encoded)
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        imageEffectRenderer: pipeline.renderer,
        imageEncoder: pipeline.encoder,
        outputFileVerifier: pipeline.verifier
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
        for item in items {
            group.addTask {
                let outcome = try await coordinator.startBatchItem(item, capabilities: makeResolvedCapabilities())
                let job = try #require(startedJob(outcome))
                try await coordinator.generateOutput(try makeGenerateExportInput(job: job))
            }
        }
        try await group.waitForAll()
    }

    #expect(await pipeline.renderer.maxObservedConcurrency == 1)
}

@Test("先行項目の開始後に契約の失効が起きても無視され、waitingの写真もバッチ開始時の認可スナップショットのまま生成を完了する")
private func batchItemsCompleteWithStartSnapshotDespitePermissionLossAfterFirstStarts() async throws {
    let batchID = makeBatchID()
    let runningItem = try makeBatchItem(batchID: batchID, mode: .perPhoto, isReviewed: true)
    let waitingItem = try makeBatchItem(batchID: batchID, mode: .perPhoto, isReviewed: true)
    let workingSourceStore = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    try await seedWorkingSource(
        projectID: runningItem.request.projectID,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore
    )
    try await seedWorkingSource(
        projectID: waitingItem.request.projectID,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore
    )
    let exportSagaStore = FakeExportSagaStore()
    // createBatch がバッチ開始時点の認可を Batch 行へ固定する（一括処理キュー簡素化
    // Issue #40 決定2）。startExport のバッチ経路（FakeExportSagaStore.swift）はこの
    // batchAuthorizations を読むだけで startExportHandler を呼ばず再評価しない。
    // 「先行項目の開始後に契約の失効・月間上限到達・昇格が起きても無視する」（1.5）は
    // Fake の分岐ロジックではなく、この固定済み認可がそのまま両方の項目へ使われる
    // ことによって表現される。
    let fixedAuthorization = try await createAuthorizedBatch(exportSagaStore, batchID: batchID)
    let pipeline = makeSucceedingGenerationPipeline()
    await pipeline.renderer.setResult(pipeline.rendered)
    await pipeline.encoder.setResult(pipeline.encoded)
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        imageEffectRenderer: pipeline.renderer,
        imageEncoder: pipeline.encoder,
        outputFileVerifier: pipeline.verifier
    )

    let runningOutcome = try await coordinator.startBatchItem(runningItem, capabilities: makeResolvedCapabilities())
    let job = try #require(startedJob(runningOutcome))
    try await coordinator.generateOutput(try makeGenerateExportInput(job: job))

    // ここで契約の失効・月間上限への到達・昇格が起きたとしても、1.5「バッチ開始時の認可
    // スナップショットで全項目を完了させる」により waitingItem も started で開始できる
    // （createBatch 後は Fake の startExport バッチ経路が固定済み認可しか参照しないため、
    // capabilities の再評価が構造的に起こり得ない）。
    let waitingOutcome = try await coordinator.startBatchItem(waitingItem, capabilities: makeResolvedCapabilities())
    let waitingStartedJob = try #require(startedJob(waitingOutcome))
    try await coordinator.generateOutput(try makeGenerateExportInput(job: waitingStartedJob))

    #expect(job.authorization.authorizedAt == fixedAuthorization.authorizedAt)
    #expect(waitingStartedJob.authorization.authorizedAt == fixedAuthorization.authorizedAt)
    #expect(waitingStartedJob.authorization.accountingMode == fixedAuthorization.accountingMode)
    let recordCalls = await exportSagaStore.recordGeneratedOutputCalls
    #expect(Set(recordCalls.map(\.exportID)) == Set([job.exportID, waitingStartedJob.exportID]))
}

// 実体確認（WorkingSourceRecord 行欠損 / 実体ファイル欠損）・revision 不一致のバッチ経路検証は
// ファイル行数制約（Global Constraints）のため ExportCoordinatorBatchStartConditionTests.swift
// へ分離する（ExportCoordinatorBatchProgressionTests.swift と同じ方針）。
