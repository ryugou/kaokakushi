import Foundation
import Testing
import Domain
@testable import Application

// ExportCoordinator.generateOutput のうち、SerialTaskQueue.run 自身のキャンセルチェック
// （投入前・取り出し直前。architecture.md 4.2）に特化した検証（Issue #7 Task 5 レビュー
// 指摘 W3）。
//
// ExportCoordinatorGenerateTests.swift の既存キャンセルテストは render 開始後にキャンセル
// するため、performGeneration の内側 catch を通る。一方このファイルは「先行 op でキューを
// 占有した状態で generateOutput を投入し、実行開始前にキャンセルする」手法
// （SerialTaskQueueTests.swift の OneShotGate と同じ）で、performGeneration が一度も
// 実行されず外側 catch だけが後始末する経路を決定的に再現する。
//
// 併せて W2（discardExport 自体の失敗で中断の真因を失わない）を、この外側 catch の経路
// についても検証する（内側 catch の検証は ExportCoordinatorGenerateTests.swift の担当）。

/// テスト専用の一回限りの非同期ゲート（SerialTaskQueueTests.swift の OneShotGate と同じ手法。
/// private 型のためファイル間で共有できず、ここへ複製する）。
private actor OneShotGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// 先行 op でキューを占有し、`generateOutput` 内部の `queue.run` が必ず「直前 op の完了待ち」
/// （4.2 の2つ目の `checkCancellation` の手前）を経由する状況を組み立てる。
private func occupyQueueWithBlockingOp(
    _ coordinator: ExportCoordinator
) async -> (blocking: Task<Void, Error>, gate: OneShotGate) {
    let (startedStream, startedContinuation) = AsyncStream<Int>.makeStream()
    var startedIterator = startedStream.makeAsyncIterator()
    let gate = OneShotGate()

    let blocking = Task<Void, Error> {
        try await coordinator.queue.run {
            startedContinuation.yield(1)
            await gate.wait()
        }
    }
    _ = await startedIterator.next()
    startedContinuation.finish()
    return (blocking, gate)
}

@Test(
    "queue.run投入前後のキャンセルでperformGenerationが一度も走らない場合も、外側catchが後始末しCancellationErrorが伝播する",
    .timeLimit(.minutes(1))
)
private func queueLevelCancellationBeforeGenerationStartsStillDiscardsAndPropagatesCancellationError() async throws {
    let pipeline = makeSucceedingGenerationPipeline()
    let exportID = makeExportID()
    let job = makeExportJob(exportID: exportID)
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)

    let coordinator = makeGenerateCoordinator(
        exportSagaStore: exportSagaStore,
        imageEffectRenderer: pipeline.renderer,
        imageEncoder: pipeline.encoder,
        outputFileVerifier: pipeline.verifier
    )

    let (blocking, blockingGate) = await occupyQueueWithBlockingOp(coordinator)

    let input = try makeGenerateExportInput(job: job)
    let generateTask = Task<Void, Error> {
        try await coordinator.generateOutput(input)
    }
    await Task.yield()
    generateTask.cancel()

    // blockingを完了させ、generateTask側のqueue.runがcheckCancellationへ到達できるようにする。
    await blockingGate.open()
    _ = try? await blocking.value

    await #expect(throws: CancellationError.self) {
        try await generateTask.value
    }

    let discardCalls = await exportSagaStore.discardExportCalls
    #expect(discardCalls.count == 1)
    #expect(discardCalls.first?.exportID == exportID)
    #expect(discardCalls.first?.temporaryFiles == [])
    // performGenerationが一度も走らなかったことをrendererが一度も呼ばれていないことで確認する。
    #expect(await pipeline.renderer.calls.isEmpty)
}

@Test(
    "上記経路でdiscardExport自体も失敗すると、真因(CancellationError)がGenerationAbortError.causeとして伝播する",
    .timeLimit(.minutes(1))
)
private func queueLevelCancellationPreservesCancellationCauseWhenDiscardAlsoFails() async throws {
    struct DiscardBoom: Error, Equatable {}
    let pipeline = makeSucceedingGenerationPipeline()
    let exportID = makeExportID()
    let job = makeExportJob(exportID: exportID)
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    await exportSagaStore.setDiscardExportFailure(DiscardBoom())

    let coordinator = makeGenerateCoordinator(
        exportSagaStore: exportSagaStore,
        imageEffectRenderer: pipeline.renderer,
        imageEncoder: pipeline.encoder,
        outputFileVerifier: pipeline.verifier
    )

    let (blocking, blockingGate) = await occupyQueueWithBlockingOp(coordinator)

    let input = try makeGenerateExportInput(job: job)
    let generateTask = Task<Void, Error> {
        try await coordinator.generateOutput(input)
    }
    await Task.yield()
    generateTask.cancel()

    await blockingGate.open()
    _ = try? await blocking.value

    do {
        try await generateTask.value
        Issue.record("エラーが送出されるはず")
    } catch let error as GenerationAbortError {
        #expect(error.cause is CancellationError)
        #expect(error.discardFailure is DiscardBoom)
    } catch {
        Issue.record("GenerationAbortErrorが期待されたが\(error)が送出された")
    }
}
