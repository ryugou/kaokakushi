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
//
// Fakes 配下の型はテストターゲット外から参照されないため internal で足りる
// （DomainTests/TestSupport.swift と同じ方針。Task 3 レビュー Suggestion 2）。

/// `startExport` の revision 不一致など、この偽実装が検査する事前条件違反。
enum FakeExportSagaStoreError: Error, Sendable, Equatable {
    /// startExport: expectedProjectRevision が projectRevisions に設定した値と一致しない
    case projectRevisionMismatch(projectID: ProjectID, expected: Int64, actual: Int64)
    /// recordGeneratedOutput / settleExport: 対象 exportID の ExportJob 行が無い
    /// （startExport が成功していない、または既に settle/discard/起動時復旧で削除済み）
    case exportJobNotFound(ExportID)
    /// recordGeneratedOutput: 対象 exportID に未確定 OutputRecord が既に存在する（PRIMARY KEY
    /// 制約。ExportSagaStoreLive+Output.swift の insertOutputRecord が
    /// SQLITE_CONSTRAINT_PRIMARYKEY として検出する経路に対応する。duplicatePendingOutput
    /// （部分 UNIQUE 制約・別 exportID）とは別ケースのため区別する）
    case duplicatePendingOutputForExportID(ExportID)
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
struct FakeStartExportCall: Sendable {
    let input: StartExportInput
    let expectedProjectRevision: Int64
}

/// `settleBatch` の1回の呼び出し引数（呼び出し記録用）。
struct FakeSettleBatchCall: Sendable {
    let batchID: BatchID
    let settledAt: Date
}

/// `discardExport` の1回の呼び出し引数（呼び出し記録用）。
struct FakeDiscardExportCall: Sendable {
    let exportID: ExportID
    let temporaryFiles: [ManagedFileRef]
}

actor FakeExportSagaStore: ExportSagaStore {
    // MARK: - 呼び出し記録

    private(set) var startExportCalls: [FakeStartExportCall] = []
    private(set) var recordGeneratedOutputCalls: [RecordOutputInput] = []
    private(set) var settleExportCalls: [ExportID] = []
    private(set) var settleBatchCalls: [FakeSettleBatchCall] = []
    private(set) var discardExportCalls: [FakeDiscardExportCall] = []
    private(set) var loadRunningJobsCallCount = 0
    private(set) var deleteRunningJobsCalls: [[ExportID]] = []

    // MARK: - 注入可能な失敗

    var startExportFailure: Error?
    var recordGeneratedOutputFailure: Error?
    var settleExportFailure: Error?
    var settleBatchFailure: Error?
    var discardExportFailure: Error?
    var loadRunningJobsFailure: Error?
    var deleteRunningJobsFailure: Error?

    // MARK: - in-memory 状態

    /// startExport の可否をテストが決める（上記ファイル冒頭コメントの判断）
    var startExportHandler: @Sendable (StartExportInput, Int64) -> ExportStartDecision
    /// startExport が検査する revision。テストが事前に設定する（未設定の projectID は 0 扱い）
    var projectRevisions: [ProjectID: Int64] = [:]
    /// ExportJob 行。startExport(.authorized) 挿入・settle/discard/起動時復旧削除で更新する
    private var runningJobs: [ExportID: ExportJob] = [:]
    /// settledAt なしの確認用 OutputRecord。recordGeneratedOutput の重複検査・settle の消費対象
    private var pendingOutputsByExportID: [ExportID: RecordOutputInput] = [:]
    /// 月間枠消費カウンタ。settleExport / settleBatch で accountingMode == .freeMonthlyConsume の
    /// 対象を確定した回数（export-saga.md 1.4）
    private(set) var meteredConsumedCount = 0
    /// トライアルクレジット消費カウンタ。同上、accountingMode == .batchTrial の対象を確定した回数
    private(set) var trialCreditConsumedCount = 0
    /// true の間、discardExport は呼び出された瞬間の `Task.isCancelled` を検査し、true なら
    /// 何もせず `CancellationError` を throw する。実ストアがキャンセルを尊重する実装に
    /// なった場合を模し、呼び出し元（ExportCoordinator）が後始末をキャンセル非伝播の
    /// コンテキストで実行しているかを検証するためのフック（Issue #7 Task 5 レビュー指摘
    /// Important 1 の回帰テスト用。既定 false では既存の振る舞いを変えない）
    var discardExportChecksCancellation = false

    init(
        startExportHandler: @escaping @Sendable (StartExportInput, Int64) -> ExportStartDecision = { _, _ in
            .blocked(ExportStartBlock(reason: .monthlyLimitReached, limit: nil))
        }
    ) {
        self.startExportHandler = startExportHandler
    }

    // MARK: - 失敗注入セッター（actor 隔離のため外部から直接代入できない。Issue #7 Task 4 準備）

    func setStartExportFailure(_ value: Error?) { startExportFailure = value }
    func setRecordGeneratedOutputFailure(_ value: Error?) { recordGeneratedOutputFailure = value }
    func setSettleExportFailure(_ value: Error?) { settleExportFailure = value }
    func setSettleBatchFailure(_ value: Error?) { settleBatchFailure = value }
    func setDiscardExportFailure(_ value: Error?) { discardExportFailure = value }
    func setLoadRunningJobsFailure(_ value: Error?) { loadRunningJobsFailure = value }
    func setDeleteRunningJobsFailure(_ value: Error?) { deleteRunningJobsFailure = value }
    func setDiscardExportChecksCancellation(_ value: Bool) { discardExportChecksCancellation = value }

    /// テストが起動時復旧シナリオ等のために ExportJob を直接注入する（startExport を経由しない）
    func seedRunningJob(_ job: ExportJob) {
        runningJobs[job.exportID] = job
    }

    /// テストが settle の事前条件検査だけを狙って未確定 OutputRecord を直接注入する
    func seedPendingOutput(_ input: RecordOutputInput) {
        pendingOutputsByExportID[input.exportID] = input
    }

    func runningJob(for exportID: ExportID) -> ExportJob? {
        runningJobs[exportID]
    }

    // MARK: - ExportSagaStore

    func startExport(
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

    /// 同一 exportID への二重呼び出しは PRIMARY KEY 制約違反として throw する
    /// （ExportSagaStoreLive+Output.swift の insertOutputRecord と対応。Task 3 レビュー
    /// Critical 2: 自分自身を重複判定から除外していたため二重呼び出しが成功していたことの修正）。
    func recordGeneratedOutput(_ input: RecordOutputInput) async throws {
        recordGeneratedOutputCalls.append(input)
        if let failure = recordGeneratedOutputFailure { throw failure }
        guard let job = runningJobs[input.exportID] else {
            throw FakeExportSagaStoreError.exportJobNotFound(input.exportID)
        }
        guard pendingOutputsByExportID[input.exportID] == nil else {
            throw FakeExportSagaStoreError.duplicatePendingOutputForExportID(input.exportID)
        }
        let duplicateExists = pendingOutputsByExportID.keys.contains { existingExportID in
            runningJobs[existingExportID]?.projectID == job.projectID
        }
        guard !duplicateExists else {
            throw FakeExportSagaStoreError.duplicatePendingOutput(projectID: job.projectID)
        }
        pendingOutputsByExportID[input.exportID] = input
    }

    func settleExport(_ exportID: ExportID) async throws {
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
        settleAndConsume(exportID, accountingMode: job.authorization.accountingMode)
    }

    func settleBatch(_ batchID: BatchID, settledAt: Date) async throws {
        settleBatchCalls.append(FakeSettleBatchCall(batchID: batchID, settledAt: settledAt))
        if let failure = settleBatchFailure { throw failure }
        let targetJobs = runningJobs.values
            .filter { $0.batchID == batchID && pendingOutputsByExportID[$0.exportID] != nil }
        guard !targetJobs.isEmpty else {
            throw FakeExportSagaStoreError.noPendingOutputToSettleForBatch(batchID)
        }
        for job in targetJobs {
            settleAndConsume(job.exportID, accountingMode: job.authorization.accountingMode)
        }
    }

    func discardExport(_ exportID: ExportID, temporaryFiles: [ManagedFileRef]) async throws {
        // 呼び出し記録より前に検査する: シールドされていない実装だと、この throw により
        // discardExportCalls に記録すら残らない（Issue #7 Task 5 レビュー指摘 Important 1）
        if discardExportChecksCancellation {
            try Task.checkCancellation()
        }
        discardExportCalls.append(FakeDiscardExportCall(exportID: exportID, temporaryFiles: temporaryFiles))
        if let failure = discardExportFailure { throw failure }
        // ExportJob 行が無ければ何もしない（temporaryFiles の登録も行わない。冪等。export-saga.md
        // 4章）。「temporaryFiles の登録も行わない」という条項自体は、この偽実装が
        // PendingFileDeletion 相当の状態を持たないため Application テストからは観測できない
        // （実効果の検証は Persistence 側テストの担当。discardExportCalls に記録される呼び出し
        // 引数までがこの偽実装の検証対象）
        guard runningJobs[exportID] != nil else { return }
        runningJobs.removeValue(forKey: exportID)
        pendingOutputsByExportID.removeValue(forKey: exportID)
        // WorkingSourceRecord は別ポート（WorkingSourceStore）の責務のためここでは触れない
    }

    func loadRunningJobs() async throws -> [ExportJob] {
        loadRunningJobsCallCount += 1
        if let failure = loadRunningJobsFailure { throw failure }
        return Array(runningJobs.values)
    }

    func deleteRunningJobs(_ exportIDs: [ExportID]) async throws {
        deleteRunningJobsCalls.append(exportIDs)
        if let failure = deleteRunningJobsFailure { throw failure }
        for exportID in exportIDs {
            runningJobs.removeValue(forKey: exportID)
            pendingOutputsByExportID.removeValue(forKey: exportID)
        }
    }

    /// settleExport / settleBatch 共通の確定処理（消費カウンタ加算・OutputRecord 確定・
    /// ExportJob 削除）。消費先は accountingMode で決まる（export-saga.md 1.4）:
    /// freeMonthlyConsume → 月間枠、batchTrial → トライアルクレジット、paidUnlimited → 消費なし
    private func settleAndConsume(_ exportID: ExportID, accountingMode: ExportAccountingMode) {
        pendingOutputsByExportID.removeValue(forKey: exportID)
        runningJobs.removeValue(forKey: exportID)
        switch accountingMode {
        case .freeMonthlyConsume:
            meteredConsumedCount += 1
        case .batchTrial:
            trialCreditConsumedCount += 1
        case .paidUnlimited:
            break
        }
    }
}
