import Foundation
import Domain
import GRDB

// UsageLedgerの読み書きと、Set<ExportID>のBLOBエンコード/デコード共有ヘルパー
// （architecture.md 6.3「クォータとトライアル」が正本）。
//
// BLOB形式の契約はExportSagaStoreLive+Accounting.swiftで確定済み（Set<ExportID>の各要素を
// UUIDの16バイト表現のまま連結する。重複を許さない）。exportIDByteLength /
// splitIntoUniqueChunksは+Accounting.swiftで定義され、ここではデコード側として再利用する
// （settleExport/settleBatchが書き込むconsumedExportIDsも同じ一意性契約を守る）。

extension ExportSagaStoreLive {
    /// Set<ExportID>を16バイト連結BLOBへエンコードする（順序はSetのため意味を持たない）。
    static func encodeExportIDSet(_ ids: Set<ExportID>) -> Data {
        var blob = Data()
        for id in ids {
            blob.append(withUnsafeBytes(of: id.rawValue.uuid) { Data($0) })
        }
        return blob
    }

    /// BLOBをSet<ExportID>へデコードする。長さ不正・重複チャンクはcorruptUsageLedgerBlobで
    /// fail-closedにthrowする（splitIntoUniqueChunksの契約をそのまま継承）。
    static func decodeExportIDSet(_ blob: Data) throws -> Set<ExportID> {
        guard blob.count % Self.exportIDByteLength == 0 else {
            throw ExportSagaStoreError.corruptUsageLedgerBlob(byteCount: blob.count)
        }
        let chunks = try Self.splitIntoUniqueChunks(blob)
        return Set(chunks.map { chunk in ExportID(rawValue: Self.uuid(fromChunk: chunk)) })
    }

    /// 16バイトのDataチャンクをUUIDへ変換する。unsafe pointerの整列前提を避けるため、
    /// 一度Arrayへ正規化してからタプルへ個別に詰める（chunk自体は常にsplitIntoUniqueChunks
    /// が16バイト単位で切り出した結果であり、この前提が崩れることはない）。
    private static func uuid(fromChunk chunk: Data) -> UUID {
        let bytes = [UInt8](chunk)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// UsageLedgerの唯一行を読み、Domainの`UsageLedger`へデコードする。行が無ければnilを
    /// 返す（呼び出し元が「消費ゼロ・periodは呼び出し時点の年月」として新規作成するかを
    /// 判断する。行が2件以上あれば契約違反としてfail-closedでthrowする（他の単一行テーブルと
    /// 同じ方針。multipleSingletonRows）。
    static func loadUsageLedger(_ connection: Database) throws -> UsageLedger? {
        guard let row = try Self.fetchSingletonRow(
            connection,
            table: "UsageLedger",
            sql: "SELECT periodYear, periodMonth, consumedExportIDs, trialConsumedExportIDs FROM UsageLedger"
        ) else {
            return nil
        }
        let consumedBlob: Data = row["consumedExportIDs"]
        let trialBlob: Data = row["trialConsumedExportIDs"]
        return UsageLedger(
            period: YearMonth(year: row["periodYear"], month: row["periodMonth"]),
            consumedExportIDs: try Self.decodeExportIDSet(consumedBlob),
            trialConsumedExportIDs: try Self.decodeExportIDSet(trialBlob)
        )
    }

    /// UsageLedgerをUPSERTする（単一行契約。行が無ければINSERT、あれば全列UPDATE。
    /// 単一行キー（Schema+Accounting.swift: id INTEGER PRIMARY KEY CHECK(id = 1)）により
    /// DB制約としても単一行が保証されるが、INSERT/UPDATEのどちらを発行するかの分岐自体は
    /// 引き続き`SELECT count(*)`で存在確認する）。
    static func saveUsageLedger(_ connection: Database, ledger: UsageLedger) throws {
        let existingCount = try Int.fetchOne(connection, sql: "SELECT count(*) FROM UsageLedger") ?? 0
        let consumedBlob = Self.encodeExportIDSet(ledger.consumedExportIDs)
        let trialBlob = Self.encodeExportIDSet(ledger.trialConsumedExportIDs)
        let arguments: StatementArguments = [
            ledger.period.year, ledger.period.month, consumedBlob, trialBlob
        ]
        if existingCount == 0 {
            try connection.execute(
                sql: """
                INSERT INTO UsageLedger (id, periodYear, periodMonth, consumedExportIDs, trialConsumedExportIDs)
                VALUES (1, ?, ?, ?, ?)
                """,
                arguments: arguments
            )
        } else {
            try connection.execute(
                sql: """
                UPDATE UsageLedger
                SET periodYear = ?, periodMonth = ?, consumedExportIDs = ?, trialConsumedExportIDs = ?
                WHERE id = 1
                """,
                arguments: arguments
            )
        }
    }

    /// settleSingleExportRecordが確定した各exportIDのaccountingModeから、消費する
    /// クレジット・枠を集計してUsageLedgerへ書き込む（3章「台帳の加算またはトライアル
    /// クレジットの消費」）。`.paidUnlimited`しか無ければ台帳に一切触れない（doc
    /// 「.paidUnlimitedは台帳に触れない」。オーケストレーター確定判断4番）。期待消費件数
    /// （消費対象outcomeの件数）と実際にUsageLedgerへ新規追加できた件数が一致しなければ
    /// settleConsumptionMismatchでthrowし、呼び出し元のdbQueue.writeがロールバックする
    /// （数え間違いによる過不足消費を防ぐ）。
    static func applyLedgerConsumption(
        _ connection: Database, outcomes: [SettleOutcome], settledAt: Date, deviceTimeZone: TimeZone
    ) throws {
        var freeConsumedIDs = Set<ExportID>()
        var trialConsumedIDs = Set<ExportID>()
        for outcome in outcomes {
            switch outcome.accountingMode {
            case .paidUnlimited:
                continue
            case .freeMonthlyConsume:
                freeConsumedIDs.insert(outcome.exportID)
            case .batchTrial:
                trialConsumedIDs.insert(outcome.exportID)
            }
        }
        let expectedConsumption = freeConsumedIDs.count + trialConsumedIDs.count
        guard expectedConsumption > 0 else { return }

        let existingLedger = try Self.loadUsageLedger(connection) ?? UsageLedger(
            period: YearMonth(from: settledAt, in: deviceTimeZone), consumedExportIDs: [], trialConsumedExportIDs: []
        )
        let rolledLedger = rollPeriod(existingLedger, now: settledAt, deviceTimeZone: deviceTimeZone)

        var updatedConsumedIDs = rolledLedger.consumedExportIDs
        var updatedTrialIDs = rolledLedger.trialConsumedExportIDs
        var actualConsumption = 0
        // .insertedがfalse（既にセットに存在した）は「このexportIDは既に消費済み」を
        // 意味する異常系。actualConsumptionへ加算しないことで下のguardが検知する。
        for exportID in freeConsumedIDs where updatedConsumedIDs.insert(exportID).inserted {
            actualConsumption += 1
        }
        for exportID in trialConsumedIDs where updatedTrialIDs.insert(exportID).inserted {
            actualConsumption += 1
        }

        guard expectedConsumption == actualConsumption else {
            throw ExportSagaStoreError.settleConsumptionMismatch(
                exportIDs: outcomes.map(\.exportID),
                expectedConsumed: expectedConsumption,
                actualConsumed: actualConsumption
            )
        }

        try Self.saveUsageLedger(connection, ledger: UsageLedger(
            period: rolledLedger.period, consumedExportIDs: updatedConsumedIDs, trialConsumedExportIDs: updatedTrialIDs
        ))
    }
}
