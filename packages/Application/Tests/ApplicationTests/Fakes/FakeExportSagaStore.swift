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
    /// startExport: バッチ経路で対応する Batch 行（batchAuthorizations）が無い
    /// （本物の ExportSagaStoreError.batchNotFound と同じ契約。createBatch が先に呼ばれている
    /// 契約のため、無ければ異常系）
    case batchNotFound(BatchID)
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

    private(set) var createBatchCalls: [CreateBatchInput] = []
    private(set) var startExportCalls: [FakeStartExportCall] = []
    private(set) var recordGeneratedOutputCalls: [RecordOutputInput] = []
    private(set) var settleExportCalls: [ExportID] = []
    private(set) var settleBatchCalls: [FakeSettleBatchCall] = []
    private(set) var discardExportCalls: [FakeDiscardExportCall] = []
    private(set) var loadRunningJobsCallCount = 0
    private(set) var deleteRunningJobsCalls: [[ExportID]] = []
    private(set) var deleteUnsettledBatchesCallCount = 0

    // MARK: - 注入可能な失敗

    var createBatchFailure: Error?
    var startExportFailure: Error?
    var recordGeneratedOutputFailure: Error?
    var settleExportFailure: Error?
    var settleBatchFailure: Error?
    var discardExportFailure: Error?
    var loadRunningJobsFailure: Error?
    var deleteRunningJobsFailure: Error?
    var deleteUnsettledBatchesFailure: Error?

    // MARK: - in-memory 状態

    /// createBatch の可否をテストが決める（startExportHandler と同じパターン）。デフォルトは
    /// 常に `.created` を返す（多くのテストはバッチ認可の成立だけを前提とするため）。
    var createBatchHandler: @Sendable (CreateBatchInput) -> BatchCreateDecision
    /// startExport の可否をテストが決める（上記ファイル冒頭コメントの判断）。単体経路
    /// （batchID == nil）でのみ呼ばれる。バッチ経路は batchAuthorizations を使う
    /// （下記 startExport 実装のコメント参照）。
    var startExportHandler: @Sendable (StartExportInput, Int64) -> ExportStartDecision
    /// バッチ経路（batchID != nil）の startExport 帰結をテストから差し替えるフック。既定は
    /// nil で、この間はバッチ経路は現状どおり batchAuthorizations の固定済み認可をそのまま
    /// 使う（再評価しない契約を維持する）。設定した場合のみこのクロージャの戻り値を使う
    /// （codexレビュー指摘 C-2: バッチ項目で `.blocked` が返る契約違反を注入し、
    /// `ExportCoordinator.startBatchItem` がそれを `.itemFailed` へ丸めずthrowで表面化する
    /// ことを検証するために必要。既定挙動を変えないためオプトインの別プロパティにした）。
    var batchStartExportOverride: (@Sendable (StartExportInput, Int64) -> ExportStartDecision)?
    /// startExport が検査する revision。テストが事前に設定する（未設定の projectID は 0 扱い）
    var projectRevisions: [ProjectID: Int64] = [:]
    /// createBatch で `.created` になった Batch 行の固定済み認可（batchID をキーに保持。
    /// `.blocked` は Batch 行が作られないため格納しない）。startExport のバッチ経路
    /// （batchID != nil）はこれをそのまま使い、startExportHandler を呼ばない（Persistence 側の
    /// 新契約 ExportSagaStoreLive+Start.swift「再評価しない」と同じ設計。一括処理キュー簡素化
    /// Issue #40 決定2）。
    private var batchAuthorizations: [BatchID: ExportAuthorization] = [:]
    /// settle 済みとしてマークされた batchID（reviewer指摘 S-2）。本物の契約（5章 手順2:
    /// どの ExportRecord からも参照されない Batch 行だけを削除する）に寄せる最小の対応。
    /// `settleBatch` が対象 OutputRecord を確定するたびにこの集合へ追加する（1件でも
    /// settle された時点でマークする。複数バッチ項目のうち一部だけが settle された状態の
    /// 区別まではこのフラグ集合の対象外——この偽実装の粒度で必要になった時点で拡張する）。
    /// `markBatchSettled` は settleBatch を経由せず起動時復旧シナリオ等を直接組み立てたい
    /// テストのための seed 用補助（`seedRunningJob` と同じ位置づけ）。
    private var settledBatchIDs: Set<BatchID> = []
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
        },
        createBatchHandler: @escaping @Sendable (CreateBatchInput) -> BatchCreateDecision = { _ in
            .created(ExportAuthorization(
                entitlementSnapshot: makeEntitlement(), accountingMode: .paidUnlimited,
                authorizedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ))
        }
    ) {
        self.startExportHandler = startExportHandler
        self.createBatchHandler = createBatchHandler
    }

    // MARK: - 失敗注入セッター（actor 隔離のため外部から直接代入できない。Issue #7 Task 4 準備）

    func setCreateBatchFailure(_ value: Error?) { createBatchFailure = value }
    func setStartExportFailure(_ value: Error?) { startExportFailure = value }
    func setRecordGeneratedOutputFailure(_ value: Error?) { recordGeneratedOutputFailure = value }
    func setSettleExportFailure(_ value: Error?) { settleExportFailure = value }
    func setSettleBatchFailure(_ value: Error?) { settleBatchFailure = value }
    func setDiscardExportFailure(_ value: Error?) { discardExportFailure = value }
    func setLoadRunningJobsFailure(_ value: Error?) { loadRunningJobsFailure = value }
    func setDeleteRunningJobsFailure(_ value: Error?) { deleteRunningJobsFailure = value }
    func setDeleteUnsettledBatchesFailure(_ value: Error?) { deleteUnsettledBatchesFailure = value }
    func setDiscardExportChecksCancellation(_ value: Bool) { discardExportChecksCancellation = value }
    func setBatchStartExportOverride(_ value: (@Sendable (StartExportInput, Int64) -> ExportStartDecision)?) {
        batchStartExportOverride = value
    }
    /// テストが起動時復旧シナリオ等のために ExportJob を直接注入する（startExport を経由しない）
    func seedRunningJob(_ job: ExportJob) {
        runningJobs[job.exportID] = job
    }

    /// テストが settle の事前条件検査だけを狙って未確定 OutputRecord を直接注入する
    func seedPendingOutput(_ input: RecordOutputInput) {
        pendingOutputsByExportID[input.exportID] = input
    }

    /// batchID を settle 済みとして直接注入する（S-2。`seedRunningJob` / `seedPendingOutput` と
    /// 同じ位置づけの seed 用補助）。通常は `settleBatch` の実行で自動的にマークされるため、
    /// これは settleBatch を経由せず起動時復旧シナリオ等を直接組み立てたいテストのためだけに
    /// 使う。
    func markBatchSettled(_ batchID: BatchID) { settledBatchIDs.insert(batchID) }

    func runningJob(for exportID: ExportID) -> ExportJob? {
        runningJobs[exportID]
    }

    // MARK: - ExportSagaStore

    /// バッチ作成（Domain の doc コメント参照）。`.created` になった認可を batchAuthorizations
    /// へ固定する（`.blocked` は格納しない。Batch 行が作られないため）。
    func createBatch(_ input: CreateBatchInput) async throws -> BatchCreateDecision {
        createBatchCalls.append(input)
        if let failure = createBatchFailure { throw failure }
        let decision = createBatchHandler(input)
        if case .created(let authorization) = decision {
            batchAuthorizations[input.batchID] = authorization
        }
        return decision
    }

    /// expectedProjectRevision 不一致は throw ではなく `.staleProjectRevision`
    /// （Domain の契約変更。ExportSagaStore.swift の doc コメントが正）。バッチ経路
    /// （input.batchID != nil）は既定では createBatch が固定した認可をそのまま使い、
    /// startExportHandler を呼ばない（再評価しない。Persistence 側の新契約と同じ）。対応する
    /// Batch 行（batchAuthorizations）が無ければ、`batchStartExportOverride` の設定有無に
    /// 関わらず本物と同じ契約で batchNotFound を throw する（createBatch が先に呼ばれている
    /// 契約のため、無ければ異常系。テストが `.blocked` を注入したい場合でも createAuthorizedBatch
    /// で先に Batch 行を作る必要がある——本物が「未 createBatch の batchID では
    /// startExport 自体が到達しない」契約を偽実装でも壊さないため）。Batch 行があれば、
    /// `batchStartExportOverride` が設定されている場合のみその固定済み認可の代わりに
    /// クロージャの戻り値を使う（テストが契約違反〈`.blocked`〉を注入するためのフック。
    /// 既定 nil では固定済み認可をそのまま使う現状挙動のまま）。単体経路（batchID == nil）
    /// は現状どおり startExportHandler を呼ぶ。
    func startExport(
        _ input: StartExportInput,
        expectedProjectRevision: Int64
    ) async throws -> ExportStartDecision {
        startExportCalls.append(FakeStartExportCall(input: input, expectedProjectRevision: expectedProjectRevision))
        if let failure = startExportFailure { throw failure }
        let storedRevision = projectRevisions[input.projectID] ?? 0
        guard storedRevision == expectedProjectRevision else {
            return .staleProjectRevision
        }
        if let batchID = input.batchID {
            guard let authorization = batchAuthorizations[batchID] else {
                throw FakeExportSagaStoreError.batchNotFound(batchID)
            }
            if let override = batchStartExportOverride {
                let decision = override(input, expectedProjectRevision)
                if case .authorized(let job) = decision {
                    runningJobs[job.exportID] = job
                }
                return decision
            }
            let job = ExportJob(
                exportID: ExportID(rawValue: UUID()),
                projectID: input.projectID,
                batchID: batchID,
                authorization: authorization,
                delivery: OutputDeliveryDescriptor(format: input.exportSetting.outputFormat, suggestedCreationDate: nil)
            )
            runningJobs[job.exportID] = job
            return .authorized(job)
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
        // settle済みとしてマークする（S-2。deleteUnsettledBatchesがこのbatchIDの認可を
        // 消さないようにするため。本物の契約〈5章 手順2〉では、settleによって
        // ExportRecordが作られたBatch行は起動時復旧のGC対象から外れる）。
        settledBatchIDs.insert(batchID)
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

    /// 起動時復旧の手順2（export-saga.md 5章）。本物は「どの ExportRecord からも参照されない
    /// Batch 行（未 settle のまま中断されたバッチの残骸）」だけを `DELETE FROM Batch` で
    /// 削除する。この偽実装も `batchAuthorizations` から `settledBatchIDs`（settleBatch実行時に
    /// 自動でマークされる。上記プロパティのdocコメント参照）を除いた分だけをクリアする
    /// （reviewer指摘 S-2。旧実装は全件無条件クリアしており、settle 済みバッチの認可まで
    /// 消してしまう点で本物の契約より過剰だった）。クリア後に未settleのbatchIDで startExport
    /// のバッチ経路を呼ぶと、本物と同じ契約で batchNotFound になる。
    func deleteUnsettledBatches() async throws {
        deleteUnsettledBatchesCallCount += 1
        if let failure = deleteUnsettledBatchesFailure { throw failure }
        batchAuthorizations = batchAuthorizations.filter { settledBatchIDs.contains($0.key) }
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
