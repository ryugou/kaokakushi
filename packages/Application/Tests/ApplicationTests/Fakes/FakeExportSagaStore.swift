import Foundation
import Domain

// FakeExportSagaStore — `ExportSagaStore`（Domain/Ports/ExportSagaStore.swift）の in-memory
// 偽実装（Issue #7 Task 3）。
//
// 正本は `ExportSagaStore` の各メソッドの doc コメント（事前条件・トランザクション境界）。
// 実 Persistence には依存しない。Coordinator（Task 4 以降）のテストが状態機械として
// 検証できるよう「呼び出し記録」「注入可能な失敗」「in-memory 状態」を持つ。
//
// startExport の「認可を評価し」は、月間上限・トライアル残高判定等の Accounting 実装
// （Persistence の担当。ExportSagaStoreLive 参照）であり、このタスクの正本（ポートの
// doc コメント）にはその評価アルゴリズムが含まれない。この偽実装では評価ロジックを
// 再現せず、`startExportHandler` でテストに判定を委ねる（doc コメントが明記する
// expectedProjectRevision 不一致の throw だけをこの偽実装自身が検査する）。

/// `startExport` の revision 不一致など、この偽実装が検査する事前条件違反。
public enum FakeExportSagaStoreError: Error, Sendable, Equatable {
    /// startExport: expectedProjectRevision が projectRevisions に設定した値と一致しない
    case projectRevisionMismatch(projectID: ProjectID, expected: Int64, actual: Int64)
    /// recordGeneratedOutput / settleExport: 対象 exportID の ExportJob 行が無い
    /// （startExport が成功していない、または既に settle/discard/起動時復旧で削除済み）
    case exportJobNotFound(ExportID)
    /// recordGeneratedOutput: 同じ projectID の未確定 OutputRecord が既に存在する
    case duplicatePendingOutput(projectID: ProjectID)
    /// settleExport: 対象 ExportJob.batchID が nil でない（settleExport は単体専用）
    case singleSettleNotAllowedForBatchedExport(ExportID)
    /// settleExport: 対象 exportID に未確定 OutputRecord が無い（recordGeneratedOutput 未実行、
    /// または二重 settle）
    case noPendingOutputToSettle(ExportID)
    /// settleBatch: 対象 batchID に未確定 OutputRecord が1件も無い
    case noPendingOutputToSettleForBatch(BatchID)
}

/// `startExport` の1回の呼び出し引数（呼び出し記録用）。
public struct FakeStartExportCall: Sendable {
    public let input: StartExportInput
    public let expectedProjectRevision: Int64
}

/// `settleBatch` の1回の呼び出し引数（呼び出し記録用）。
public struct FakeSettleBatchCall: Sendable {
    public let batchID: BatchID
    public let settledAt: Date
}

/// `discardExport` の1回の呼び出し引数（呼び出し記録用）。
public struct FakeDiscardExportCall: Sendable {
    public let exportID: ExportID
    public let temporaryFiles: [ManagedFileRef]
}

