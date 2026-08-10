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
// 場合は CheckedContinuation を waiters へ積んで保留し、runStartupRecovery() が成功で
// 完了した瞬間にまとめて resume する。ExportCoordinator の開始経路がこれを await する配線は
// Task 9 の Files 節に含まれないため、この Coordinator 自身の実装のみに留める。

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
    private let updateGuidanceHook: @Sendable () async -> Void

    private var recoveryTask: Task<StartupRecoveryReport, Error>?
    private var isRecoveryCompleted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        exportSagaStore: ExportSagaStore,
        outputDeliveryStore: OutputDeliveryStore,
        maintenanceStore: MaintenanceStore,
        managedFileStore: ManagedFileStore,
        updateGuidanceHook: @escaping @Sendable () async -> Void = {}
    ) {
        self.exportSagaStore = exportSagaStore
        self.outputDeliveryStore = outputDeliveryStore
        self.maintenanceStore = maintenanceStore
        self.managedFileStore = managedFileStore
        self.updateGuidanceHook = updateGuidanceHook
    }

    /// export-saga.md 5章の順序で起動時復旧を実行する。2回目以降の呼び出しは再実行せず、
    /// 最初の呼び出しの結果（成功なら report・失敗なら同じ throw）をそのまま返す
    /// （architecture.md 4.3「起動時に1回のみ実行」）。
    public func runStartupRecovery() async throws -> StartupRecoveryReport {
        if let recoveryTask {
            return try await recoveryTask.value
        }
        let task = Task { try await self.performRecovery() }
        recoveryTask = task
        let report = try await task.value
        completeGate()
        return report
    }

    /// 復旧が完了するまで呼び出し元を保留する（architecture.md 4.3「完了まで他のすべてを
    /// 開始させない」）。既に完了していれば即座に返る。
    public func awaitRecoveryCompleted() async {
        if isRecoveryCompleted { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// ストアの throw は握りつぶさずそのまま伝播する（Global Constraints「エラーの
    /// 握りつぶし禁止」）。伝播した場合 completeGate は呼ばれず、ゲートは開かないまま残る。
    /// 孤児ファイルGC（runOrphanFileGC）だけは例外で、GC 起因の失敗を throw させず
    /// report へ落として後続の手順へ進む（W-3。ファイル冒頭コメント参照）。
    private func performRecovery() async throws -> StartupRecoveryReport {
        let runningJobs = try await exportSagaStore.loadRunningJobs()
        try await exportSagaStore.deleteRunningJobs(runningJobs.map(\.exportID))

        let fileGC = await runOrphanFileGC()

        let outputDeliverySnapshots = try await outputDeliveryStore.resolveOrphanedAttempts()
        let unknownLibrarySaves = try await outputDeliveryStore.loadUnknownLibrarySaves()

        await updateGuidanceHook()

        return StartupRecoveryReport(
            outputDeliverySnapshots: outputDeliverySnapshots,
            unknownLibrarySaves: unknownLibrarySaves,
            deletedRunningJobCount: runningJobs.count,
            deletedFileCount: fileGC.deletedCount,
            failedFileDeletions: fileGC.failedFileDeletions,
            pendingRecordClearFailures: fileGC.pendingRecordClearFailures,
            fileGCFailure: fileGC.gcFailure
        )
    }

    private func completeGate() {
        guard !isRecoveryCompleted else { return }
        isRecoveryCompleted = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for continuation in pendingWaiters {
            continuation.resume()
        }
    }
}

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
