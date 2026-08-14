import Foundation
import Testing
import Domain
@testable import Application

// ExportCoordinator.generateOutput / discardExport が起動時復旧ゲートを待つこと（Issue #32 C-2）。
//
// 正本: architecture.md 4.3「起動時に1回のみ実行し、完了まで他のすべてを開始させない」、
// export-saga.md 5章「起動時復旧」。settleExport/settleBatch と同じ理由（cold start の残存
// ExportJob に対して、復旧より先にこれらの操作が到達しうる）で、queue.run へ投入する前に
// ゲートを待つ。自己デッドロック非発生の検証は ExportCoordinatorSettleRecoveryGateTests.swift
// の settleExport/settleBatch で代表させ、ここでは重複させない（同じ SerialTaskQueue/
// RecoveryGate 配線であり検証対象の機構は共通のため）。

@Test("復旧未完了の間はgenerateOutputがstoreへ進まず、完了後に生成できる", .timeLimit(.minutes(1)))
private func generateOutputWaitsForRecoveryGateThenProceeds() async throws {
    let pipeline = makeSucceedingGenerationPipeline()
    await pipeline.renderer.setResult(pipeline.rendered)
    await pipeline.encoder.setResult(pipeline.encoded)

    let exportID = makeExportID()
    let job = makeExportJob(exportID: exportID)
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    let gate = FakeRecoveryGate(isOpen: false)
    let coordinator = makeGenerateCoordinator(
        exportSagaStore: exportSagaStore,
        imageEffectRenderer: pipeline.renderer,
        imageEncoder: pipeline.encoder,
        outputFileVerifier: pipeline.verifier,
        recoveryGate: gate
    )

    let input = try makeGenerateExportInput(job: job)
    let task = Task { try await coordinator.generateOutput(input) }
    for _ in 0..<5 { await Task.yield() }
    #expect(await exportSagaStore.recordGeneratedOutputCalls.isEmpty)
    #expect(await pipeline.renderer.calls.isEmpty)

    await gate.open()
    try await task.value

    #expect(await exportSagaStore.recordGeneratedOutputCalls.count == 1)
}

@Test("復旧未完了の間はdiscardExportがstoreへ進まず、完了後に破棄できる", .timeLimit(.minutes(1)))
private func discardExportWaitsForRecoveryGateThenProceeds() async throws {
    let exportID = makeExportID()
    let job = makeExportJob(exportID: exportID)
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    let gate = FakeRecoveryGate(isOpen: false)
    let coordinator = makeGenerateCoordinator(
        exportSagaStore: exportSagaStore,
        outputFileVerifier: FakeOutputFileVerifier(defaultOutcome: .success(makeVerifiedOutputMeasurement())),
        recoveryGate: gate
    )

    let task = Task { try await coordinator.discardExport(exportID, temporaryFiles: []) }
    for _ in 0..<5 { await Task.yield() }
    #expect(await exportSagaStore.discardExportCalls.isEmpty)

    await gate.open()
    try await task.value

    #expect(await exportSagaStore.discardExportCalls.count == 1)
    #expect(await exportSagaStore.runningJob(for: exportID) == nil)
}

@Test("復旧が失敗で確定した後にgenerateOutputを呼ぶと、待たずにStartupRecoveryFailedErrorで返る")
private func generateOutputAfterRecoveryFailureReturnsErrorWithoutWaiting() async throws {
    struct Boom: Error, Equatable {}
    let gate = FakeRecoveryGate(isOpen: false)
    await gate.fail(Boom())
    let exportSagaStore = FakeExportSagaStore()
    let job = makeExportJob(exportID: makeExportID())
    let coordinator = makeGenerateCoordinator(
        exportSagaStore: exportSagaStore,
        outputFileVerifier: FakeOutputFileVerifier(defaultOutcome: .success(makeVerifiedOutputMeasurement())),
        recoveryGate: gate
    )

    do {
        try await coordinator.generateOutput(try makeGenerateExportInput(job: job))
        Issue.record("StartupRecoveryFailedErrorが投げられるはずだった")
    } catch let error as StartupRecoveryFailedError {
        #expect(error.cause is Boom)
    } catch {
        Issue.record("想定外のエラー: \(error)")
    }
}
