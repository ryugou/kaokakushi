import Foundation

// 一括処理への参入可否（architecture.md 6.4「バッチ処理」節冒頭。Task 2,
// Issue #20）。
//
// 一括処理の制限なし利用は canUseProBatch が必要。canUseBatchTrial だけを持つ利用者は、
// 残クレジットの範囲で一括処理を実行できる。判定に Plan を使わない（料金表や説明文での
// プラン名使用は構わないが、実装上の条件式はすべて能力で書く。同節）。

public func canEnterBatch(capabilities: ResolvedCapabilities, remainingCredits: Int) -> Bool {
    capabilities.canUseProBatch ||
    (capabilities.canUseBatchTrial && remainingCredits > 0)
}
