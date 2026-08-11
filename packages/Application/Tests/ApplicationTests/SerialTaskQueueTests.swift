import Testing
@testable import Application

// `SerialTaskQueue`（architecture.md 4.2「排他区間の実装規則」）の直列性を検証する。
//
// 「投入順」は真に並列レースした呼び出しの間では観測不能な性質のため（Swift の並行性ランタイムは
// 複数スレッドから同時に actor へ入ろうとするジョブの到達順を仕様として保証しない）、
// このファイルでは 2 種類のアプローチで検証する:
// 1. 排他の証明: 多数の操作を真に並列投入し、同時実行数の実測値が常に 1 であることを確認する
//    （`executesQueuedOperationsWithoutOverlap`）。
// 2. FIFO の証明: `OneShotGate` で「直前の op がまだ完了していない」ことを確定させたうえで
//    次を投入する、という手順を繰り返し、投入順どおりに実行されることを決定的に確認する
//    （`executesQueuedOperationsSequentiallyInSubmissionOrder` /
//    `throwingOpDoesNotBlockQueuedSuccessor`）。

// OneShotGate（FIFO順序を決定的に組み立てるためのテスト補助）は TestSupport.swift へ集約した
// （Issue #7 レビュー第2ラウンド S-2）。

/// テスト専用の一回限りの真偽値フラグ。`op` の内部から「観測できた」ことを actor 越しに
/// テスト本体へ伝えるために使う（`Task.isCancelled` はローカル変数へキャプチャできない
/// ため、actor 経由で記録する）。
private actor ObservedFlag {
    private(set) var wasObserved = false

    func markObserved() {
        wasObserved = true
    }
}

/// 真に並列実行された `op` の同時実行数を数える。`SerialTaskQueue.run` の外側からは
/// 排他が壊れているかどうかを直接観測できないため、`op` 自身に enter/exit を報告させる。
private actor ConcurrencyTracker {
    private var activeCount = 0
    private(set) var maxObservedConcurrency = 0
    private(set) var completedCount = 0

    func enter() {
        activeCount += 1
        maxObservedConcurrency = max(maxObservedConcurrency, activeCount)
    }

    func exit() {
        activeCount -= 1
        completedCount += 1
    }
}

@Test(
    "並列に投入した多数のopは、同時に実行される件数が常に1件を超えない",
    .timeLimit(.minutes(1))
)
func executesQueuedOperationsWithoutOverlap() async throws {
    let queue = SerialTaskQueue()
    let tracker = ConcurrencyTracker()
    let operationCount = 20

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<operationCount {
            group.addTask {
                _ = try await queue.run {
                    await tracker.enter()
                    // 排他が壊れていれば重複実行の観測窓を作るため、わずかに処理時間を持たせる。
                    try await Task.sleep(for: .milliseconds(1))
                    await tracker.exit()
                }
            }
        }
        try await group.waitForAll()
    }

    #expect(await tracker.maxObservedConcurrency == 1)
    #expect(await tracker.completedCount == operationCount)
}

@Test(
    "並列に投入した複数のopが、投入順に1件ずつ実行される（FIFO）",
    .timeLimit(.minutes(1))
)
func executesQueuedOperationsSequentiallyInSubmissionOrder() async throws {
    let queue = SerialTaskQueue()
    let (startedStream, startedContinuation) = AsyncStream<Int>.makeStream()
    var startedIterator = startedStream.makeAsyncIterator()
    let gate1 = OneShotGate()
    let gate2 = OneShotGate()
    let gate3 = OneShotGate()

    let task1 = Task<Int, Error> {
        try await queue.run {
            startedContinuation.yield(1)
            await gate1.wait()
            return 1
        }
    }
    #expect(await startedIterator.next() == 1)

    // op1がgate1待ちでまだ完了していない間に投入するため、op2はop1の直後に連結される。
    let task2 = Task<Int, Error> {
        try await queue.run {
            startedContinuation.yield(2)
            await gate2.wait()
            return 2
        }
    }
    await gate1.open()
    #expect(await startedIterator.next() == 2)

    // 同様に、op2がgate2待ちでまだ完了していない間にop3を投入する。
    let task3 = Task<Int, Error> {
        try await queue.run {
            startedContinuation.yield(3)
            await gate3.wait()
            return 3
        }
    }
    await gate2.open()
    #expect(await startedIterator.next() == 3)
    await gate3.open()

    #expect(try await task1.value == 1)
    #expect(try await task2.value == 2)
    #expect(try await task3.value == 3)

    startedContinuation.finish()
}

@Test(
    "直前のopがthrowしても、キューに続けて投入したopの実行は妨げられない",
    .timeLimit(.minutes(1))
)
func throwingOpDoesNotBlockQueuedSuccessor() async throws {
    struct BoomError: Error, Equatable {}

    let queue = SerialTaskQueue()
    let (startedStream, startedContinuation) = AsyncStream<Int>.makeStream()
    var startedIterator = startedStream.makeAsyncIterator()
    let releaseGate = OneShotGate()

    let failing = Task<Void, Error> {
        try await queue.run {
            startedContinuation.yield(1)
            await releaseGate.wait()
            throw BoomError()
        }
    }
    #expect(await startedIterator.next() == 1)

    // failing(op1)がまだthrowする前(ゲート待ち中)に、同じキューへ後続を投入する。
    let succeeding = Task<Int, Error> {
        try await queue.run { 42 }
    }

    await releaseGate.open()

    var caughtError: Error?
    do {
        try await failing.value
    } catch {
        caughtError = error
    }
    #expect(caughtError is BoomError)

    let result = try await succeeding.value
    #expect(result == 42)

    startedContinuation.finish()
}

