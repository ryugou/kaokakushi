import Foundation
import Domain

// ExportCoordinator+Batch — バッチ進行（Issue #7 Task 7、追補: batch-progression spec）。
//
// 正本: export-saga.md 1.1（バッチの開始条件: 各写真の確認一致 + BatchReviewState.batchID の
// 一致 + モード別条件）・1.5（開始後の権限変化:「まだ認可されていない写真は開始せず、バッチを
// paused にする」）、1.6（開始の順序は単体と共通）、architecture.md 6.4「一枚の失敗でバッチ
// 全体を停止しない」、Domain/Queue/QueueMachine.swift の queueStateAfterAuthorization
// （1.2 の能力ブロックの遷移先）。
//
// startBatchItem の帰結は BatchItemStartOutcome で表す（上記の正本の突き合わせ結果。
// docs/superpowers/specs/2026-08-06-issue7-task7-batch-progression.md の表が正）:
// - started: 開始した。バッチは継続する
// - itemFailed: 1.2 の能力ブロック（isExemptFromCapabilityBlock の免除が成立しない場合。
//   レビュー第2ラウンド C）。この項目のみ終了。バッチは継続する
// - itemPaused: 実体欠損。この項目のみ paused(.sourceReselectionRequired)。バッチは継続する
// - confirmationMismatch: 1.1 の確認不一致。この項目のみ非開始。バッチは継続する
// - batchPaused: 1.3 の権限・クォータブロック。バッチを停止し、以降の写真を開始しない
//
// 決定済みの設計判断（オーケストレーターの spec で確定済み。疑問視しない）:
// - Coordinator はバッチ全体を1回の呼び出しでループ処理しない。1.6 の「専用の排他ゲートや
//   素材単位のロックは不要」のとおり、直列性は SerialTaskQueue（Task 2）が構造的に保証する
//   ため、呼び出し元（バッチ進行ループ）が写真ごとに startBatchItem → 認可されれば
//   generateOutput（Task 5、既存の公開 API）の順で呼び、`batchPaused` を受け取ったときだけ
//   残りの waiting を呼ばないことで 1.5「未認可は開始せず paused」を実現する。それ以外の帰結
//   （itemFailed / itemPaused / confirmationMismatch）は次の写真の開始を妨げない。Coordinator
//   自身が「バッチを paused にする」というグローバル状態を持つ必要はない
//   （ExportJob の行の有無だけが状態を表す。export-saga.md 2 章と同じ設計原則）
// - 1.1 のモード別条件はここでのみ判定する（Domain に新しい型を追加しない。おまかせ一括/
//   1 枚ずつ確認という区別自体が Domain の正本コードブロックに型として存在しないため、
//   Application 層の入力構築の都合として BatchReviewMode を定義する）
// - startExport（単体）と処理順序を共有するため、実体確認・store 呼び出しは
//   ExportCoordinator.swift の authorizeAndStart(_:batchID:queueItemID:) をそのまま再利用する。
//   authorizeAndStart の戻り値は `AuthorizeAndStartOutcome`（started/workingSourceMissing/
//   blocked の3ケースのみ）であり、confirmationMismatch/renderSpecBlocked は型として
//   存在しない（レビュー第2ラウンド B。旧実装は `ExportStartOutcome` をそのまま返し、
//   ここで到達不能な分岐と `preconditionFailure` を人間の推論に頼って書いていた）

/// 一括処理の確認モード（architecture.md 6.4「一括処理モード」）。
/// おまかせ一括は一覧確認（`BatchReviewState.overviewConfirmed`）で全写真の確認を代表させ、
/// 1 枚ずつ確認は写真ごとの `ReviewDecision` 確定（`SingleExportRequest.isReviewed`）を見る
/// （export-saga.md 1.1 の表）。
public enum BatchReviewMode: Sendable, Equatable {
    case overview
    case perPhoto
}

/// `startBatchItem` の帰結（上記ファイル冒頭コメントの表が正）。`ExportStartOutcome` と異なり、
/// 項目単独の終了（バッチは継続）とバッチ全体の停止を型で区別する。
public enum BatchItemStartOutcome: Sendable {
    /// 開始した。バッチは継続する
    case started(ExportJob)
    /// 1.2 の能力ブロック（isExemptFromCapabilityBlock の免除が成立しない場合）。
    /// `queueStateAfterAuthorization` の戻り値をそのまま載せる
    /// （この Coordinator で `ExportQueueState` を組み立てない）。この項目のみ終了しバッチは継続する
    case itemFailed(ExportQueueState)
    /// 実体欠損。この項目のみ `paused(.sourceReselectionRequired)`。バッチは継続する
    case itemPaused(ExportQueueState)
    /// 1.1 の確認不一致。この項目のみ非開始。バッチは継続する
    case confirmationMismatch
    /// 1.3 の権限・クォータブロック（export-saga.md 1.5）。バッチを停止し、以降の写真を開始しない
    case batchPaused(ExportStartBlock)
}

