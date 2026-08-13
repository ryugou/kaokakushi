import Foundation

// 受け渡しの永続化ポート（export-saga.md 7 章「受け渡し」・7.0「写真ライブラリ保存の結果不明」、
// architecture.md「未受け渡し出力の状態」）。
//
// `OutputDeliveryStore` は `ExportSagaStore` とは寿命が異なるため分ける（正本の注記どおり）。
// `OutputState` / `OutputRecord.isUndelivered` は Accounting/OutputRecord.swift（Task 3）に
// 実装済みのため再宣言しない。`OutputDeliverySnapshot` はそれを読み取り専用で束ねるだけ。
//
// `ShareResult`（export-saga.md 7.0 末尾）はここに含めない。SharePresenter（image-pipeline.md
// 5 章の @MainActor UI プロトコル）専用の型で、永続化ポートのシグネチャに現れないため
// （spec 参照。SharePresenter 自体も Task 4 のスコープ外）。
//
// アクセス修飾（public）の方針は ExportSagaStore.swift と同じ。

/// 保存の試行中を表す。runtime 側のテーブル（export-saga.md 7.0）。
/// 正本は Sendable のみ（試行中の一時状態を値として比較する用途が正本コードブロックに無いため
/// Equatable を追加しない）
public struct DeliveryAttempt: Sendable {
    public let exportID: ExportID
    public let startedAt: Date
    public let previousState: OutputState   // 試行開始前の状態

    public init(exportID: ExportID, startedAt: Date, previousState: OutputState) {
        self.exportID = exportID
        self.startedAt = startedAt
        self.previousState = previousState
    }
}

/// 写真ライブラリ保存の結果が不明であることの記録。runtime 側のテーブル（export-saga.md 7.0）。
/// 正本は Sendable のみ
public struct UnknownLibrarySave: Sendable {
    public let exportID: ExportID
    public let occurredAt: Date

    public init(exportID: ExportID, occurredAt: Date) {
        self.exportID = exportID
        self.occurredAt = occurredAt
    }
}

/// OutputRecord と UnknownLibrarySave を結合した読み取り用の値（architecture.md
/// 「未受け渡し出力の状態」）。正本は Sendable のみ（OutputRecord 自体が Equatable でないため
/// 合成できない。OutputRecord.swift と同じ判断）
public struct OutputDeliverySnapshot: Sendable {
    public let output: OutputRecord
    public let hasUnknownLibrarySave: Bool

    public init(output: OutputRecord, hasUnknownLibrarySave: Bool) {
        self.output = output
        self.hasUnknownLibrarySave = hasUnknownLibrarySave
    }

    /// 利用者の対応が要る。isUndelivered とは別の軸
    public var requiresDeliveryAttention: Bool {
        output.isUndelivered || hasUnknownLibrarySave
    }
}

/// 受け渡し（7 章）。ExportSagaStore とは寿命が異なるため分ける
public protocol OutputDeliveryStore: Sendable {
    /// previousState を記録する。事前条件: settledAt != nil（nil なら throw）
    func beginDeliveryAttempt(_ exportID: ExportID) async throws
    /// delivered への更新と attempt 削除を単一トランザクションで
    func completeLibrarySave(_ exportID: ExportID) async throws
    /// **共有（`SharePresenter`への外部提示）の開始前に呼ぶ。** `settledAt == nil` なら throw する。
    /// `completeShare` と同じ事前条件を検査するだけの読み取り専用 API（`completeShare` は検査に
    /// 加えて `delivered` への状態更新も行うため、外部提示より前の「検査だけ」には使えない。
    /// Issue #32 C-1: 従来は外部提示の後で `completeShare` が検査していたため、未確定
    /// （`settledAt == nil`）の出力でも共有シートが開いてしまっていた）。呼び出し元は引数の
    /// `OutputRecord.settledAt` を信頼してはならない（stale でありうるため）。必ずこの API で
    /// 権威あるストアへ問い合わせること（export-saga.md 7.0「共有には DeliveryAttempt を
    /// 作らない」・7 章「利用者への受け渡し」）。
    func requireSettled(_ exportID: ExportID) async throws
    /// 事前条件: settledAt != nil（nil なら throw）
    func completeShare(_ exportID: ExportID) async throws
    /// previousState へ戻す（現在が delivered なら維持）
    func abandonDeliveryAttempt(_ exportID: ExportID) async throws
    /// 起動時。残存 attempt を previousState に応じて解決し、解決後の全出力の受け渡し状態を返す（単一トランザクション）
    func resolveOrphanedAttempts() async throws -> [OutputDeliverySnapshot]
    func loadUnknownLibrarySaves() async throws -> [UnknownLibrarySave]
    func clearUnknownLibrarySave(_ exportID: ExportID) async throws
    /// 完了後の出力を利用者が明示的に破棄する（状態遷移ではない）。DB トランザクションで OutputRecord を
    /// 削除し、同一トランザクションで実体ファイルを PendingFileDeletion へ登録する。実削除はコミット後、
    /// 失敗時は起動時再試行する（削除経路の正本はアーキテクチャ設計 7.5）。UnknownLibrarySave があれば
    /// FK CASCADE で消える。事前条件: settledAt != nil（完了前のやり直しは discardExport を使う）、
    /// かつ対象の DeliveryAttempt が存在しないこと（7.0。試行中の破棄は拒否する）
    func deleteOutput(_ exportID: ExportID) async throws
}
