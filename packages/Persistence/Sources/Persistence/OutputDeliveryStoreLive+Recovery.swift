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

    /// 1件のDeliveryAttemptをpreviousStateおよび現在のOutputRecord.stateに応じて解決する
    /// （7.0表）: generated→deliveryUnknownへ更新、deliveryUnknownはそのまま、
    /// delivered→OutputRecord.stateは維持しUnknownLibrarySaveへupsertする。
    /// いずれの場合もDeliveryAttempt行は削除する（3ケース共通）。
    ///
    /// currentState == .delivered || previousState == .delivered のOR条件で判定する（AND
    /// 条件や previousState 側だけの判定にしない）。「delivered不可逆」の不変条件が守られて
    /// いる限りこの2つは本来常に一致するはずだが、updateOutputRecordState側のWHERE句防御
    /// （+Attempt.swift、引き継ぎ1）により previousState == .generated かつ実際の
    /// OutputRecord.state が既に .delivered という不整合データでもUPDATEはスキップされ
    /// deliveredは後退しない。しかしその場合もUnknownLibrarySaveのupsertを欠かすと
    /// 「deliveredだが写真ライブラリ保存結果は不明」という注記が付かず、次回以降のGC/保持
    /// 期限処理で通常deliveredとして扱われ再試行用ファイルが失われる
    /// （architecture.md:1616, 1618）。フェイルクローズで両方を見て、万一の不整合時も
    /// 注記の付け忘れ（＝ファイル誤削除という重大事故）を起こさない側に倒す。
    private static func resolveOrphanedAttempt(_ connection: Database, row: Row, resolvedAt: Date) throws {
        let exportIDRaw: UUID = row["exportID"]
        let exportID = ExportID(rawValue: exportIDRaw)
        let previousStateRaw: Int = row["previousState"]
        let previousState = try Self.decodeOutputState(
            previousStateRaw, table: "DeliveryAttempt", column: "previousState"
        )
        let currentState = try Self.currentOutputState(connection, exportID: exportID)
        if currentState == .delivered || previousState == .delivered {
            try Self.upsertUnknownLibrarySave(connection, exportID: exportID, occurredAt: resolvedAt)
        } else if previousState == .generated {
            try Self.updateOutputRecordState(connection, exportID: exportID, state: .deliveryUnknown)
        }
        // previousState == .deliveryUnknown かつ currentState != .delivered: 現状維持（何もしない）
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
    /// この失敗は列値の不正ではなく型の契約の食い違いのため、専用の
    /// invalidOutputFileKind（対象exportIDを持つ）で報告する。
    private static func makeOutputDeliverySnapshot(_ row: Row) throws -> OutputDeliverySnapshot {
        let exportID = ExportID(rawValue: row["exportID"])
        let outputFileRef = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: row["outputFileID"]))
        guard let outputFile = OutputFileRef(outputFileRef) else {
            throw OutputDeliveryStoreError.invalidOutputFileKind(exportID: exportID)
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
            exportID: exportID,
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
