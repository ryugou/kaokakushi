import Testing
@testable import Domain
import Foundation

/// Task 3: エクスポートキュー状態機械の型群（architecture.md 6.4 + 9.1）。
///
/// `ExportQueueState.isTerminal`（completed/failed/canceledでtrue、それ以外でfalse）、
/// `ExportQueueFailure` のフィールド保持、`AppErrorCode` の固定rawValue（欠番込み）を検証する。

private func sampleFailure() -> ExportQueueFailure {
    ExportQueueFailure(
        errorCode: .renderFailed, isRetryable: true, occurredAt: Date(timeIntervalSince1970: 1_700_000_000))
}

// MARK: - ExportQueueState.isTerminal

@Test(
    "isTerminalはcompleted/failed/canceledでtrueそれ以外でfalse",
    arguments: [
        (ExportQueueState.waiting, false),
        (ExportQueueState.analyzing, false),
        (ExportQueueState.reviewRequired, false),
        (ExportQueueState.exporting, false),
        (ExportQueueState.completed, true),
        (ExportQueueState.failed(ExportQueueFailure(
            errorCode: .renderFailed,
            isRetryable: true,
            occurredAt: Date(timeIntervalSince1970: 0)
        )), true),
        (ExportQueueState.canceled, true),
        (ExportQueueState.paused(.userPaused), false)
    ]
)
func isTerminalReflectsExpectedStates(state: ExportQueueState, expected: Bool) {
    #expect(state.isTerminal == expected)
}

@Test("ExportQueueFailureが全フィールドを保持する")
func exportQueueFailureHoldsAllFields() {
    let occurredAt = Date(timeIntervalSince1970: 1_700_000_000)
    let subject = assertSendableEquatable(ExportQueueFailure(
        errorCode: .storageInsufficient,
        isRetryable: false,
        occurredAt: occurredAt
    ))
    #expect(subject.errorCode == .storageInsufficient)
    #expect(subject.isRetryable == false)
    #expect(subject.occurredAt == occurredAt)
}

@Test(
    "QueuePauseReasonは4ケースを持ちHashableである",
    arguments: [
        QueuePauseReason.entitlementExpired, .storageInsufficient, .userPaused, .sourceReselectionRequired
    ]
)
func queuePauseReasonHasFourCases(reason: QueuePauseReason) {
    #expect(Set([reason]).contains(reason))
}

@Test("ExportQueueStateはfailedのペイロードを保持する")
func exportQueueStateFailedHoldsPayload() {
    let failure = sampleFailure()
    let subject = ExportQueueState.failed(failure)
    guard case .failed(let payload) = subject else {
        Issue.record("failed ケースが期待どおりに構築されていません")
        return
    }
    #expect(payload == failure)
}

// MARK: - AppErrorCode の固定 rawValue（architecture.md 9.1。欠番 10/11/12/14/20 を含む）

@Test(
    "AppErrorCodeのrawValueが正本どおりで欠番を維持する",
    arguments: [
        (AppErrorCode.unknown, Int32(0)),
        (AppErrorCode.photoLoadFailed, Int32(1)),
        (AppErrorCode.unsupportedFormat, Int32(2)),
        (AppErrorCode.detectionFailed, Int32(3)),
        (AppErrorCode.renderFailed, Int32(4)),
        (AppErrorCode.encodeFailed, Int32(5)),
        (AppErrorCode.storageInsufficient, Int32(6)),
        (AppErrorCode.fileWriteFailed, Int32(7)),
        (AppErrorCode.fileVerificationFailed, Int32(8)),
        (AppErrorCode.databaseFailure, Int32(9)),
        (AppErrorCode.protectedDataUnavailable, Int32(13)),
        (AppErrorCode.photoLibrarySaveFailed, Int32(15)),
        (AppErrorCode.photoLibraryPermissionDenied, Int32(16)),
        (AppErrorCode.shareFailed, Int32(17)),
        (AppErrorCode.entitlementVerificationFailed, Int32(18)),
        (AppErrorCode.purchaseFailed, Int32(19)),
        (AppErrorCode.sourceMissing, Int32(21)),
        (AppErrorCode.sourceMismatch, Int32(22)),
        (AppErrorCode.capabilityRequired, Int32(23))
    ]
)
func appErrorCodeRawValueMatchesCanonicalDoc(code: AppErrorCode, expected: Int32) {
    #expect(code.rawValue == expected)
}

@Test("AppErrorCodeは欠番10/11/12/14/20をraw値として持たない")
func appErrorCodeHasNoCaseForGapValues() {
    let gapValues: [Int32] = [10, 11, 12, 14, 20]
    for gap in gapValues {
        #expect(AppErrorCode(rawValue: gap) == nil)
    }
}

@Test("AppErrorCodeは正本どおり19ケースを持つ")
func appErrorCodeHasExactlyNineteenCases() {
    let allCases: [AppErrorCode] = [
        .unknown, .photoLoadFailed, .unsupportedFormat, .detectionFailed, .renderFailed,
        .encodeFailed, .storageInsufficient, .fileWriteFailed, .fileVerificationFailed,
        .databaseFailure, .protectedDataUnavailable, .photoLibrarySaveFailed,
        .photoLibraryPermissionDenied, .shareFailed, .entitlementVerificationFailed,
        .purchaseFailed, .sourceMissing, .sourceMismatch, .capabilityRequired
    ]
    #expect(allCases.count == 19)
    #expect(Set(allCases).count == 19)
    // default無しのswitchで全ケースをrawValueへ写す。将来ケースが追加されるとこのswitchが
    // 網羅性を失いコンパイルエラーになるため、配列への追加漏れを機械的に検出できる。
    #expect(Set(allCases.map(appErrorCodeExhaustiveRawValue)).count == 19)
}

// 分岐数はケース数そのもの（網羅的 switch によるコンパイル時検出が目的のため許容する）。
// swiftlint:disable:next cyclomatic_complexity
private func appErrorCodeExhaustiveRawValue(_ subject: AppErrorCode) -> Int32 {
    switch subject {
    case .unknown: return 0
    case .photoLoadFailed: return 1
    case .unsupportedFormat: return 2
    case .detectionFailed: return 3
    case .renderFailed: return 4
    case .encodeFailed: return 5
    case .storageInsufficient: return 6
    case .fileWriteFailed: return 7
    case .fileVerificationFailed: return 8
    case .databaseFailure: return 9
    case .protectedDataUnavailable: return 13
    case .photoLibrarySaveFailed: return 15
    case .photoLibraryPermissionDenied: return 16
    case .shareFailed: return 17
    case .entitlementVerificationFailed: return 18
    case .purchaseFailed: return 19
    case .sourceMissing: return 21
    case .sourceMismatch: return 22
    case .capabilityRequired: return 23
    }
}
