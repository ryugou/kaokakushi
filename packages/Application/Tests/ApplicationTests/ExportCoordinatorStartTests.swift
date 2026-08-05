import Foundation
import Testing
import Domain
@testable import Application

// ExportCoordinator.startExport（Issue #7 Task 4「認可と開始」）。
//
// 正本: export-saga.md 1 章「認可」（1.1〜1.6）、test-plan.md 3.1「認可と生成」（Task4 該当部分）。
// 生成 `recordGeneratedOutput` 以降（Task 5 の担当）はこのファイルの対象外。
//
// 偽ストア（Fakes/*.swift）だけを注入し、各中断点（1.1 不一致 / 1.2 blocked / 実体欠損 /
// revision 不一致 / 全成立）での挙動を検証する（test-plan.md 3 章「application saga test」の方針）。

/// 1.1 確認の一致検査（projectID / detectionRevision / previewRenderHash / 確認状態要約）の
/// どの構成要素を不一致にするかを表す。
private enum ConfirmationMismatchCase: Sendable, Equatable {
    case projectID
    case detectionRevision
    case previewRenderHash
    case reviewNotConfirmed
}

// MARK: - ExportStartOutcome の判別ヘルパー
//
// ExportStartOutcome は Equatable ではない（.started(ExportJob) の ExportJob が Equatable で
// ないため。ExportJob.swift 冒頭コメントの決定を踏襲）。case ごとの判別関数で代替する。

private func isConfirmationMismatch(_ outcome: ExportStartOutcome) -> Bool {
    if case .confirmationMismatch = outcome { return true }
    return false
}

private func isWorkingSourceMissing(_ outcome: ExportStartOutcome) -> Bool {
    if case .workingSourceMissing = outcome { return true }
    return false
}

private func renderSpecBlockReason(_ outcome: ExportStartOutcome) -> RenderSpecBlockReason? {
    if case .renderSpecBlocked(let reason) = outcome { return reason }
    return nil
}

private func startedJob(_ outcome: ExportStartOutcome) -> ExportJob? {
    if case .started(let job) = outcome { return job }
    return nil
}

/// 標準構成の ExportCoordinator を組み立てる（ファイル行数制約〈Global Constraints〉のため、
/// 各テストで異なる差し替え対象だけを引数化する。Fakes/*.swift 以外の依存は既定値で足りる）。
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
        queue: SerialTaskQueue()
    )
}

/// processingTemporary 種別の WorkingSourceFileRef フィクスチャ。
private func makeWorkingSourceFileRef() throws -> WorkingSourceFileRef {
    let ref = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))
    return try #require(WorkingSourceFileRef(ref))
}

/// 1.1・1.2 の両方を必ず通過する（renderSpec は regions 無しで能力を要求しない）標準リクエスト。
/// projectID は毎回新規発行するため、各テストは同じ projectID を FakeWorkingSourceStore の
/// シード等へそのまま使い回せる。
private func makeFullyConsistentRequest(
    expectedProjectRevision: Int64 = 0
) throws -> (request: SingleExportRequest, capabilities: ResolvedCapabilities) {
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
    return (request, makeResolvedCapabilities())
}

// MARK: - 1.1 確認の一致検査

