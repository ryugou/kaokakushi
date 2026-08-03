import Foundation
import Domain
import GRDB

// resolveOrphanedAttempts（export-saga.md 7.0「写真ライブラリ保存の結果不明」・
// 「resolveOrphanedAttemptsでdeliveredを維持したときupsertする」が正本）。

extension OutputDeliveryStoreLive {
    /// 起動時。残存DeliveryAttemptをpreviousStateに応じて解決し、解決後の全出力の受け渡し
    /// 状態を返す（単一トランザクション。7.0表）。
    public func resolveOrphanedAttempts() async throws -> [OutputDeliverySnapshot] {
        let resolvedAt = now()
        return try await database.dbQueue.write { connection in
            let attemptRows = try Row.fetchAll(
                connection, sql: "SELECT exportID, previousState FROM DeliveryAttempt"
            )
            for row in attemptRows {
                try Self.resolveOrphanedAttempt(connection, row: row, resolvedAt: resolvedAt)
            }
            return try Self.loadAllDeliverySnapshots(connection)
        }
    }

    /// 1件のDeliveryAttemptをpreviousStateに応じて解決する（7.0表）:
    /// generated→deliveryUnknownへ更新、deliveryUnknownはそのまま、
    /// delivered→OutputRecord.stateは維持しUnknownLibrarySaveへupsertする。
    /// いずれの場合もDeliveryAttempt行は削除する（3ケース共通）。
    private static func resolveOrphanedAttempt(_ connection: Database, row: Row, resolvedAt: Date) throws {
        let exportIDRaw: UUID = row["exportID"]
        let exportID = ExportID(rawValue: exportIDRaw)
        let previousStateRaw: Int = row["previousState"]
        let previousState = try Self.decodeOutputState(
            previousStateRaw, table: "DeliveryAttempt", column: "previousState"
        )
        switch previousState {
        case .generated:
            try Self.updateOutputRecordState(connection, exportID: exportID, state: .deliveryUnknown)
        case .deliveryUnknown:
            break
        case .delivered:
            try Self.upsertUnknownLibrarySave(connection, exportID: exportID, occurredAt: resolvedAt)
        }
        try Self.deleteDeliveryAttempt(connection, exportID: exportID)
    }

    /// UnknownLibrarySave.occurredAtをupsertする（upsertExportedSettingsEntryRowと同じ
    /// ON CONFLICTパターン）。
    private static func upsertUnknownLibrarySave(_ connection: Database, exportID: ExportID, occurredAt: Date) throws {
        try connection.execute(
            sql: """
            INSERT INTO UnknownLibrarySave (exportID, occurredAt) VALUES (?, ?)
            ON CONFLICT(exportID) DO UPDATE SET occurredAt = excluded.occurredAt
            """,
            arguments: [exportID.rawValue, occurredAt]
        )
    }

    /// OutputRecord全件をUnknownLibrarySaveとLEFT JOINして読み、[OutputDeliverySnapshot]へ
    /// デコードする。
    private static func loadAllDeliverySnapshots(_ connection: Database) throws -> [OutputDeliverySnapshot] {
        let rows = try Row.fetchAll(
            connection,
            sql: """
            SELECT o.exportID, o.projectID, o.batchID, o.outputFileID, o.outputByteSize, o.outputSHA256,
                o.state, o.generatedAt, o.settledAt, o.expiresAt, o.format, o.suggestedCreationDate,
                (u.exportID IS NOT NULL) AS hasUnknownLibrarySave
            FROM OutputRecord o
            LEFT JOIN UnknownLibrarySave u ON u.exportID = o.exportID
            """
        )
        return try rows.map(Self.makeOutputDeliverySnapshot)
    }

    /// OutputRecord行（上記SELECTの列形状）をDomainの`OutputDeliverySnapshot`へデコードする。
    /// outputFileIDはkindを.outputへ固定して構築するためOutputFileRef.init(_:)は理論上
    /// 失敗しないが、契約違反時にforce-unwrap/fatalErrorでクラッシュさせず、フェイル
    /// クローズで例外にする（他のPersistenceコードにforce-unwrapの前例が無いため）。
    private static func makeOutputDeliverySnapshot(_ row: Row) throws -> OutputDeliverySnapshot {
        let outputFileRef = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: row["outputFileID"]))
        guard let outputFile = OutputFileRef(outputFileRef) else {
            throw OutputDeliveryStoreError.invalidColumnValue(
                table: "OutputRecord", column: "outputFileID", rawValue: 0
            )
        }
        let stateRaw: Int = row["state"]
        let state = try Self.decodeOutputState(stateRaw, table: "OutputRecord", column: "state")
        let formatRaw: Int = row["format"]
        guard let formatColumn = ImageFormatColumn(rawValue: formatRaw) else {
            throw OutputDeliveryStoreError.invalidColumnValue(
                table: "OutputRecord", column: "format", rawValue: formatRaw
            )
        }
        let batchIDRaw: UUID? = row["batchID"]
        let output = OutputRecord(
            exportID: ExportID(rawValue: row["exportID"]),
            projectID: ProjectID(rawValue: row["projectID"]),
            batchID: batchIDRaw.map(BatchID.init(rawValue:)),
            outputFile: outputFile,
            outputByteSize: row["outputByteSize"],
            outputSHA256: row["outputSHA256"],
            state: state,
            generatedAt: row["generatedAt"],
            settledAt: row["settledAt"],
            expiresAt: row["expiresAt"],
            format: formatColumn.domainValue,
            suggestedCreationDate: row["suggestedCreationDate"]
        )
        return OutputDeliverySnapshot(output: output, hasUnknownLibrarySave: row["hasUnknownLibrarySave"])
    }
}
