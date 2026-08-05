import Foundation
import Domain

// StartupRecoveryCoordinator — 起動時復旧（Issue #7 Task 9）。
//
// 正本: export-saga.md 5章「起動時復旧」（復旧手順1〜5の順序）、architecture.md 4.3
// （「起動時に1回のみ実行し、完了まで他のすべてを開始させない」）、test-plan.md 3.5
// 「起動時復旧」・3.6「出力の寿命と履歴」の復旧案内項目。
//
// 手順1「running の ExportJob 削除」と、それに伴う未確定（settledAt IS NULL）出力の削除は
// ExportSagaStore.deleteRunningJobs が単一の呼び出しでまとめて行う（ポートの doc コメント）。
// loadRunningJobs → deleteRunningJobs の順で呼ぶ。完了済み（settledAt != nil）の出力には
// この手順で一切触れない（deleteRunningJobs の対象は running な ExportJob 行のみ）。
//
// 手順2「孤児ファイルのGC」はこの Coordinator が呼び出さない。MaintenanceStore
// （Domain/Ports/MaintenanceStore.swift）が公開するのは listExistingFileIDs /
// listReferencedFileIDs / registerOrphan / loadPendingFileDeletions /
// clearPendingFileDeletion という個別のプリミティブのみで、それらを kind ごとの参照ポリシー
// （architecture.md 7.5 の対応表）で束ねて実行するオーケストレーションはまだ存在しない。
// Task 9 の正本（上記3点）と計画の Interfaces 節は MaintenanceStore を Consumes に含めず、
// StartupRecoveryReport の構成要素にも孤児GCの結果は現れない。対象kindの列挙・物理削除
// 失敗時の再試行方針は正本に定義が無く非自明な判断を要するため、本タスクでは実装しない
// （計画外の判断は実装せず差し戻す。プロジェクトの Global Constraints）。
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

    public init(
        outputDeliverySnapshots: [OutputDeliverySnapshot],
        unknownLibrarySaves: [UnknownLibrarySave],
        deletedRunningJobCount: Int
    ) {
        self.outputDeliverySnapshots = outputDeliverySnapshots
        self.unknownLibrarySaves = unknownLibrarySaves
        self.deletedRunningJobCount = deletedRunningJobCount
    }
}

public actor StartupRecoveryCoordinator {
    private let exportSagaStore: ExportSagaStore
    private let outputDeliveryStore: OutputDeliveryStore
    private let updateGuidanceHook: @Sendable () async -> Void

    private var recoveryTask: Task<StartupRecoveryReport, Error>?
    private var isRecoveryCompleted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        exportSagaStore: ExportSagaStore,
        outputDeliveryStore: OutputDeliveryStore,
        updateGuidanceHook: @escaping @Sendable () async -> Void = {}
    ) {
        self.exportSagaStore = exportSagaStore
        self.outputDeliveryStore = outputDeliveryStore
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

        let outputDeliverySnapshots = try await outputDeliveryStore.resolveOrphanedAttempts()
        let unknownLibrarySaves = try await outputDeliveryStore.loadUnknownLibrarySaves()

        await updateGuidanceHook()

        return StartupRecoveryReport(
            outputDeliverySnapshots: outputDeliverySnapshots,
            unknownLibrarySaves: unknownLibrarySaves,
            deletedRunningJobCount: runningJobs.count
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
