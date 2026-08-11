import Foundation
import Testing
import Domain
@testable import Application

// ExportCoordinator.generateOutput（Issue #7 Task 5「生成」）。
//
// 正本: export-saga.md 3章「手順」（手順1〜4）、4章「中断・やり直し・破棄」、
// test-plan.md 3.1「認可と生成」後半・3.3「完了前の破棄」。
//
// 偽ストア・偽画像処理ポート（Fakes/*.swift）だけを注入し、生成の各段階（レンダリング→
// エンコード→健全性確認→recordGeneratedOutput）と、各段階の失敗が discardExport へ
// つながる中断経路を検証する（test-plan.md 3 章「application saga test」の方針）。
//
// reviewer 一次レビュー fix round 1（Important 2）の反映: queue.run 自体がキュー投入前/
// 取り出し直前でキャンセルされた場合の後始末を generateOutput の外側 catch でもカバーする
// ようにしたため、内側（performGeneration）で既に discardExport が呼ばれた後にエラーが
// 外側へ伝播した場合、外側でも discardExport が呼ばれる（discardExport は冪等なので二重
// 呼び出し自体は無害。ExportCoordinator+Generate.swift 冒頭コメント参照）。このため、
// 以下のテストは discardCalls の「件数」ではなく「最初の呼び出しの内容」を検証する
// （queue.run 投入前後のキャンセルに特化した検証は
// ExportCoordinatorGenerateResilienceTests.swift が担当）。
//
// reviewer 一次レビュー fix round 2 の反映:
// - W1: 外側 catch の discardExport も SerialTaskQueue 経由になった
//   （詳細は ExportCoordinator+Generate.swift 冒頭コメント）
// - W2: discardExport 自体が失敗しても中断の真因が `CleanupPreservingError.cause`
//   （レビュー第2ラウンド A で Cleanup.swift へ共通化。旧 `GenerationAbortError`）として
//   伝播することを、内側 catch について本ファイル末尾で検証する（外側 catch は
//   ExportCoordinatorGenerateResilienceTests.swift が検証する）
// - W3: queue.run 自身のキャンセルチェックで performGeneration が一度も走らない経路の
//   テストを ExportCoordinatorGenerateResilienceTests.swift へ追加した
//
// 共有ヘルパー（makeGenerateCoordinator / makeSucceedingGenerationPipeline）は
// TestSupport.swift に集約している（複数の Generate 系テストファイルで使うため）。

// MARK: - 生成完了: recordGeneratedOutput のみが呼ばれ、他のstore操作・台帳に触れない

@Test("生成完了時点でrecordGeneratedOutputのみが呼ばれ、settle系・WorkingSourceRecordの変更は起きない")
private func generationOnlyRecordsOutputWithoutTouchingSettlementOrWorkingSource() async throws {
    let pipeline = makeSucceedingGenerationPipeline()
    await pipeline.renderer.setResult(pipeline.rendered)
    await pipeline.encoder.setResult(pipeline.encoded)

    let exportID = makeExportID()
    let job = makeExportJob(exportID: exportID, accountingMode: .freeMonthlyConsume)
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    let workingSourceStore = FakeWorkingSourceStore()

    let coordinator = makeGenerateCoordinator(
        exportSagaStore: exportSagaStore,
        imageEffectRenderer: pipeline.renderer,
        imageEncoder: pipeline.encoder,
        outputFileVerifier: pipeline.verifier,
        workingSourceStore: workingSourceStore
    )

    try await coordinator.generateOutput(try makeGenerateExportInput(job: job))

    let recordCalls = await exportSagaStore.recordGeneratedOutputCalls
    #expect(recordCalls.count == 1)
    #expect(recordCalls.first?.exportID == exportID)
    #expect(recordCalls.first?.outputFile == pipeline.encoded)
    #expect(recordCalls.first?.outputByteSize == pipeline.measurement.byteSize)
    #expect(recordCalls.first?.outputSHA256 == pipeline.measurement.sha256)

    let settleExportCalls = await exportSagaStore.settleExportCalls
    let settleBatchCalls = await exportSagaStore.settleBatchCalls
    let discardCalls = await exportSagaStore.discardExportCalls
    #expect(settleExportCalls.isEmpty)
    #expect(settleBatchCalls.isEmpty)
    #expect(discardCalls.isEmpty)
    #expect(await exportSagaStore.meteredConsumedCount == 0)
    #expect(await exportSagaStore.trialCreditConsumedCount == 0)

    let deleteWorkingSourceCalls = await workingSourceStore.deleteWorkingSourceCalls
    let invalidateWorkingSourceCalls = await workingSourceStore.invalidateWorkingSourceCalls
    #expect(deleteWorkingSourceCalls.isEmpty)
    #expect(invalidateWorkingSourceCalls.isEmpty)
}

