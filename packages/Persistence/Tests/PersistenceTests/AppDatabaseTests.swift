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

        // tamperingQueueの接続を生かしたまま再openする。この時点で-wal/-shmサイド
        // カーが存在するため、実際にはAppDatabase.rejectIfExistingFileUsesWALの
        // サイドカー存在検査でpragmaValidationFailedがthrowされる（ヘッダ検査に
        // 到達する前に拒否される）。validatePragmas側のjournal_modeガードは
        // defense-in-depthとして残っているが、この経路（読み返し検証側で拒否
        // されるケース）を直接カバーするテストは現時点では無い。
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

    @Test("他接続が無い状態でWAL化されたDBをopenすると復旧エラーになり、ヘッダが自己修復されないこと")
    func openThrowsAndDoesNotSelfHealWhenNoOtherConnectionHoldsWAL() throws {
        let url = makeTemporaryDatabaseURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            let walURL = URL(fileURLWithPath: url.path + "-wal")
            let shmURL = URL(fileURLWithPath: url.path + "-shm")
            try? FileManager.default.removeItem(at: walURL)
            try? FileManager.default.removeItem(at: shmURL)
        }

        // 正規の手順でファイルを作成してから、別接続でWALへ切り替える。
        _ = try AppDatabase.open(at: url)

        do {
            let tamperingQueue = try DatabaseQueue(path: url.path)
            try tamperingQueue.writeWithoutTransaction { database in
                try database.execute(sql: "PRAGMA journal_mode = WAL")
            }
            // ここでスコープを抜けてtamperingQueueへの最後の参照を破棄する。GRDBの
            // DatabaseQueueはdeinitでsqlite3接続を同期的にクローズし、WALモードの
            // 最終接続のクローズはSQLiteの仕様上チェックポイント（-wal/-shmの削除）
            // を伴う。
            //
            // openThrowsWhenJournalModeWasChangedExternally（上）は
            // withExtendedLifetimeでtampering接続を生かしたまま再openしており、
            // 「他接続が存在するためDELETEへの切り替え自体が失敗する」状況を
            // 検証している。この状況は却下済みの旧実装（接続を開いてPRAGMA
            // journal_modeを読み返すだけの方式）でもgreenになり、回帰防止に
            // ならない。本テストは接続を一切残さないことで、「他接続は無いのに
            // ファイルヘッダにWALが永続化されたまま残っている」状況を再現し、
            // ヘッダ読み取り方式でなければ検出できないケースを検証する。
        }

        // 前提の検証: サイドカーが実際に消えていることを確認する。もし
        // -wal/-shmが残っていた場合、直後のopenはヘッダ検査ではなくサイドカー
        // 存在検査で拒否されてしまい、本テストが検証したい「ヘッダ読み取りだけで
        // 検出できること」を実際にはカバーしないままテストCの重複に劣化する。
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: url.path + "-shm"))

        do {
            _ = try AppDatabase.open(at: url)
            Issue.record("他接続が無いWAL化DBに対しopenがエラーを送出しなかった")
        } catch let error as AppDatabaseError {
            guard case .pragmaValidationFailed(let pragma, _, let actual) = error else {
                Issue.record("期待したエラーケース(pragmaValidationFailed)ではない: \(error)")
                return
            }
            #expect(pragma == "journal_mode")
            #expect(actual.lowercased() == "wal")
        } catch {
            Issue.record("AppDatabaseError以外がthrowされた: \(error)")
        }

        // throw後もヘッダが自己修復されず、WALのまま残っていることを直接検証する
        // （「想定外のjournal_modeを黙って直さず復旧エラーとして報告する」という
        // 規約〈test-plan.md 4.2〉の本体はこの一文で検証される）。
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        let header = try fileHandle.read(upToCount: 20)
        let headerBytes = Array(header ?? Data())
        #expect(headerBytes.count == 20)
        guard headerBytes.count == 20 else { return }
        #expect(headerBytes[18] == 2 || headerBytes[19] == 2)
    }

    @Test("0バイトのファイルが既に存在してもopenが成功すること")
    func openSucceedsWhenExistingFileIsEmpty() throws {
        let url = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // ヘッダを20バイト未満しか読めない状態（新規作成直後・空ファイル）は
        // 「検査不要」として早期returnする経路であり、fail-openではなく
        // 正規の正常系であることを示す。
        let created = FileManager.default.createFile(atPath: url.path, contents: nil)
        #expect(created)

        _ = try AppDatabase.open(at: url)
    }

    @Test("DB本体が0バイトでも-walサイドカーが残っていれば復旧エラーになること")
    func openThrowsWhenWalSidecarExistsEvenIfMainFileIsEmpty() throws {
        let url = makeTemporaryDatabaseURL()
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: walURL)
        }

        // 新規DBをWALで書き込み始めた直後、チェックポイント前にクラッシュした
        // 状況を模す: DB本体は0バイト（ヘッダ未確定）のまま、-walだけが残る。
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        #expect(FileManager.default.createFile(atPath: walURL.path, contents: Data([0x01, 0x02, 0x03])))

        do {
            _ = try AppDatabase.open(at: url)
            Issue.record("-walサイドカーが残っているにもかかわらずopenがエラーを送出しなかった")
        } catch let error as AppDatabaseError {
            guard case .pragmaValidationFailed(let pragma, _, let actual) = error else {
                Issue.record("期待したエラーケース(pragmaValidationFailed)ではない: \(error)")
                return
            }
            #expect(pragma == "journal_mode")
            #expect(actual.lowercased() == "wal")
        } catch {
            Issue.record("AppDatabaseError以外がthrowされた: \(error)")
        }
    }

    @Test("pragmaValidationFailedのerrorDescriptionがWAL検出時だけ専用の案内文になり、それ以外は汎用の検証失敗メッセージのままであること")
    func errorDescriptionDistinguishesWalDetectionFromGenericPragmaFailure() {
        // このテストはDBファイルを一切作らない純粋関数テスト（errorDescriptionは
        // enumのcase/associated valueだけから文字列を組み立てる）。
        //
        // 実装のerrorDescriptionは `pragma == "journal_mode" && actual.lowercased()
        // == "wal"` の2条件が揃ったときだけ、「データは失われていない・削除・
        // 再作成は不要」という専用の案内文に分岐する。将来この文字列リテラルの
        // どちらか一方でも変われば分岐が黙って死に、汎用メッセージ（「必要で
        // あればDBファイルを再作成してください」という、無傷のユーザーデータの
        // 削除を誘導しかねない文言）へ無検出で退行する。これは以前Majorとして
        // 修正した問題そのものであり、ここで退行を検知する。
        //
        // 実装の複数行文字列リテラルは `\` 行継続でつないでおり、行末のスペース
        // + 継続により行の境界には半角スペースが挿入される
        // （例:「DBファイルを 削除・再作成する必要はありません」のように、
        // 単語の境目ではない位置で分断される）。判定に使う部分文字列は
        // AppDatabase.swiftのerrorDescription実装を直接読み、行境界をまたがず
        // 1行に完全に収まっている語だけを選んでいる
        // （"再作成する必要はありません" と "journal_mode=DELETE" は、それぞれ
        // 実装のWAL分岐内で単一行の中に丸ごと収まっている）。
        let walDescription = AppDatabaseError.pragmaValidationFailed(
            pragma: "journal_mode",
            expected: "delete",
            actual: "wal"
        ).errorDescription

        #expect(walDescription?.contains("再作成する必要はありません") == true)
        #expect(walDescription?.contains("journal_mode=DELETE") == true)
        // 汎用メッセージ側の文言（無傷データの削除を誘導しかねない案内）が
        // 混入していないこと。
        #expect(walDescription?.contains("再作成してください") == false)

        // 対比: journal_mode以外のpragma（ここではsynchronous）は専用分岐に
        // 入らず、従来通り汎用メッセージ（PRAGMA名を含む検証失敗の案内）に
        // なること。
        let genericDescription = AppDatabaseError.pragmaValidationFailed(
            pragma: "synchronous",
            expected: "3",
            actual: "2"
        ).errorDescription

        #expect(genericDescription?.contains("PRAGMA synchronous の検証に失敗しました") == true)
    }
}
