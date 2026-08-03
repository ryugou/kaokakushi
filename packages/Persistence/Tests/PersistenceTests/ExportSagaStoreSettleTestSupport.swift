import Foundation
import GRDB
import Domain
@testable import Persistence

// ExportSagaStoreSettleTests / ExportSagaStoreSettleBatchTests / ExportSagaStoreSettleLedgerTests /
// ExportSagaStoreSettleSideEffectsTests / ExportSagaStoreQuotaTestsが共有するヘルパー群
// （settleExport/settleBatchとUsageLedger/ExportedSettingsEntry/ExportRecordを検証する
// テスト専用。ExportSagaStoreTestSupport.swift / SchemaTestSupport.swiftの既存ヘルパーは
// そのまま再利用し、ここでは重複定義しない）。

// UsageLedgerの唯一行を読む。ExportSagaStoreLive.decodeExportIDSet（@testable経由で
// 参照可能）でBLOBをSet<ExportID>へデコードする。行が無ければnilを返す。
// テストフィクスチャの束（読み出し列ひとそろい）。
// swiftlint:disable large_tuple
func usageLedgerFields(_ database: AppDatabase) throws -> (
    periodYear: Int32, periodMonth: Int32, consumedExportIDs: Set<ExportID>, trialConsumedExportIDs: Set<ExportID>
)? {
    // swiftlint:enable large_tuple
    try database.dbQueue.read { connection in
        guard let row = try Row.fetchOne(
            connection,
            sql: "SELECT periodYear, periodMonth, consumedExportIDs, trialConsumedExportIDs FROM UsageLedger"
        ) else {
            return nil
        }
        let consumedBlob: Data = row["consumedExportIDs"]
        let trialBlob: Data = row["trialConsumedExportIDs"]
        return (
            row["periodYear"], row["periodMonth"],
            try ExportSagaStoreLive.decodeExportIDSet(consumedBlob),
            try ExportSagaStoreLive.decodeExportIDSet(trialBlob)
        )
    }
}

func usageLedgerRowExists(_ database: AppDatabase) throws -> Bool {
    try database.dbQueue.read { connection in
        (try Int.fetchOne(connection, sql: "SELECT count(*) FROM UsageLedger") ?? 0) > 0
    }
}

/// UsageLedgerの唯一行を、period・consumedExportIDs・trialConsumedExportIDsを明示的に
/// 指定して挿入する（既存のinsertUsageLedgerRow〈ExportSagaStoreTestSupport.swift〉は
/// trialConsumedCountしか指定できず、period跨ぎや消費件数の重複再現テストには使えない）。
/// エンコードはExportSagaStoreLive.encodeExportIDSet（@testable経由）を使い、本実装と
/// 同じBLOB形式で書く。
func insertUsageLedgerRowWithIDs(
    _ connection: Database,
    periodYear: Int32,
    periodMonth: Int32,
    consumedExportIDs: Set<ExportID>,
    trialConsumedExportIDs: Set<ExportID>
) throws {
    try connection.execute(
        sql: """
        INSERT INTO UsageLedger (periodYear, periodMonth, consumedExportIDs, trialConsumedExportIDs)
        VALUES (?, ?, ?, ?)
        """,
        arguments: [
            periodYear, periodMonth,
            ExportSagaStoreLive.encodeExportIDSet(consumedExportIDs),
            ExportSagaStoreLive.encodeExportIDSet(trialConsumedExportIDs)
        ]
    )
}

/// 中身に意味の無い、重複の無いExportIDの集合を作る（月間枠到達の再現用フィクスチャ）。
func makeExportIDs(count: Int) -> Set<ExportID> {
    Set((0..<count).map { _ in ExportID(rawValue: UUID()) })
}

/// queueItemID付き・batchID nilのExportJob行を直接構築する（settleExportのキュー項目
/// 事前条件チェック〈対応するキュー項目が存在しない〉をピンポイントで再現するテスト専用
/// フィクスチャ）。startExportのqueueItemIDRequiresBatchID検査によりこの組み合わせは
/// startExport経由では作成不能になったため、raw SQLで直接構築する（データ不整合に対する
/// settleExport側の防御が機能することを確認する。他の事前条件違反テストと同じ方針。
/// ExportSagaStoreSettleTests.swiftのrejectsWhenExportJobHasBatchID等）。
func insertQueueBackedExportJobWithoutBatch(
    _ connection: Database, exportID: UUID, projectID: UUID, queueItemID: UUID
) throws {
    try connection.execute(
        sql: """
        INSERT INTO ExportJob (
            exportID, projectID, batchID, queueItemID, authorizedAt, accountingMode,
            entitlementPlan, entitlementStatus, entitlementExpiresAt,
            entitlementLastVerifiedAt, entitlementIsSandbox, deliveryFormat,
            deliverySuggestedCreationDate, settingsHash
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
            exportID, projectID, nil, queueItemID, schemaTestReferenceDate, 1,
            1, 1, nil, schemaTestReferenceDate, false, 1, nil, schemaTestHash(seed: 0xEE)
        ]
    )
}

func exportedSettingsEntryFields(
    _ database: AppDatabase, projectID: UUID
) throws -> (settingsHash: Data, exportedAt: Date)? {
    try database.dbQueue.read { connection in
        guard let row = try Row.fetchOne(
            connection, sql: "SELECT settingsHash, exportedAt FROM ExportedSettingsEntry WHERE projectID = ?",
            arguments: [projectID]
        ) else {
            return nil
        }
        return (row["settingsHash"], row["exportedAt"])
    }
}

// テストフィクスチャの束（読み出し列ひとそろい。SchemaTestSupport.outputRecordFieldsと
// 同じ「swiftlint large_tuple」抑制パターン）。
// swiftlint:disable large_tuple
func exportRecordFields(_ database: AppDatabase, exportID: UUID) throws -> (
    exportedAt: Date, accountingMode: Int, format: Int, outputByteSize: Int64, batchID: UUID?
)? {
    // swiftlint:enable large_tuple
    try database.dbQueue.read { connection in
        guard let row = try Row.fetchOne(
            connection,
            sql: """
            SELECT exportedAt, accountingMode, format, outputByteSize, batchID
            FROM ExportRecord WHERE exportID = ?
            """,
            arguments: [exportID]
        ) else {
            return nil
        }
        return (row["exportedAt"], row["accountingMode"], row["format"], row["outputByteSize"], row["batchID"])
    }
}