/// バッチ内 1 写真の開始入力。`ExportCoordinator.startBatchItem(_:capabilities:)` へ渡す。
public struct BatchExportItemRequest: Sendable {
    public let batchID: BatchID
    public let queueItemID: ExportQueueItemID
    public let mode: BatchReviewMode
    public let batchReviewState: BatchReviewState
    public let request: SingleExportRequest

    public init(
        batchID: BatchID,
        queueItemID: ExportQueueItemID,
        mode: BatchReviewMode,
        batchReviewState: BatchReviewState,
        request: SingleExportRequest
    ) {
        self.batchID = batchID
        self.queueItemID = queueItemID
        self.mode = mode
        self.batchReviewState = batchReviewState
        self.request = request
    }
}

extension ExportCoordinator {
    /// export-saga.md 1.6 の順序でバッチ内 1 写真を認可・開始する。1.1 のみ単体と異なり
    /// バッチ向けの一致検査（isBatchConfirmationConsistent）を使う。1.2 の能力ブロックは
    /// `isExemptFromCapabilityBlock`（単体と共有）の免除評価を経てもなお成立する場合にのみ
    /// `queueStateAfterAuthorization(_:occurredAt:)` の戻り値をそのまま `itemFailed` に載せる
    /// （レビュー第2ラウンド C）。1.2 以降（実体確認・startExport）は単体と共通の経路
    /// （authorizeAndStart）を再利用する。
    ///
    /// 呼び出し元は写真を順番に処理し、`batchPaused` が返った時点で残りの `waiting` を呼ばない
    /// ことで、1.5「まだ認可されていない写真は開始せず、バッチを paused にする」を実現する。
    /// それ以外の帰結（itemFailed / itemPaused / confirmationMismatch）は該当項目のみを終了させ、
    /// バッチは次の写真へ進む（architecture.md 6.4「一枚の失敗でバッチ全体を停止しない」）。
    /// 既に `.started` して `generateOutput` まで進んだ写真は、この呼び出しの後で権限が変わっても
    /// 開始時の `ExportJob.authorization` のまま完了する（authorization は startExport 時点で
    /// ExportJob へ固定済みのため、Coordinator 側で追加の対応は不要）。
    public func startBatchItem(
        _ item: BatchExportItemRequest,
        capabilities: ResolvedCapabilities
    ) async throws -> BatchItemStartOutcome {
        try await recoveryGate.awaitRecoveryCompleted()
        guard isBatchConfirmationConsistent(item) else {
            return .confirmationMismatch
        }

        let renderSpecAuthorization = authorizeRenderSpec(
            item.request.renderSpec, stampCatalog: stampCatalog, capabilities: capabilities
        )
        if let queueState = queueStateAfterAuthorization(renderSpecAuthorization, occurredAt: now()) {
            // Task 10「変更せず再書き出し」の免除（export-saga.md 1.2）。単体側
            // （ExportCoordinator.swift の startExport）と同じ形で、1.2 の能力ブロックの
            // 場合にのみ評価する。免除の条件（確定記録の存在・設定の一致・同一 Project）は
            // 単体／バッチを区別しないため、経路によって認可結果が食い違ってはならない
            // （レビュー第2ラウンド C）。消費（accountingMode）の評価は免除せず、従来どおり
            // authorizeAndStart 経由の startExport に委ねる。
            guard try await isExemptFromCapabilityBlock(item.request) else {
                return .itemFailed(queueState)
            }
        }

        let outcome = try await queue.run {
            try await self.authorizeAndStart(item.request, batchID: item.batchID, queueItemID: item.queueItemID)
        }
        switch outcome {
        case .started(let job):
            return .started(job)
        case .workingSourceMissing:
            return .itemPaused(.paused(.sourceReselectionRequired))
        case .blocked(let block):
            return .batchPaused(block)
        }
    }

    /// export-saga.md 1.1 バッチ行: 各写真の確認一致 + BatchReviewState.batchID の一致 +
    /// モード別条件（おまかせ一括は overviewConfirmed、1 枚ずつ確認は isReviewed）。
    private func isBatchConfirmationConsistent(_ item: BatchExportItemRequest) -> Bool {
        guard item.batchReviewState.batchID == item.batchID else {
            return false
        }
        let confirmation = item.request.previewConfirmation
        guard confirmation.projectID == item.request.projectID,
              confirmation.detectionRevision == item.request.currentDetectionRevision,
              confirmation.previewRenderHash == item.request.currentPreviewRenderHash
        else {
            return false
        }
        switch item.mode {
        case .overview:
            return item.batchReviewState.overviewConfirmed
        case .perPhoto:
            return item.request.isReviewed
        }
    }
}
