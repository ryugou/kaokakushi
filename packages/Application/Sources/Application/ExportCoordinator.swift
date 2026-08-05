import Foundation
import Domain

// ExportCoordinator — 書き出しの認可・開始・生成・中断後始末・完了操作(Issue #7 Task 4 / 5 / 6)。
//
// 正本: export-saga.md 1章「認可」（1.1〜1.6。Task 4）、3章「手順」・4章「中断・やり直し・
// 破棄」（Task 5。実装は ExportCoordinator+Generate.swift）、3章 手順5・6章「確定後に出力
// 実体が失われた場合」（Task 6。実装は ExportCoordinator+Settle.swift）、
// docs/superpowers/specs/2026-08-05-issue7-task4-export-coordinator.md「実装方針」。
// stored property と init はこのファイルに集約する（extension は stored property を
// 追加できないため。Task 5 の生成 `generateOutput` / `discardExport` は
// ExportCoordinator+Generate.swift、Task 6 の `settleExport` / `settleBatch` /
// `verifyOutputIntegrity` は ExportCoordinator+Settle.swift が実装する）。
//
// architecture.md 4.2「actor であることを排他の根拠にしない」ため、状態変更を伴う区間
// （実体欠損時の invalidateWorkingSource 呼び出し、startExport 呼び出し、
// ExportCoordinator+Generate.swift の generateOutput / discardExport、
// ExportCoordinator+Settle.swift の settleExport / settleBatch / 実体喪失時の deleteOutput）は
// SerialTaskQueue 経由で直列化する。1.1 の一致検査・1.2 の能力検査・実体喪失検査の
// OutputFileVerifier 呼び出し（読み取りのみ）は store に触れないため queue の外で評価する。

/// `startExport` の判定結果（export-saga.md 1章、上記スペック「実装方針」3）。
public enum ExportStartOutcome: Sendable {
    case blocked(ExportStartBlock)
    case renderSpecBlocked(RenderSpecBlockReason)
    case confirmationMismatch
    case workingSourceMissing
    case started(ExportJob)
}

public actor ExportCoordinator {
    let exportSagaStore: ExportSagaStore
    private let workingSourceStore: WorkingSourceStore
    private let managedFileStore: ManagedFileStore
    let stampCatalog: StampCatalog
    let imageEffectRenderer: ImageEffectRenderer
    let imageEncoder: ImageEncoder
    let outputFileVerifier: OutputFileVerifier
    let outputDeliveryStore: OutputDeliveryStore
    /// settleBatch へ渡す settledAt の取得元（Global Constraints「裸の Date() 禁止」）。
    /// export-saga.md 3章「settledAt は呼び出し側が渡した時刻で全件に統一する」。
    let now: @Sendable () -> Date
    let queue: SerialTaskQueue

    public init(
        exportSagaStore: ExportSagaStore,
        workingSourceStore: WorkingSourceStore,
        managedFileStore: ManagedFileStore,
        stampCatalog: StampCatalog,
        imageEffectRenderer: ImageEffectRenderer,
        imageEncoder: ImageEncoder,
        outputFileVerifier: OutputFileVerifier,
        outputDeliveryStore: OutputDeliveryStore,
        now: @escaping @Sendable () -> Date,
        queue: SerialTaskQueue
    ) {
        self.exportSagaStore = exportSagaStore
        self.workingSourceStore = workingSourceStore
        self.managedFileStore = managedFileStore
        self.stampCatalog = stampCatalog
        self.imageEffectRenderer = imageEffectRenderer
        self.imageEncoder = imageEncoder
        self.outputFileVerifier = outputFileVerifier
        self.outputDeliveryStore = outputDeliveryStore
        self.now = now
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

    /// 単体は batchID / queueItemID とも nil のまま呼ぶ。バッチ項目の開始
    /// （ExportCoordinator+Batch.swift の startBatchItem）はこの同じ経路を batchID /
    /// queueItemID つきで再利用する（1.6 の実体確認・startExport 呼び出し順序は単体・バッチで
    /// 変わらないため重複させない）。
    func authorizeAndStart(
        _ request: SingleExportRequest,
        batchID: BatchID? = nil,
        queueItemID: ExportQueueItemID? = nil
    ) async throws -> ExportStartOutcome {
        guard try await workingSourceExists(for: request.projectID) else {
            try await workingSourceStore.invalidateWorkingSource(request.projectID)
            return .workingSourceMissing
        }

        let input = StartExportInput(
            projectID: request.projectID,
            batchID: batchID,
            queueItemID: queueItemID,
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
    /// （export-saga.md 1.6 手順3）。実体確認は `exists` の存在確認専用 API のみを使う
    /// （image-pipeline.md「実体の存在確認」）。`exists` の throw（保護データ利用不可・
    /// I/O 障害など）は欠損として扱わず、そのまま呼び出し元へ伝播させる
    /// （Global Constraints「エラーの握りつぶし禁止」）。
    private func workingSourceExists(for projectID: ProjectID) async throws -> Bool {
        guard let record = try await workingSourceStore.loadWorkingSource(for: projectID) else {
            return false
        }
        return try await managedFileStore.exists(record.sourceFile.ref)
    }
}
