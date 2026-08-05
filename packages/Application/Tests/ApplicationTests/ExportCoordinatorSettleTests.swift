import Foundation
import Testing
import Domain
@testable import Application

// ExportCoordinator.settleExport / settleBatch / verifyOutputIntegrity
// （Issue #7 Task 6「完了操作と実体喪失」）。
//
// 正本: export-saga.md 3章 手順5（settleExport / settleBatch は store の単一トランザクションへ
// 委譲する。ここが唯一の確定境界）、6章「確定後に出力実体が失われた場合」、
// test-plan.md 3.2「完了」・3.4「確定後の実体喪失」。
//
// 偽ストア（Fakes/*.swift）だけを注入し、settle の store 委譲・throw 伝播・二重 settle の
// 拒否と、実体喪失の削除経路の区別（missing/emptyFile/undecodable・測定値不一致 → 削除、
// ioFailure → 削除しない。Task 1 レビューでの決定）を検証する。

private func makeCoordinator(
    exportSagaStore: FakeExportSagaStore = FakeExportSagaStore(),
    outputDeliveryStore: FakeOutputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock()),
    outputFileVerifier: FakeOutputFileVerifier = FakeOutputFileVerifier(
        defaultOutcome: .success(makeVerifiedOutputMeasurement())
    ),
    now: @escaping @Sendable () -> Date = makeFixedClock()
) -> ExportCoordinator {
    ExportCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: FakeWorkingSourceStore(),
        managedFileStore: FakeManagedFileStore(),
        stampCatalog: FakeStampCatalog(),
        imageEffectRenderer: FakeImageEffectRenderer(),
        imageEncoder: FakeImageEncoder(),
        outputFileVerifier: outputFileVerifier,
        outputDeliveryStore: outputDeliveryStore,
        now: now,
        queue: SerialTaskQueue(),
        exportedSettingsEntryStore: FakeExportedSettingsEntryStore(),
        settingsHashDigest: FakeSha256Digest()
    )
}

// MARK: - settleExport

@Test("settleExportはexportSagaStore.settleExportをそのまま呼ぶ")
private func settleExportDelegatesToStore() async throws {
    let exportID = makeExportID()
    let job = makeExportJob(exportID: exportID)
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    await exportSagaStore.seedPendingOutput(makeRecordOutputInput(exportID: exportID))
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore)

    try await coordinator.settleExport(exportID)

    let calls = await exportSagaStore.settleExportCalls
    #expect(calls == [exportID])
}

@Test("exportSagaStore.settleExportのthrowは握りつぶさず呼び出し元まで伝播する")
private func settleExportPropagatesStoreFailure() async throws {
    struct SettleBoom: Error, Equatable {}
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.setSettleExportFailure(SettleBoom())
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore)

    await #expect(throws: SettleBoom.self) {
        try await coordinator.settleExport(makeExportID())
    }
}

@Test("二重settleExportは消費が重複せず、2回目の呼び出しはストアの拒否が伝播する")
private func doubleSettleExportDoesNotDoubleConsumeAndPropagatesRejection() async throws {
    let exportID = makeExportID()
    let job = makeExportJob(exportID: exportID, accountingMode: .freeMonthlyConsume)
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    await exportSagaStore.seedPendingOutput(makeRecordOutputInput(exportID: exportID))
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore)

    try await coordinator.settleExport(exportID)
    #expect(await exportSagaStore.meteredConsumedCount == 1)

    // settleAndConsume が ExportJob 行を削除するため、2回目は exportJobNotFound で拒否される
    // （export-saga.md 3章 手順5「最後に ExportJob を削除する」）。
    await #expect(throws: FakeExportSagaStoreError.exportJobNotFound(exportID)) {
        try await coordinator.settleExport(exportID)
    }
    #expect(await exportSagaStore.meteredConsumedCount == 1)
}

// MARK: - settleBatch

