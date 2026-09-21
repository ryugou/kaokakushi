import Foundation
import Testing
import Domain
@testable import Application

// ExportCoordinator.startBatchItem — 実体確認（WorkingSourceRecord 行欠損 / 実体ファイル欠損）・
// revision 不一致のバッチ経路検証（一括処理キュー簡素化 Issue #40）。
//
// 正本: export-saga.md 1.6 手順3（行自体が存在しない場合は invalidateWorkingSource を呼ばず
// itemFailed。行はあるが実体ファイルが無ければ invalidateWorkingSource を呼び itemPaused）・
// 手順5（expectedProjectRevision 不一致は throw ではなく itemFailed）。
//
// ExportCoordinatorBatchTests.swift のファイル行数制約（Global Constraints）のため、この3観点を
// このファイルへ分離する（ExportCoordinatorBatchProgressionTests.swift と同じ方針）。

// MARK: - BatchItemStartOutcome の判別ヘルパー（BatchTests.swift と同じ方針。private のため共有できない）

private func isItemFailed(_ outcome: BatchItemStartOutcome) -> Bool {
    if case .itemFailed = outcome { return true }
    return false
}

private func isItemPaused(_ outcome: BatchItemStartOutcome) -> Bool {
    if case .itemPaused = outcome { return true }
    return false
}

private func startedJob(_ outcome: BatchItemStartOutcome) -> ExportJob? {
    if case .started(let job) = outcome { return job }
    return nil
}

// MARK: - フィクスチャ組み立て（BatchTests.swift と同じ定義。private のため共有できない）

private func makeCoordinator(
    exportSagaStore: ExportSagaStore,
    workingSourceStore: WorkingSourceStore = FakeWorkingSourceStore(),
    managedFileStore: ManagedFileStore = FakeManagedFileStore(),
    stampCatalog: StampCatalog = FakeStampCatalog()
) -> ExportCoordinator {
    ExportCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        stampCatalog: stampCatalog,
        imageEffectRenderer: FakeImageEffectRenderer(),
        imageEncoder: FakeImageEncoder(),
        outputFileVerifier: FakeOutputFileVerifier(defaultOutcome: .success(makeVerifiedOutputMeasurement())),
        outputDeliveryStore: FakeOutputDeliveryStore(now: makeFixedClock()),
        now: makeFixedClock(),
        queue: SerialTaskQueue(),
        exportedSettingsEntryStore: FakeExportedSettingsEntryStore(),
        settingsHashDigest: FakeSha256Digest(),
        recoveryGate: FakeRecoveryGate()
    )
}

/// processingTemporary 種別の WorkingSourceFileRef フィクスチャ（BatchTests.swift と同じ定義。
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
/// expectedProjectRevision はこのファイルの revision 不一致テストのためだけに差し替え可能にする
/// （既定 0。BatchTests.swift の makeBatchItem とは差し替え可能パラメータの集合が異なるため
/// 別定義とする）。
private func makeBatchItem(
    batchID: BatchID,
    mode: BatchReviewMode,
    expectedProjectRevision: Int64 = 0
) throws -> BatchExportItemRequest {
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
        expectedProjectRevision: expectedProjectRevision
    )
    let reviewState = BatchReviewState(batchID: batchID, overviewConfirmed: true)
    return BatchExportItemRequest(
        batchID: batchID,
        mode: mode,
        batchReviewState: reviewState,
        request: request
    )
}

// MARK: - 実体確認（WorkingSourceRecord 行欠損 / 実体ファイル欠損）・revision 不一致

@Test("WorkingSourceRecordの行自体が無ければitemFailedを返しinvalidateWorkingSourceは呼ばれず、バッチは継続する")
private func missingWorkingSourceRowReturnsItemFailedWithoutInvalidatingAndBatchContinues() async throws {
    // export-saga.md 1.6 手順3: 行自体が無い場合は再選択で復帰できないため
    // invalidateWorkingSource を呼ばない（単体の ExportStartOutcome.sourceRowMissing と
    // 同じ判定。バッチでは throw せず itemFailed としてこの項目だけを終了させる）。
    let batchID = makeBatchID()
    let missingRowItem = try makeBatchItem(batchID: batchID, mode: .overview)
    let nextItem = try makeBatchItem(batchID: batchID, mode: .overview)
    let workingSourceStore = FakeWorkingSourceStore() // missingRowItem は seed しない → 行自体が無い
    let managedFileStore = FakeManagedFileStore()
    try await seedWorkingSource(
        projectID: nextItem.request.projectID,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore
    )
    let exportSagaStore = FakeExportSagaStore()
    _ = try await createAuthorizedBatch(exportSagaStore, batchID: batchID)
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )

    let missingOutcome = try await coordinator.startBatchItem(missingRowItem, capabilities: makeResolvedCapabilities())
    let nextOutcome = try await coordinator.startBatchItem(nextItem, capabilities: makeResolvedCapabilities())

    #expect(isItemFailed(missingOutcome))
    let invalidateCalls = await workingSourceStore.invalidateWorkingSourceCalls
    #expect(invalidateCalls.isEmpty)
    #expect(startedJob(nextOutcome) != nil)
}