// MARK: - 健全性確認の各失敗ケース

@Test(
    "健全性確認が不成立ならrecordGeneratedOutputへ進まずdiscardExportで中断する",
    arguments: [
        OutputFileVerificationError.missing,
        .emptyFile,
        .undecodable,
        .ioFailure
    ]
)
private func verificationFailureAbortsBeforeRecordingAndDiscards(
    _ verificationError: OutputFileVerificationError
) async throws {
    let pipeline = makeSucceedingGenerationPipeline()
    await pipeline.renderer.setResult(pipeline.rendered)
    await pipeline.encoder.setResult(pipeline.encoded)
    await pipeline.verifier.setDefaultOutcome(.verificationFailure(verificationError))

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

    await #expect(throws: verificationError) {
        try await coordinator.generateOutput(try makeGenerateExportInput(job: job))
    }

    let recordCalls = await exportSagaStore.recordGeneratedOutputCalls
    #expect(recordCalls.isEmpty)
    let discardCalls = await exportSagaStore.discardExportCalls
    #expect(!discardCalls.isEmpty)
    #expect(discardCalls.first?.exportID == exportID)
    #expect(discardCalls.first?.temporaryFiles == [pipeline.rendered.file.ref, pipeline.encoded.ref])
}

// MARK: - 各段階の失敗が discardExport へつながり、temporaryFiles が積み上げ規則どおりになる

@Test("レンダリング失敗はtemporaryFilesが空のままdiscardExportを呼び、エラーが伝播する")
private func renderFailureDiscardsWithoutTemporaryFilesAndPropagatesError() async throws {
    struct RenderBoom: Error, Equatable {}
    let pipeline = makeSucceedingGenerationPipeline()
    await pipeline.renderer.setFailure(RenderBoom())

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

    await #expect(throws: RenderBoom.self) {
        try await coordinator.generateOutput(try makeGenerateExportInput(job: job))
    }

    let discardCalls = await exportSagaStore.discardExportCalls
    #expect(!discardCalls.isEmpty)
    #expect(discardCalls.first?.exportID == exportID)
    #expect(discardCalls.first?.temporaryFiles == [])
}

@Test("エンコード失敗はrender成功分のtemporaryFilesを添えてdiscardExportを呼ぶ")
private func encodeFailureDiscardsWithRenderedTemporaryFile() async throws {
    struct EncodeBoom: Error, Equatable {}
    let pipeline = makeSucceedingGenerationPipeline()
    await pipeline.renderer.setResult(pipeline.rendered)
    await pipeline.encoder.setFailure(EncodeBoom())

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

    await #expect(throws: EncodeBoom.self) {
        try await coordinator.generateOutput(try makeGenerateExportInput(job: job))
    }

    let discardCalls = await exportSagaStore.discardExportCalls
    #expect(!discardCalls.isEmpty)
    #expect(discardCalls.first?.temporaryFiles == [pipeline.rendered.file.ref])
}

