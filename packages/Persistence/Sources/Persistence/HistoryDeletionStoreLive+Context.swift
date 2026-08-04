import Foundation
import Domain
import GRDB

// DeletionContext相当の値をDBから読み取るprivateヘルパー群と、削除可否判定ロジック
// （architecture.md「削除の可否判定」1650〜1719行のcanDeleteHistoryUnitに相当。
// HistoryStores.swift冒頭コメントの通りDomain公開の純粋関数としては実装せず、
// このファイルへPersistence層のprivateロジックとして実装する）。

extension HistoryDeletionStoreLive {
    /// `HistoryUnit`は現状`.project`のみのため単純な取り出しだが、将来caseが増えた場合に
    /// 呼び出し元を洗い出しやすいよう専用ヘルパーへ切り出す。
    static func projectID(for unit: HistoryUnit) -> ProjectID {
        switch unit {
        case .project(let projectID):
            return projectID
        }
    }

    /// 同一DBトランザクション内でDeletionContext相当の値を読み取る（Domain公開の
    /// `DeletionContext`をそのまま使う。inspectDeletion/deleteHistoryUnitの両方から呼ぶ）。
    static func loadDeletionContext(
        _ connection: Database, unit: HistoryUnit, trigger: DeletionTrigger
    ) throws -> DeletionContext {
        let projectID = Self.projectID(for: unit)
        return DeletionContext(
            trigger: trigger,
            // isFavorite/isBeingEdited: Schema+Project.swiftのProjectテーブルに対応する列が
            // 存在しないため常にfalse固定（既知のスキーマギャップ。HistoryDeletionStoreLive.
            // swift冒頭コメント参照。列が追加されるまでの暫定であり、オーケストレーターが
            // 最終報告でエスカレーションする）。
            isFavorite: false,
            isBeingEdited: false,
            hasNonTerminalQueueItem: try Self.hasNonTerminalQueueItem(connection, projectID: projectID),
            hasUndeliveredOutputRecord: try Self.hasUndeliveredOutputRecord(connection, projectID: projectID),
            hasRunningExportJob: try Self.hasRunningExportJob(connection, projectID: projectID),
            hasWorkingSourceRecord: try Self.hasWorkingSourceRecord(connection, projectID: projectID)
        )
    }

    /// architecture.md「削除の可否判定」1650〜1719行のcanDeleteHistoryUnit相当。
    /// 拒否する場合は理由付きのエラーを返す（呼び出し元がthrowする）。許可する場合はnil。
    static func evaluateDeletion(_ context: DeletionContext, unit: HistoryUnit) -> HistoryDeletionStoreError? {
        let absoluteReasons = Self.absoluteProtections(in: context)
        guard absoluteReasons.isEmpty else {
            return .blockedByAbsoluteProtection(unit: unit, reasons: absoluteReasons)
        }

        let overridableReasons = Self.overridableProtections(in: context)
        guard !overridableReasons.isEmpty else {
            return nil
        }

        switch context.trigger {
        case .storagePressure, .retentionExpiry:
            // 上書き可能な保護でもこの2つのtriggerでは上書きできない（保護する）。
            // 呼び出し元のCoordinatorが「次の候補へ進む」等の後続動作を行う契約
            // （architecture.md「削除の可否判定」表）。
            return .blockedByOverridableProtection(unit: unit, reasons: overridableReasons)
        case .userInitiated(let confirmedOverrides):
            let unconfirmed = overridableReasons.subtracting(confirmedOverrides)
            guard unconfirmed.isEmpty else {
                return .blockedByOverridableProtection(unit: unit, reasons: unconfirmed)
            }
            return nil
        }
    }

    /// inspectDeletion（DeletionInspection.blockedByAbsoluteProtection）とevaluateDeletionの
    /// 両方が使う共通の集計（重複判定ロジックを1か所にする）。
    static func absoluteProtections(in context: DeletionContext) -> Set<AbsoluteProtection> {
        var reasons: Set<AbsoluteProtection> = []
        if context.hasNonTerminalQueueItem { reasons.insert(.nonTerminalQueueItem) }
        if context.hasRunningExportJob { reasons.insert(.exportJobRunning) }
        if context.hasUndeliveredOutputRecord { reasons.insert(.undeliveredOutput) }
        return reasons
    }

    /// inspectDeletion（DeletionInspection.overridableProtections）とevaluateDeletionの
    /// 両方が使う共通の集計。
    static func overridableProtections(in context: DeletionContext) -> Set<OverridableProtection> {
        var reasons: Set<OverridableProtection> = []
        if context.isFavorite { reasons.insert(.favorite) }
        if context.isBeingEdited { reasons.insert(.beingEdited) }
        if context.hasWorkingSourceRecord { reasons.insert(.workingSource) }
        return reasons
    }

    /// 絶対保護1: 非終端のExportQueueItemが1件でもあるか（ExportQueueStateColumnの終端3種
    /// 〈completed/failed/canceled〉以外。WorkingSourceStoreLive.swiftの割当を再利用する。
    /// 新たにraw value割当を作り直さない）。
    private static func hasNonTerminalQueueItem(_ connection: Database, projectID: ProjectID) throws -> Bool {
        let count = try Int.fetchOne(
            connection,
            sql: "SELECT count(*) FROM ExportQueueItem WHERE projectID = ? AND state NOT IN (?, ?, ?)",
            arguments: [
                projectID.rawValue,
                ExportQueueStateColumn.completed.rawValue,
                ExportQueueStateColumn.failed.rawValue,
                ExportQueueStateColumn.canceled.rawValue
            ]
        ) ?? 0
        return count > 0
    }

    /// 絶対保護2: ExportJob行が1件でもあるか（ExportJob行は進行中の書き出しのみ存在し、
    /// settle完了時〈ExportSagaStoreLive+Settle.swift〉や起動時復旧〈+Recovery.swift〉で
    /// 必ず削除される設計）。
    private static func hasRunningExportJob(_ connection: Database, projectID: ProjectID) throws -> Bool {
        let count = try Int.fetchOne(
            connection, sql: "SELECT count(*) FROM ExportJob WHERE projectID = ?", arguments: [projectID.rawValue]
        ) ?? 0
        return count > 0
    }

    /// 絶対保護3: settledAt確定済みかつisUndelivered（state = generated/deliveryUnknown）の
    /// OutputRecordが1件でもあるか（Domain OutputRecord.isUndeliveredの定義と同じ）。
    private static func hasUndeliveredOutputRecord(_ connection: Database, projectID: ProjectID) throws -> Bool {
        let count = try Int.fetchOne(
            connection,
            sql: """
            SELECT count(*) FROM OutputRecord
            WHERE projectID = ? AND settledAt IS NOT NULL AND state IN (?, ?)
            """,
            arguments: [projectID.rawValue, OutputState.generated.rawValue, OutputState.deliveryUnknown.rawValue]
        ) ?? 0
        return count > 0
    }

    /// 上書き可能な保護: WorkingSourceRecord行の有無。WorkingSourceStoreLive.swiftの
    /// loadSourceFileIDを再利用する（同じ問い合わせを重複定義しない）。
    private static func hasWorkingSourceRecord(_ connection: Database, projectID: ProjectID) throws -> Bool {
        try WorkingSourceStoreLive.loadSourceFileID(connection, projectID: projectID) != nil
    }
}
