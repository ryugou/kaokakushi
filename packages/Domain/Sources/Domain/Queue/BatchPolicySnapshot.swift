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

// raw value は DB 列値（architecture.md 6.4 のコードブロックが正本。
// スキーマ移行をまたぐため case の宣言順に依存させない）。
/// このバッチが Pro の通常一括かトライアルか。作成時に確定する
public enum BatchKind: UInt32, Sendable, Hashable {
    case proBatch = 1      // canUseProBatch による通常の一括処理
    case trial = 2         // クレジット消費による一括トライアル
}
