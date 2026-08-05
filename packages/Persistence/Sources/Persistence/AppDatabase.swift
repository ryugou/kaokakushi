import Foundation
import GRDB

// アプリの唯一のDB接続（architecture.md 7.1「接続と journal」が正本）。
//
// 接続は DatabaseQueue を1つだけ使い（DatabasePool・in-memoryは使わない）、
// journal_mode = DELETE / synchronous = EXTRA / foreign_keys = ON を接続確立時に
// 設定する。設定コマンドの実行だけでは規約を満たしたことにならない
// （journal_modeはファイルヘッダに記録される場合があり、他接続の状態次第で
// 切り替えが反映されないことがある）ため、起動時に必ず実際の値を読み返して
// 検証し、加えて PRAGMA foreign_key_check で外部キー違反の有無を確認する。
// スキーマ（テーブル定義・制約）は Schema.swift の AppSchema.makeMigrator() が
// 単一の DatabaseMigrator として提供する（Issue #6 Task 2）。

/// AppDatabase.open(at:) が送出する復旧エラー。
/// 運用者が次のアクションを判断できるよう、期待値と実際の値、または違反件数を持つ。
public enum AppDatabaseError: Error, Sendable, Equatable {
    /// 起動時に読み返したPRAGMAの値が接続規約と一致しなかった。
    case pragmaValidationFailed(pragma: String, expected: String, actual: String)

    /// 起動時の PRAGMA foreign_key_check で外部キー制約違反を検出した。
    case foreignKeyViolationsDetected(violationCount: Int)
}

extension AppDatabaseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .pragmaValidationFailed(let pragma, let expected, let actual):
            // journal_mode = WAL の検出は「他プロセスに開かれている」「破損している」
            // のいずれでもなく、データも失われていない（ファイルヘッダにWALが永続
            // 記録されているだけ）。汎用メッセージのまま「DBファイルを再作成して
            // ください」と案内すると、無傷のユーザーデータを運用者が削除しかねない
            // ため、このケースだけ専用の案内を返す。
            if pragma == "journal_mode", actual.lowercased() == "wal" {
                return """
                AppDatabase: このDBファイルは journal_mode = WAL として永続化されて \
                います（規約は \(expected)）。データは失われていません。DBファイルを \
                削除・再作成する必要はありません。復旧手順: このDBを開いている全 \
                プロセスを終了したうえで `sqlite3 <DBファイル> \
                "PRAGMA journal_mode=DELETE;"` を実行し、journal_modeをDELETEへ \
                変換してください。コマンド実行後も -wal / -shm ファイルが残る場合は、 \
                その2ファイルのみ（DBファイル本体ではない）を手動削除してください。
                """
            }
            return """
            AppDatabase: PRAGMA \(pragma) の検証に失敗しました \
            （期待値: \(expected), 実際の値: \(actual)）。DBファイルが他プロセスから \
            開かれたままか、破損している可能性があります。DBを排他的に開けるか \
            確認したうえで、必要であればDBファイルを再作成してください。
            """
        case .foreignKeyViolationsDetected(let violationCount):
            return """
            AppDatabase: 起動時のPRAGMA foreign_key_checkで\(violationCount)件の \
            外部キー制約違反を検出しました。DBが不整合な状態で書き込まれた可能性が \
            あります。バックアップからの復元、または該当行の手動修復を検討してください。
            """
        }
    }
}

/// アプリのDB接続を保持する。将来のRepository実装（Task 3以降）が同じモジュール内の
/// 他ファイルから dbQueue を使えるよう internal（モジュール内既定アクセス）で公開する。
public struct AppDatabase: Sendable {
    let dbQueue: DatabaseQueue

