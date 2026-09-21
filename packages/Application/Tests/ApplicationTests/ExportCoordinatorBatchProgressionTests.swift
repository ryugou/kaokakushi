import Foundation
import Testing
import Domain
@testable import Application

// ExportCoordinator.startBatchItem — 1項目の帰結がバッチ全体を止めないことの検証
// （Issue #7 Task 7 追補。正本は下記の architecture.md 6.4・export-saga.md 1.5 のとおり。
// 一括処理キュー簡素化 Issue #40 決定1）。
//
// 正本: architecture.md 6.4「一枚の失敗でバッチ全体を停止しない」、export-saga.md 1.5
// （開始後に有料契約の失効・月間上限への到達・昇格が起きても無視し、バッチ開始時の認可
// スナップショットで全項目を完了させる＝バッチ全体を止める特別なケースは存在しない）、
// Domain/Queue/QueueMachine.swift の queueStateAfterAuthorization（1.2 の能力ブロックの
// 判定にのみ使う）。
//
// ExportCoordinatorBatchTests.swift のファイル行数制約（Global Constraints）のため、
// itemFailed / itemPaused がバッチを継続させることの検証のみをこのファイルへ分離する
// （StartTests.swift / StartBlockedTests.swift と同じ方針）。1.1 のモード別条件・直列1件は
// ExportCoordinatorBatchTests.swift が担う。

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
private func makeBatchItem(
    batchID: BatchID,
    mode: BatchReviewMode,
    overviewConfirmed: Bool = true,
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
        isReviewed: true,
        expectedProjectRevision: 0
    )
    let reviewState = BatchReviewState(batchID: batchID, overviewConfirmed: overviewConfirmed)
    return BatchExportItemRequest(
        batchID: batchID,
        mode: mode,
        batchReviewState: reviewState,
        request: request
    )
}

// MARK: - 1.2 能力ブロック（itemFailed）

@Test("1.2能力検査がblockedならitemFailedを返し、次の写真の開始は妨げられない")
private func capabilityBlockedItemDoesNotStopSubsequentItems() async throws {
    let batchID = makeBatchID()
    let firstItem = try makeBatchItem(batchID: batchID, mode: .overview)
    let premiumRenderSpec = try makeRenderSpec(regions: [try makeBuiltInStampRegion(code: "seasonal-cat")])
    let blockedItem = try makeBatchItem(batchID: batchID, mode: .overview, renderSpec: premiumRenderSpec)
    let thirdItem = try makeBatchItem(batchID: batchID, mode: .overview)
    let workingSourceStore = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    for item in [firstItem, thirdItem] {
        try await seedWorkingSource(
            projectID: item.request.projectID,
            workingSourceStore: workingSourceStore,
            managedFileStore: managedFileStore
        )
    }
    let exportSagaStore = FakeExportSagaStore()
    _ = try await createAuthorizedBatch(exportSagaStore, batchID: batchID)
    let catalog = FakeStampCatalog(requirementsByCode: ["seasonal-cat": .premium(packID: "seasonal")])
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        stampCatalog: catalog
    )
    let capabilities = makeResolvedCapabilities(canUsePremiumStamps: false)

    let firstOutcome = try await coordinator.startBatchItem(firstItem, capabilities: capabilities)
    let blockedOutcome = try await coordinator.startBatchItem(blockedItem, capabilities: capabilities)
    let thirdOutcome = try await coordinator.startBatchItem(thirdItem, capabilities: capabilities)

    #expect(startedJob(firstOutcome) != nil)
    #expect(isItemFailed(blockedOutcome))
    #expect(startedJob(thirdOutcome) != nil)
    #expect(await exportSagaStore.startExportCalls.count == 2)
}

// MARK: - 実体欠損（itemPaused）

@Test("実体欠損の項目はitemPausedになりinvalidateWorkingSourceが呼ばれ、バッチは継続する")
private func missingWorkingSourceReturnsItemPausedAndBatchContinues() async throws {
    // 「実体欠損」= WorkingSourceRecord の行はあるが実体ファイルが無い経路（export-saga.md
    // 1.6 手順3）。行自体が無い経路は itemFailed に写像され invalidateWorkingSource を
    // 呼ばないため区別する（ExportCoordinatorBatchStartConditionTests.swift 参照）。
    let batchID = makeBatchID()
    let missingItem = try makeBatchItem(batchID: batchID, mode: .overview)
    let nextItem = try makeBatchItem(batchID: batchID, mode: .overview)
    let sourceFileRef = try makeWorkingSourceFileRef()
    let workingSourceStore = FakeWorkingSourceStore()
    await workingSourceStore.seedWorkingSource(
        WorkingSourceRecord(
            projectID: missingItem.request.projectID,
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
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore
    )

    let missingOutcome = try await coordinator.startBatchItem(missingItem, capabilities: makeResolvedCapabilities())
    let nextOutcome = try await coordinator.startBatchItem(nextItem, capabilities: makeResolvedCapabilities())

    #expect(isItemPaused(missingOutcome))
    #expect(await workingSourceStore.invalidateWorkingSourceCalls == [missingItem.request.projectID])
    #expect(startedJob(nextOutcome) != nil)
}

// MARK: - 1.1 確認不一致（非開始でもバッチ継続）

@Test("確認不一致の項目は非開始でもバッチは継続する")
private func confirmationMismatchDoesNotStopBatch() async throws {
    let batchID = makeBatchID()
    let mismatchedItem = try makeBatchItem(batchID: batchID, mode: .overview, overviewConfirmed: false)
    let nextItem = try makeBatchItem(batchID: batchID, mode: .overview)
    let workingSourceStore = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    try await seedWorkingSource(
        projectID: nextItem.request.projectID,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore
    )
    let exportSagaStore = FakeExportSagaStore()
    _ = try await createAuthorizedBatch(exportSagaStore, batchID: batchID)
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore
    )

    let mismatchOutcome = try await coordinator.startBatchItem(mismatchedItem, capabilities: makeResolvedCapabilities())
    let nextOutcome = try await coordinator.startBatchItem(nextItem, capabilities: makeResolvedCapabilities())

    #expect(isItemFailed(mismatchOutcome))
    #expect(startedJob(nextOutcome) != nil)
}

// 1.3 の権限・クォータ評価はバッチ項目ごとに再評価されない（export-saga.md 1.6 手順4:
// バッチ項目の startExport は評価せず、Batch 行に固定された認可をそのまま ExportJob.authorization
// へコピーする。ExportStartDecision.blocked は batchID == nil の呼び出しでのみ返り、バッチ項目
// では起こらない）。「バッチ項目単位で1.3がblockedになり、それでもバッチが継続する」という
// シナリオはこの契約と構造的に矛盾するため削除した。1.3のブロックはバッチ全体＝createBatch
// 時点で一度だけ発生し、その検証は Persistence 層の ExportSagaStoreCreateBatchTests.swift が
// 担う（Application 層は createBatch 自体を呼ぶ公開 API を持たないためスコープ外）。
