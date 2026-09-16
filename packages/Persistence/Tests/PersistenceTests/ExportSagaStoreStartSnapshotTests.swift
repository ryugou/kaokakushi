import Foundation
import Testing
import Domain
@testable import Persistence

// ExportSagaStoreLive.startExport — 1.5「開始後に有料契約の失効・月間上限への到達・昇格が
// 起きても無視し、バッチ開始時の認可スナップショットで全項目を完了させる」の Persistence 側の
// 実現（一括処理キュー簡素化 Issue #40 決定2。ExportSagaStoreLive+Start.swift
// loadBatchAuthorizationSnapshot が正）。
//
// 同一 batchID を持つ既存の ExportJob 行があれば、その authorization をそのまま使い
// resolveVerifiedCapabilities / resolveAccountingMode の fresh 評価を行わない。行が無ければ
// （先行項目が itemFailed 等で ExportJob を作れなかった場合）従来どおり fresh 評価する。
//
// 実行環境注記: このファイルはコンテナ（Linux、CryptoKit 非搭載）でビルド・実行できない
// （ExportSagaStoreLive+Start.swift の insertExportJob が CryptoKitSha256Digest を使うため、
// packages/Persistence 自体が `swift build` すら通らない）。TDD の red 確認・green 確認は
// ホストと CI の検証に委ねる。実装は既存の ExportSagaStoreStartTests.swift 系のパターン
// （makeTestAppDatabase・insertProject・insertSubscriptionStateRow・insertBatchRow・
// makeExportSagaStore・authorizeExportJob）に倣って書いた。

@Suite("ExportSagaStoreLive.startExport バッチ認可スナップショットの再利用")
struct ExportSagaStoreStartSnapshotTests {
    @Test("同一batchIDの先行ExportJobがある場合、開始後の契約失効を無視しauthorizationを再利用すること")
    func reusesAuthorizationSnapshotIgnoringPermissionLossAfterFirstItemStarted() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let batchID = BatchID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            // plan 3 = pro、status 1 = active。proBatchはcanUseProBatchを要求するため、
            // 失効するとblocked(.capabilityVerificationRequired)になる（後述のUPDATE）。
            try insertSubscriptionStateRow(connection, plan: 3, status: 1)
            try insertBatchRow(connection, batchID: batchID.rawValue, kind: 1, trialCreditCount: 0)
        }
        let store = makeExportSagaStore(database: database)

        // 項目1: fresh評価でpaidUnlimitedとして認可される（authorizesProBatchWhenCapableAsPaidUnlimited
        // と同じ前提）。
        let firstJob = try await authorizeExportJob(store: store, projectID: projectID, batchID: batchID)
        #expect(firstJob.authorization.accountingMode == .paidUnlimited)

        // ここで契約の失効が起きたとみなす（statusをactiveからexpiredへ変更）。fresh評価なら
        // resolveCapabilitiesがfree相当へ倒れcanUseProBatchを失うため、
        // blocksProBatchWhenIncapableAsCapabilityVerificationRequiredと同じ理由でblockedになる
        // はずの状態を作る。
        try await database.dbQueue.write { connection in
            try connection.execute(sql: "UPDATE SubscriptionState SET status = ?", arguments: [4])
        }

        // 項目2: 同一batchIDのExportJob行（項目1）が既にあるため、fresh評価をせず項目1の
        // authorizationをそのまま再利用してauthorizedになるはず（1.5）。
        let decision = try await store.startExport(
            try makeStartExportInputFixture(projectID: projectID, batchID: batchID), expectedProjectRevision: 0
        )

        guard case let .authorized(secondJob) = decision else {
            Issue.record("失効を無視してauthorizedになるべきだが、blockedになった: \(decision)")
            return
        }
        #expect(secondJob.authorization.entitlementSnapshot == firstJob.authorization.entitlementSnapshot)
        #expect(secondJob.authorization.accountingMode == firstJob.authorization.accountingMode)
        #expect(secondJob.authorization.authorizedAt == firstJob.authorization.authorizedAt)
        // 失効後のstatus(4)ではなく、項目1が認可された時点のstatus(1=active)がそのまま
        // 保存されていること（fresh評価していないことの直接証拠）。
        #expect(secondJob.authorization.entitlementSnapshot.status == .active)
    }

    @Test("同一batchIDの先行ExportJobが無い場合は次の項目もfresh評価されること")
    func fallsBackToFreshEvaluationWhenNoPriorExportJobExistsForBatch() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let batchID = BatchID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            // 最初から失効状態（status 4 = expired）で挿入する。先行項目がitemFailed等で
            // ExportJobを作れなかった状況を模す（このbatchIDのExportJob行はまだ0件）。
            try insertSubscriptionStateRow(connection, plan: 3, status: 4)
            try insertBatchRow(connection, batchID: batchID.rawValue, kind: 1, trialCreditCount: 0)
        }
        let store = makeExportSagaStore(database: database)

        let decision = try await store.startExport(
            try makeStartExportInputFixture(projectID: projectID, batchID: batchID), expectedProjectRevision: 0
        )

        // 再利用対象のExportJob行が無いためfresh評価が働き、失効状態どおりblockedになる
        // （blocksProBatchWhenIncapableAsCapabilityVerificationRequiredと同じ理由）。
        guard case let .blocked(block) = decision else {
            Issue.record("先行ExportJobが無いのでfresh評価されblockedになるべきだが、authorizedになった: \(decision)")
            return
        }
        #expect(block.reason == .capabilityVerificationRequired)
        let jobCount: Int = try await database.dbQueue.read { connection in
            try Int.fetchOne(connection, sql: "SELECT count(*) FROM ExportJob") ?? -1
        }
        #expect(jobCount == 0)
    }
}
