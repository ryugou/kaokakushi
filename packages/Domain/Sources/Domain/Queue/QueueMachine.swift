import Foundation

// エクスポートキュー状態機械の遷移関数（architecture.md 6.4「バッチ処理」+
// test-plan.md 2.4「バッチの1項目が blocked のとき failed(capabilityRequired) へ遷移し、
// バッチの完了判定が成立すること」）。
//
// 状態の集合（`ExportQueueState` / `ExportQueueFailure` / `AppErrorCode.capabilityRequired`）
// は Queue/ExportQueueState.swift で確定済みのため、ここに新しい state/case を追加しない
// （正本の「状態を増やさない」原則）。`isTerminal` も同ファイルの1箇所を再利用し、独自の
// 終端判定を書き下さない（architecture.md 6.4「isTerminal を各所で書き下さない」。
// 履歴削除可否判定・バッチ完了判定・復旧対象選定がすべてこの1述語を使う）。
//
// 正本に明記が無く判断した点（確定済み）:
// - `queueStateAfterAuthorization` は `.authorized` の場合 nil を返す（このタイミングでは
//   状態を変えない。authorized 後の次状態決定は Application 層の話で Task 8 の対象外）。
// - `.blocked(reason)` は reason の具体的な種類に関わらず常に
//   `.failed(errorCode: .capabilityRequired, isRetryable: false)` を返す（premium / custom /
//   unknownBuiltIn いずれでも同一のキュー状態。Paywall 表示の出し分けは UI 層の責務）。
// - `isBatchComplete` は itemStates が空配列なら false（空バッチは完了とは言えない）。

/// authorizeRenderSpec が blocked を返したキュー項目の遷移先を決める。
/// 正本: test-plan.md 2.4「バッチの1項目が blocked のとき failed(capabilityRequired)へ遷移」
public func queueStateAfterAuthorization(
    _ authorization: RenderSpecAuthorization,
    occurredAt: Date
) -> ExportQueueState? {
    switch authorization {
    case .authorized:
        return nil
    case .blocked:
        let failure = ExportQueueFailure(
            errorCode: .capabilityRequired,
            isRetryable: false,
            occurredAt: occurredAt
        )
        return .failed(failure)
    }
}

/// バッチ内の全キュー項目が終端状態に達しているかどうか（バッチの完了判定）。
/// 正本: architecture.md 6.4 の isTerminal を複数項目に畳み込んだもの。新しい判定基準は導入しない。
public func isBatchComplete(_ itemStates: [ExportQueueState]) -> Bool {
    guard !itemStates.isEmpty else {
        return false
    }
    return itemStates.allSatisfy { $0.isTerminal }
}
