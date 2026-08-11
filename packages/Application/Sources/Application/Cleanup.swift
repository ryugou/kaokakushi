import Foundation

// Cleanup — 後始末（discardExport / abandonDeliveryAttempt 等）の失敗で元エラーを失わない
// ための共通ヘルパー（Issue #7 レビュー第2ラウンド A）。
//
// 正本: Global Constraints「エラーの握りつぶし禁止」。ExportCoordinator+Generate.swift
// （Task 5, reviewer 一次レビュー fix round 2 W2）で導入した「元エラーを優先して throw し、
// 後始末の失敗も失わない」ロジックが OutputDeliveryCoordinator.swift の
// abandonDeliveryAttempt 失敗経路にも同型で必要だったため、Application 内の共通ヘルパーへ
// 括り出す。
//
// runShieldedFromCancellation はもともと ExportCoordinator+Generate.swift の private
// メソッドだったが、OutputDeliveryCoordinator.saveToPhotoLibrary の abandonDeliveryAttempt
// 失敗経路にも同型で必要になったため、後始末ヘルパーの集約先であるこのファイルへ移した
// （Issue #7 受け渡し後始末のキャンセルシールド横展開）。

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
///
/// 注意（意図的な破棄）: この正規化は `cause.cleanupFailure`（1回目の後始末の失敗）を
/// 保持しない。1回目の cleanup が失敗し、2回目の cleanup（この呼び出し）が成功した場合、
/// 1回目の cleanupFailure は呼び出し元へ伝わらず消える。真因（rootCause）は常に保持される
/// ため実害は小さいが、Global Constraints「エラーの握りつぶし禁止」との兼ね合いを踏まえた
/// 意図的な設計判断である（1回目の後始末失敗そのものを追跡する用途には使えない）。
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

/// キャンセル済みのタスクコンテキストであっても、渡した処理を最後まで実行させるための
/// シールド。非構造化 `Task` は親のキャンセル状態を継承しないため、呼び出し元が
/// キャンセルされていても、ここで包んだ処理はキャンセルされていない文脈で実行される。
/// 処理自体が失敗すればそのエラーはそのまま伝播する。
///
/// 呼び出し元が既に `SerialTaskQueue.run` の op の内側にいる場合、ここで queue を
/// 取り直してはならない（自己デッドロックする。呼び出し元がキューを保持したまま
/// 完了を待っているため、同じキューへ新たな `run` を投入しても実行順が回ってこない）。
func runShieldedFromCancellation<T: Sendable>(
    _ operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await Task { try await operation() }.value
}
