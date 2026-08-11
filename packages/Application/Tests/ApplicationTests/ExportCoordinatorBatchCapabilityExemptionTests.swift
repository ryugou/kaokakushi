import Foundation
import Testing
import Domain
@testable import Application

// ExportCoordinator.startBatchItem — 「変更せず再書き出し」の能力免除のバッチ経路への適用
// （Issue #7 レビュー第2ラウンド C）。
//
// 正本: export-saga.md 1.2「変更せず再書き出しの免除」の表（単体／バッチを区別しない）、
// ExportCoordinatorCapabilityExemptionTests.swift（単体側の同じ検証。本ファイルはその
// バッチ版）。免除の条件（確定記録の存在・設定の一致・同一 Project）は単体と共有する
// isExemptFromCapabilityBlock をそのまま使うため、ここでは免除成立・不成立の分岐が
// バッチ経路でも同じ結果になることのみを検証する。

// MARK: - BatchItemStartOutcome の判別ヘルパー（BatchTests.swift と同じ方針。private のため共有できない）

private func itemFailedQueueState(_ outcome: BatchItemStartOutcome) -> ExportQueueState? {
    if case .itemFailed(let state) = outcome { return state }
    return nil
}

private func startedJob(_ outcome: BatchItemStartOutcome) -> ExportJob? {
    if case .started(let job) = outcome { return job }
    return nil
}

// MARK: - フィクスチャ組み立て

private func makeCoordinator(
    exportSagaStore: ExportSagaStore,
    workingSourceStore: WorkingSourceStore,
    managedFileStore: ManagedFileStore,
    stampCatalog: StampCatalog,
    exportedSettingsEntryStore: ExportedSettingsEntryStore,
    settingsHashDigest: Sha256Digest = FakeSha256Digest()
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
        exportedSettingsEntryStore: exportedSettingsEntryStore,
        settingsHashDigest: settingsHashDigest,
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

/// premium スタンプ1件を使う RenderSpec と、それを premium として分類する StampCatalog、
/// premium スタンプ能力を持たない（Pro 失効後を模した）ResolvedCapabilities の組
/// （ExportCoordinatorCapabilityExemptionTests.swift の DowngradedPremiumStampScenario と同じ方針）。
private struct DowngradedPremiumStampScenario {
    let renderSpec: RenderSpec
    let catalog: FakeStampCatalog
    let capabilities: ResolvedCapabilities
}

private func makeDowngradedPremiumStampScenario(
    code: String = "seasonal-cat"
) throws -> DowngradedPremiumStampScenario {
    let renderSpec = try makeRenderSpec(regions: [try makeBuiltInStampRegion(code: code)])
    let catalog = FakeStampCatalog(requirementsByCode: [code: .premium(packID: "seasonal")])
    let capabilities = makeResolvedCapabilities(canUsePremiumStamps: false)
    return DowngradedPremiumStampScenario(renderSpec: renderSpec, catalog: catalog, capabilities: capabilities)
}

/// 1.1・BatchReviewState の一致を必ず通過するバッチ項目を、指定した renderSpec で組み立てる。
private func makeBatchItem(
    batchID: BatchID, renderSpec: RenderSpec
) throws -> BatchExportItemRequest {
    let projectID = makeProjectID()
    let hash = try makePreviewRenderHash()
    let confirmation = PreviewConfirmation(projectID: projectID, detectionRevision: 5, previewRenderHash: hash)
    let request = SingleExportRequest(
        projectID: projectID,
        renderSpec: renderSpec,
        exportSetting: makeExportSetting(),
        previewConfirmation: confirmation,
        currentDetectionRevision: 5,
        currentPreviewRenderHash: hash,
        isReviewed: true,
        expectedProjectRevision: 0
    )
    let reviewState = BatchReviewState(batchID: batchID, overviewConfirmed: true)
    return BatchExportItemRequest(
        batchID: batchID,
        queueItemID: ExportQueueItemID(rawValue: UUID()),
        mode: .overview,
        batchReviewState: reviewState,
        request: request
    )
}

// MARK: - 免除成立（Pro失効後・設定一致）

@Test("Pro失効後でも確定記録のsettingsHashが現在の設定と一致すれば、バッチ項目は免除されて開始できる")
private func exemptionAllowsBatchItemToStartWhenSettingsHashMatches() async throws {
    let scenario = try makeDowngradedPremiumStampScenario()
    let batchID = makeBatchID()
    let item = try makeBatchItem(batchID: batchID, renderSpec: scenario.renderSpec)

    let workingSourceStore = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    try await seedWorkingSource(
        projectID: item.request.projectID, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )

    let digest = FakeSha256Digest()
    let matchingHash = try projectSettingsHash(
        renderSpec: item.request.renderSpec, exportSetting: item.request.exportSetting, digest: digest
    )
    let entryStore = FakeExportedSettingsEntryStore()
    await entryStore.seedEntry(
        ExportedSettingsEntry(
            projectID: item.request.projectID,
            settingsHash: matchingHash,
            exportedAt: Date(timeIntervalSince1970: 1_699_000_000)
        )
    )

    let expectedJob = makeExportJob(exportID: makeExportID(), projectID: item.request.projectID, batchID: batchID)
    let exportSagaStore = FakeExportSagaStore(startExportHandler: { _, _ in .authorized(expectedJob) })
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        stampCatalog: scenario.catalog,
        exportedSettingsEntryStore: entryStore,
        settingsHashDigest: digest
    )

    let outcome = try await coordinator.startBatchItem(item, capabilities: scenario.capabilities)

    let job = try #require(startedJob(outcome))
    #expect(job.exportID == expectedJob.exportID)
    let startExportCalls = await exportSagaStore.startExportCalls
    #expect(startExportCalls.count == 1)
}

