import Foundation
import Testing
import Domain
@testable import Persistence

// ExportSagaStoreLive.startExportの入力検証・データ整合性検査のテスト
// （export-saga.md 0章 discardExport付近のPendingFileDeletion契約とは無関係。
// ExportSagaStoreStartTests.swiftから分離: 400行制限のため、勘定モードの解決結果を
// 検証するテスト〈ExportSagaStoreStartTests.swift〉と、入力検証・DB破損検知を検証する
// テスト〈このファイル〉に分割する）。
//
// 1.1（確認の一致）・1.2（能力）の検査と月間枠チェック（monthlyLimitReached）は
// Persistenceのスコープ外（オーケストレーター確定判断）のため、ここでは検証しない。
// previewConfirmation.projectIDとinput.projectIDの整合検査だけは差し戻し対応7番で
// store側のゲートとして追加されたため、ここで検証する。
//
// バッチ経路（UsageLedgerのBLOB破損検知・Pro加入済みトライアルバッチのpaidUnlimited
// 認可）を検証していたテストは、認可評価がcreateBatchへ移設された（一括処理キュー簡素化
// Issue #40 決定2）ためExportSagaStoreCreateBatchTests.swiftへ移設した。startExportの
// バッチ経路はBatch行に固定済みの認可を読むだけで、UsageLedgerを一切読まない。

@Suite("ExportSagaStoreLive.startExport(検証・データ整合性)")
struct ExportSagaStoreStartValidationTests {
    @Test("previewConfirmation.projectIDがinput.projectIDと異なる場合previewConfirmationProjectMismatchでthrowすること")
    func throwsWhenPreviewConfirmationProjectIDMismatches() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let otherProjectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertSubscriptionStateRow(connection, plan: 1, status: 1)
        }
        let store = makeExportSagaStore(database: database)
        let mismatchedInput = try makeStartExportInputFixture(
            projectID: projectID, previewConfirmationProjectID: otherProjectID
        )

        do {
            _ = try await store.startExport(mismatchedInput, expectedProjectRevision: 0)
            Issue.record("previewConfirmation.projectID不一致なのにstartExportが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .previewConfirmationProjectMismatch(let subjectProjectID, let previewProjectID) = error else {
                Issue.record("期待したエラーケース(previewConfirmationProjectMismatch)ではない: \(error)")
                return
            }
            #expect(subjectProjectID == projectID)
            #expect(previewProjectID == otherProjectID)
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }
    }

    // SubscriptionState / UsageLedgerへ「2件目のINSERT」でmultipleSingletonRowsの
    // fail-closedを検証するテストは、ここに置いていた（throwsWhenSubscriptionState
    // HasMultipleRows / throwsWhenUsageLedgerHasMultipleRows）。id INTEGER PRIMARY KEY
    // CHECK(id = 1)（Schema+Delivery.swift / Schema+Accounting.swift）の導入により、
    // 通常のINSERT経路では2件目の行そのものが物理的に作れなくなった（id省略でも
    // 自動採番id=2でCHECK違反、id=1明示でもPRIMARY KEY重複で失敗する）ため、ここでは
    // 削除した。単一行キーのCHECK制約そのものの拒否はSchemaSingletonKeyTests.swiftの
    // usageLedgerSingleRowKeyRejectsSecondInsert /
    // subscriptionStateSingleRowKeyRejectsSecondInsertが検証する。fetchSingletonRowの
    // multipleSingletonRows検知（CHECK制約を意図的に無効化してでも通す二重担保）は
    // ExportSagaStoreSingletonContractTests.swiftへ移設した。

    @Test("expectedProjectRevisionが実際のprojectRevisionと不一致ならstaleProjectRevisionを返しExportJobを作らないこと")
    func returnsStaleProjectRevisionWhenProjectRevisionMismatches() async throws {
        // Domain契約変更（一括処理キュー簡素化 Issue #40）: revision不一致はthrowではなく
        // ExportStartDecision.staleProjectRevisionという型付きの判定結果で返る
        // （ExportSagaStore.swift docコメント参照）。
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertSubscriptionStateRow(connection, plan: 1, status: 1)
        }
        let store = makeExportSagaStore(database: database)

        let decision = try await store.startExport(
            try makeStartExportInputFixture(projectID: projectID), expectedProjectRevision: 999
        )

        guard case .staleProjectRevision = decision else {
            Issue.record("staleProjectRevisionであるべきだが違う結果になった: \(decision)")
            return
        }
        let jobCount: Int = try await database.dbQueue.read { connection in
            try Int.fetchOne(connection, sql: "SELECT count(*) FROM ExportJob") ?? -1
        }
        #expect(jobCount == 0)
    }

    @Test("Batch行のaccountingModeが不正値の場合table: \"Batch\"のinvalidColumnValueでthrowし、ExportJobの破損と誤認しないこと")
    func throwsInvalidColumnValueWithBatchTableWhenBatchRowAccountingModeIsCorrupted() async throws {
        // decodeAuthorization（+Mapping.swift）はExportJob/Batch双方の認可行を共有デコードする
        // ため、table引数を正しく"Batch"で渡していることをここで検証する。これを検証しないと
        // Batch行の破損がExportJobの破損として誤って報告されても気づけない
        // （運用者が誤ったテーブルを調査してしまう）。
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let batchID = BatchID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            // plan 3 = pro、status 1 = active。proBatchはcanUseProBatchを要求する
            // （ExportSagaStoreStartSnapshotTests.swiftと同じ組み合わせ）。
            try insertSubscriptionStateRow(connection, plan: 3, status: 1)
        }
        let store = makeExportSagaStore(database: database)
        _ = try await createAuthorizedBatch(store: store, batchID: batchID, kind: .proBatch)
        try await database.dbQueue.write { connection in
            try connection.execute(sql: "UPDATE Batch SET accountingMode = ?", arguments: [999])
        }

        do {
            _ = try await store.startExport(
                try makeStartExportInputFixture(projectID: projectID, batchID: batchID), expectedProjectRevision: 0
            )
            Issue.record("Batch行のaccountingModeが不正値なのにstartExportが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .invalidColumnValue(let table, let column, let rawValue) = error else {
                Issue.record("期待したエラーケース(invalidColumnValue)ではない: \(error)")
                return
            }
            #expect(table == "Batch", "ExportJobの破損と誤認していないか（table引数の検証）")
            #expect(column == "accountingMode")
            #expect(rawValue == 999)
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }
    }
}
