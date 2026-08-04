import Foundation

// 履歴削除の永続化ポート（architecture.md「削除の可否判定」〜「出力の削除経路」節）。
//
// `canDeleteHistoryUnit(_:context:)` という純粋関数（1639〜1643 行目）はここに実装しない。
// このドメイン層実装計画のどの Task にも明示的に割り当てられていないため（spec 参照。
// 計画の欠落と思われる）。この計画では「プロトコル群と入力型」が Task 4 の対象であり、
// 純粋関数は対象外とする。
//
// アクセス修飾（public）の方針は ExportSagaStore.swift と同じ。

/// 閲覧・削除の単位（architecture.md「削除の可否判定」）。
/// 履歴は写真アプリ型のフラットな写真グリッドであり、単位は Project のみ
public enum HistoryUnit: Sendable, Equatable {
    case project(ProjectID)
}

/// 削除の契機（architecture.md「削除の可否判定」）。
public enum DeletionTrigger: Sendable {
    case storagePressure      // 容量超過による自動削除
    case retentionExpiry      // 保存期間による期限削除
    /// 利用者による手動削除。confirmedOverrides に明示確認済みの参照が入る
    case userInitiated(confirmedOverrides: Set<OverridableProtection>)
}

/// 利用者の明示確認で上書きできる保護
public enum OverridableProtection: Sendable, Hashable {
    case favorite
    case beingEdited
    case workingSource
}

/// 同一 DB トランザクション内で読み取った参照状況
public struct DeletionContext: Sendable {
    public let trigger: DeletionTrigger
    public let isFavorite: Bool
    public let isBeingEdited: Bool
    public let hasNonTerminalQueueItem: Bool
    public let hasUndeliveredOutputRecord: Bool   // isUndelivered のみ（settledAt != nil の出力が対象）。delivered は保護しない
    public let hasRunningExportJob: Bool
    public let hasWorkingSourceRecord: Bool
    public let hasDeliveryAttemptInProgress: Bool // 対象Projectの出力に試行中のDeliveryAttemptが1件でもあるか

    public init(
        trigger: DeletionTrigger,
        isFavorite: Bool,
        isBeingEdited: Bool,
        hasNonTerminalQueueItem: Bool,
        hasUndeliveredOutputRecord: Bool,
        hasRunningExportJob: Bool,
        hasWorkingSourceRecord: Bool,
        hasDeliveryAttemptInProgress: Bool
    ) {
        self.trigger = trigger
        self.isFavorite = isFavorite
        self.isBeingEdited = isBeingEdited
        self.hasNonTerminalQueueItem = hasNonTerminalQueueItem
        self.hasUndeliveredOutputRecord = hasUndeliveredOutputRecord
        self.hasRunningExportJob = hasRunningExportJob
        self.hasWorkingSourceRecord = hasWorkingSourceRecord
        self.hasDeliveryAttemptInProgress = hasDeliveryAttemptInProgress
    }
}

// Domain — 永続化ポート（architecture.md「実装の所在」〜「出力の削除経路」節）。
public protocol HistoryDeletionStore: Sendable {
    /// 確認画面の表示用。ここで得た値を削除の根拠にしない
    func inspectDeletion(
        _ unit: HistoryUnit,
        trigger: DeletionTrigger
    ) async throws -> DeletionInspection

    /// DB トランザクション内で DeletionContext を再取得し、
    /// canDeleteHistoryUnit を再評価してから削除する（所属 Batch が空になった場合の自動削除を含む）
    func deleteHistoryUnit(
        _ unit: HistoryUnit,
        trigger: DeletionTrigger
    ) async throws
}

/// 確認画面へ出す情報。削除の可否そのものは保証しない
public struct DeletionInspection: Sendable {
    public let blockedByAbsoluteProtection: Set<AbsoluteProtection>
    public let overridableProtections: Set<OverridableProtection>
    public let reclaimableBytes: Int64

    public init(
        blockedByAbsoluteProtection: Set<AbsoluteProtection>,
        overridableProtections: Set<OverridableProtection>,
        reclaimableBytes: Int64
    ) {
        self.blockedByAbsoluteProtection = blockedByAbsoluteProtection
        self.overridableProtections = overridableProtections
        self.reclaimableBytes = reclaimableBytes
    }
}

public enum AbsoluteProtection: Sendable, Hashable {
    case nonTerminalQueueItem
    case exportJobRunning
    case undeliveredOutput
    /// 試行中のDeliveryAttempt（写真ライブラリ保存）が存在するため削除を拒否する
    case deliveryAttemptInProgress
}
