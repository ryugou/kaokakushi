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
// 手順2「孤児ファイルのGC」は architecture.md 7.5 の手順(1)〜(3)をそのまま実行する（Task 11）。
// (1) loadPendingFileDeletions で未処理分の実体削除を再試行し、成功したものだけ
// clearPendingFileDeletion で消す。(2) 孤児GC対象の種別ごとに listExistingFileIDs と
// listReferencedFileIDs の差集合を求め registerOrphan で削除候補へ登録する。(3) 登録した候補を
// (1)と同じ経路（drainPendingFileDeletions）で削除する。5章の順序に従い deleteRunningJobs の
// 後、resolveOrphanedAttempts の前に実行する。
//
// `.historyThumbnail` は孤児GC対象の種別（orphanGCKinds）に含めない（architecture.md 7.5 の
// MaintenanceStore 対応表が根拠）。v1 では参照列が無く listReferencedFileIDs が常に空集合を
// 返すため、対象へ含めると現用中の実体まで孤児として削除してしまう。Issue #26 で参照列の追加と
// 同時に有効化する。
//
// 個々のファイル削除・登録解除の失敗は復旧全体を止めない（登録を残し次回起動で再試行する）。
// 失敗を握りつぶさないため、件数を StartupRecoveryReport へ含める（Global Constraints
// 「エラーの握りつぶし禁止」。運用者が次のアクションを判断できる情報）。
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
    /// 孤児ファイル GC（architecture.md 7.5 手順(1)〜(3)）で実削除に成功した件数。
    public let deletedFileCount: Int
    /// 孤児ファイル GC で実削除に失敗した件数（登録は残り次回起動で再試行する）。
    public let failedFileDeletionCount: Int

    public init(
        outputDeliverySnapshots: [OutputDeliverySnapshot],
        unknownLibrarySaves: [UnknownLibrarySave],
        deletedRunningJobCount: Int,
        deletedFileCount: Int,
        failedFileDeletionCount: Int
    ) {
        self.outputDeliverySnapshots = outputDeliverySnapshots
        self.unknownLibrarySaves = unknownLibrarySaves
        self.deletedRunningJobCount = deletedRunningJobCount
        self.deletedFileCount = deletedFileCount
        self.failedFileDeletionCount = failedFileDeletionCount
    }
}

/// 孤児ファイル GC 1 回分の集計（削除件数・失敗件数）。
private struct FileDeletionTally {
    var deletedCount = 0
    var failedCount = 0
}

public actor StartupRecoveryCoordinator {
    /// 孤児GC対象の種別。`.historyThumbnail` は含めない（ファイル冒頭コメント参照）。
    private static let orphanGCKinds: [ManagedFileKind] = [
        .output, .stampAsset, .processingTemporary, .stampThumbnail, .rasterTemporary
    ]

    private let exportSagaStore: ExportSagaStore
    private let outputDeliveryStore: OutputDeliveryStore
    private let maintenanceStore: MaintenanceStore
    private let managedFileStore: ManagedFileStore
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
    private func performRecovery() async throws -> StartupRecoveryReport {
        let runningJobs = try await exportSagaStore.loadRunningJobs()
        try await exportSagaStore.deleteRunningJobs(runningJobs.map(\.exportID))

        let fileGCTally = try await runOrphanFileGC()

        let outputDeliverySnapshots = try await outputDeliveryStore.resolveOrphanedAttempts()
        let unknownLibrarySaves = try await outputDeliveryStore.loadUnknownLibrarySaves()

        await updateGuidanceHook()

        return StartupRecoveryReport(
            outputDeliverySnapshots: outputDeliverySnapshots,
            unknownLibrarySaves: unknownLibrarySaves,
            deletedRunningJobCount: runningJobs.count,
            deletedFileCount: fileGCTally.deletedCount,
            failedFileDeletionCount: fileGCTally.failedCount
        )
    }

    /// architecture.md 7.5 手順(1)〜(3)。(1)と(3)はどちらも drainPendingFileDeletions を使う。
    private func runOrphanFileGC() async throws -> FileDeletionTally {
        let firstPass = try await drainPendingFileDeletions()
        try await registerOrphanFiles()
        let secondPass = try await drainPendingFileDeletions()
        return FileDeletionTally(
            deletedCount: firstPass.deletedCount + secondPass.deletedCount,
            failedCount: firstPass.failedCount + secondPass.failedCount
        )
    }

    /// 未処理の PendingFileDeletion をすべて実削除する。個々の失敗は catch して件数へ積み、
    /// 登録を残したまま次の項目へ進む（復旧全体を止めない。登録は次回起動で再試行される）。
    private func drainPendingFileDeletions() async throws -> FileDeletionTally {
        let pending = try await maintenanceStore.loadPendingFileDeletions()
        var tally = FileDeletionTally()
        for pendingDeletion in pending {
            do {
                try await managedFileStore.delete(pendingDeletion.file)
                try await maintenanceStore.clearPendingFileDeletion(pendingDeletion.file)
                tally.deletedCount += 1
            } catch {
                tally.failedCount += 1
            }
        }
        return tally
    }

    /// 孤児GC対象の種別ごとに listExistingFileIDs と listReferencedFileIDs の差集合を求め、
    /// registerOrphan で削除候補へ登録する（`.historyThumbnail` は orphanGCKinds に含めない）。
    private func registerOrphanFiles() async throws {
        for kind in Self.orphanGCKinds {
            let existingFileIDs = try await maintenanceStore.listExistingFileIDs(kind: kind)
            let referencedFileIDs = try await maintenanceStore.listReferencedFileIDs(kind: kind)
            let orphanFileIDs = existingFileIDs.subtracting(referencedFileIDs)
            for fileID in orphanFileIDs {
                try await maintenanceStore.registerOrphan(ManagedFileRef(kind: kind, fileID: fileID))
            }
        }
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
