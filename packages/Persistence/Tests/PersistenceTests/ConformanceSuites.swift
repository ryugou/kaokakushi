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

/// `ExportStartBlockReason`（Accounting/ExportAuthorization.swift）はCaseIterableでは
/// ないため手で列挙する。この配列がDomain側の網羅契約
/// （packages/Domain/Tests/DomainTests/Accounting/ExportAuthorizationTests.swiftの
/// 「ExportStartBlockReasonは3ケース…」テスト）と1対1で対応する唯一の場所であり、Domainに
/// caseが追加された場合はそちらのテストとこの配列の両方を更新する必要がある（どちらか
/// 片方だけを更新すると他方が壊れることで検知される）。
let allExportStartBlockReasons: [ExportStartBlockReason] = [
    .monthlyLimitReached, .trialCreditsUnavailable, .capabilityVerificationRequired
]

/// startExport経路が担当するreason（単体書き出しの`monthlyLimitReached`のみ。理由は
/// startExportRequiredBlockReasons/createBatchRequiredBlockReasonsのdocコメント参照）。
let startExportRequiredBlockReasons: [ExportStartBlockReason] = [.monthlyLimitReached]

/// createBatch経路が担当するreason（`.trialCreditsUnavailable` /
/// `.capabilityVerificationRequired`）。
///
/// 一括処理キュー簡素化 Issue #40（createBatchの新設）により、この2reasonはcreateBatch側
/// でのみ到達可能になった（startExportのバッチ経路はBatch行に固定済みの認可を読むだけで、
/// 認可の再評価をしない。ExportSagaStoreLive+Start.swiftのloadBatchAuthorization参照）。
/// startExportRequiredBlockReasonsとcreateBatchRequiredBlockReasonsを合わせると
/// allExportStartBlockReasons全体を過不足なく覆う（漏れも重複もない）ことを
/// `ExportSagaStoreConformanceTests.requiredBlockReasonsTogetherCoverAllCasesExactlyOnce`
/// が検証する。
let createBatchRequiredBlockReasons: [ExportStartBlockReason] = [
    .trialCreditsUnavailable, .capabilityVerificationRequired
]

