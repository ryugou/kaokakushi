import Foundation

// バッチ処理の開始時ポリシースナップショット（architecture.md 6.4「バッチ処理」
// 「開始時の設定を固定する」）。

public struct BatchPolicySnapshot: Sendable, Equatable {
    public let kind: BatchKind            // クランプ先を決める（下記）
    public let batchSizeLimit: Int32
    public let trialCreditCount: Int32
    public let concurrencyLimit: Int32

    public init(kind: BatchKind, batchSizeLimit: Int32, trialCreditCount: Int32, concurrencyLimit: Int32) {
        self.kind = kind
        self.batchSizeLimit = batchSizeLimit
        self.trialCreditCount = trialCreditCount
        self.concurrencyLimit = concurrencyLimit
    }
}

// architecture.md 6.4 のコードブロックは raw value 無しの enum
// （`enum BatchKind: Sendable, Hashable { case proBatch, case trial }`）だが、直後の表で
// DB 列値 proBatch=1 / trial=2 が固定されている。「列値を固定する（`case` 宣言順に依存させると
// 版によって trial のバッチが proBatch として上限 50 でクランプされうる。OutputState と同じ規則）」
// という明文の要求を満たすには raw value が必須であり、OutputState（Accounting/OutputRecord.swift）
// と同じ理由で UInt32 raw value を付ける。
/// このバッチが Pro の通常一括かトライアルか。作成時に確定する
public enum BatchKind: UInt32, Sendable, Hashable {
    case proBatch = 1      // canUseProBatch による通常の一括処理
    case trial = 2         // クレジット消費による一括トライアル
}