@Test("recordGeneratedOutput失敗はrender・encode成功分のtemporaryFilesを添えてdiscardExportを呼ぶ")
private func recordFailureDiscardsWithBothTemporaryFilesAndPropagatesError() async throws {
    struct RecordBoom: Error, Equatable {}
    let pipeline = makeSucceedingGenerationPipeline()
    await pipeline.renderer.setResult(pipeline.rendered)
    await pipeline.encoder.setResult(pipeline.encoded)

    let exportID = makeExportID()
    let job = makeExportJob(exportID: exportID)
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    await exportSagaStore.setRecordGeneratedOutputFailure(RecordBoom())

    let coordinator = makeGenerateCoordinator(
        exportSagaStore: exportSagaStore,
        imageEffectRenderer: pipeline.renderer,
        imageEncoder: pipeline.encoder,
        outputFileVerifier: pipeline.verifier
    )

    await #expect(throws: RecordBoom.self) {
        try await coordinator.generateOutput(try makeGenerateExportInput(job: job))
    }

    let discardCalls = await exportSagaStore.discardExportCalls
    #expect(!discardCalls.isEmpty)
    #expect(discardCalls.first?.temporaryFiles == [pipeline.rendered.file.ref, pipeline.encoded.ref])
}

// MARK: - 直列化: generateOutput 経由でも同時に処理中のジョブが1件までに保たれる

@Test(
    "並列に投入した複数のgenerateOutputは、同時にrenderが実行される件数が常に1件を超えない",
    .timeLimit(.minutes(1))
)
private func generateOutputSerializesRenderCallsAcrossConcurrentInvocations() async throws {
    let renderer = FakeImageEffectRenderer()
    await renderer.setResult(makeRenderedImage())
    await renderer.setDelayNanoseconds(2_000_000) // 2ms。同時実行があれば重複窓を作るのに十分
    let encoder = FakeImageEncoder()
    await encoder.setResult(makeOutputFileRef())
    let verifier = FakeOutputFileVerifier(defaultOutcome: .success(makeVerifiedOutputMeasurement()))
    let exportSagaStore = FakeExportSagaStore()

    var jobs: [ExportJob] = []
    for _ in 0..<5 {
        let job = makeExportJob(exportID: makeExportID())
        await exportSagaStore.seedRunningJob(job)
        jobs.append(job)
    }

    let coordinator = makeGenerateCoordinator(
        exportSagaStore: exportSagaStore,
        imageEffectRenderer: renderer,
        imageEncoder: encoder,
        outputFileVerifier: verifier
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
        for job in jobs {
            group.addTask {
                try await coordinator.generateOutput(try makeGenerateExportInput(job: job))
            }
        }
        try await group.waitForAll()
    }

    #expect(await renderer.maxObservedConcurrency == 1)
    #expect(await exportSagaStore.recordGeneratedOutputCalls.count == 5)
}

// MARK: - キャンセル: 生成の失敗と同じdiscard経路を通る

