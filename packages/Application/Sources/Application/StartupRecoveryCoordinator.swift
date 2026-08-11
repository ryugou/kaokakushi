import Foundation
import Domain

// StartupRecoveryCoordinator — 起動時復旧（Issue #7 Task 9・Task 11）。
//
// 正本: export-saga.md 5章「起動時復旧」（復旧手順1〜5の順序）、architecture.md 4.3
// （「起動時に1回のみ実行し、完了まで他のすべてを開始させない」）、architecture.md 7.5
// 「孤児ファイルの GC」（`MaintenanceStore` 節。手順(1)〜(3)）、test-plan.md 3.5
// 「起動時復旧」・3.6「出力の寿命と履歴」の復旧案内項目。
//
// 手順1「running の ExportJob 削除」と、それに伴う未確定（settledAt IS NULL）出力の削除は
// ExportSagaStore.deleteRunningJobs が単一の呼び出しでまとめて行う（ポートの doc コメント）。
// loadRunningJobs → deleteRunningJobs の順で呼ぶ。完了済み（settledAt != nil）の出力には
// この手順で一切触れない（deleteRunningJobs の対象は running な ExportJob 行のみ）。
//
// 手順2「孤児ファイルのGC」は architecture.md 7.5 の手順(1)〜(3)をそのまま実行する
// （Task 11。実装は StartupRecoveryCoordinator+FileGC.swift）。手順(1)で削除を試みた ref の
// 集合を、手順(3)（(2)が登録した ref の削除）の対象から除外する。これが無いと、(1)で
// 削除に失敗した ref の実体はディスクに残ったままのため、(2)の差集合が同じ ref を孤児として
// 再登録し、(3)が同一起動内で同じ ref を2回目の削除試行にかけてしまう
// （Task 11 レビュー C-1）。5章の順序に従い deleteRunningJobs の後、resolveOrphanedAttempts の
// 前に実行する。
//
// `.historyThumbnail` は孤児GC対象の種別（orphanGCKinds）に含めない（architecture.md 7.5 の
// MaintenanceStore 対応表が根拠）。v1 では参照列が無く listReferencedFileIDs が常に空集合を
// 返すため、対象へ含めると現用中の実体まで孤児として削除してしまう。Issue #26 で参照列の追加と
// 同時に有効化する。
//
// 個々のファイル削除・登録解除の失敗は復旧全体を止めない（登録を残し次回起動で再試行する）。
// 失敗を握りつぶさないため、種別・原因エラーを StartupRecoveryReport へ含める（Global
// Constraints「エラーの握りつぶし禁止」。運用者が次のアクションを判断できる情報。Task 11
// レビュー W-1〜W-3）。孤児ファイルGC手順(1)〜(3)自体がストア操作の失敗で完走できなかった
// 場合も、GC 以外の復旧手順を止めない（個々のファイル削除の失敗を復旧全体から隔離している
// のと非対称にしない設計。Task 11 レビュー W-3）。
//
// 手順5「更新誘導」もこの Coordinator が判定ロジックを持たない（architecture.md 6.6 が正本、
// 実装はサブプロジェクト10）。呼び出し点だけを updateGuidanceHook として設け、既定は no-op
// にする（計画 Task 9 チェックリスト「呼び出し点だけ設ける」）。
//
// 「起動時に1回のみ実行」は、最初の runStartupRecovery() 呼び出しが作った Task を
// recoveryTask として保持し、以降の呼び出しはその Task の結果（成功・失敗いずれも）を
// そのまま返すことで満たす（再実行しない。失敗時はゲートを開かないまま残る）。
//
// 「完了まで他のすべてを開始させない」ゲート（awaitRecoveryCompleted）は、完了前に呼ばれた
// 場合は CheckedContinuation を waiters（UUID キー付き）へ積んで保留し、runStartupRecovery() が
// 成功で完了した瞬間にまとめて resume する（Task 9）。ExportCoordinator / OutputDeliveryCoordinator
// の変更系操作がこれをキュー投入前に await する配線は Task 12 で行った（RecoveryGate.swift）。
//
// Task 12 レビュー C-1: awaitRecoveryCompleted は async throws にし、次の2点を満たす。
// - 復旧が失敗で確定している場合（recoveryFailure が非 nil）は待たずに即座に
//   StartupRecoveryFailedError を throw する。復旧は再実行されないため、以後この状態のまま
//   プロセス生存中は変わらない（「新しい書き出しを開始させない」が要求であり無応答は不可）。
// - 待機中にキャンセルされた場合は withTaskCancellationHandler の onCancel から自身の
//   waiterID を waiters から除去したうえで CancellationError を resume する。actor は
//   登録（withCheckedThrowingContinuation のクロージャ内で waiters へ追加する部分）から
//   次の await までを中断せずに実行するため、cancelWaiter・completeGate・failGate のいずれが
//   先に waiters からこの waiterID を取り除いても、取り除いた側だけが resume する
//   （dictionary の removeValue が nil を返せば何もしない）。これにより
//   CheckedContinuation の二重 resume（クラッシュする）を避ける。

