import Foundation
import Domain
import GRDB

// loadUnknownLibrarySaves / clearUnknownLibrarySave / deleteOutput（export-saga.md 7章
// 不変条件（422行）・7.0表「deleteOutputの行」、architecture.md「出力の削除経路」（7.5）が
// 正本）。
//
// deleteOutputはOutputDeliveryStoreLive+Attempt.swiftのdeliveryAttemptCountヘルパーを
// 再利用する（settledAt != nilかつDeliveryAttempt不在という事前条件は、beginDeliveryAttempt
// の検査と同じ形のため）。

extension OutputDeliveryStoreLive {
    /// UnknownLibrarySaveの全件を返す。事前条件は無い（起動時案内・完了画面表示のどちらも
    /// 全件を必要とするため絞り込みをこの層へ持ち込まない）。
    public func loadUnknownLibrarySaves() async throws -> [UnknownLibrarySave] {
        let rows = try await database.dbQueue.read { connection in
            try Row.fetchAll(connection, sql: "SELECT exportID, occurredAt FROM UnknownLibrarySave")
        }
        return rows.map { row in
            UnknownLibrarySave(exportID: ExportID(rawValue: row["exportID"]), occurredAt: row["occurredAt"])
        }
    }

    /// 利用者が「確認した」を選んだ行を削除する（export-saga.md 7.0）。対象行が無くても
    /// エラーにしない（MaintenanceStoreLive.clearPendingFileDeletionと同じ、単純DELETEで
    /// 自然に冪等になる設計。二重タップや再送でも安全に呼べる）。
    public func clearUnknownLibrarySave(_ exportID: ExportID) async throws {
        try await database.dbQueue.write { connection in
            try connection.execute(
                sql: "DELETE FROM UnknownLibrarySave WHERE exportID = ?", arguments: [exportID.rawValue]
            )
        }
    }

    /// 完了後の出力を利用者が明示的に破棄する（状態遷移ではない。7.0表）。単一トランザクションで
    /// OutputRecordを削除しPendingFileDeletionへ登録する（実削除・GCは呼び出し元/
    /// MaintenanceStoreの担当。architecture.md 7.5「出力の削除経路」の手順1・2のみをここで行う）。
    /// 対象行が既に無ければ何もせず正常終了する（discardExportの「ExportJob行が無ければ何も
    /// しない」と同じ、冪等性のための設計判断。export-saga.md 4章）。
    public func deleteOutput(_ exportID: ExportID) async throws {
        try await database.dbQueue.write { connection in
            guard let outputFileID = try Self.outputFileIDForDeletion(connection, exportID: exportID) else {
                return
            }
            try connection.execute(sql: "DELETE FROM OutputRecord WHERE exportID = ?", arguments: [exportID.rawValue])
            try connection.execute(
                sql: "INSERT OR IGNORE INTO PendingFileDeletion (kind, fileID) VALUES (?, ?)",
                arguments: [ManagedFileKind.output.rawValue, outputFileID]
            )
        }
    }

    /// deleteOutputの事前条件チェック込みでOutputRecord.outputFileIDを読む。行が存在しなければ
    /// nilを返す（冪等。呼び出し元はこの場合何もしない）。行が存在すればsettledAt != nil、かつ
    /// DeliveryAttempt不在（試行中の破棄は拒否。7.0）を検証してからoutputFileIDを返す。
    private static func outputFileIDForDeletion(_ connection: Database, exportID: ExportID) throws -> UUID? {
        guard let row = try Row.fetchOne(
            connection, sql: "SELECT settledAt, outputFileID FROM OutputRecord WHERE exportID = ?",
            arguments: [exportID.rawValue]
        ) else {
            return nil
        }
        let settledAt: Date? = row["settledAt"]
        guard settledAt != nil else {
            throw OutputDeliveryStoreError.notSettled(exportID: exportID)
        }
        guard try Self.deliveryAttemptCount(connection, exportID: exportID) == 0 else {
            throw OutputDeliveryStoreError.deliveryAttemptAlreadyInProgress(exportID: exportID)
        }
        // outputFileIDはNOT NULL列（Schema+Accounting.swift）のため非Optionalでデコードする。
        let outputFileID: UUID = row["outputFileID"]
        return outputFileID
    }
}
