import Foundation
import Testing
import Domain
@testable import Persistence

// ExportSagaStoreLive.startExport — 1.5「開始後に有料契約の失効・月間上限への到達・昇格が
// 起きても無視し、バッチ開始時の認可スナップショットで全項目を完了させる」の Persistence 側の
// 実現（一括処理キュー簡素化 Issue #40 決定2。ExportSagaStoreLive+Start.swift
// loadBatchAuthorization が正）。
//
// 旧方式（同一batchIDの既存ExportJob行から認可を再利用し、行が無ければfresh評価へ
// フォールバックする方式）はdiscardExportで参照元のExportJobが消えると再現できなくなる
// 欠陥があったため、Batch行に認可を固定する新方式へ置き換えて廃棄した。
// 新方式では: (1) createBatchがBatch作成と同一トランザクションで認可を評価・固定する、
// (2) startExportのバッチ経路はBatch行の固定済み認可を読むだけで再評価しない、
// (3) 対応するBatch行が無ければfresh評価へフォールバックせずbatchNotFoundをthrowする
// （createBatchが先に呼ばれている契約のため、無ければ異常系）。
//
// 実行環境注記: CryptoKit は Apple 専用のため、Linux コンテナでの実行には CryptoKit 相当の
// 差し替え（シム）が必要。最終的な検証はホスト・CI（macos-15）が正とする。

@Suite("ExportSagaStoreLive.startExport バッチ認可の固定")
struct ExportSagaStoreStartSnapshotTests {
    @Test("createBatchで固定した認可が、開始後の契約失効を無視して以降の項目に使われ続けること")
    func usesAuthorizationFixedByCreateBatchIgnoringPermissionLossAfterFirstItemStarted() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let firstProjectID = ProjectID(rawValue: UUID())
        let secondProjectID = ProjectID(rawValue: UUID())
        let batchID = BatchID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: firstProjectID.rawValue)
            try insertProject(connection, projectID: secondProjectID.rawValue)
            // plan 3 = pro、status 1 = active。proBatchはcanUseProBatchを要求するため、
            // 失効するとblocked(.capabilityVerificationRequired)になる（後述のUPDATE）。
            try insertSubscriptionStateRow(connection, plan: 3, status: 1)
        }
        let store = makeExportSagaStore(database: database)

        // createBatch: 契約が有効なうちに認可を評価しBatch行へ固定する。
        let authorization = try await createAuthorizedBatch(store: store, batchID: batchID, kind: .proBatch)
        #expect(authorization.accountingMode == .paidUnlimited)
        #expect(authorization.entitlementSnapshot.status == .active)

        // 項目1: Batch行の固定済み認可をそのまま使ってauthorizedになる。
        let firstJob = try await authorizeExportJob(store: store, projectID: firstProjectID, batchID: batchID)
        #expect(firstJob.authorization.accountingMode == .paidUnlimited)
        #expect(firstJob.batchID == batchID)

        // ここで契約の失効が起きたとみなす（statusをactiveからexpiredへ変更）。fresh評価なら
        // resolveCapabilitiesがfree相当へ倒れcanUseProBatchを失うためblockedになるはずだが、
        // createBatchが固定した認可は再評価されない。
        try await database.dbQueue.write { connection in
            try connection.execute(sql: "UPDATE SubscriptionState SET status = ?", arguments: [4])
        }

        // 項目2: Batch行に固定された認可をそのまま読むため、失効を無視してauthorizedになる
        // はず（1.5）。
        let decision = try await store.startExport(
            try makeStartExportInputFixture(projectID: secondProjectID, batchID: batchID), expectedProjectRevision: 0
        )

        guard case let .authorized(secondJob) = decision else {
            Issue.record("失効を無視してauthorizedになるべきだが、blockedになった: \(decision)")
            return
        }
        #expect(secondJob.batchID == batchID)
        #expect(secondJob.authorization.entitlementSnapshot == firstJob.authorization.entitlementSnapshot)
        #expect(secondJob.authorization.accountingMode == firstJob.authorization.accountingMode)
        #expect(secondJob.authorization.authorizedAt == firstJob.authorization.authorizedAt)
        // 失効後のstatus(4)ではなく、createBatchが認可を固定した時点のstatus(1=active)が
        // そのまま保存されていること（再評価していないことの直接証拠）。
        #expect(secondJob.authorization.entitlementSnapshot.status == .active)
    }

    @Test("対応するBatch行が無い場合、fresh評価へフォールバックせずbatchNotFoundがthrowされること")
    func throwsBatchNotFoundWhenNoBatchRowExists() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let batchID = BatchID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            // plan 3 = pro、status 1 = active。fresh評価が行われるなら認可されるはずの
            // 契約状態にしておく——それでもbatchNotFoundになることで、fresh評価への
            // フォールバックが本当に存在しないことを検証する。
            try insertSubscriptionStateRow(connection, plan: 3, status: 1)
            // createBatchを一度も呼ばないため、このbatchIDに対応するBatch行は存在しない。
        }
        let store = makeExportSagaStore(database: database)

        do {
            _ = try await store.startExport(
                try makeStartExportInputFixture(projectID: projectID, batchID: batchID), expectedProjectRevision: 0
            )
            Issue.record("Batch行が無いのにstartExportが成功した")
        } catch let error as ExportSagaStoreError {
            guard case .batchNotFound(let notFoundBatchID) = error else {
                Issue.record("期待したエラーケース(batchNotFound)ではない: \(error)")
                return
            }
            #expect(notFoundBatchID == batchID)
        } catch {
            Issue.record("ExportSagaStoreError以外がthrowされた: \(error)")
        }
        let jobCount: Int = try await database.dbQueue.read { connection in
            try Int.fetchOne(connection, sql: "SELECT count(*) FROM ExportJob") ?? -1
        }
        #expect(jobCount == 0)
    }
}