/// 起動時復旧の結果（export-saga.md 5章。復旧案内 UI の入力）。
public struct StartupRecoveryReport: Sendable {
    public let outputDeliverySnapshots: [OutputDeliverySnapshot]
    public let unknownLibrarySaves: [UnknownLibrarySave]
    public let deletedRunningJobCount: Int
    /// 孤児ファイル GC（architecture.md 7.5 手順(1)〜(3)）で実削除と登録解除
    /// （clearPendingFileDeletion）の両方に成功した件数。実体は消えたが登録解除だけ
    /// 失敗した件数は含まない（pendingRecordClearFailures 側に計上する。Task 11
    /// レビュー最終指摘）。ディスク上の実体が消えた総数は
    /// `deletedFileCount + pendingRecordClearFailures.count` である。
    public let deletedFileCount: Int
    /// 孤児ファイル GC で実体の削除自体に失敗した内訳（Task 11 レビュー W-1）。
    /// 端末に実体が残り続ける件数（failedFileDeletionCount）と一致する。登録は残り
    /// 次回起動で再試行される。deletedFileCount・pendingRecordClearFailures とは
    /// 排他（実体削除に失敗した ref はどちらにも計上されない）。
    public let failedFileDeletions: [FileDeletionFailure]
    /// 実体の削除には成功したが PendingFileDeletion の登録行を消せなかった内訳
    /// （Task 11 レビュー W-2）。実体は既に消えているため failedFileDeletionCount には
    /// 含めない（登録行だけが残り続けるケースを削除失敗と区別する）。この件数の分だけ
    /// 実体は消えているが deletedFileCount には計上されない（登録解除まで成功して
    /// いないため）。
    public let pendingRecordClearFailures: [FileDeletionFailure]
    /// 孤児ファイルGC手順(1)〜(3)自体がストア操作の失敗で完走できなかった場合の原因
    /// （Task 11 レビュー W-3）。GC 以外の復旧手順は継続するため、この場合
    /// deletedFileCount・failedFileDeletions 等は完走できた範囲のみを反映する。
    public let fileGCFailure: Error?

    /// 孤児ファイル GC で実体の削除自体に失敗した件数（端末に実体が残っている件数）。
    public var failedFileDeletionCount: Int { failedFileDeletions.count }

    public init(
        outputDeliverySnapshots: [OutputDeliverySnapshot],
        unknownLibrarySaves: [UnknownLibrarySave],
        deletedRunningJobCount: Int,
        deletedFileCount: Int,
        failedFileDeletions: [FileDeletionFailure],
        pendingRecordClearFailures: [FileDeletionFailure],
        fileGCFailure: Error?
    ) {
        self.outputDeliverySnapshots = outputDeliverySnapshots
        self.unknownLibrarySaves = unknownLibrarySaves
        self.deletedRunningJobCount = deletedRunningJobCount
        self.deletedFileCount = deletedFileCount
        self.failedFileDeletions = failedFileDeletions
        self.pendingRecordClearFailures = pendingRecordClearFailures
        self.fileGCFailure = fileGCFailure
    }
}

/// 孤児ファイルGCの個別失敗1件の理由（Task 11 レビュー W-1）。`ManagedFileID` は
/// 文字列化して載せない（ManagedFileRef.swift 冒頭コメント「識別子を文字列補間で診断へ
/// 流す経路を作らない」＝architecture.md 6.5）。
public struct FileDeletionFailure: Sendable {
    public let kind: ManagedFileKind
    public let cause: Error