@Test(
    "1.1確認の一致検査が不成立なら、authorizeRenderSpecの評価にもstoreにも進まずconfirmationMismatchになる",
    arguments: [
        ConfirmationMismatchCase.projectID,
        .detectionRevision,
        .previewRenderHash,
        .reviewNotConfirmed
    ]
)
private func confirmationMismatchShortCircuitsBeforeCapabilityCheckAndStore(
    _ mismatch: ConfirmationMismatchCase
) async throws {
    let matchingProjectID = makeProjectID()
    let hash = try makePreviewRenderHash()
    let confirmation = PreviewConfirmation(projectID: matchingProjectID, detectionRevision: 5, previewRenderHash: hash)

    // 1.2で評価されれば必ずblockedになる構成にしておき、1.1の不一致がそれより先に
    // 短絡することを間接的に証明する（1.2まで進めばrenderSpecBlockedが返ってしまうはず）。
    let renderSpec = try makeRenderSpec(regions: [try makeBuiltInStampRegion(code: "seasonal-cat")])
    let catalog = FakeStampCatalog(requirementsByCode: ["seasonal-cat": .premium(packID: "seasonal")])
    let capabilities = makeResolvedCapabilities(canUsePremiumStamps: false)

    let request = SingleExportRequest(
        projectID: mismatch == .projectID ? makeProjectID() : matchingProjectID,
        renderSpec: renderSpec,
        exportSetting: makeExportSetting(),
        previewConfirmation: confirmation,
        currentDetectionRevision: mismatch == .detectionRevision ? 999 : 5,
        currentPreviewRenderHash: mismatch == .previewRenderHash ? (try makePreviewRenderHash(fillByte: 0x01)) : hash,
        isReviewed: mismatch != .reviewNotConfirmed,
        expectedProjectRevision: 0
    )

    let exportSagaStore = FakeExportSagaStore()
    let workingSourceStore = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        stampCatalog: catalog
    )

    let outcome = try await coordinator.startExport(request, capabilities: capabilities)

    #expect(isConfirmationMismatch(outcome))
    let startExportCalls = await exportSagaStore.startExportCalls
    let loadWorkingSourceCalls = await workingSourceStore.loadWorkingSourceCalls
    let existsCalls = await managedFileStore.existsCalls
    #expect(startExportCalls.isEmpty)
    #expect(loadWorkingSourceCalls.isEmpty)
    #expect(existsCalls.isEmpty)
}

// MARK: - 1.2 設定内容の能力検査

@Test("1.2能力検査がblockedならrenderSpecBlockedを返しstartExportは呼ばれない")
private func renderSpecBlockedByCapabilityCheckDoesNotCallStartExport() async throws {
    let projectID = makeProjectID()
    let hash = try makePreviewRenderHash()
    let confirmation = PreviewConfirmation(projectID: projectID, detectionRevision: 5, previewRenderHash: hash)
    let renderSpec = try makeRenderSpec(regions: [try makeBuiltInStampRegion(code: "seasonal-cat")])
    let catalog = FakeStampCatalog(requirementsByCode: ["seasonal-cat": .premium(packID: "seasonal")])
    let capabilities = makeResolvedCapabilities(canUsePremiumStamps: false)

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

    let exportSagaStore = FakeExportSagaStore()
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore, stampCatalog: catalog)

    let outcome = try await coordinator.startExport(request, capabilities: capabilities)

    #expect(renderSpecBlockReason(outcome) == .premiumStampNotAvailable)
    let startExportCalls = await exportSagaStore.startExportCalls
    #expect(startExportCalls.isEmpty)
}

// MARK: - 実体確認（WorkingSourceRecord / 実体ファイル）

@Test("WorkingSourceRecordが無ければinvalidateWorkingSourceを呼びworkingSourceMissingを返す")
private func missingWorkingSourceRecordInvalidatesAndReturnsMissing() async throws {
    let (request, capabilities) = try makeFullyConsistentRequest()
    let exportSagaStore = FakeExportSagaStore()
    let workingSourceStore = FakeWorkingSourceStore() // 何も seed しない → レコードが無い
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore, workingSourceStore: workingSourceStore)

    let outcome = try await coordinator.startExport(request, capabilities: capabilities)

    #expect(isWorkingSourceMissing(outcome))
    let invalidateCalls = await workingSourceStore.invalidateWorkingSourceCalls
    let startExportCalls = await exportSagaStore.startExportCalls
    #expect(invalidateCalls == [request.projectID])
    #expect(startExportCalls.isEmpty)
}

@Test("WorkingSourceRecordはあるが実体ファイルが無ければinvalidateWorkingSourceを呼びworkingSourceMissingを返す")
private func missingWorkingSourceFileInvalidatesAndReturnsMissing() async throws {
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
    let managedFileStore = FakeManagedFileStore() // ref を seed しない → 実体欠損
    let exportSagaStore = FakeExportSagaStore()
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )

    let outcome = try await coordinator.startExport(request, capabilities: capabilities)

    #expect(isWorkingSourceMissing(outcome))
    let invalidateCalls = await workingSourceStore.invalidateWorkingSourceCalls
    let existsCalls = await managedFileStore.existsCalls
    let startExportCalls = await exportSagaStore.startExportCalls
    #expect(invalidateCalls == [request.projectID])
    #expect(existsCalls == [sourceFileRef.ref])
    #expect(startExportCalls.isEmpty)
}

