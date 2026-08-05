import Foundation
import Testing
import Domain
@testable import Application

// ExportCoordinator.startExport の 1.3 accountingMode blocked 写像テスト
// （Issue #7 Task 4 レビュー Warning）。
//
// 正本: export-saga.md 1.3（accountingMode の評価は Persistence の startExport が担う。
// この偽実装では startExportHandler がその判定を代行する）。FakeExportSagaStore の既定
// ハンドラは `.blocked(ExportStartBlock(reason: .monthlyLimitReached, limit: nil))` を返す
// （Fakes/FakeExportSagaStore.swift 冒頭コメント）。ExportCoordinatorStartTests.swift の
// ファイル行数制約（Global Constraints）のため、このテストのみ別ファイルに置く。

@Test("1.3のblocked判定はExportStartOutcome.blockedへ写像されExportJobは作られない")
private func accountingBlockedMapsToOutcomeWithoutCreatingJob() async throws {
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
    let sourceFileRef = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))
    let workingSourceFileRef = try #require(WorkingSourceFileRef(sourceFileRef))
    let workingSourceStore = FakeWorkingSourceStore()
    await workingSourceStore.seedWorkingSource(
        WorkingSourceRecord(
            projectID: projectID,
            sourceFile: workingSourceFileRef,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    )
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.seedExistingFile(sourceFileRef)
    let exportSagaStore = FakeExportSagaStore() // 既定ハンドラ: .blocked(.monthlyLimitReached)
    let coordinator = ExportCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        stampCatalog: FakeStampCatalog(),
        imageEffectRenderer: FakeImageEffectRenderer(),
        imageEncoder: FakeImageEncoder(),
        outputFileVerifier: FakeOutputFileVerifier(defaultOutcome: .success(makeVerifiedOutputMeasurement())),
        queue: SerialTaskQueue()
    )

    let outcome = try await coordinator.startExport(request, capabilities: makeResolvedCapabilities())

    guard case .blocked(let block) = outcome else {
        Issue.record("expected .blocked but got \(outcome)")
        return
    }
    #expect(block == ExportStartBlock(reason: .monthlyLimitReached, limit: nil))
    let runningJobs = try await exportSagaStore.loadRunningJobs()
    #expect(runningJobs.isEmpty)
}
