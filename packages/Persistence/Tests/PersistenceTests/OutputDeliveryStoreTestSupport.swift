import Foundation
import GRDB
import Domain
@testable import Persistence

// OutputDeliveryStoreAttemptTests / OutputDeliveryStoreShareTests /
// OutputDeliveryStoreAbandonTests / OutputDeliveryStoreResolveOrphanedAttemptsTestsが
// 共有するヘルパー群。makeTestAppDatabase()（WorkingSourceStoreTestSupport.swift）・
// insertProject（SchemaTestSupport.swift）・outputRecordFields
// （ExportSagaStoreTestSupport.swift）はそのまま再利用し、ここでは重複定義しない。
//
// SchemaTestSupport.swiftの既存insertOutputRecordはformat: 0固定（無効なImageFormat値）
// のため、resolveOrphanedAttemptsのデコード（ImageFormatColumnへの変換）が
// invalidColumnValueで失敗してしまう。ここでは有効なformat（1 = jpeg）を使う専用の
// 挿入ヘルパーを追加する（既存の共有ヘルパーは変更しない）。

/// OutputDeliveryStoreLiveをテスト用に組み立てる。
func makeOutputDeliveryStore(
    database: AppDatabase,
    now: @escaping @Sendable () -> Date = { schemaTestReferenceDate }
) -> OutputDeliveryStoreLive {
    OutputDeliveryStoreLive(database: database, now: now)
}

/// state/settledAtを指定してOutputRecordを1行挿入する。format = 1（jpeg。有効な値）固定、
/// batchIDは常にnil固定（このセッションのテストはbatchIDのバリエーションを必要としない。
/// YAGNI。引数5個以内の制約にも合わせる）。呼び出し前にinsertProject(_:projectID:)で
/// 親Project行を挿入しておくこと（FK制約）。
func insertDeliveryOutputRecord(
    _ connection: Database,
    exportID: UUID,
    projectID: UUID,
    state: Int,
    settledAt: Date?
) throws {
    try connection.execute(
        sql: """
        INSERT INTO OutputRecord (
            exportID, projectID, batchID, outputFileID, outputByteSize, outputSHA256,
            state, generatedAt, settledAt, expiresAt, format, suggestedCreationDate
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
            exportID, projectID, nil, UUID(), 2_048, schemaTestHash(seed: 0xAB),
            state, schemaTestReferenceDate, settledAt, nil, 1, nil
        ]
    )
}

/// DeliveryAttempt行を直接挿入する。
func insertDeliveryAttemptRow(
    _ connection: Database, exportID: UUID, startedAt: Date, previousState: Int
) throws {
    try connection.execute(
        sql: "INSERT INTO DeliveryAttempt (exportID, startedAt, previousState) VALUES (?, ?, ?)",
        arguments: [exportID, startedAt, previousState]
    )
}

/// 対象exportIDに対応するDeliveryAttempt行が存在するか。
func deliveryAttemptExists(_ database: AppDatabase, exportID: UUID) throws -> Bool {
    try database.dbQueue.read { connection in
        let count = try Int.fetchOne(
            connection, sql: "SELECT count(*) FROM DeliveryAttempt WHERE exportID = ?", arguments: [exportID]
        ) ?? 0
        return count > 0
    }
}

/// 対象exportIDに対応するUnknownLibrarySave行が存在するか。
func unknownLibrarySaveExists(_ database: AppDatabase, exportID: UUID) throws -> Bool {
    try database.dbQueue.read { connection in
        let count = try Int.fetchOne(
            connection, sql: "SELECT count(*) FROM UnknownLibrarySave WHERE exportID = ?", arguments: [exportID]
        ) ?? 0
        return count > 0
    }
}
