import Foundation

// 書き出し認可の型群（export-saga.md 1.1 / 1.2 / 1.3）。
//
// 純粋関数 authorizeRenderSpec と型 RenderSpecAuthorization / RenderSpecBlockReason は
// Task 8（免除規則の型面）の担当のためここには含めない。
// ExportStartBlockReason / ExportStartBlock は 1.3 節の同一 swift コードブロックで
// ExportAuthorization / ExportAccountingMode と並んで宣言されており不可分のためここに含める
// （0 章の ExportStartDecision.blocked(ExportStartBlock) が返り値として参照する）。
// ExportStartDecision 自体、ExportSagaStore / OutputDeliveryStore・StartExportInput /
// RecordOutputInput 等の入力型は 0 章にあり 1.3 節のコードブロックには含まれないため、
// 引き続き Task 4（永続化ポート群）の担当としてここには含めない。

/// 利用者が確認したプレビューの同一性（1.1）
public struct PreviewConfirmation: Sendable, Equatable {
    public let projectID: ProjectID
    public let detectionRevision: Int64
    public let previewRenderHash: PreviewRenderHash

    public init(projectID: ProjectID, detectionRevision: Int64, previewRenderHash: PreviewRenderHash) {
        self.projectID = projectID
        self.detectionRevision = detectionRevision
        self.previewRenderHash = previewRenderHash
    }
}

/// バッチ一覧の確認状態を batchID と結び付けて保持する（1.1）
public struct BatchReviewState: Sendable, Equatable {
    public let batchID: BatchID
    public let overviewConfirmed: Bool

    public init(batchID: BatchID, overviewConfirmed: Bool) {
        self.batchID = batchID
        self.overviewConfirmed = overviewConfirmed
    }
}

/// 組み込みスタンプの分類。アプリにハードコードし、リモート設定から変更できない（ADR 0005）
public protocol StampCatalog: Sendable {
    func requirement(forBuiltIn code: String) -> StampRequirement?
}

public enum StampRequirement: Sendable, Hashable {
    case free, premium(packID: String), custom, unknownBuiltIn
}

/// 正本は Sendable のみで Equatable は宣言していない（Entitlement は Equatable だが
/// ExportAuthorization 自体を値として比較する用途が正本コードブロックに無いため追加しない）
public struct ExportAuthorization: Sendable {
    public let entitlementSnapshot: Entitlement
    public let accountingMode: ExportAccountingMode
    public let authorizedAt: Date

    public init(entitlementSnapshot: Entitlement, accountingMode: ExportAccountingMode, authorizedAt: Date) {
        self.entitlementSnapshot = entitlementSnapshot
        self.accountingMode = accountingMode
        self.authorizedAt = authorizedAt
    }
}

public enum ExportStartBlockReason: Sendable, Equatable {
    case monthlyLimitReached, trialCreditsUnavailable
    case capabilityVerificationRequired   // entitlementSnapshot.verificationRequired
}

public struct ExportStartBlock: Sendable, Equatable {
    public let reason: ExportStartBlockReason
    public let limit: Int?

    public init(reason: ExportStartBlockReason, limit: Int?) {
        self.reason = reason
        self.limit = limit
    }
}

/// ADR 0006: 勘定の単位は「受け渡した成果物」。素材の同一性は使わない
public enum ExportAccountingMode: Sendable, Equatable {
    case paidUnlimited
    case freeMonthlyConsume
    case batchTrial
}