// MARK: - 免除不成立（確定記録なし）

@Test("確定記録が無ければバッチ項目は免除されずitemFailedになる")
private func missingEntryDoesNotExemptBatchItem() async throws {
    let scenario = try makeDowngradedPremiumStampScenario()
    let batchID = makeBatchID()
    let item = try makeBatchItem(batchID: batchID, renderSpec: scenario.renderSpec)

    let exportSagaStore = FakeExportSagaStore()
    let entryStore = FakeExportedSettingsEntryStore() // 何も seed しない → 確定記録が無い
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: FakeWorkingSourceStore(),
        managedFileStore: FakeManagedFileStore(),
        stampCatalog: scenario.catalog,
        exportedSettingsEntryStore: entryStore,
        settingsHashDigest: FakeSha256Digest()
    )

    let outcome = try await coordinator.startBatchItem(item, capabilities: scenario.capabilities)

    let expectedFailure = ExportQueueFailure(
        errorCode: .capabilityRequired, isRetryable: false, occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(itemFailedQueueState(outcome) == .failed(expectedFailure))
    let startExportCalls = await exportSagaStore.startExportCalls
    #expect(startExportCalls.isEmpty)
}

// MARK: - 免除成立後もaccountingModeの消費評価は通常どおりstartExportに委ねられる

@Test("バッチ項目の免除成立後もstartExportが呼ばれ、accountingModeの評価は通常どおりstoreに委ねられる")
private func exemptionStillDelegatesAccountingModeEvaluationForBatchItem() async throws {
    let scenario = try makeDowngradedPremiumStampScenario()
    let batchID = makeBatchID()
    let item = try makeBatchItem(batchID: batchID, renderSpec: scenario.renderSpec)

    let workingSourceStore = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    try await seedWorkingSource(
        projectID: item.request.projectID, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )

    let digest = FakeSha256Digest()
    let matchingHash = try projectSettingsHash(
        renderSpec: item.request.renderSpec, exportSetting: item.request.exportSetting, digest: digest
    )
    let entryStore = FakeExportedSettingsEntryStore()
    await entryStore.seedEntry(
        ExportedSettingsEntry(
            projectID: item.request.projectID,
            settingsHash: matchingHash,
            exportedAt: Date(timeIntervalSince1970: 1_699_000_000)
        )
    )

    // FakeExportSagaStore の既定ハンドラは .blocked(.monthlyLimitReached) を返す
    // （Fakes/FakeExportSagaStore.swift 冒頭コメント）。1.2 の能力ブロックを免除しても、
    // 1.3 のクォータ評価（accountingMode）は startExport 呼び出しを経て通常どおり働くことを示す。
    let exportSagaStore = FakeExportSagaStore()
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        stampCatalog: scenario.catalog,
        exportedSettingsEntryStore: entryStore,
        settingsHashDigest: digest
    )

    let outcome = try await coordinator.startBatchItem(item, capabilities: scenario.capabilities)

    guard case .batchPaused(let block) = outcome else {
        Issue.record("expected .batchPaused(monthlyLimitReached) but got \(outcome)")
        return
    }
    #expect(block.reason == .monthlyLimitReached)
    let startExportCalls = await exportSagaStore.startExportCalls
    #expect(startExportCalls.count == 1)
}
