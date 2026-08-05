import Foundation
import Domain

// ExportCoordinator — 書き出しの認可と開始（Issue #7 Task 4）。
//
// 正本: export-saga.md 1章「認可」（1.1〜1.6）、
// docs/superpowers/specs/2026-08-05-issue7-task4-export-coordinator.md「実装方針」。
// 生成 `recordGeneratedOutput` 以降（Task 5 の担当）はこのファイルの対象外。
//
// architecture.md 4.2「actor であることを排他の根拠にしない」ため、状態変更を伴う区間
// （実体欠損時の invalidateWorkingSource 呼び出し、および startExport 呼び出し）は
// SerialTaskQueue 経由で直列化する。1.1 の一致検査・1.2 の能力検査はどの store にも
// 触れないため queue の外で評価する。

/// `startExport` の判定結果（export-saga.md 1章、上記スペック「実装方針」3）。
public enum ExportStartOutcome: Sendable {
    case blocked(ExportStartBlock)
    case renderSpecBlocked(RenderSpecBlockReason)
    case confirmationMismatch
    case workingSourceMissing
    case started(ExportJob)
}

public actor ExportCoordinator {
    private let exportSagaStore: ExportSagaStore
    private let workingSourceStore: WorkingSourceStore
    private let managedFileStore: ManagedFileStore
    private let stampCatalog: StampCatalog
    private let queue: SerialTaskQueue

    public init(
        exportSagaStore: ExportSagaStore,
        workingSourceStore: WorkingSourceStore,
        managedFileStore: ManagedFileStore,
        stampCatalog: StampCatalog,
        queue: SerialTaskQueue
    ) {
        self.exportSagaStore = exportSagaStore
        self.workingSourceStore = workingSourceStore
        self.managedFileStore = managedFileStore
        self.stampCatalog = stampCatalog
        self.queue = queue
    }

    /// export-saga.md 1.6 の順序で認可を評価し、成立すれば `ExportJob` を挿入する。
    public func startExport(
        _ request: SingleExportRequest,
        capabilities: ResolvedCapabilities
    ) async throws -> ExportStartOutcome {
        guard isConfirmationConsistent(request) else {
            return .confirmationMismatch
        }

        let renderSpecAuthorization = authorizeRenderSpec(
            request.renderSpec, stampCatalog: stampCatalog, capabilities: capabilities
        )
        if case .blocked(let reason) = renderSpecAuthorization {
            return .renderSpecBlocked(reason)
        }

        return try await queue.run {
            try await self.authorizeAndStart(request)
        }
    }

    // MARK: - 1.1 確認の一致検査

    /// 保存済み `ReviewDecision` の要約（`request.isReviewed`）をそのまま信頼し、
    /// `triage` の再導出は行わない（export-saga.md 1.1）。
    private func isConfirmationConsistent(_ request: SingleExportRequest) -> Bool {
        let confirmation = request.previewConfirmation
        return request.isReviewed
            && confirmation.projectID == request.projectID
            && confirmation.detectionRevision == request.currentDetectionRevision
            && confirmation.previewRenderHash == request.currentPreviewRenderHash
    }

    // MARK: - 実体確認・startExport 呼び出し（SerialTaskQueue 経由）

    private func authorizeAndStart(_ request: SingleExportRequest) async throws -> ExportStartOutcome {
        guard try await workingSourceExists(for: request.projectID) else {
            try await workingSourceStore.invalidateWorkingSource(request.projectID)
            return .workingSourceMissing
        }

        let input = StartExportInput(
            projectID: request.projectID,
            batchID: nil,
            queueItemID: nil,
            renderSpec: request.renderSpec,
            exportSetting: request.exportSetting,
            previewConfirmation: request.previewConfirmation
        )
        // expectedProjectRevision 不一致等の throw はここで catch せず呼び出し元へ伝播させる
        // （Global Constraints「エラーの握りつぶし禁止」）。
        let decision = try await exportSagaStore.startExport(
            input, expectedProjectRevision: request.expectedProjectRevision
        )
        switch decision {
        case .blocked(let block):
            return .blocked(block)
        case .authorized(let job):
            return .started(job)
        }
    }

    /// `WorkingSourceRecord` が無い、または実体ファイルが無ければ false
    /// （export-saga.md 1.6 手順3。実体確認の throw はすべて欠損として扱う）。
    private func workingSourceExists(for projectID: ProjectID) async throws -> Bool {
        guard let record = try await workingSourceStore.loadWorkingSource(for: projectID) else {
            return false
        }
        do {
            _ = try await managedFileStore.withReadAccess(record.sourceFile.ref) { _ in }
            return true
        } catch {
            return false
        }
    }
}
