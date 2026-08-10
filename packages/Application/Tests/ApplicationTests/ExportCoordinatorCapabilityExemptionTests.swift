import Foundation
import Testing
import Domain
@testable import Application

// ExportCoordinator.startExport — 「変更せず再書き出し」の能力免除（Issue #7 Task 10）。
//
// 正本: export-saga.md 1.2「変更せず再書き出しの免除」の表、architecture.md 6.2
// 「比較対象を台帳へ持つ」。
//
// 免除は authorizeRenderSpec が blocked を返した場合にのみ評価する。免除の適用範囲は
// 有料スタンプの能力要件のみであり、月間枠・トライアルクレジットの消費（accountingMode の
// 評価）は免除しない（従来どおり startExport に委ねる）。

// MARK: - ExportStartOutcome の判別ヘルパー（StartTests.swift と同じ方針。private のため共有できない）

private func renderSpecBlockReason(_ outcome: ExportStartOutcome) -> RenderSpecBlockReason? {
    if case .renderSpecBlocked(let reason) = outcome { return reason }
    return nil
}

private func startedJob(_ outcome: ExportStartOutcome) -> ExportJob? {
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

/// premium スタンプ1件を使う RenderSpec と、それを premium として分類する StampCatalog、
/// premium スタンプ能力を持たない（降格後）ResolvedCapabilities の組（large_tuple lint 回避
/// のため struct にまとめる。TestSupport.swift の SucceedingGenerationPipeline と同じ方針）。
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

/// 1.1・実体確認を必ず通過する標準リクエストを、指定した renderSpec / exportSetting で組み立てる。
private func makeRequest(
    renderSpec: RenderSpec,
    exportSetting: ExportSetting = makeExportSetting(),
    projectID: ProjectID = makeProjectID()
) throws -> SingleExportRequest {
    let hash = try makePreviewRenderHash()
    let confirmation = PreviewConfirmation(projectID: projectID, detectionRevision: 5, previewRenderHash: hash)
    return SingleExportRequest(
        projectID: projectID,
        renderSpec: renderSpec,
        exportSetting: exportSetting,
        previewConfirmation: confirmation,
        currentDetectionRevision: 5,
        currentPreviewRenderHash: hash,
        isReviewed: true,
        expectedProjectRevision: 0
    )
}

// MARK: - 免除成立（降格後・設定一致）

@Test("確定記録のsettingsHashが現在の設定と一致すれば1.2のblockedを免除しExportJobを挿入する")
private func exemptionAllowsStartWhenSettingsHashMatches() async throws {
    let scenario = try makeDowngradedPremiumStampScenario()
    let projectID = makeProjectID()
    let request = try makeRequest(renderSpec: scenario.renderSpec, projectID: projectID)

    let workingSourceStore = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    try await seedWorkingSource(
        projectID: projectID, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )

    let digest = FakeSha256Digest()
    let matchingHash = try projectSettingsHash(
        renderSpec: request.renderSpec, exportSetting: request.exportSetting, digest: digest
    )
    let entryStore = FakeExportedSettingsEntryStore()
    await entryStore.seedEntry(
        ExportedSettingsEntry(
            projectID: projectID, settingsHash: matchingHash, exportedAt: Date(timeIntervalSince1970: 1_699_000_000)
        )
    )

    let exportID = makeExportID()
    let expectedJob = makeExportJob(exportID: exportID, projectID: projectID)
    let exportSagaStore = FakeExportSagaStore(startExportHandler: { _, _ in .authorized(expectedJob) })

    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        stampCatalog: scenario.catalog,
        exportedSettingsEntryStore: entryStore,
        settingsHashDigest: digest
    )

    let outcome = try await coordinator.startExport(request, capabilities: scenario.capabilities)

    let job = try #require(startedJob(outcome))
    #expect(job.exportID == exportID)
    let loadEntryCalls = await entryStore.loadEntryCalls
    #expect(loadEntryCalls == [projectID])
    let startExportCalls = await exportSagaStore.startExportCalls
    #expect(startExportCalls.count == 1)
}

// MARK: - settingsHash不一致