// MARK: - startExport 呼び出し（revision 不一致 / 全成立）

@Test("expectedProjectRevisionがFakeのrevision(既定0)と不一致なら、throwがCoordinator.startExportの呼び出し元まで伝播する")
private func projectRevisionMismatchPropagatesToCaller() async throws {
    let (request, capabilities) = try makeFullyConsistentRequest(expectedProjectRevision: 1)
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
    let coordinator = makeCoordinator(
        exportSagaStore: FakeExportSagaStore(),
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore
    )

    // FakeExportSagaStore は projectRevisions 未設定の projectID を revision 0 として扱う
    // （Fakes/FakeExportSagaStore.swift 冒頭コメント）。expectedProjectRevision: 1 との不一致で
    // projectRevisionMismatch が throw される。
    await #expect(throws: FakeExportSagaStoreError.projectRevisionMismatch(
        projectID: request.projectID, expected: 1, actual: 0
    )) {
        _ = try await coordinator.startExport(request, capabilities: capabilities)
    }
}

@Test("1.1・1.2・実体確認・revisionがすべて成立する場合はExportJobを挿入しstartedを返す")
private func fullyAuthorizedRequestReturnsStartedJob() async throws {
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

    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore, workingSourceStore: workingSourceStore, managedFileStore: managedFileStore
    )

    let outcome = try await coordinator.startExport(request, capabilities: capabilities)

    let job = try #require(startedJob(outcome))
    #expect(job.exportID == exportID)
    let invalidateCalls = await workingSourceStore.invalidateWorkingSourceCalls
    let startExportCalls = await exportSagaStore.startExportCalls
    #expect(invalidateCalls.isEmpty)
    #expect(startExportCalls.count == 1)
}

// MARK: - 失敗注入の伝播テスト（C1 の回帰テスト。実体確認は exists 専用 API のみを使う）

@Test("existsの失敗はworkingSourceMissingに化けず、invalidateWorkingSourceを呼ばずに呼び出し元へ伝播する")
private func existsFailurePropagatesWithoutInvalidatingOrMissing() async throws {
    struct ExistsBoom: Error, Equatable {}
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
    await managedFileStore.setExistsFailure(ExistsBoom())
    let coordinator = makeCoordinator(
        exportSagaStore: FakeExportSagaStore(),
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore
    )

    await #expect(throws: ExistsBoom.self) {
        _ = try await coordinator.startExport(request, capabilities: capabilities)
    }
    let invalidateCalls = await workingSourceStore.invalidateWorkingSourceCalls
    #expect(invalidateCalls.isEmpty)
}

@Test("loadWorkingSourceの失敗は握りつぶさず呼び出し元へ伝播する")
private func loadWorkingSourceFailurePropagatesToCaller() async throws {
    struct LoadWorkingSourceBoom: Error, Equatable {}
    let (request, capabilities) = try makeFullyConsistentRequest()
    let workingSourceStore = FakeWorkingSourceStore()
    await workingSourceStore.setLoadWorkingSourceFailure(LoadWorkingSourceBoom())
    let coordinator = makeCoordinator(exportSagaStore: FakeExportSagaStore(), workingSourceStore: workingSourceStore)

    await #expect(throws: LoadWorkingSourceBoom.self) {
        _ = try await coordinator.startExport(request, capabilities: capabilities)
    }
}

@Test("欠損経路のinvalidateWorkingSourceの失敗は握りつぶさず呼び出し元へ伝播する")
private func invalidateWorkingSourceFailurePropagatesToCaller() async throws {
    struct InvalidateBoom: Error, Equatable {}
    let (request, capabilities) = try makeFullyConsistentRequest()
    let workingSourceStore = FakeWorkingSourceStore() // 何も seed しない → レコードが無い（欠損経路）
    await workingSourceStore.setInvalidateWorkingSourceFailure(InvalidateBoom())
    let coordinator = makeCoordinator(exportSagaStore: FakeExportSagaStore(), workingSourceStore: workingSourceStore)

    await #expect(throws: InvalidateBoom.self) {
        _ = try await coordinator.startExport(request, capabilities: capabilities)
    }
}