@Test("WorkingSourceRecordの行はあるが実体ファイルが無ければitemPausedを返しinvalidateWorkingSourceが呼ばれ、バッチは継続する")
private func missingWorkingSourceFileReturnsItemPausedAndBatchContinues() async throws {
    let batchID = makeBatchID()
    let missingFileItem = try makeBatchItem(batchID: batchID, mode: .overview)
    let nextItem = try makeBatchItem(batchID: batchID, mode: .overview)
    let sourceFileRef = try makeWorkingSourceFileRef()
    let workingSourceStore = FakeWorkingSourceStore()
    await workingSourceStore.seedWorkingSource(
        WorkingSourceRecord(
            projectID: missingFileItem.request.projectID,
            sourceFile: sourceFileRef,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    )
    let managedFileStore = FakeManagedFileStore() // ref を seed しない → 実体欠損
    try await seedWorkingSource(
        projectID: nextItem.request.projectID,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore
    )
    let exportSagaStore = FakeExportSagaStore()
    _ = try await createAuthorizedBatch(exportSagaStore, batchID: batchID)
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )

    let missingOutcome = try await coordinator.startBatchItem(missingFileItem, capabilities: makeResolvedCapabilities())
    let nextOutcome = try await coordinator.startBatchItem(nextItem, capabilities: makeResolvedCapabilities())

    #expect(isItemPaused(missingOutcome))
    let invalidateCalls = await workingSourceStore.invalidateWorkingSourceCalls
    #expect(invalidateCalls == [missingFileItem.request.projectID])
    #expect(startedJob(nextOutcome) != nil)
}

@Test("expectedProjectRevision不一致の項目はthrowで上位へ伝播せずitemFailedを返し、バッチは継続する")
private func staleProjectRevisionReturnsItemFailedAndBatchContinues() async throws {
    let batchID = makeBatchID()
    let staleItem = try makeBatchItem(batchID: batchID, mode: .overview, expectedProjectRevision: 1)
    let nextItem = try makeBatchItem(batchID: batchID, mode: .overview)
    let workingSourceStore = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    for item in [staleItem, nextItem] {
        try await seedWorkingSource(
            projectID: item.request.projectID,
            workingSourceStore: workingSourceStore,
            managedFileStore: managedFileStore
        )
    }
    let exportSagaStore = FakeExportSagaStore()
    _ = try await createAuthorizedBatch(exportSagaStore, batchID: batchID)
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )

    // FakeExportSagaStore は projectRevisions 未設定の projectID を revision 0 として扱う
    // （Fakes/FakeExportSagaStore.swift 冒頭コメント）。staleItem の expectedProjectRevision: 1
    // は不一致となり ExportStartDecision.staleProjectRevision → itemFailed に写像される
    // （throw しない。export-saga.md 1.6 手順5・BatchTests.swift 冒頭コメントの itemFailed 定義）。
    let staleOutcome = try await coordinator.startBatchItem(staleItem, capabilities: makeResolvedCapabilities())
    let nextOutcome = try await coordinator.startBatchItem(nextItem, capabilities: makeResolvedCapabilities())

    #expect(isItemFailed(staleOutcome))
    #expect(startedJob(nextOutcome) != nil)
}

// MARK: - createBatch未呼び出し（batchNotFoundの伝播）

@Test("createBatchを呼んでいないbatchIDでstartBatchItemを呼ぶと、batchNotFoundが呼び出し元まで伝播する")
private func missingBatchAuthorizationPropagatesBatchNotFoundToCaller() async throws {
    // authorizeAndStart（ExportCoordinator.swift）は exportSagaStore.startExport の throw を
    // catch せずそのまま伝播させる契約（Global Constraints「エラーの握りつぶし禁止」）。
    // createBatch を一度も呼んでいない batchID は batchAuthorizations に固定済み認可が無く、
    // 本物の ExportSagaStoreLive と同じ契約で FakeExportSagaStoreError.batchNotFound が
    // throw される（reviewer指摘 W-3）。
    let batchID = makeBatchID()
    let item = try makeBatchItem(batchID: batchID, mode: .overview)
    let workingSourceStore = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    try await seedWorkingSource(
        projectID: item.request.projectID, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )
    let exportSagaStore = FakeExportSagaStore()
    // createBatch を意図的に呼ばない。
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )

    await #expect(throws: FakeExportSagaStoreError.batchNotFound(batchID)) {
        _ = try await coordinator.startBatchItem(item, capabilities: makeResolvedCapabilities())
    }
}
