import Testing
@testable import Domain
import Foundation

// Task 2: 一括処理への参入可否（architecture.md 6.4「バッチ処理」節〈872-879行付近〉、
// Issue #20）。
//
// canUseProBatch を持つ利用者は remainingCredits に関わらず常に参入できる。
// canUseBatchTrial だけの利用者は残クレジットがある間だけ参入できる。
// どちらの能力も無ければ remainingCredits に関わらず参入できない。

// capabilities(...) ビルダーは TestSupport.swift の共有ヘルパーを使う。

// MARK: - canUseProBatchを持てばremainingCreditsに関わらず常に参入できる

@Test(
    "canUseProBatchがtrueならremainingCreditsの値に関わらず常に参入できる",
    arguments: [0, 1, 5]
)
func canEnterBatchAlwaysAllowsWhenProBatchIsGranted(remainingCredits: Int) {
    let subject = capabilities(canUseProBatch: true, canUseBatchTrial: false)

    #expect(canEnterBatch(capabilities: subject, remainingCredits: remainingCredits) == true)
}

// MARK: - canUseBatchTrialのみの利用者は残クレジットの範囲でのみ参入できる

@Test("canUseProBatchが無くcanUseBatchTrialがありremainingCreditsが正なら参入できる")
func canEnterBatchAllowsTrialUserWithRemainingCredits() {
    let subject = capabilities(canUseProBatch: false, canUseBatchTrial: true)

    #expect(canEnterBatch(capabilities: subject, remainingCredits: 1) == true)
}

@Test("canUseProBatchが無くremainingCreditsが0なら参入できない")
func canEnterBatchDeniesWhenRemainingCreditsIsZero() {
    let subject = capabilities(canUseProBatch: false, canUseBatchTrial: true)

    #expect(canEnterBatch(capabilities: subject, remainingCredits: 0) == false)
}

// MARK: - 両方の能力が無ければremainingCreditsに関わらず参入できない

@Test(
    "canUseProBatchもcanUseBatchTrialも無ければremainingCreditsに関わらず参入できない",
    arguments: [0, 1, 5]
)
func canEnterBatchDeniesWhenNeitherCapabilityIsGranted(remainingCredits: Int) {
    let subject = capabilities(canUseProBatch: false, canUseBatchTrial: false)

    #expect(canEnterBatch(capabilities: subject, remainingCredits: remainingCredits) == false)
}