@Test("settleBatchはexportSagaStore.settleBatchへ注入されたクロックのsettledAtを渡す")
private func settleBatchDelegatesToStoreWithInjectedClock() async throws {
    let batchID = makeBatchID()
    let exportID = makeExportID()
    let job = makeExportJob(exportID: exportID, batchID: batchID)
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    await exportSagaStore.seedPendingOutput(makeRecordOutputInput(exportID: exportID))
    let fixedNow = Date(timeIntervalSince1970: 1_705_000_000)
    let coordinator = makeCoordinator(exportSagaStore: exportSagaStore, now: { fixedNow })

    try await coordinator.settleBatch(batchID)

    let calls = await exportSagaStore.settleBatchCalls
    #expect(calls.count == 1)
    #expect(calls.first?.batchID == batchID)
    #expect(calls.first?.settledAt == fixedNow)
}

@Test("確定対象が0件のsettleBatchはストアのthrowが伝播する")
private func settleBatchWithNoTargetsPropagatesStoreRejection() async throws {
    let batchID = makeBatchID()
    let coordinator = makeCoordinator()

    await #expect(throws: FakeExportSagaStoreError.noPendingOutputToSettleForBatch(batchID)) {
        try await coordinator.settleBatch(batchID)
    }
}

// MARK: - 確定後の実体喪失（6章）

@Test(
    "健全性検査がmissing/emptyFile/undecodableのいずれかならOutputRecordを削除しlostを返す",
    arguments: [
        OutputFileVerificationError.missing,
        .emptyFile,
        .undecodable
    ]
)
private func verificationFailureDeletesOutputAndReturnsLost(
    _ verificationError: OutputFileVerificationError
) async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let verifier = FakeOutputFileVerifier(defaultOutcome: .verificationFailure(verificationError))
    let exportSagaStore = FakeExportSagaStore()
    let coordinator = makeCoordinator(
        exportSagaStore: exportSagaStore, outputDeliveryStore: outputDeliveryStore, outputFileVerifier: verifier
    )

    let outcome = try await coordinator.verifyOutputIntegrity(output)

    #expect(outcome == .lost)
    let deleteCalls = await outputDeliveryStore.deleteOutputCalls
    #expect(deleteCalls == [exportID])
    #expect(await exportSagaStore.meteredConsumedCount == 0)
    #expect(await exportSagaStore.trialCreditConsumedCount == 0)
}

@Test("測定値(byteSize/sha256)が不一致ならOutputRecordを削除しlostを返す")
private func measurementMismatchDeletesOutputAndReturnsLost() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let mismatchedMeasurement = VerifiedOutputMeasurement(
        byteSize: output.outputByteSize + 1, sha256: output.outputSHA256
    )
    let verifier = FakeOutputFileVerifier(defaultOutcome: .success(mismatchedMeasurement))
    let coordinator = makeCoordinator(outputDeliveryStore: outputDeliveryStore, outputFileVerifier: verifier)

    let outcome = try await coordinator.verifyOutputIntegrity(output)

    #expect(outcome == .lost)
    let deleteCalls = await outputDeliveryStore.deleteOutputCalls
    #expect(deleteCalls == [exportID])
}

@Test("健全性検査がioFailureなら削除せずverificationUnavailableを返す")
private func ioFailureDoesNotDeleteAndReturnsVerificationUnavailable() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .generated)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let verifier = FakeOutputFileVerifier(defaultOutcome: .verificationFailure(.ioFailure))
    let coordinator = makeCoordinator(outputDeliveryStore: outputDeliveryStore, outputFileVerifier: verifier)

    let outcome = try await coordinator.verifyOutputIntegrity(output)

    #expect(outcome == .verificationUnavailable)
    let deleteCalls = await outputDeliveryStore.deleteOutputCalls
    #expect(deleteCalls.isEmpty)
}

@Test("測定値が一致すればintactを返し削除しない")
private func matchingMeasurementReturnsIntactWithoutDeleting() async throws {
    let exportID = makeExportID()
    let output = makeOutputRecord(exportID: exportID, state: .delivered)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await outputDeliveryStore.seedOutput(output)
    let measurement = VerifiedOutputMeasurement(byteSize: output.outputByteSize, sha256: output.outputSHA256)
    let verifier = FakeOutputFileVerifier(defaultOutcome: .success(measurement))
    let coordinator = makeCoordinator(outputDeliveryStore: outputDeliveryStore, outputFileVerifier: verifier)

    let outcome = try await coordinator.verifyOutputIntegrity(output)

    #expect(outcome == .intact)
    let deleteCalls = await outputDeliveryStore.deleteOutputCalls
    #expect(deleteCalls.isEmpty)
}
