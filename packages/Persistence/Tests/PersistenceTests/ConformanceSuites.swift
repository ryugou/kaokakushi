import Foundation
import Testing
import GRDB
import Domain
@testable import Persistence

// 永続化ポート（ExportSagaStore / OutputDeliveryStore / StampStore）の適合スイート
// （Issue #6 Task 7・test-plan.md 4.1「プロトコル適合テスト」が正本）。
//
// ここに置く検証関数（verifyXxx）はプロトコル型（`some <Protocol>`）だけを受け取り、本体
// 内部では Persistence の内部型・GRDB の Database/Row・生SQLを一切使わない。理由は
// 「実装（Live）と偽実装（Fake）へ同じスイートを実行し、両者の挙動が一致することを確認する」
// （test-plan.md 4.1）ため。DB行の準備・Live storeの組み立てのようなテスト用フィクスチャ
// 作りは検証関数の外側（各 @Test 本体。@testable import Persistence を使ってよい）で行う。
//
// **現状の適用範囲（重要）**: DomainTestsのフェイク（FakeExportSagaStore /
// FakeOutputDeliveryStore / FakeStampStore、packages/Domain/Tests/DomainTests/Ports/*.swift）
// は private actor として宣言されており、モジュール外のPersistenceTestsから参照できない。
// そのためこのTaskでは検証関数をLive実装のみへ適用する。フェイクへの適用はApplication層の
// フェイク整備（サブプロジェクト4）が完了し、フェイクが参照可能な形（internal以上）で
// 提供されてから行う。
//
// ファイル分割: 400行・型本体250行制限のため、ExportSagaStoreはこのファイル、
// OutputDeliveryStoreはConformanceSuites+OutputDelivery.swift、StampStoreは
// ConformanceSuites+Stamp.swiftに分ける（WorkingSourceStoreLive.swiftの分割パターンを踏襲）。

// MARK: - ExportSagaStore: 検証関数

/// startExportのblocked網羅スイート1件分（label はIssue.record出力用の識別子）。
struct ExportStartBlockScenario: Sendable {
    let label: String
    let input: StartExportInput
    let expectedProjectRevision: Int64
    let expectedReason: ExportStartBlockReason
}

/// startExportの blocked 網羅を検証する。`ExportStartBlockReason`
/// （Accounting/ExportAuthorization.swift）はCaseIterableではないため、正本の3 caseを
/// ここに明示し、渡されたscenariosが過不足なく覆っているかをまず確認したうえで、各
/// シナリオが期待したreasonでblockedになることを確認する。各reasonを発生させるDB行の
/// 準備は呼び出し側が行い、ここではstartExportの戻り値の判定ロジックだけを担う。
func verifyExportSagaStoreStartBlockedCoverage(
    _ store: some ExportSagaStore,
    scenarios: [ExportStartBlockScenario]
) async throws {
    // ExportStartBlockReasonはHashableではないためSetにできない。3 caseを配列で明示し、
    // containsで網羅を確認する。
    let requiredReasons: [ExportStartBlockReason] = [
        .monthlyLimitReached, .trialCreditsUnavailable, .capabilityVerificationRequired
    ]
    let providedReasons = scenarios.map(\.expectedReason)
    for reason in requiredReasons {
        #expect(providedReasons.contains(reason), "\(reason)を検証するscenarioが渡されていない")
    }

    for scenario in scenarios {
        let decision = try await store.startExport(
            scenario.input, expectedProjectRevision: scenario.expectedProjectRevision
        )
        guard case let .blocked(block) = decision else {
            Issue.record("\(scenario.label): blockedであるべき")
            continue
        }
        #expect(block.reason == scenario.expectedReason, "\(scenario.label)")
    }
}

/// discardExportは「ExportJob行が無ければ何もしない」（ExportSagaStore.swift doc コメント
/// 原文）ことを検証する。冪等性を示すため2回連続で呼んでも例外が出ないことを確認する。
func verifyDiscardExportIsIdempotentForUnknownExportID(
    _ store: some ExportSagaStore,
    exportID: ExportID
) async throws {
    try await store.discardExport(exportID, temporaryFiles: [])
    try await store.discardExport(exportID, temporaryFiles: [])
}

