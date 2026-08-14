import Foundation
import Domain

// OutputDeliveryCoordinator — 利用者への受け渡し（Issue #7 Task 8）。
//
// 正本: export-saga.md 7章「利用者への受け渡し」・7.0「写真ライブラリ保存の結果不明」、
// test-plan.md 3.2「完了」の受け渡し項目・3.6「出力の寿命と履歴」の受け渡し状態項目。
//
// 保存（写真ライブラリ）は DeliveryAttempt を経由する3手順（7.0 表）。begin から
// MediaSaver.saveToPhotoLibrary を経て成功なら completeLibrarySave・失敗なら
// abandonDeliveryAttempt までを単一の SerialTaskQueue.run 呼び出しで直列化する
// （ExportCoordinator と共有するグローバル直列キュー1本。architecture.md 4.2。
// actor の isolation を排他の根拠にしない）。completeLibrarySave 自体が失敗した場合は
// abandon せずそのまま伝播する（写真ライブラリへの保存は既に成功しており、DB 反映だけが
// 不明のまま残る。7.0「保存の結果不明」と同じ状況を起動時解決に委ねるため、ここで
// previousState へ戻してはならない）。saveToPhotoLibrary 失敗時の abandonDeliveryAttempt
// 自体が失敗しても、保存失敗の真因を失わない（レビュー第2ラウンド A。Cleanup.swift の
// runCleanupPreservingError を経由する）。abandonDeliveryAttempt と completeLibrarySave は
// いずれも runShieldedFromCancellation（Cleanup.swift）で包み、呼び出し元のキャンセルが
// SerialTaskQueue.onCancel 経由で op 内部へ伝播していても後始末・完了反映の DB 書き込みを
// 完走させる（受け渡し後始末のキャンセルシールド横展開。レビュー第2ラウンド W-1:
// 保存成功直後にキャンセルされると completeLibrarySave も abandonDeliveryAttempt と同じ理由
// （GRDB の DatabaseWriter が task キャンセル時に CancellationError を throw する契約）で
// 失敗しうる。保存は既に成立しているため、その事実の DB 反映を取りやめる理由は無く、同じ
// シールドを適用する。同型の後始末は ExportCoordinator+Generate.swift の discardExport に
// 既にある）。
//
// 共有には DeliveryAttempt を作らない（7.0「共有には DeliveryAttempt を作らない」。結果が
// 同期的に返るため中断点が無い）。Issue #32 C-1: SharePresenter へ渡す前に
// outputDeliveryStore.requireSettled で settledAt != nil を検査する（検査自体は store への
// 問い合わせのため queue 経由。saveToPhotoLibrary の beginDeliveryAttempt と同じ順序）。
// SharePresenter.share 自体は外部 UI 提示であり店（store）を変更しないため queue の外で呼ぶ
// （ExportCoordinator+Settle.swift の OutputFileVerifier.verify と同じ方針。「読み取りは
// 経由しない」）。ShareResult.completed のときのみ completeShare を queue 経由で呼ぶ。
// canceled / failed / unknown は store を呼ばず現在の状態を維持する（安全側へ倒す）。
//
// 破棄（deleteOutput）は queue 経由の薄い委譲。事前条件違反（settledAt == nil・
// DeliveryAttempt 存在中）を含め store の throw をそのまま伝播する
// （Global Constraints「エラーの握りつぶし禁止」）。

/// `SharePresenter` は `@MainActor` の `AnyObject` プロトコルで `Sendable` を宣言していない
/// （Ports/OutputPresentation.swift）。実体は `@MainActor` 隔離のみで安全に守られる
/// （正本コメントの前提）が、existential（`any SharePresenter`）越しではコンパイラの region
/// ベース Sendable 検査がその保証を追跡できず、`OutputDeliveryCoordinator`（self）の隔離
/// 領域に由来する値を `@MainActor` 隔離のメソッドへそのまま渡すと「sending self-isolated
/// value」を拒否する。この box 自体は `@unchecked Sendable` で「呼び出し側が手動でこの値の
/// 安全性を保証する」ことを表し、box を経由して受け渡す（box の型自体が Sendable なため
/// self の隔離領域から切り離して渡せる。box を経由せず `.value` を self 側で先に取り出すと
/// 同じ拒否が再発するため、unwrap は必ず受け取り側で行う）。
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

