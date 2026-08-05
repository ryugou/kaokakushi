import Foundation
import Testing
import Domain
@testable import Application

// ExportCoordinator.discardExport（Issue #7 Task 5「中断・やり直し・破棄」）。
//
// 正本: export-saga.md 4章「中断・やり直し・破棄」、test-plan.md 3.3「完了前の破棄」。
//
// 「やり直す」・利用者キャンセル用の公開 API そのものの契約（exportSagaStore.discardExport への
// 薄い委譲・冪等性・台帳不変・WorkingSourceRecord保持・エラー伝播）を検証する。生成の各失敗
// 段階から discardExport が呼ばれるケースは ExportCoordinatorGenerateTests.swift の担当。

private func makeCoordinator(
    exportSagaStore: FakeExportSagaStore,
    workingSourceStore: FakeWorkingSourceStore = FakeWorkingSourceStore()
) -> ExportCoordinator {
    ExportCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: FakeManagedFileStore(),
        stampCatalog: FakeStampCatalog(),
        imageEffectRenderer: FakeImageEffectRenderer(),
        imageEncoder: FakeImageEncoder(),
        outputFileVerifier: FakeOutputFileVerifier(defaultOutcome: .success(makeVerifiedOutputMeasurement())),
        outputDeliveryStore: FakeOutputDeliveryStore(now: makeFixedClock()),
        now: makeFixedClock(),
        queue: SerialTaskQueue(),
        exportedSettingsEntryStore: FakeExportedSettingsEntryStore(),
        settingsHashDigest: FakeSha256Digest()
    )
}

@Test("discardExportはexportSagaStore.discardExportをtemporaryFiles込みでそのまま呼ぶ")
private func discardExportDelegatesToStoreWithTemporaryFiles() async throws {
    let exportID = makeExportID()
    let job = makeExportJob(exportID: exportID)
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore)

    let temporaryFiles = [
        ManagedFileRef(kind: .rasterTemporary, fileID: ManagedFileID(rawValue: UUID())),
        ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    ]
    try await coordinator.discardExport(exportID, temporaryFiles: temporaryFiles)

    let discardCalls = await exportSagaStore.discardExportCalls
    #expect(discardCalls.count == 1)
    #expect(discardCalls.first?.exportID == exportID)
    #expect(discardCalls.first?.temporaryFiles == temporaryFiles)
}

@Test("discardExportはtemporaryFilesを省略すると空配列で呼ぶ")
private func discardExportDefaultsToEmptyTemporaryFiles() async throws {
    let exportID = makeExportID()
    let job = makeExportJob(exportID: exportID)
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore)

    try await coordinator.discardExport(exportID)

    let discardCalls = await exportSagaStore.discardExportCalls
    #expect(discardCalls.first?.temporaryFiles == [])
}

@Test("破棄の回数に制限が無く、同じexportIDへの複数回呼び出しがエラーにならない(冪等)")
private func discardingRepeatedlyForSameExportIDDoesNotThrow() async throws {
    let exportID = makeExportID()
    let job = makeExportJob(exportID: exportID)
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore)

    try await coordinator.discardExport(exportID)
    try await coordinator.discardExport(exportID)
    try await coordinator.discardExport(exportID)

    let discardCalls = await exportSagaStore.discardExportCalls
    #expect(discardCalls.count == 3)
}

@Test("破棄後も台帳(月間枠・トライアルクレジット)が不変であること")
private func discardDoesNotChangeLedgerCounters() async throws {
    let freeExportID = makeExportID()
    let trialExportID = makeExportID()
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(makeExportJob(exportID: freeExportID, accountingMode: .freeMonthlyConsume))
    await exportSagaStore.seedRunningJob(makeExportJob(exportID: trialExportID, accountingMode: .batchTrial))
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore)

    try await coordinator.discardExport(freeExportID)
    try await coordinator.discardExport(trialExportID)

    #expect(await exportSagaStore.meteredConsumedCount == 0)
    #expect(await exportSagaStore.trialCreditConsumedCount == 0)
}

@Test("破棄後もWorkingSourceRecordが保持され、削除・無効化のいずれも呼ばれない")
private func discardDoesNotTouchWorkingSourceRecord() async throws {
    let exportID = makeExportID()
    let job = makeExportJob(exportID: exportID)
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    let workingSourceStore = FakeWorkingSourceStore()
    let sourceFileRef = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))
    guard let workingSourceFileRef = WorkingSourceFileRef(sourceFileRef) else {
        Issue.record("test setup invariant violated: kind must be .processingTemporary")
        return
    }
    await workingSourceStore.seedWorkingSource(
        WorkingSourceRecord(
            projectID: job.projectID,
            sourceFile: workingSourceFileRef,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    )
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore, workingSourceStore: workingSourceStore)

    try await coordinator.discardExport(exportID)

    let deleteCalls = await workingSourceStore.deleteWorkingSourceCalls
    let invalidateCalls = await workingSourceStore.invalidateWorkingSourceCalls
    #expect(deleteCalls.isEmpty)
    #expect(invalidateCalls.isEmpty)
    let record = try await workingSourceStore.loadWorkingSource(for: job.projectID)
    #expect(record != nil)
}

@Test("exportSagaStore.discardExportのthrowは握りつぶさず呼び出し元まで伝播する")
private func discardExportPropagatesStoreFailure() async throws {
    struct DiscardBoom: Error, Equatable {}
    let exportID = makeExportID()
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.setDiscardExportFailure(DiscardBoom())
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore)

    await #expect(throws: DiscardBoom.self) {
        try await coordinator.discardExport(exportID)
    }
}