// MARK: - ExportSagaStore: フィクスチャ

/// startExportのblocked網羅スイート用の入力を1つのAppDatabaseの上に用意する。
/// SubscriptionState/UsageLedgerはDB全体で単一行の制約があるため（ExportSagaStoreLive+
/// Start.swiftのloadSubscriptionStateコメント参照）、3reasonすべてを同じ行の上で
/// 再現できるよう設計する:
///   - monthlyLimitReached: 単体書き出し（batchIDなし）+ consumedExportIDsをmonthlyLimit
///     （既定5）以上にする
///   - trialCreditsUnavailable: trialバッチ（kind=2, trialCreditCount=3）+
///     trialConsumedExportIDsを3件にする
///   - capabilityVerificationRequired: proBatch（kind=1）。free planはcanUseProBatchが
///     false（ResolveCapabilities.swift capabilities(forPlan:)）のためバッチ種別だけで
///     到達できる（SubscriptionStateを差し替える必要が無い）
func makeExportStartBlockScenarios(_ database: AppDatabase) async throws -> [ExportStartBlockScenario] {
    let monthlyLimitProjectID = ProjectID(rawValue: UUID())
    let trialProjectID = ProjectID(rawValue: UUID())
    let proBatchProjectID = ProjectID(rawValue: UUID())
    let trialBatchID = BatchID(rawValue: UUID())
    let proBatchID = BatchID(rawValue: UUID())
    try await seedAuthorizedProject(database, projectID: monthlyLimitProjectID, plan: 1, status: 1)
    try await seedAuthorizedProject(database, projectID: trialProjectID, plan: 1, status: 1)
    try await seedAuthorizedProject(database, projectID: proBatchProjectID, plan: 1, status: 1)
    try await database.dbQueue.write { connection in
        try insertBatchRow(connection, batchID: trialBatchID.rawValue, kind: 2, trialCreditCount: 3)
        try insertBatchRow(connection, batchID: proBatchID.rawValue, kind: 1, trialCreditCount: 0)
        try insertUsageLedgerRowWithIDs(
            connection, periodYear: 2_023, periodMonth: 11,
            consumedExportIDs: makeExportIDs(count: 5), trialConsumedExportIDs: makeExportIDs(count: 3)
        )
    }
    return [
        ExportStartBlockScenario(
            label: "monthlyLimitReached",
            input: try makeStartExportInputFixture(projectID: monthlyLimitProjectID),
            expectedProjectRevision: 0,
            expectedReason: .monthlyLimitReached
        ),
        ExportStartBlockScenario(
            label: "trialCreditsUnavailable",
            input: try makeStartExportInputFixture(projectID: trialProjectID, batchID: trialBatchID),
            expectedProjectRevision: 0,
            expectedReason: .trialCreditsUnavailable
        ),
        ExportStartBlockScenario(
            label: "capabilityVerificationRequired",
            input: try makeStartExportInputFixture(projectID: proBatchProjectID, batchID: proBatchID),
            expectedProjectRevision: 0,
            expectedReason: .capabilityVerificationRequired
        )
    ]
}

// MARK: - ExportSagaStore: Liveへの適用

@Suite("ConformanceSuites: ExportSagaStore (Live)")
struct ExportSagaStoreConformanceTests {
    @Test("startExportはExportStartBlockReasonの3 case全てにblockedで到達できること")
    func startExportCoversAllBlockReasons() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let scenarios = try await makeExportStartBlockScenarios(database)

        try await verifyExportSagaStoreStartBlockedCoverage(store, scenarios: scenarios)
    }

    @Test("discardExportは存在しないexportIDに対してプロトコル経由で冪等であること")
    func discardExportIsIdempotentThroughProtocol() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)

        try await verifyDiscardExportIsIdempotentForUnknownExportID(store, exportID: ExportID(rawValue: UUID()))
    }
}