    private init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// journal_mode = DELETE / synchronous = EXTRA / foreign_keys = ON の接続規約で
    /// ファイルDBを開く。in-memory用のAPIは用意しない
    /// （journal_modeの検証がin-memoryでは意味を成さないため。ファイルDB専用）。
    public static func open(at url: URL) throws -> AppDatabase {
        // 既存DBファイルがある場合、prepareDatabaseで journal_mode = DELETE を
        // 適用する前に、現在のjournal_modeをファイルヘッダから検査する。
        // 理由: DELETE設定 → 読み返し検証 の順序だと、外部プロセスがWAL化した
        // 既存DBを開いた際、この接続確立自体がDELETEへ自己修復してしまい、
        // 「journal_modeがDELETE以外（TRUNCATE/PERSIST/WAL）なら復旧エラーになる」
        // という要求（test-plan.md 4.2）に反する。journal_mode = DELETEの接続規約
        // 自体はarchitecture.md 7.1が正本。新規作成されるファイルにはこの問題が
        // 起きない（SQLite既定のjournal_modeがdeleteのため）のでチェックを省略する。
        try rejectIfExistingFileUsesWAL(at: url)

        var configuration = Configuration()
        // prepareDatabaseは新しい接続が確立された直後、トランザクション開始前に
        // 呼ばれる。PRAGMA foreign_keys / journal_mode はトランザクション中の変更が
        // no-opになりうるため（SQLiteの仕様）、この経路で設定する。
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA journal_mode = DELETE")
            try database.execute(sql: "PRAGMA synchronous = EXTRA")
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)

        try validatePragmas(dbQueue: dbQueue)
        try validateForeignKeyIntegrity(dbQueue: dbQueue)

        // スキーマ（全テーブル・制約）を単一トランザクションのマイグレーションで
        // 確定する（Schema.swift / test-plan.md 4.2「スキーマ移行が単一トランザク
        // ションで確定し、途中適用が観測されないこと」）。PRAGMA検証・
        // foreign_key_check検証より後に置くのは、テーブルが無い新規DBでもこの2つの
        // 検証自体は意味を持つため（Task 1時点の挙動を変えない）。
        try AppSchema.makeMigrator().migrate(dbQueue)