public actor FakeExportSagaStore: ExportSagaStore {
    // MARK: - 呼び出し記録

    public private(set) var startExportCalls: [FakeStartExportCall] = []
    public private(set) var recordGeneratedOutputCalls: [RecordOutputInput] = []
    public private(set) var settleExportCalls: [ExportID] = []
    public private(set) var settleBatchCalls: [FakeSettleBatchCall] = []
    public private(set) var discardExportCalls: [FakeDiscardExportCall] = []
    public private(set) var loadRunningJobsCallCount = 0
    public private(set) var deleteRunningJobsCalls: [[ExportID]] = []

    // MARK: - 注入可能な失敗

    public var startExportFailure: Error?
    public var recordGeneratedOutputFailure: Error?
    public var settleExportFailure: Error?
    public var settleBatchFailure: Error?
    public var discardExportFailure: Error?
    public var loadRunningJobsFailure: Error?
    public var deleteRunningJobsFailure: Error?

    // MARK: - in-memory 状態

    /// startExport の可否をテストが決める（上記ファイル冒頭コメントの判断）
    public var startExportHandler: @Sendable (StartExportInput, Int64) -> ExportStartDecision
    /// startExport が検査する revision。テストが事前に設定する（未設定の projectID は 0 扱い）
    public var projectRevisions: [ProjectID: Int64] = [:]
    /// ExportJob 行。startExport(.authorized) 挿入・settle/discard/起動時復旧削除で更新する
    private var runningJobs: [ExportID: ExportJob] = [:]
    /// settledAt なしの確認用 OutputRecord。recordGeneratedOutput の重複検査・settle の消費対象
    private var pendingOutputsByExportID: [ExportID: RecordOutputInput] = [:]
    /// 台帳（消費）カウンタ。settleExport / settleBatch でのみ加算する
    public private(set) var ledgerConsumedCount = 0

    public init(
        startExportHandler: @escaping @Sendable (StartExportInput, Int64) -> ExportStartDecision = { _, _ in
            .blocked(ExportStartBlock(reason: .monthlyLimitReached, limit: nil))
        }
    ) {
        self.startExportHandler = startExportHandler
    }

    /// テストが起動時復旧シナリオ等のために ExportJob を直接注入する（startExport を経由しない）
    public func seedRunningJob(_ job: ExportJob) {
        runningJobs[job.exportID] = job
    }

    /// テストが settle の事前条件検査だけを狙って未確定 OutputRecord を直接注入する
    public func seedPendingOutput(_ input: RecordOutputInput) {
        pendingOutputsByExportID[input.exportID] = input
    }

    public func runningJob(for exportID: ExportID) -> ExportJob? {
        runningJobs[exportID]
    }

    // MARK: - ExportSagaStore

    public func startExport(
        _ input: StartExportInput,
        expectedProjectRevision: Int64
    ) async throws -> ExportStartDecision {
        startExportCalls.append(FakeStartExportCall(input: input, expectedProjectRevision: expectedProjectRevision))
        if let failure = startExportFailure { throw failure }
        let storedRevision = projectRevisions[input.projectID] ?? 0
        guard storedRevision == expectedProjectRevision else {
            throw FakeExportSagaStoreError.projectRevisionMismatch(
                projectID: input.projectID, expected: expectedProjectRevision, actual: storedRevision
            )
        }
        let decision = startExportHandler(input, expectedProjectRevision)
        if case .authorized(let job) = decision {
            runningJobs[job.exportID] = job
        }
        return decision
    }

    public func recordGeneratedOutput(_ input: RecordOutputInput) async throws {
        recordGeneratedOutputCalls.append(input)
        if let failure = recordGeneratedOutputFailure { throw failure }
        guard let job = runningJobs[input.exportID] else {
            throw FakeExportSagaStoreError.exportJobNotFound(input.exportID)
        }
        let duplicateExists = pendingOutputsByExportID.keys.contains { existingExportID in
            existingExportID != input.exportID && runningJobs[existingExportID]?.projectID == job.projectID
        }
        guard !duplicateExists else {
            throw FakeExportSagaStoreError.duplicatePendingOutput(projectID: job.projectID)
        }
        pendingOutputsByExportID[input.exportID] = input
    }

    public func settleExport(_ exportID: ExportID) async throws {
        settleExportCalls.append(exportID)
        if let failure = settleExportFailure { throw failure }
        guard let job = runningJobs[exportID] else {
            throw FakeExportSagaStoreError.exportJobNotFound(exportID)
        }
        guard job.batchID == nil else {
            throw FakeExportSagaStoreError.singleSettleNotAllowedForBatchedExport(exportID)
        }
        guard pendingOutputsByExportID[exportID] != nil else {
            throw FakeExportSagaStoreError.noPendingOutputToSettle(exportID)
        }
        settleAndConsume(exportID)
    }

    public func settleBatch(_ batchID: BatchID, settledAt: Date) async throws {
        settleBatchCalls.append(FakeSettleBatchCall(batchID: batchID, settledAt: settledAt))
        if let failure = settleBatchFailure { throw failure }
        let targetExportIDs = runningJobs.values
            .filter { $0.batchID == batchID && pendingOutputsByExportID[$0.exportID] != nil }
            .map(\.exportID)
        guard !targetExportIDs.isEmpty else {
            throw FakeExportSagaStoreError.noPendingOutputToSettleForBatch(batchID)
        }
        for exportID in targetExportIDs {
            settleAndConsume(exportID)
        }
    }

    public func discardExport(_ exportID: ExportID, temporaryFiles: [ManagedFileRef]) async throws {
        discardExportCalls.append(FakeDiscardExportCall(exportID: exportID, temporaryFiles: temporaryFiles))
        if let failure = discardExportFailure { throw failure }
        // ExportJob 行が無ければ何もしない（temporaryFiles の登録も行わない。冪等）
        guard runningJobs[exportID] != nil else { return }
        runningJobs.removeValue(forKey: exportID)
        pendingOutputsByExportID.removeValue(forKey: exportID)
        // WorkingSourceRecord は別ポート（WorkingSourceStore）の責務のためここでは触れない
    }

    public func loadRunningJobs() async throws -> [ExportJob] {
        loadRunningJobsCallCount += 1
        if let failure = loadRunningJobsFailure { throw failure }
        return Array(runningJobs.values)
    }

    public func deleteRunningJobs(_ exportIDs: [ExportID]) async throws {
        deleteRunningJobsCalls.append(exportIDs)
        if let failure = deleteRunningJobsFailure { throw failure }
        for exportID in exportIDs {
            runningJobs.removeValue(forKey: exportID)
            pendingOutputsByExportID.removeValue(forKey: exportID)
        }
    }

    /// settleExport / settleBatch 共通の確定処理（台帳加算・OutputRecord 確定・ExportJob 削除）
    private func settleAndConsume(_ exportID: ExportID) {
        pendingOutputsByExportID.removeValue(forKey: exportID)
        runningJobs.removeValue(forKey: exportID)
        ledgerConsumedCount += 1
    }
}
