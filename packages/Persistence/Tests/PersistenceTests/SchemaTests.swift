import Foundation
import Testing
import GRDB
@testable import Persistence

// AppSchema.makeMigrator() のマイグレーション自体を検証する（test-plan.md 4.2）。
// 個々のテーブルの制約（RESTRICT/SET NULL/部分UNIQUE/CASCADE）はSchemaConstraintTests
// が担当し、このファイルはマイグレーションの原子性・接続規約の再確認・
// foreign_key_checkの3点に役割を絞る。
//
// AppDatabaseTests（Task 1）と同様、実ファイルDBを使う（in-memoryは使わない）。

@Suite("Schema")
struct SchemaTests {

    private func makeTemporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaTests-\(UUID().uuidString).sqlite")
    }

    @Test("実運用のマイグレーションが完走し、全20テーブルが揃うこと")
    func productionMigratorCreatesAllTables() throws {
        let url = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let appDatabase = try AppDatabase.open(at: url)

        let expectedTables = [
            "Project", "FaceTrack", "EffectSetting", "ExportSetting", "CustomStamp",
            "StampAsset", "ProjectStampAsset", "ExportRecord", "Batch", "BatchPreset",
            "DeliveryAttempt", "UnknownLibrarySave", "ExportJob", "OutputRecord",
            "ExportQueueItem", "WorkingSourceRecord", "PendingFileDeletion",
            "UsageLedger", "SubscriptionState", "ExportedSettingsEntry"
        ]
        #expect(expectedTables.count == 20)

        try appDatabase.dbQueue.read { database in
            for tableName in expectedTables {
                let exists = try database.tableExists(tableName)
                #expect(exists, "テーブルが見つからない: \(tableName)")
            }
        }
    }

    @Test("マイグレーションが途中で失敗した場合、単一トランザクションとしてロールバックされテーブルが1つも残らないこと")
    func brokenMigrationRollsBackEntirely() throws {
        // 実運用のテーブル作成関数群（createProjectTables等）をそのまま呼びつつ、
        // 最後に意図的に無効なSQLを実行する「壊れたマイグレーション」を組み立てる。
        // AppSchema.makeMigrator()を経由しない生のDatabaseMigratorを使うのは、
        // 正常なv1定義を壊さずに異常系だけを再現するため。
        let url = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var brokenMigrator = DatabaseMigrator()
        brokenMigrator.registerMigration("v1-intentionally-broken") { database in
            try createProjectTables(database)
            try createStampTables(database)
            try createQueueTables(database)
            try createAccountingTables(database)
            try createDeliveryTables(database)
            // 存在しないテーブルへの問い合わせで意図的に失敗させる。
            try database.execute(sql: "SELECT * FROM ThisTableIntentionallyDoesNotExist")
        }

        let queue = try DatabaseQueue(path: url.path)

        do {
            try brokenMigrator.migrate(queue)
            Issue.record("壊れたマイグレーションがエラーを送出しなかった")
        } catch {
            // 期待どおりthrowされた。エラー型はGRDBのDatabaseErrorで問わない。
        }

        // GRDB 自身の管理テーブル（grdb_migrations）と SQLite 内部テーブルは
        // マイグレーションのトランザクション外で作られるため対象外にする。
        let tableCount = try queue.read { database in
            try Int.fetchOne(
                database,
                sql: """
                SELECT count(*) FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'grdb_%' AND name NOT LIKE 'sqlite_%'
                """
            ) ?? -1
        }
        #expect(tableCount == 0)
    }

    @Test("スキーマ適用後もsynchronous=EXTRA/foreign_keys=ONが維持されること")
    func pragmasSurviveAfterSchemaIsLoaded() throws {
        // Task 1のAppDatabaseTests.openSetsExpectedPragmasと同じ検証だが、こちらは
        // テーブルが載った状態（AppSchemaのマイグレーション完了後）でも壊れていない
        // ことの確認に役割を絞る（重複ではなく、テーブル追加によるPRAGMA設定の
        // 意図しない副作用が無いことの回帰確認）。
        let url = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let appDatabase = try AppDatabase.open(at: url)

        try appDatabase.dbQueue.read { database in
            let synchronous = try Int.fetchOne(database, sql: "PRAGMA synchronous")
            #expect(synchronous == 3)

            let foreignKeys = try Int.fetchOne(database, sql: "PRAGMA foreign_keys")
            #expect(foreignKeys == 1)
        }
    }

    @Test("スキーマ適用後もforeign_key_checkが0件であり、再openが成功すること")
    func foreignKeyCheckStaysCleanAfterSchemaIsLoaded() throws {
        // 1回目のopenでスキーマが作られる。2回目のopenは、テーブルが既に存在する
        // 状態でAppDatabase.open内部のvalidateForeignKeyIntegrityを通ることになり、
        // 「スキーマ適用後」のforeign_key_checkを検証できる（Task 1のテストは
        // テーブルが無い状態の0件確認だった）。
        let url = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try AppDatabase.open(at: url)
        let reopened = try AppDatabase.open(at: url)

        let violations = try reopened.dbQueue.read { database in
            try Row.fetchAll(database, sql: "PRAGMA foreign_key_check")
        }
        #expect(violations.isEmpty)
    }
}
