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

/// テスト専用の一回限りの非同期ゲート。`open()` が呼ばれるまで `wait()` を保留する。
/// `SerialTaskQueue` 本体の実装ではなく、FIFO順序を決定的に組み立てるためのテスト補助。
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
}