    public init(kind: ManagedFileKind, cause: Error) {
        self.kind = kind
        self.cause = cause
    }
}

public actor StartupRecoveryCoordinator {
    /// 孤児GC対象の種別。`.historyThumbnail` は含めない（ファイル冒頭コメント参照）。
    static let orphanGCKinds: [ManagedFileKind] = ManagedFileKind.allCases.filter(isOrphanGCTarget)

    let exportSagaStore: ExportSagaStore
    let outputDeliveryStore: OutputDeliveryStore
    let maintenanceStore: MaintenanceStore
    let managedFileStore: ManagedFileStore
    /// 復旧手順の変更系操作（deleteRunningJobs・resolveOrphanedAttempts・孤児ファイルGCの
    /// 削除・登録）が経由する共有直列キュー（Issue #7 Task 12。architecture.md 4.2「すべての
    /// 変更系 Coordinator が単一のグローバル直列キューを共有する」）。ExportCoordinator /
    /// OutputDeliveryCoordinator と同じインスタンスを注入する。
    let queue: SerialTaskQueue
    /// 手順5「更新誘導」の呼び出し点（ファイル冒頭コメント参照。判定ロジックはサブプロジェクト10
    /// が実装する）。このフックはゲート開放（completeGate）前に await されるため、ブロッキングな
    /// I/O を行ってはならない（W-4）。ネットワークに触れると、起動直後の初回書き出しがその完了
    /// まで待たされてしまう（サブプロジェクト10 実装時の注意）。
    private let updateGuidanceHook: @Sendable () async -> Void

    private var recoveryTask: Task<StartupRecoveryReport, Error>?
    private var isRecoveryCompleted = false
    /// 復旧が失敗で確定した際の原因エラー（C-1）。非 nil の間、以後の awaitRecoveryCompleted
    /// はこれを cause として StartupRecoveryFailedError を待たずに throw する。
    private var recoveryFailure: Error?
    /// 待機中の awaitRecoveryCompleted 呼び出し（C-1: キャンセル時に該当分だけを除去できるよう
    /// UUID をキーにする）。
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    public init(
        exportSagaStore: ExportSagaStore,
        outputDeliveryStore: OutputDeliveryStore,
        maintenanceStore: MaintenanceStore,
        managedFileStore: ManagedFileStore,
        queue: SerialTaskQueue,
        updateGuidanceHook: @escaping @Sendable () async -> Void = {}
    ) {
        self.exportSagaStore = exportSagaStore
        self.outputDeliveryStore = outputDeliveryStore
        self.maintenanceStore = maintenanceStore
        self.managedFileStore = managedFileStore
        self.queue = queue
        self.updateGuidanceHook = updateGuidanceHook
    }

    /// export-saga.md 5章の順序で起動時復旧を実行する。2回目以降の呼び出しは再実行せず、
    /// 最初の呼び出しの結果（成功なら report・失敗なら同じ throw）をそのまま返す
    /// （architecture.md 4.3「起動時に1回のみ実行」）。
    public func runStartupRecovery() async throws -> StartupRecoveryReport {
        if let recoveryTask {
            return try await recoveryTask.value
        }
        // ゲート開放（completeGate）を復旧 Task の内側へ置き、performRecovery の完了と
        // 同一 Task 内で原子的に行う。runStartupRecovery を呼び出した側（呼び出し元の
        // コンテキスト）が後で `task.value` を待つ間にキャンセルされても、この Task 自体は
        // 独立して完走するため、ゲート開放が呼び出し元の都合に左右されない（Issue #7
        // Task 12）。
        let task = Task {
            do {
                let report = try await self.performRecovery()
                self.completeGate()
                return report
            } catch {
                self.failGate(cause: error)
                throw error
            }
        }
        recoveryTask = task
        return try await task.value
    }

    /// 復旧が完了するまで呼び出し元を保留する（architecture.md 4.3「完了まで他のすべてを
    /// 開始させない」）。既に完了していれば即座に返る。復旧が失敗で確定していれば待たずに
    /// StartupRecoveryFailedError を throw する。待機中にキャンセルされた場合は waiters から
    /// 自身を除去したうえで CancellationError を throw する（C-1。ファイル冒頭コメント参照）。
    public func awaitRecoveryCompleted() async throws {
        if isRecoveryCompleted { return }
        if let recoveryFailure {
            throw StartupRecoveryFailedError(cause: recoveryFailure)
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    /// C-1 のキャンセルハンドラ本体。既に completeGate / failGate が resume 済みなら
    /// waiters から見つからず何もしない（二重 resume を避ける）。
    private func cancelWaiter(_ waiterID: UUID) {
        guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
    }

    /// ストアの throw は握りつぶさずそのまま伝播する（Global Constraints「エラーの
    /// 握りつぶし禁止」）。伝播した場合 completeGate は呼ばれず、ゲートは開かないまま残る。
    /// 孤児ファイルGC（runOrphanFileGC）だけは例外で、GC 起因の失敗を throw させず
    /// report へ落として後続の手順へ進む（W-3。ファイル冒頭コメント参照）。
    private func performRecovery() async throws -> StartupRecoveryReport {
        // loadRunningJobs（queue外の読み取り）→ deleteRunningJobs（queue内の書き込み）の間隔は
        // Task 12 で共有 SerialTaskQueue を経由するようになった分だけ広がっている
        // （キューの順番待ちが挟まる）。この read-then-write に原子性は無いが、
        // ExportCoordinator+Settle.swift の verifyOutputIntegrity と同種の非原子性であり実害も
        // 同様に無い: その間に別の書き出しが running なジョブへ介入すれば store 側が検出し、
        // 呼び出し元へは握りつぶさず伝わる（S-3）。
        let runningJobs = try await exportSagaStore.loadRunningJobs()
        let runningExportIDs = runningJobs.map(\.exportID)
        try await queue.run { try await self.exportSagaStore.deleteRunningJobs(runningExportIDs) }

        let fileGC = await runOrphanFileGC()

        let outputDeliverySnapshots = try await queue.run {
            try await self.outputDeliveryStore.resolveOrphanedAttempts()
        }
        let unknownLibrarySaves = try await outputDeliveryStore.loadUnknownLibrarySaves()

        await updateGuidanceHook()

        return StartupRecoveryReport(
            outputDeliverySnapshots: outputDeliverySnapshots,
            unknownLibrarySaves: unknownLibrarySaves,
            deletedRunningJobCount: runningJobs.count,
            deletedFileCount: fileGC.tally.deletedCount,
            failedFileDeletions: fileGC.tally.failedFileDeletions,
            pendingRecordClearFailures: fileGC.tally.pendingRecordClearFailures,
            fileGCFailure: fileGC.gcFailure
        )
    }

    private func completeGate() {
        guard !isRecoveryCompleted else { return }
        isRecoveryCompleted = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for continuation in pendingWaiters.values {
            continuation.resume()
        }
    }

    /// 復旧が失敗で確定したことを記録し、待機中の呼び出し全員へ StartupRecoveryFailedError を
    /// 返す（C-1）。以後の awaitRecoveryCompleted 呼び出しは recoveryFailure を見て待たずに
    /// throw する。
    private func failGate(cause: Error) {
        guard !isRecoveryCompleted, recoveryFailure == nil else { return }
        recoveryFailure = cause
        let pendingWaiters = waiters
        waiters.removeAll()
        for continuation in pendingWaiters.values {
            continuation.resume(throwing: StartupRecoveryFailedError(cause: cause))
        }
    }
}

// S-1（Task 12 レビュー）: 準拠は RecoveryGate.swift 側ではなくこの具象型のファイルへ置く
// （抽象側が具象型を知る配置は依存の向きと食い違うため。RecoveryGate.swift 冒頭コメント参照）。
extension StartupRecoveryCoordinator: RecoveryGate {}

/// `.historyThumbnail` を孤児GC対象外にする判定（Task 11 レビュー S-1）。網羅 `switch` に
/// することで、`ManagedFileKind` に case が増えた際にコンパイルエラーで対応判断を強制する
/// （配列リテラルのベタ書きだと無言で GC 対象外になってしまうため）。
private func isOrphanGCTarget(_ kind: ManagedFileKind) -> Bool {
    switch kind {
    case .output, .stampAsset, .processingTemporary, .stampThumbnail, .rasterTemporary:
        return true
    case .historyThumbnail:
        return false
    }
}