// MARK: - キャンセル伝播（architecture.md 4.2 の2箇所の Task.checkCancellation()）
//
// 以下3件は reviewer FAIL 指摘（`op` が非構造化 `Task` 内で実行され、呼び出し元の
// キャンセルを継承しないため 4.2 の2チェックポイントが成立しない）に対する修正の検証。

@Test(
    "直前のopの完了待ち中にキャンセルされたopは実行されず、CancellationErrorが呼び出し元へ伝わる",
    .timeLimit(.minutes(1))
)
func cancelingWhileWaitingInQueuePreventsExecutionAndPropagatesCancellationError() async throws {
    let queue = SerialTaskQueue()
    let (startedStream, startedContinuation) = AsyncStream<Int>.makeStream()
    var startedIterator = startedStream.makeAsyncIterator()
    let blockingGate = OneShotGate()

    // op1をキューへ投入し、gate待ちで先頭を占有させる。これによりop2は必ず
    // 「直前のopの完了待ち」（4.2の2つ目のチェックポイント手前）を経由する。
    let blocking = Task<Void, Error> {
        try await queue.run {
            startedContinuation.yield(1)
            await blockingGate.wait()
        }
    }
    #expect(await startedIterator.next() == 1)

    // op2はop1の完了待ちでまだ「取り出して処理を開始する直前」に到達していない状態で投入する。
    let queued = Task<Int, Error> {
        try await queue.run {
            startedContinuation.yield(2)
            return 99
        }
    }

    // queuedがrun呼び出し内部へ進む猶予を与えてからキャンセルする。1つ目・2つ目どちらの
    // Task.checkCancellation() で検出されても「opが実行されずCancellationErrorが返る」
    // という期待結果は変わらないため、このyieldはテストの正しさに必須ではなく、
    // より現実的な「投入後にキャンセルされる」経路を狙う演出。
    await Task.yield()
    queued.cancel()

    // op1(blocking)を完了させ、op2側の「previousTail?.value」待ちから先へ進めるようにする。
    await blockingGate.open()
    _ = try? await blocking.value

    var caughtError: Error?
    do {
        _ = try await queued.value
    } catch {
        caughtError = error
    }
    #expect(caughtError is CancellationError)

    startedContinuation.finish()

    // op2の本体（yield(2)）が実行されていれば既にストリームへバッファされているはず。
    // finish()後にnextしてnilが返ることで「opが実行されなかった」ことを決定的に確認する。
    #expect(await startedIterator.next() == nil)
}

@Test(
    "実行中のopは、呼び出し元のキャンセルをTask.isCancelledとして観測できる",
    .timeLimit(.minutes(1))
)
func cancelingWhileOpIsRunningPropagatesToTaskIsCancelled() async throws {
    let queue = SerialTaskQueue()
    let observed = ObservedFlag()
    let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
    var startedIterator = startedStream.makeAsyncIterator()

    let running = Task<Int, Error> {
        try await queue.run {
            startedContinuation.yield(())
            // 外側（呼び出し元タスク）のキャンセルが current.cancel() 経由でここまで
            // 届くことを、isCancelled のポーリングで確認する。
            while !Task.isCancelled {
                await Task.yield()
            }
            await observed.markObserved()
            return 1
        }
    }
    #expect(await startedIterator.next() != nil)

    running.cancel()

    // opはisCancelledを検出しても自動では中断されない（early return / throw するかは
    // op自身の責務）ため、このopは正常にreturnし、run自体は成功として結果を返す。
    let result = try await running.value
    #expect(result == 1)
    #expect(await observed.wasObserved)

    startedContinuation.finish()
}

@Test(
    "キャンセルされたopは、キューに続けて投入した後続opの実行を妨げない",
    .timeLimit(.minutes(1))
)
func canceledOpDoesNotBlockQueuedSuccessor() async throws {
    let queue = SerialTaskQueue()
    let (startedStream, startedContinuation) = AsyncStream<Int>.makeStream()
    var startedIterator = startedStream.makeAsyncIterator()
    let blockingGate = OneShotGate()

    // op1をキューへ投入し、gate待ちで先頭を占有させる。
    let blocking = Task<Void, Error> {
        try await queue.run {
            startedContinuation.yield(1)
            await blockingGate.wait()
        }
    }
    #expect(await startedIterator.next() == 1)

    // op2はop1の完了待ち中にキャンセルする。
    let canceled = Task<Int, Error> {
        try await queue.run {
            startedContinuation.yield(2)
            return 2
        }
    }
    await Task.yield()
    canceled.cancel()

    // op3はop2の投入直後（tailの読み取り〜差し替えの間にawaitを挟まず）に投入するため、
    // 既存のFIFO保証によりop2の直後へ連結される。
    let succeeding = Task<Int, Error> {
        try await queue.run {
            startedContinuation.yield(3)
            return 3
        }
    }

    await blockingGate.open()
    _ = try? await blocking.value

    var caughtError: Error?
    do {
        _ = try await canceled.value
    } catch {
        caughtError = error
    }
    #expect(caughtError is CancellationError)

    let result = try await succeeding.value
    #expect(result == 3)

    startedContinuation.finish()
}
