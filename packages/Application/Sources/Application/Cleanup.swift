import Foundation

// Cleanup — 後始末（discardExport / abandonDeliveryAttempt 等）の失敗で元エラーを失わない
// ための共通ヘルパー（Issue #7 レビュー第2ラウンド A）。
//
// 正本: Global Constraints「エラーの握りつぶし禁止」。ExportCoordinator+Generate.swift
// （Task 5, reviewer 一次レビュー fix round 2 W2）で導入した「元エラーを優先して throw し、
// 後始末の失敗も失わない」ロジックが OutputDeliveryCoordinator.swift の
// abandonDeliveryAttempt 失敗経路にも同型で必要だったため、Application 内の共通ヘルパーへ
// 括り出す。

/// 後始末（`cleanup`）自体が失敗した場合に、失敗の真因を後始末の失敗へすり替えずに
/// 呼び出し元へ伝えるための複合エラー。`cause` が本来の失敗（真因）、`cleanupFailure` が
/// 後始末自体の失敗であり、どちらも失われない。
public struct CleanupPreservingError: Error, Sendable {
    public let cause: Error
    public let cleanupFailure: Error
}

/// `cause`（本来の失敗）の後始末として `cleanup` を実行し、`cleanup` の成否に関わらず
/// `cause` を最優先で throw する。`cleanup` 自体が失敗した場合は `cause` を失わず
/// `CleanupPreservingError` へ包んで throw する。`cause` が既に `CleanupPreservingError`
/// （呼び出し元が二重に後始末を試みた場合の入れ子ラップ）であれば、その `cause`（真因そのもの）
/// を取り出してから使う（真因が入れ子になって埋もれないようにするための正規化）。
public func runCleanupPreservingError(
    cause: Error, cleanup: @Sendable () async throws -> Void
) async throws -> Never {
    let rootCause = (cause as? CleanupPreservingError)?.cause ?? cause
    do {
        try await cleanup()
    } catch let cleanupFailure {
        throw CleanupPreservingError(cause: rootCause, cleanupFailure: cleanupFailure)
    }
    throw rootCause
}