@Test("確定記録はあるがsettingsHashが現在の設定と不一致なら免除せずrenderSpecBlockedのまま")
private func settingsHashMismatchDoesNotExempt() async throws {
    let scenario = try makeDowngradedPremiumStampScenario()
    let projectID = makeProjectID()
    let request = try makeRequest(renderSpec: scenario.renderSpec, projectID: projectID)

    let digest = FakeSha256Digest()
    // 異なる exportSetting から計算したハッシュを確定記録として登録し、意図的に不一致にする。
    let differentExportSetting = ExportSetting(
        outputAspect: .square,
        outputFormat: .jpeg,
        compressionQuality: 0.9,
        metadataPolicy: MetadataPolicy(
            removeLocation: true, removeDeviceInfo: true, removeSoftwareInfo: true, keepCaptureDate: true
        )
    )
    let mismatchedHash = try projectSettingsHash(
        renderSpec: request.renderSpec, exportSetting: differentExportSetting, digest: digest
    )
    let entryStore = FakeExportedSettingsEntryStore()
    await entryStore.seedEntry(
        ExportedSettingsEntry(
            projectID: projectID, settingsHash: mismatchedHash, exportedAt: Date(timeIntervalSince1970: 1_699_000_000)
        )
    )

    let exportSagaStore = FakeExportSagaStore()
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: FakeWorkingSourceStore(),
        managedFileStore: FakeManagedFileStore(),
        stampCatalog: scenario.catalog,
        exportedSettingsEntryStore: entryStore,
        settingsHashDigest: digest
    )

    let outcome = try await coordinator.startExport(request, capabilities: scenario.capabilities)

    #expect(renderSpecBlockReason(outcome) == .premiumStampNotAvailable)
    let startExportCalls = await exportSagaStore.startExportCalls
    #expect(startExportCalls.isEmpty)
}

// MARK: - 確定記録が無い

@Test("確定記録が無ければ免除せずrenderSpecBlockedのまま")
private func missingEntryDoesNotExempt() async throws {
    let scenario = try makeDowngradedPremiumStampScenario()
    let request = try makeRequest(renderSpec: scenario.renderSpec)

    let exportSagaStore = FakeExportSagaStore()
    let entryStore = FakeExportedSettingsEntryStore() // 何も seed しない → 確定記録が無い
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: FakeWorkingSourceStore(),
        managedFileStore: FakeManagedFileStore(),
        stampCatalog: scenario.catalog,
        exportedSettingsEntryStore: entryStore
    )

    let outcome = try await coordinator.startExport(request, capabilities: scenario.capabilities)

    #expect(renderSpecBlockReason(outcome) == .premiumStampNotAvailable)
    let loadEntryCalls = await entryStore.loadEntryCalls
    #expect(loadEntryCalls == [request.projectID])
    let startExportCalls = await exportSagaStore.startExportCalls
    #expect(startExportCalls.isEmpty)
}

// MARK: - 免除成立後もaccountingModeの消費評価は通常どおり

@Test("免除成立時もstartExportが呼ばれ、accountingModeの評価は通常どおりstoreに委ねられる")
private func exemptionStillDelegatesAccountingModeEvaluationToStartExport() async throws {
    let scenario = try makeDowngradedPremiumStampScenario()
    let projectID = makeProjectID()
    let request = try makeRequest(renderSpec: scenario.renderSpec, projectID: projectID)

    let workingSourceStore = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    try await seedWorkingSource(
        projectID: projectID, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )

    let digest = FakeSha256Digest()
    let matchingHash = try projectSettingsHash(
        renderSpec: request.renderSpec, exportSetting: request.exportSetting, digest: digest
    )
    let entryStore = FakeExportedSettingsEntryStore()
    await entryStore.seedEntry(
        ExportedSettingsEntry(
            projectID: projectID, settingsHash: matchingHash, exportedAt: Date(timeIntervalSince1970: 1_699_000_000)
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

    let outcome = try await coordinator.startExport(request, capabilities: scenario.capabilities)

    guard case .blocked(let block) = outcome else {
        Issue.record("expected .blocked(monthlyLimitReached) but got \(outcome)")
        return
    }
    #expect(block.reason == .monthlyLimitReached)
    let startExportCalls = await exportSagaStore.startExportCalls
    #expect(startExportCalls.count == 1)
}