/// startExportの blocked 網羅を検証する。呼び出し側が requiredReasons で期待する
/// reasonの集合を明示し、渡されたscenariosが過不足なく覆っているかをまず確認したうえで、
/// 各シナリオが期待したreasonでblockedになることを確認する。各reasonを発生させるDB行の
/// 準備は呼び出し側が行い、ここではstartExportの戻り値の判定ロジックだけを担う。
func verifyExportSagaStoreStartBlockedCoverage(
    _ store: some ExportSagaStore,
    scenarios: [ExportStartBlockScenario],
    requiredReasons: [ExportStartBlockReason]
) async throws {
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

/// createBatchのblocked網羅スイート1件分（verifyExportSagaStoreStartBlockedCoverageと対）。
struct CreateBatchBlockScenario: Sendable {
    let label: String
    let input: CreateBatchInput
    let expectedReason: ExportStartBlockReason
}

/// createBatchのblocked網羅を検証する（verifyExportSagaStoreStartBlockedCoverageと対）。
func verifyExportSagaStoreCreateBatchBlockedCoverage(
    _ store: some ExportSagaStore,
    scenarios: [CreateBatchBlockScenario],
    requiredReasons: [ExportStartBlockReason]
) async throws {
    let providedReasons = scenarios.map(\.expectedReason)
    for reason in requiredReasons {
        #expect(providedReasons.contains(reason), "\(reason)を検証するscenarioが渡されていない")
    }

    for scenario in scenarios {
        let decision = try await store.createBatch(scenario.input)
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

/// startExportのblocked網羅スイート用の入力を用意する。単体書き出し（batchID == nil）
/// 限定のmonthlyLimitReachedのみを対象にする。
///
/// trialCreditsUnavailable・バッチ経路のcapabilityVerificationRequiredはcreateBatchへ
/// 移設したためmakeCreateBatchBlockScenariosが担当する。単体経路の
/// capabilityVerificationRequired（SubscriptionState行が無い）はSubscriptionStateが
/// DB全体で単一行の制約を持つため（ExportSagaStoreLive+Start.swiftのloadSubscriptionState
/// コメント参照）、monthlyLimitReached用に用意する行（SubscriptionState行が存在する状態）
/// と同じDB内で同時に再現できない。該当ケースは
/// ExportSagaStoreStartTests.swift.blocksWhenSubscriptionStateMissingが単体で検証する。
func makeExportStartBlockScenarios(_ database: AppDatabase) async throws -> [ExportStartBlockScenario] {
    let monthlyLimitProjectID = ProjectID(rawValue: UUID())
    try await seedAuthorizedProject(database, projectID: monthlyLimitProjectID, plan: 1, status: 1)
    try await database.dbQueue.write { connection in
        try insertUsageLedgerRowWithIDs(
            connection, periodYear: 2_023, periodMonth: 11,
            consumedExportIDs: makeExportIDs(count: 5), trialConsumedExportIDs: []
        )
    }
    return [
        ExportStartBlockScenario(
            label: "monthlyLimitReached",
            input: try makeStartExportInputFixture(projectID: monthlyLimitProjectID),
            expectedProjectRevision: 0,
            expectedReason: .monthlyLimitReached
        )
    ]
}

/// createBatchのblocked網羅スイート用の入力を用意する（バッチ専用の2reason:
/// trialCreditsUnavailable / capabilityVerificationRequired）。createBatchはprojectIDを
/// 取らずSubscriptionStateとUsageLedgerだけを見るため、1つのSubscriptionState行
/// （plan=1free相当。Domain/Billing/SubscriptionState.swiftのPlanはfree=1/standard=2/pro=3で、
/// plan=1はfree。ResolveCapabilities.swiftのfreeEquivalentCapabilitiesによりcanUseProBatch
/// == false）で両方のreasonを同時に再現できる:
///   - trialCreditsUnavailable: trialポリシー（trialCreditCount=3）+
///     trialConsumedExportIDsを3件にする
///   - capabilityVerificationRequired: proBatchポリシー。canUseProBatch == falseのため
///     ポリシー種別だけで到達できる
func makeCreateBatchBlockScenarios(_ database: AppDatabase) async throws -> [CreateBatchBlockScenario] {
    try await database.dbQueue.write { connection in
        try insertSubscriptionStateRow(connection, plan: 1, status: 1)
        try insertUsageLedgerRowWithIDs(
            connection, periodYear: 2_023, periodMonth: 11,
            consumedExportIDs: [], trialConsumedExportIDs: makeExportIDs(count: 3)
        )
    }
    let trialPolicy = BatchPolicySnapshot(kind: .trial, batchSizeLimit: 50, trialCreditCount: 3, concurrencyLimit: 1)
    let proBatchPolicy = BatchPolicySnapshot(
        kind: .proBatch, batchSizeLimit: 50, trialCreditCount: 0, concurrencyLimit: 1
    )
    return [
        CreateBatchBlockScenario(
            label: "trialCreditsUnavailable",
            input: CreateBatchInput(batchID: BatchID(rawValue: UUID()), policy: trialPolicy),
            expectedReason: .trialCreditsUnavailable
        ),
        CreateBatchBlockScenario(
            label: "capabilityVerificationRequired",
            input: CreateBatchInput(batchID: BatchID(rawValue: UUID()), policy: proBatchPolicy),
            expectedReason: .capabilityVerificationRequired
        )
    ]
}

// MARK: - ExportSagaStore: Liveへの適用

@Suite("ConformanceSuites: ExportSagaStore (Live)")
struct ExportSagaStoreConformanceTests {
    @Test("startExportは単体書き出しのmonthlyLimitReachedへblockedで到達できること")
    func startExportCoversSingleExportBlockReasons() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let scenarios = try await makeExportStartBlockScenarios(database)

        try await verifyExportSagaStoreStartBlockedCoverage(
            store, scenarios: scenarios, requiredReasons: startExportRequiredBlockReasons
        )
    }

    @Test("createBatchはtrialCreditsUnavailable/capabilityVerificationRequiredへblockedで到達できること")
    func createBatchCoversBatchBlockReasons() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let scenarios = try await makeCreateBatchBlockScenarios(database)

        try await verifyExportSagaStoreCreateBatchBlockedCoverage(
            store, scenarios: scenarios, requiredReasons: createBatchRequiredBlockReasons
        )
    }

    @Test("startExport用とcreateBatch用のrequiredReasonsを合わせるとExportStartBlockReasonの全caseを過不足なく覆うこと")
    func requiredBlockReasonsTogetherCoverAllCasesExactlyOnce() {
        let combined = startExportRequiredBlockReasons + createBatchRequiredBlockReasons

        #expect(combined.count == allExportStartBlockReasons.count, "合計件数が全case数と一致しない（重複または過剰）")
        for reason in allExportStartBlockReasons {
            let occurrences = combined.filter { $0 == reason }.count
            #expect(occurrences == 1, "\(reason)がrequiredReasonsの合計にちょうど1回含まれていない（実際は\(occurrences)回）")
        }
    }

    @Test("discardExportは存在しないexportIDに対してプロトコル経由で冪等であること")
    func discardExportIsIdempotentThroughProtocol() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)

        try await verifyDiscardExportIsIdempotentForUnknownExportID(store, exportID: ExportID(rawValue: UUID()))
    }
}
