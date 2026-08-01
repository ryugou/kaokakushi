import Testing
@testable import Domain
import Foundation

// Task 8: エクスポートキュー状態機械の遷移関数
// （architecture.md 6.4「バッチ処理」+ test-plan.md 2.4「バッチの1項目が blocked のとき
// failed(capabilityRequired) へ遷移し、バッチの完了判定が成立すること」）。
//
// `queueStateAfterAuthorization` が blocked の理由に関わらず同一の failed へ遷移すること、
// authorized では状態を変えない（nil）こと、`isBatchComplete` が既存の `isTerminal` を
// 畳み込んでバッチの完了判定を行う（新しい終端判定基準を導入しない）ことを検証する。

private let sampleOccurredAt = Date(timeIntervalSince1970: 1_700_000_000)

@Test("queueStateAfterAuthorizationはauthorizedでnilを返す（このタイミングでは状態を変えない）")
func queueStateAfterAuthorizationReturnsNilForAuthorized() {
    let subject = queueStateAfterAuthorization(.authorized, occurredAt: sampleOccurredAt)
    #expect(subject == nil)
}

@Test(
    "queueStateAfterAuthorizationはblockedの理由に関わらずfailed(capabilityRequired, isRetryable: false)を返す",
    arguments: [
        RenderSpecBlockReason.premiumStampNotAvailable,
        .customStampNotAvailable,
        .unknownBuiltInStampCode
    ]
)
func queueStateAfterAuthorizationReturnsFailedForAnyBlockedReason(reason: RenderSpecBlockReason) {
    let subject = queueStateAfterAuthorization(.blocked(reason), occurredAt: sampleOccurredAt)
    let expected = ExportQueueState.failed(
        ExportQueueFailure(errorCode: .capabilityRequired, isRetryable: false, occurredAt: sampleOccurredAt)
    )
    #expect(subject == expected)
}

@Test("isBatchCompleteは空配列でfalseを返す（空バッチは完了とは言えない）")
func isBatchCompleteReturnsFalseForEmptyBatch() {
    #expect(isBatchComplete([]) == false)
}

@Test("isBatchCompleteは全項目が終端状態（completed/failed/canceledの組み合わせ）ならtrueを返す")
func isBatchCompleteReturnsTrueWhenAllItemsAreTerminal() {
    let failure = ExportQueueFailure(errorCode: .renderFailed, isRetryable: true, occurredAt: sampleOccurredAt)
    let states: [ExportQueueState] = [.completed, .failed(failure), .canceled, .completed]
    #expect(isBatchComplete(states) == true)
}

@Test(
    "isBatchCompleteは非終端状態が1件でも混ざればfalseを返す",
    arguments: [
        ExportQueueState.waiting, .analyzing, .reviewRequired, .exporting, .paused(.userPaused)
    ]
)
func isBatchCompleteReturnsFalseWhenAnyItemIsNonTerminal(nonTerminalState: ExportQueueState) {
    let states: [ExportQueueState] = [.completed, nonTerminalState, .canceled]
    #expect(isBatchComplete(states) == false)
}