@Test("render完了後にキャンセルされると、CancellationErrorが伝播しdiscardExportが呼ばれる")
private func cancellationAfterRenderDiscardsAndPropagatesCancellationError() async throws {
    let pipeline = makeSucceedingGenerationPipeline()
    await pipeline.renderer.setResult(pipeline.rendered)
    // render自体を成立させたうえで、その直後にキャンセルする猶予を作る（Fakeにdelayが
    // 無いと、テストスレッドがrenderの呼び出しを検知した時点で全工程が既に完了してしまい、
    // キャンセルが手遅れになる）。
    await pipeline.renderer.setDelayNanoseconds(20_000_000)
    await pipeline.encoder.setResult(pipeline.encoded)

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

    let input = try makeGenerateExportInput(job: job)
    let task = Task {
        try await coordinator.generateOutput(input)
    }
    while await pipeline.renderer.calls.isEmpty {
        await Task.yield()
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    let discardCalls = await exportSagaStore.discardExportCalls
    #expect(!discardCalls.isEmpty)
    #expect(discardCalls.first?.exportID == exportID)
}

// MARK: - W2: discardExport自体の失敗で中断の真因を失わない（内側catch）

@Test("内側catch: レンダリング失敗時にdiscardExportも失敗すると、真因がCleanupPreservingError.causeとして伝播する")
private func innerCatchPreservesOriginalCauseWhenDiscardAlsoFails() async throws {
    struct RenderBoom: Error, Equatable {}
    struct DiscardBoom: Error, Equatable {}
    let pipeline = makeSucceedingGenerationPipeline()
    await pipeline.renderer.setFailure(RenderBoom())

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

    do {
        try await coordinator.generateOutput(try makeGenerateExportInput(job: job))
        Issue.record("エラーが送出されるはず")
    } catch let error as CleanupPreservingError {
        #expect(error.cause is RenderBoom)
        #expect(error.cleanupFailure is DiscardBoom)
    } catch {
        Issue.record("CleanupPreservingErrorが期待されたが\(error)が送出された")
    }

    let discardCalls = await exportSagaStore.discardExportCalls
    #expect(!discardCalls.isEmpty)
}

// MARK: - W-2: 生成経路のキャンセルシールドを守る回帰テスト（内側catch）

@Test(
    "内側catch: render完了後にキャンセルされてもdiscardExportはシールドされ完走しExportJobが残らない",
    .timeLimit(.minutes(1))
)
private func innerCatchDiscardExportIsShieldedFromCancellation() async throws {
    let pipeline = makeSucceedingGenerationPipeline()
    await pipeline.renderer.setResult(pipeline.rendered)
    // render自体を成立させたうえで、その直後にキャンセルする猶予を作る
    // （cancellationAfterRenderDiscardsAndPropagatesCancellationErrorと同じ手法）。
    await pipeline.renderer.setDelayNanoseconds(20_000_000)
    await pipeline.encoder.setResult(pipeline.encoded)

    let exportID = makeExportID()
    let job = makeExportJob(exportID: exportID)
    let exportSagaStore = FakeExportSagaStore()
    await exportSagaStore.seedRunningJob(job)
    // discardExportChecksCancellationを立てて初めて、シールドを外すと
    // discardExportの最初の呼び出しがcheckCancellationで即throwし失敗することを検出できる
    // （Issue #7 レビュー第2ラウンド W-2: これまでどのテストからも呼ばれていなかったフック）。
    await exportSagaStore.setDiscardExportChecksCancellation(true)

    let coordinator = makeGenerateCoordinator(
        exportSagaStore: exportSagaStore,
        imageEffectRenderer: pipeline.renderer,
        imageEncoder: pipeline.encoder,
        outputFileVerifier: pipeline.verifier
    )

    let input = try makeGenerateExportInput(job: job)
    let task = Task {
        try await coordinator.generateOutput(input)
    }
    while await pipeline.renderer.calls.isEmpty {
        await Task.yield()
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }

    // generateOutput側の外側catch（安全網）は、内側catchの成否に関わらずqueue.runから漏れた
    // 全エラーに対して冪等にdiscardExportを呼び直す（temporaryFiles: []固定）。内側catchの
    // シールドが外れて最初の呼び出しが失敗しても、外側catchの安全網がdiscardCalls自体は
    // 非空にしてしまうため「呼ばれたか」だけでは内側シールドの実効を検出できない。内側catchの
    // discardExportは蓄積済みtemporaryFiles（render成功分）を添えて呼ぶため、最初の呼び出しの
    // 引数まで見て初めて内側シールドが効いたことを区別できる。
    let discardCalls = await exportSagaStore.discardExportCalls
    #expect(discardCalls.first?.exportID == exportID)
    #expect(discardCalls.first?.temporaryFiles == [pipeline.rendered.file.ref])
    #expect(await exportSagaStore.runningJob(for: exportID) == nil)
}