        return AppDatabase(dbQueue: dbQueue)
    }

    /// SQLiteファイルフォーマット（https://sqlite.org/fileformat.html
    /// 1.3 The Database Header）の先頭16バイトに置かれるマジック文字列。
    /// これと一致しないファイルはSQLite DBとして扱わず、ヘッダのjournal_mode
    /// 判定（オフセット18/19）を行わない（DBでないファイルのオフセット18/19が
    /// たまたま2のとき「journal_modeがwal」と誤診断するのを防ぐ。ファイルの
    /// 妥当性そのものの判定は後続のGRDB接続に委ねる）。
    private static let sqliteHeaderMagic: [UInt8] = Array("SQLite format 3\0".utf8)

    /// 既存のDBファイルがjournal_mode = WALであるかを、SQLite接続を一切使わず
    /// ファイルヘッダのバイト読み取りと-wal/-shmサイドカーの存在確認のみで判定
    /// する。WALであれば復旧エラーをthrowする。ファイルが存在しない場合、または
    /// 新規作成直後・空ファイル等でヘッダを20バイト読み切れない場合は「検査不要」
    /// としてそのまま返る（新規作成パスではSQLite既定のjournal_modeがdeleteの
    /// ため）。
    ///
    /// readonly接続でPRAGMA journal_modeを問い合わせる方式は採らない。readonly
    /// 接続でWALのDBを開こうとするとerror 14（SQLITE_CANTOPEN）で失敗し検出
    /// できなかったため、接続を介さないヘッダ読みにしている。
    ///
    /// ヘッダのオフセット18（file format write version）・19（file format read
    /// version）がjournal modeを表す: 1 = legacy（rollback journal =
    /// DELETE/TRUNCATE/PERSIST）、2 = WAL。TRUNCATE/PERSISTは接続ごとの実行時
    /// 設定でありファイルヘッダには永続されないため、このヘッダ検査ではWAL検出
    /// のみを行えばtest-plan.md 4.2の「journal_modeがDELETE以外なら復旧エラーに
    /// なる」要求を満たす。実行時のTRUNCATE/PERSISTへのドリフトは、接続確立後に
    /// 設定する3 PRAGMAの読み返し検証（validatePragmas）が別途検出する。
    ///
    /// -wal/-shmサイドカーの存在も合わせて確認する。新規DBをWALで書き込み始めた
    /// 直後にチェックポイント前でクラッシュした場合、DB本体はヘッダが未確定
    /// （20バイト未満）のままだが-walにはWALの内容が残ることがあり、ヘッダ検査
    /// だけでは見逃す。journal_mode = DELETEの運用下では-wal/-shmは決して生成
    /// されないため、存在そのものがWAL使用の証跡であり誤検知は無い。
    ///
    /// I/Oエラー（権限不足・破損等）は握りつぶさずそのまま呼び出し元へ伝播させる
    /// （fail-closed）。なお、fileExists確認からこの関数を抜けるまでの間、また
    /// この関数から後続のDatabaseQueue生成までの間には理論上のTOCTOU（他プロセス
    /// によるファイルの削除・置換）が存在するが、起動時に単一プロセスから呼ばれる
    /// 経路であることを前提として許容する。
    private static func rejectIfExistingFileUsesWAL(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        let walSidecarPath = url.path + "-wal"
        let shmSidecarPath = url.path + "-shm"
        if FileManager.default.fileExists(atPath: walSidecarPath)
            || FileManager.default.fileExists(atPath: shmSidecarPath) {
            throw AppDatabaseError.pragmaValidationFailed(
                pragma: "journal_mode",
                expected: "delete",
                actual: "wal"
            )
        }

        let fileHandle = try FileHandle(forReadingFrom: url)
        // 読み取り専用ハンドルのクローズ失敗はDBの状態に影響しないため、
        // エラーは握りつぶしてよい（fail-closedが必要なのはDB内容の読み取り
        // 自体であり、ハンドルの解放結果ではない）。
        defer { try? fileHandle.close() }

        // ヘッダは100バイトあるが、判定に使うマジック文字列(0-15)とオフセット
        // 18/19が読めれば十分なので20バイトだけ読む（DBファイル全体をメモリに
        // 読み込まない）。
        guard let header = try fileHandle.read(upToCount: 20), header.count == 20 else {
            return
        }

        // Dataのインデックスは常に0始まりとは限らないため、Arrayへ変換してから
        // 添字参照する（FileHandle.readの戻り値のstartIndexが0である保証に
        // 依拠しない）。
        let headerBytes = Array(header)

        guard Array(headerBytes[0..<16]) == sqliteHeaderMagic else {
            return
        }

        let fileFormatWriteVersion = headerBytes[18]
        let fileFormatReadVersion = headerBytes[19]

        if fileFormatWriteVersion == 2 || fileFormatReadVersion == 2 {
            throw AppDatabaseError.pragmaValidationFailed(
                pragma: "journal_mode",
                expected: "delete",
                actual: "wal"
            )
        }
    }

    /// 設定したPRAGMAを実際に読み返し、期待値と一致するか検証する。
    /// 一致しない場合は復旧エラーとしてthrowする（握りつぶさない）。
    ///
    /// internal（モジュール内既定アクセス）にしているのは、AppDatabaseTests が
    /// AppDatabase.open(at:) を経由せず生の GRDB DatabaseQueue を直接開いて
    /// journal_mode = PERSIST を再現し、この関数を直接呼び出して復旧エラーを
    /// 固定するため（TRUNCATE/PERSISTはファイルヘッダに残らずヘッダ検査
    /// では検出できない。Issue #6 Task 1 レビュー指摘）。
    static func validatePragmas(dbQueue: DatabaseQueue) throws {
        try dbQueue.read { database in
            let journalMode = try String.fetchOne(database, sql: "PRAGMA journal_mode") ?? ""
            guard journalMode.lowercased() == "delete" else {
                throw AppDatabaseError.pragmaValidationFailed(
                    pragma: "journal_mode",
                    expected: "delete",
                    actual: journalMode
                )
            }

            // synchronous=EXTRAはSQLite内部表現で整数値3。
            let expectedSynchronous = 3
            let synchronous = try Int.fetchOne(database, sql: "PRAGMA synchronous") ?? -1
            guard synchronous == expectedSynchronous else {
                throw AppDatabaseError.pragmaValidationFailed(
                    pragma: "synchronous",
                    expected: String(expectedSynchronous),
                    actual: String(synchronous)
                )
            }

            let foreignKeys = try Int.fetchOne(database, sql: "PRAGMA foreign_keys") ?? -1
            guard foreignKeys == 1 else {
                throw AppDatabaseError.pragmaValidationFailed(
                    pragma: "foreign_keys",
                    expected: "1",
                    actual: String(foreignKeys)
                )
            }
        }
    }

    /// PRAGMA foreign_key_check を実行し、違反があれば復旧エラーとしてthrowする。
    /// 現時点ではテーブルが無いため通常は0件だが、将来スキーマが載っても機能するよう
    /// 常に実行する。
    private static func validateForeignKeyIntegrity(dbQueue: DatabaseQueue) throws {
        let violations = try dbQueue.read { database in
            try Row.fetchAll(database, sql: "PRAGMA foreign_key_check")
        }
        guard violations.isEmpty else {
            throw AppDatabaseError.foreignKeyViolationsDetected(violationCount: violations.count)
        }
    }
}
