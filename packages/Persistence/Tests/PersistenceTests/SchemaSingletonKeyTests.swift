import Foundation
import Testing
import GRDB
@testable import Persistence

// UsageLedger / SubscriptionState の単一行キー（architecture.md 7.1 一意制約表の
// 「単一行キー」行が正本。SchemaConstraintTests.swift から type_body_length 対応で分離）。

@Suite("Schema 単一行キー")
struct SchemaSingletonKeyTests {

    @Test("UsageLedgerへ2件目のINSERTがCHECK制約違反で失敗すること")
    func usageLedgerSingleRowKeyRejectsSecondInsert() throws {
        let (appDatabase, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        try appDatabase.dbQueue.write { database in
            try insertUsageLedgerRow(database, trialConsumedCount: 0)
        }

        do {
            try appDatabase.dbQueue.write { database in
                try insertUsageLedgerRow(database, trialConsumedCount: 0)
            }
            Issue.record("UsageLedgerの2件目INSERTが成功してしまった")
        } catch DatabaseError.SQLITE_CONSTRAINT_CHECK {
            // 期待どおり単一行キー（id INTEGER PRIMARY KEY CHECK(id = 1)）で拒否された。
        } catch {
            Issue.record("SQLITE_CONSTRAINT_CHECK以外がthrowされた: \(error)")
        }
    }

    @Test("SubscriptionStateへ2件目のINSERTがCHECK制約違反で失敗すること")
    func subscriptionStateSingleRowKeyRejectsSecondInsert() throws {
        let (appDatabase, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        try appDatabase.dbQueue.write { database in
            try insertSubscriptionStateRow(database, plan: 1, status: 1)
        }

        do {
            try appDatabase.dbQueue.write { database in
                try insertSubscriptionStateRow(database, plan: 1, status: 1)
            }
            Issue.record("SubscriptionStateの2件目INSERTが成功してしまった")
        } catch DatabaseError.SQLITE_CONSTRAINT_CHECK {
            // 期待どおり単一行キー（id INTEGER PRIMARY KEY CHECK(id = 1)）で拒否された。
        } catch {
            Issue.record("SQLITE_CONSTRAINT_CHECK以外がthrowされた: \(error)")
        }
    }
}
