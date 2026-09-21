import Foundation
import Domain

// ExportCoordinator+Batch — バッチ進行（Issue #7 Task 7、追補: batch-progression spec、
// 一括処理キュー簡素化 Issue #40 決定1）。
//
// 正本: export-saga.md 1.1（バッチの開始条件: 各写真の確認一致 + BatchReviewState.batchID の
// 一致 + モード別条件）・1.5（開始後の権限変化: 有料契約の失効・月間上限への到達・昇格が
// 起きても無視し、バッチ開始時の認可スナップショットで全項目を完了させる）、1.6（開始の順序は
// 単体と共通・手順4の帰結）、architecture.md 6.4「一枚の失敗でバッチ全体を停止しない」、
// Domain/Queue/QueueMachine.swift の queueStateAfterAuthorization（1.2 の能力ブロックの
// 判定に使う。判定結果の ExportQueueState 自体はもう保持しない）。
//
// startBatchItem の帰結は BatchItemStartOutcome で表す（export-saga.md 1.6 の enum
// 定義と完全一致。started 以外は associated value を持たない）:
// - started: 開始した。バッチは継続する
// - itemPaused: 手順3で `WorkingSourceRecord` の行はあるが実体ファイルが失われていた。
//   この項目のみ paused(.sourceReselectionRequired) として扱われる。バッチは継続する
// - itemFailed: 手順1（確認不一致）・2（能力ブロックで免除不成立）・5（revision 不一致）の
//   いずれかが不成立、または手順3で `WorkingSourceRecord` の行自体が存在しない
//   （AppErrorCode.sourceMissing）。この項目のみ failed として扱われる。バッチは継続する
//
// 決定済みの設計判断（オーケストレーターの spec で確定済み。疑問視しない）:
// - Coordinator はバッチ全体を1回の呼び出しでループ処理しない。1.6 の「専用の排他ゲートや
//   素材単位のロックは不要」のとおり、直列性は SerialTaskQueue（Task 2）が構造的に保証する
//   ため、呼び出し元（バッチ進行ループ）が写真ごとに startBatchItem → 認可されれば
//   generateOutput（Task 5、既存の公開 API）の順で呼ぶ。1.6 の帰結はすべて該当項目のみを
//   終了させバッチ全体を止める特別なケースを持たないため、呼び出し元は
//   items を最後まで順番に処理すればよい。1.5「開始後の失効・昇格を無視する」は Coordinator
//   側の分岐では実現しない。バッチの認可は Coordinator が一度だけ呼ぶ createBatch（1.6）が
//   バッチ作成時に評価して `Batch` 行へ固定し、各項目の startExport はその固定済み認可を
//   読むだけで再評価しない（一括処理キュー簡素化 Issue #40 決定2。Coordinator は
//   authorizeAndStart を常に同じ形で呼ぶだけでよく、固定済み認可の読み出しは Persistence 側の
//   責務）。Coordinator 自身が「バッチを paused にする」というグローバル状態を持つ必要はない
//   （ExportJob の行の有無だけが状態を表す。export-saga.md 2 章と同じ設計原則）
// - 1.1 のモード別条件はここでのみ判定する（Domain に新しい型を追加しない。おまかせ一括/
//   1 枚ずつ確認という区別自体が Domain の正本コードブロックに型として存在しないため、
//   Application 層の入力構築の都合として BatchReviewMode を定義する）
// - startExport（単体）と処理順序を共有するため、実体確認・store 呼び出しは
//   ExportCoordinator.swift の authorizeAndStart(_:batchID:) をそのまま再利用する。
//   authorizeAndStart の戻り値は `AuthorizeAndStartOutcome`（started/workingSourceMissing/
//   sourceRowMissing/staleProjectRevision/blocked のケースしか存在しない）であり、
//   confirmationMismatch/renderSpecBlocked は型として存在しない（レビュー第2ラウンド B。
//   旧実装は `ExportStartOutcome` をそのまま返し、
//   ここで到達不能な分岐と `preconditionFailure` を人間の推論に頼って書いていた）

/// 一括処理の確認モード（architecture.md 6.4「一括処理モード」）。
/// おまかせ一括は一覧確認（`BatchReviewState.overviewConfirmed`）で全写真の確認を代表させ、
/// 1 枚ずつ確認は写真ごとの `ReviewDecision` 確定（`SingleExportRequest.isReviewed`）を見る
/// （export-saga.md 1.1 の表）。
public enum BatchReviewMode: Sendable, Equatable {
    case overview
    case perPhoto
}

/// `startBatchItem` の帰結（export-saga.md 1.6 の enum 定義と完全一致。
/// `started` 以外は associated value を持たない）。
public enum BatchItemStartOutcome: Sendable {
    /// 開始した。バッチは継続する
    case started(ExportJob)
    /// 手順3で `WorkingSourceRecord` の行はあるが実体ファイルが失われていた。該当項目だけが
    /// セッション内で paused(.sourceReselectionRequired) として扱われる。バッチの残り項目は
    /// 続行する
    case itemPaused
    /// 手順1・2・5のいずれかが不成立（確認不一致・能力不足・revision 不一致）、または手順3で
    /// `WorkingSourceRecord` の行自体が存在しない（`AppErrorCode.sourceMissing`）。該当項目
    /// だけがセッション内で failed として扱われる。バッチの残り項目は続行する
    case itemFailed
}

