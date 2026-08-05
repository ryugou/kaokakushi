import Foundation
import Domain

// SingleExportRequest — 単体書き出し開始の入力（Issue #7 Task 4「ExportCoordinator — 認可と開始」）。
//
// 正本: export-saga.md 1 章「認可」（1.1「確認済みの設定でのみ書き出す」/ 1.6「開始の順序」）。
//
// 決定済みの設計判断（オーケストレーターの spec で確定済み。疑問視しない）:
// - `capabilities: ResolvedCapabilities` はここへ含めない。`ExportCoordinator.startExport(_:capabilities:)`
//   の独立引数として呼び出し元（テストコードがその役）から渡される
// - バッチ用フィールド（batchID / queueItemID / BatchReviewState 等）は追加しない
//   （YAGNI。単体書き出し専用であり、バッチは Issue #7 Task 7 の担当）

/// 単体書き出し開始の入力。`ExportCoordinator.startExport(_:capabilities:)` へ渡す。
public struct SingleExportRequest: Sendable {
    public let projectID: ProjectID
    public let renderSpec: RenderSpec
    public let exportSetting: ExportSetting

    /// 利用者が確認した時点の値（export-saga.md 1.1）。
    public let previewConfirmation: PreviewConfirmation

    /// 現在の検出リビジョン。1.1 の一致検査で `previewConfirmation.detectionRevision` と
    /// 比較する対象（再検出のたびに増える。architecture.md 6.1「再検出時は対応づけを試みない」）。
    public let currentDetectionRevision: Int64

    /// 現在のプレビューハッシュ。1.1 の一致検査で `previewConfirmation.previewRenderHash` と
    /// 比較する対象。
    public let currentPreviewRenderHash: PreviewRenderHash

    /// 保存済み確認状態の要約（`reviewRequired` かつ `unreviewed` の写真が残っていないか。
    /// architecture.md 6.1「書き出し認可での確認」節が正本）。`ExportCoordinator` はこの値を
    /// そのまま信頼し、`triage` の再導出は一切行わない（export-saga.md 1.1「保存済みの
    /// ReviewDecision をそのまま信頼し、triage を再実行して独立に再検証することはしない」）。
    public let isReviewed: Bool

    public let expectedProjectRevision: Int64

    public init(
        projectID: ProjectID,
        renderSpec: RenderSpec,
        exportSetting: ExportSetting,
        previewConfirmation: PreviewConfirmation,
        currentDetectionRevision: Int64,
        currentPreviewRenderHash: PreviewRenderHash,
        isReviewed: Bool,
        expectedProjectRevision: Int64
    ) {
        self.projectID = projectID
        self.renderSpec = renderSpec
        self.exportSetting = exportSetting
        self.previewConfirmation = previewConfirmation
        self.currentDetectionRevision = currentDetectionRevision
        self.currentPreviewRenderHash = currentPreviewRenderHash
        self.isReviewed = isReviewed
        self.expectedProjectRevision = expectedProjectRevision
    }
}