public actor OutputDeliveryCoordinator {
    private let outputDeliveryStore: OutputDeliveryStore
    private let mediaSaver: MediaSaver
    private let sharePresenterBox: UncheckedSendableBox<SharePresenter>
    private let queue: SerialTaskQueue
    /// 起動時復旧の完了ゲート（Issue #7 Task 12）。変更系操作はキュー投入前にこれを待つ
    /// （export-saga.md 5章「復旧が完了するまで新しい書き出しを開始させない」。キュー内で
    /// 待つと復旧側の操作がキューを取れず自己デッドロックするため、必ずキュー投入より前に待つ）。
    private let recoveryGate: RecoveryGate

    public init(
        outputDeliveryStore: OutputDeliveryStore,
        mediaSaver: MediaSaver,
        sharePresenter: SharePresenter,
        queue: SerialTaskQueue,
        recoveryGate: RecoveryGate
    ) {
        self.outputDeliveryStore = outputDeliveryStore
        self.mediaSaver = mediaSaver
        self.sharePresenterBox = UncheckedSendableBox(value: sharePresenter)
        self.queue = queue
        self.recoveryGate = recoveryGate
    }

    /// 写真ライブラリへ保存する（export-saga.md 7.0 表 手順1〜4）。保存が失敗した場合の
    /// abandonDeliveryAttempt 自体の失敗で、保存失敗の真因が置き換わらないよう
    /// `runCleanupPreservingError`（Cleanup.swift。レビュー第2ラウンド A）を経由する。
    /// 保存が成立した後に呼び出し元のタスクがキャンセルされても throw せず、成功として
    /// 正常 return する（`completeLibrarySave` へのシールドにより DB 反映を完走させるため）。
    /// 呼び出し元はキャンセルを再保存の要求根拠にしてはならない（写真ライブラリへの重複を作る）。
    /// `mediaSaver.saveToPhotoLibrary` 自身がキャンセル起因で throw した場合も同様に扱う。
    /// PhotoKit 側で書き込みが成立したかは判別できないまま `abandonDeliveryAttempt` により
    /// `DeliveryAttempt` が削除される（結果不明の痕跡は残らない）。
    /// この throw も自動再保存の要求根拠にしてはならない（同じく重複を作る）。
    ///
    /// この catch・後続の completeLibrarySave 呼び出しは、いずれも既に `queue.run` の op の
    /// 内側で実行されている。`SerialTaskQueue.run` の `onCancel: { current.cancel() }`
    /// （SerialTaskQueue.swift）が呼び出し元のキャンセルを op 内部へ明示的に伝播させるため、
    /// ここへ来た時点で既にタスクがキャンセル済みでありうる。`abandonDeliveryAttempt` /
    /// `completeLibrarySave` はいずれも DB 書き込みを伴い、キャンセル済み文脈では失敗しうる
    /// （GRDB の DatabaseWriter は task キャンセル時に CancellationError を throw する契約）ため、
    /// どちらも `runShieldedFromCancellation`（Cleanup.swift）でキャンセル非伝播のコンテキストへ
    /// 包む（ExportCoordinator+Generate.swift の discardExport と同型。受け渡し後始末の
    /// キャンセルシールド横展開）。保存（PhotoKit 側）は既に成立しているため、
    /// completeLibrarySave 側のシールドを外して DB 反映を取りやめる理由は無い（レビュー第2
    /// ラウンド W-1）。ここで `queue.run` を取り直してはならない（既に op の内側にいるため
    /// 自己デッドロックする）。
    public func saveToPhotoLibrary(_ output: OutputRecord) async throws {
        try await recoveryGate.awaitRecoveryCompleted()
        try await queue.run {
            try await self.outputDeliveryStore.beginDeliveryAttempt(output.exportID)
            do {
                try await self.mediaSaver.saveToPhotoLibrary(self.outputFile(for: output))
            } catch {
                try await runCleanupPreservingError(cause: error) {
                    try await runShieldedFromCancellation {
                        try await self.outputDeliveryStore.abandonDeliveryAttempt(output.exportID)
                    }
                }
            }
            try await runShieldedFromCancellation {
                try await self.outputDeliveryStore.completeLibrarySave(output.exportID)
            }
        }
    }

    /// OS 共有へ渡す（export-saga.md 7.0「共有には DeliveryAttempt を作らない」）。
    ///
    /// Issue #32 C-1: `SharePresenter` へ渡す**前**に `outputDeliveryStore.requireSettled` で
    /// `settledAt != nil` を検査する（`saveToPhotoLibrary` の `beginDeliveryAttempt` と同じ順序。
    /// 従来は `SharePresenter` へ渡した後に `completeShare` が初めて検査しており、未確定の出力
    /// でも共有シートが開いてしまっていた）。引数 `output.settledAt` は呼び出し元が保持する
    /// 値であり stale でありうるため判断根拠にせず、必ず `requireSettled` で権威あるストアへ
    /// 問い合わせる。検査は `saveToPhotoLibrary` と同じく復旧ゲートを待った後 `queue.run` の
    /// 中で行う。
    public func share(_ output: OutputRecord) async throws -> ShareResult {
        try await recoveryGate.awaitRecoveryCompleted()
        try await queue.run {
            try await self.outputDeliveryStore.requireSettled(output.exportID)
        }
        let result = await Self.performShare(sharePresenterBox, file: outputFile(for: output))
        guard result == .completed else {
            return result
        }
        try await recoveryGate.awaitRecoveryCompleted()
        try await queue.run {
            try await self.outputDeliveryStore.completeShare(output.exportID)
        }
        return result
    }

    /// box（Sendable）を受け取ってから unwrap して呼ぶ（型注釈上のコメントは box 定義側を参照）。
    private static func performShare(
        _ presenterBox: UncheckedSendableBox<SharePresenter>, file: OutputFile
    ) async -> ShareResult {
        await presenterBox.value.share(file)
    }

    /// 完了後の出力を利用者が明示的に破棄する（export-saga.md 7.0 表。状態遷移ではない）。
    public func deleteOutput(_ exportID: ExportID) async throws {
        try await recoveryGate.awaitRecoveryCompleted()
        try await queue.run {
            try await self.outputDeliveryStore.deleteOutput(exportID)
        }
    }

    private nonisolated func outputFile(for output: OutputRecord) -> OutputFile {
        OutputFile(
            exportID: output.exportID,
            file: output.outputFile,
            format: output.format,
            byteSize: output.outputByteSize,
            suggestedCreationDate: output.suggestedCreationDate
        )
    }
}
