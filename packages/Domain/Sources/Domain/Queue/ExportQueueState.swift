import Foundation

// エクスポートキュー状態機械の型群（architecture.md 6.4「バッチ処理」+ 9.1「ログ・診断」）。
//
// 状態機械そのもの（遷移関数）は Task 8 の担当。ここでは状態を表す型のみを転記する。

public enum ExportQueueState: Sendable, Equatable {
    case waiting
    case analyzing
    case reviewRequired
    case exporting
    case completed
    case failed(ExportQueueFailure)
    case canceled
    case paused(QueuePauseReason)
}

/// 失敗の理由。再試行の可否を型で持つ
public struct ExportQueueFailure: Sendable, Equatable {
    public let errorCode: AppErrorCode      // 9.1 の列挙
    public let isRetryable: Bool
    public let occurredAt: Date

    public init(errorCode: AppErrorCode, isRetryable: Bool, occurredAt: Date) {
        self.errorCode = errorCode
        self.isRetryable = isRetryable
        self.occurredAt = occurredAt
    }
}

public enum QueuePauseReason: Sendable, Equatable {
    case entitlementExpired            // Pro 契約の終了（書き出し Saga 1.4）
    case storageInsufficient
    case userPaused
    /// 処理用の元素材が失われた。同じ写真を選び直せば再開できる
    case sourceReselectionRequired
}

public extension ExportQueueState {
    /// 終端かどうかの判定を 1 か所に置く
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .canceled: return true
        case .waiting, .analyzing, .reviewRequired, .exporting, .paused: return false
        }
    }
}

// architecture.md 9.1 からの最小限の転記（AppError / CrashReporter / CrashContext は対象外。
// ExportQueueFailure.errorCode の型としてのみ必要なため enum 本体のみ用意する。
// このプロパティは計画表のどの Task にも明示割当が無いギャップであり、Task 3 が作る
// ExportQueueFailure のフィールド型としてコンパイルに必須のため、正本の enum 本体のみを
// ここへ転記する判断とした（spec で確定済み）。
//
// 欠番（10, 11, 12, 14, 20）はそのまま維持し詰め直さない（正本の指示。「値の欠番はそのまま
// 維持し詰め直さない」9.1）。
public enum AppErrorCode: Int32, Sendable, Hashable {
    case unknown = 0
    case photoLoadFailed = 1
    case unsupportedFormat = 2
    case detectionFailed = 3
    case renderFailed = 4
    case encodeFailed = 5
    case storageInsufficient = 6
    case fileWriteFailed = 7
    case fileVerificationFailed = 8
    case databaseFailure = 9
    case protectedDataUnavailable = 13
    case photoLibrarySaveFailed = 15
    case photoLibraryPermissionDenied = 16
    case shareFailed = 17
    case entitlementVerificationFailed = 18
    case purchaseFailed = 19
    case sourceMissing = 21
    case sourceMismatch = 22
    case capabilityRequired = 23      // 設定内容が現在の能力で許されない
}
