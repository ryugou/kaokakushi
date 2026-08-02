import Foundation
import Testing
import GRDB
@testable import Persistence

// AppDatabase.open(at:) の接続規約テスト（architecture.md 7.1「接続と journal」、
// test-plan.md 4.2）。
//
// journal_mode = DELETE / synchronous = EXTRA / foreign_keys = ON が実際に設定され、
// 読み返して検証されること、および journal_mode が DELETE 以外なら復旧エラーになる
// ことを確認する。foreign_key_check の違反検知テストはテーブルが載る Task 2 以降。

@Suite("AppDatabase")
struct AppDatabaseTests {

    /// テストごとに衝突しないファイルパスを発行する。in-memory は使わない
    /// （journal_mode の検証が in-memory では意味を成さないため。AppDatabase自体も
    /// ファイルDB専用）。
    private func makeTemporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDatabaseTests-\(UUID().uuidString).sqlite")
    }

    @Test("openで作成したDBのjournal_mode/synchronous/foreign_keysが規約どおりであること")
    func openSetsExpectedPragmas() throws {
        let url = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let appDatabase = try AppDatabase.open(at: url)

        // AppDatabase 自身の起動時検証を信用するだけでなく、テスト側でも生の
        // GRDB 接続経由でPRAGMAを読み返し、実際にDBへ反映されていることを確認する。
        try appDatabase.dbQueue.read { database in
            let journalMode = try String.fetchOne(database, sql: "PRAGMA journal_mode")
            #expect(journalMode?.lowercased() == "delete")

            let synchronous = try Int.fetchOne(database, sql: "PRAGMA synchronous")
            #expect(synchronous == 3)

            let foreignKeys = try Int.fetchOne(database, sql: "PRAGMA foreign_keys")
            #expect(foreignKeys == 1)
        }
    }

    @Test("journal_modeが外部からWALへ書き換えられたDBを開くと復旧エラーになること")
    func openThrowsWhenJournalModeWasChangedExternally() throws {
        let url = makeTemporaryDatabaseURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            // WALへの切り替えで生成されうる -wal / -shm サイドカーを後始末する
            // （SQLiteの命名規則: 元ファイル名末尾へ直接 "-wal" / "-shm" を付与する。
            // パス拡張子の追加ではない）。
            let walURL = URL(fileURLWithPath: url.path + "-wal")
            let shmURL = URL(fileURLWithPath: url.path + "-shm")
            try? FileManager.default.removeItem(at: walURL)
            try? FileManager.default.removeItem(at: shmURL)
        }

        // 正規の手順でファイルを作成してから、別接続で外部改変を再現する。
        _ = try AppDatabase.open(at: url)

        let tamperingQueue = try DatabaseQueue(path: url.path)
        try tamperingQueue.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA journal_mode = WAL")
        }

        // SQLiteの仕様上、WALから非WALへの切り替えは他に接続が無いときしか成立しない。
        // tamperingQueueの接続を生かしたまま再openすることで、DELETEへの切り替えが
        // 実際には反映されない状況を再現し、読み返し検証が失敗することを確認する。
        withExtendedLifetime(tamperingQueue) {
            do {
                _ = try AppDatabase.open(at: url)
                Issue.record("journal_modeがWALのままのDBに対しopenがエラーを送出しなかった")
            } catch let error as AppDatabaseError {
                guard case .pragmaValidationFailed(let pragma, _, _) = error else {
                    Issue.record("期待したエラーケース(pragmaValidationFailed)ではない: \(error)")
                    return
                }
                #expect(pragma == "journal_mode")
            } catch {
                Issue.record("AppDatabaseError以外がthrowされた: \(error)")
            }
        }
    }

    @Test("foreign_key_checkに違反が無ければopenが成功すること")
    func openSucceedsWhenNoForeignKeyViolations() throws {
        let url = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Task 1時点ではテーブルが無いため、違反0件で成功することのみを確認する。
        // 違反ケースの網羅的テストはスキーマが載るTask 2以降で追加する。
        _ = try AppDatabase.open(at: url)
    }
}