/// バッチ内 1 写真の開始入力。`ExportCoordinator.startBatchItem(_:capabilities:)` へ渡す。
public struct BatchExportItemRequest: Sendable {
    public let batchID: BatchID
    public let mode: BatchReviewMode
    public let batchReviewState: BatchReviewState
    public let request: SingleExportRequest

    public init(
        batchID: BatchID,
        mode: BatchReviewMode,
        batchReviewState: BatchReviewState,
        request: SingleExportRequest
    ) {
        self.batchID = batchID
        self.mode = mode
        self.batchReviewState = batchReviewState
        self.request = request
    }
}

extension ExportCoordinator {
    /// export-saga.md 1.6 の順序でバッチ内 1 写真を認可・開始する。1.1 のみ単体と異なり
    /// バッチ向けの一致検査（isBatchConfirmationConsistent）を使う。1.2 の能力ブロックは
    /// `isExemptFromCapabilityBlock`（単体と共有）の免除評価を経てもなお成立する場合にのみ
    /// `itemFailed` を返す（`queueStateAfterAuthorization(_:occurredAt:)` はブロック検知にのみ
    /// 使い、戻り値の `ExportQueueState` 自体はもう保持しない。レビュー第2ラウンド C）。1.2
    /// 以降（実体確認・startExport）は単体と共通の経路（authorizeAndStart）を再利用する。
    ///
    /// 呼び出し元は写真を順番に処理する。started 以外の帰結（itemFailed / itemPaused）は
    /// いずれも該当項目のみを終了させバッチを止めないため（architecture.md 6.4「一枚の失敗で
    /// バッチ全体を停止しない」）、呼び出し元は残りの項目も続けて呼んでよい。1.5「開始後に
    /// 有料契約の失効・月間上限への到達・昇格が起きても無視し、バッチ開始時の認可
    /// スナップショットで全項目を完了させる」は、この Coordinator の分岐では実現しない。
    /// バッチの認可は Coordinator が一度だけ呼ぶ createBatch がバッチ作成時に評価して
    /// `Batch` 行へ固定し、各項目の startExport はその固定済み認可を読むだけで再評価しない
    /// （一括処理キュー簡素化 Issue #40 決定2）。Coordinator は authorizeAndStart を
    /// 常に同じ形で呼ぶだけでよく、追加の対応は不要。
    public func startBatchItem(
        _ item: BatchExportItemRequest,
        capabilities: ResolvedCapabilities
    ) async throws -> BatchItemStartOutcome {
        try await recoveryGate.awaitRecoveryCompleted()
        guard isBatchConfirmationConsistent(item) else {
            return .itemFailed
        }

        let renderSpecAuthorization = authorizeRenderSpec(
            item.request.renderSpec, stampCatalog: stampCatalog, capabilities: capabilities
        )
        if queueStateAfterAuthorization(renderSpecAuthorization, occurredAt: now()) != nil {
            // Task 10「変更せず再書き出し」の免除（export-saga.md 1.2）。単体側
            // （ExportCoordinator.swift の startExport）と同じ形で、1.2 の能力ブロックの
            // 場合にのみ評価する。免除の条件（確定記録の存在・設定の一致・同一 Project）は
            // 単体／バッチを区別しないため、経路によって認可結果が食い違ってはならない
            // （レビュー第2ラウンド C）。一方で 1.3 の消費（accountingMode）はバッチ項目では
            // 評価しない。createBatch がバッチ作成時に一度だけ評価して `Batch` 行へ固定した
            // 認可を、各項目の ExportJob.authorization へそのままコピーする（正本 1.6
            // 手順4）。したがってこの 1.2 免除の成否は accountingMode に影響しない。
            guard try await isExemptFromCapabilityBlock(item.request) else {
                return .itemFailed
            }
        }

        let outcome = try await queue.run {
            try await self.authorizeAndStart(item.request, batchID: item.batchID)
        }
        switch outcome {
        case .started(let job):
            return .started(job)
        case .workingSourceMissing:
            return .itemPaused
        case .sourceRowMissing, .staleProjectRevision, .blocked:
            // 手順3（行自体が存在しない）・手順5（revision 不一致）は該当項目のみを終了させ
            // バッチを止めない（1.6）。`.blocked` は正本 1.6 手順4によりバッチ項目では発生
            // しない（Batch 行に固定された認可を評価せずコピーするため）が、
            // `AuthorizeAndStartOutcome` を単体経路と共有しているため網羅として畳み込む
            // （防御的分岐）。単体と異なり throw しない（このファイル冒頭コメント
            // 「itemFailed」の定義参照）。
            return .itemFailed
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
