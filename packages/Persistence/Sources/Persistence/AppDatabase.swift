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
// スキーマ（テーブル定義）はまだ無い（Task 2の担当）。

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

        return AppDatabase(dbQueue: dbQueue)
    }

    /// 設定したPRAGMAを実際に読み返し、期待値と一致するか検証する。
    /// 一致しない場合は復旧エラーとしてthrowする（握りつぶさない）。
    private static func validatePragmas(dbQueue: DatabaseQueue) throws {
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
