import Testing
@testable import Domain
import Foundation

/// Task 4: 履歴削除の永続化ポート（architecture.md「削除の可否判定」〜「出力の削除経路」節）。
///
/// `HistoryUnit` / `DeletionTrigger` / `OverridableProtection` / `DeletionContext` /
/// `DeletionInspection` / `AbsoluteProtection` の各ケース・フィールド保持と、
/// `HistoryDeletionStore` への最小準拠を検証する。`canDeleteHistoryUnit`（純粋関数）は
/// どのタスクにも割り当てが無いためここでは扱わない（spec 参照）。

// MARK: - HistoryUnit

@Test("HistoryUnit.projectはProjectIDを保持し値として比較できる")
func historyUnitProjectHoldsProjectID() {
    let projectID = ProjectID(rawValue: UUID())
    let subject = HistoryUnit.project(projectID)
    #expect(subject == .project(projectID))
    #expect(subject != .project(ProjectID(rawValue: UUID())))
}

// MARK: - DeletionTrigger（3ケース）

@Test("DeletionTriggerのstoragePressureとretentionExpiryは引数を持たないcaseとして構築できる")
func deletionTriggerParameterlessCasesConstruct() {
    let cases: [DeletionTrigger] = [.storagePressure, .retentionExpiry]
    #expect(cases.count == 2)
}

@Test("DeletionTrigger.userInitiatedはconfirmedOverridesのSetを保持する")
func deletionTriggerUserInitiatedHoldsConfirmedOverrides() {
    let overrides: Set<OverridableProtection> = [.favorite, .workingSource]
    let subject = DeletionTrigger.userInitiated(confirmedOverrides: overrides)
    guard case let .userInitiated(heldOverrides) = subject else {
        Issue.record("userInitiatedケースであるべき")
        return
    }
    #expect(heldOverrides == overrides)
}

// MARK: - OverridableProtection（3ケース、Hashable）

@Test(
    "OverridableProtectionはfavorite/beingEdited/workingSourceの3ケースを持ちHashableである",
    arguments: [OverridableProtection.favorite, .beingEdited, .workingSource]
)
func overridableProtectionHasThreeCases(protectionCase: OverridableProtection) {
    #expect(Set([protectionCase]).contains(protectionCase))
}

// MARK: - DeletionContext（同一DBトランザクション内で読み取った参照状況）

@Test("DeletionContextが全フィールドを保持する")
func deletionContextHoldsAllFields() {
    let subject = DeletionContext(
        trigger: .storagePressure,
        isFavorite: true,
        isBeingEdited: false,
        hasNonTerminalQueueItem: true,
        hasUndeliveredOutputRecord: false,
        hasRunningExportJob: true,
        hasWorkingSourceRecord: false
    )

    guard case .storagePressure = subject.trigger else {
        Issue.record("triggerがstoragePressureであるべき")
        return
    }
    #expect(subject.isFavorite == true)
    #expect(subject.isBeingEdited == false)
    #expect(subject.hasNonTerminalQueueItem == true)
    #expect(subject.hasUndeliveredOutputRecord == false)
    #expect(subject.hasRunningExportJob == true)
    #expect(subject.hasWorkingSourceRecord == false)
}

// MARK: - DeletionInspection / AbsoluteProtection

@Test("DeletionInspectionが全フィールドを保持する")
func deletionInspectionHoldsAllFields() {
    let subject = DeletionInspection(
        blockedByAbsoluteProtection: [.exportJobRunning],
        overridableProtections: [.favorite, .beingEdited],
        reclaimableBytes: 4_096
    )

    #expect(subject.blockedByAbsoluteProtection == [.exportJobRunning])
    #expect(subject.overridableProtections == [.favorite, .beingEdited])
    #expect(subject.reclaimableBytes == 4_096)
}

@Test(
    "AbsoluteProtectionはnonTerminalQueueItem/exportJobRunning/undeliveredOutputの3ケースを持ちHashableである",
    arguments: [AbsoluteProtection.nonTerminalQueueItem, .exportJobRunning, .undeliveredOutput]
)
func absoluteProtectionHasThreeCases(protectionCase: AbsoluteProtection) {
    #expect(Set([protectionCase]).contains(protectionCase))
}

// MARK: - HistoryDeletionStore への最小準拠

private actor FakeHistoryDeletionStore: HistoryDeletionStore {
    private(set) var inspectDeletionCalls: [(unit: HistoryUnit, trigger: DeletionTrigger)] = []
    private(set) var deleteHistoryUnitCalls: [(unit: HistoryUnit, trigger: DeletionTrigger)] = []

    var inspectDeletionResult: DeletionInspection

    init(inspectDeletionResult: DeletionInspection) {
        self.inspectDeletionResult = inspectDeletionResult
    }

    func inspectDeletion(_ unit: HistoryUnit, trigger: DeletionTrigger) async throws -> DeletionInspection {
        inspectDeletionCalls.append((unit, trigger))
        return inspectDeletionResult
    }

    func deleteHistoryUnit(_ unit: HistoryUnit, trigger: DeletionTrigger) async throws {
        deleteHistoryUnitCalls.append((unit, trigger))
    }
}

@Test("HistoryDeletionStoreへの最小準拠がunitとtriggerを渡された値どおりに記録する")
func fakeHistoryDeletionStoreForwardsArguments() async throws {
    let expectedInspection = DeletionInspection(
        blockedByAbsoluteProtection: [],
        overridableProtections: [.favorite],
        reclaimableBytes: 1_024
    )
    let store = FakeHistoryDeletionStore(inspectDeletionResult: expectedInspection)
    let unit = HistoryUnit.project(ProjectID(rawValue: UUID()))
    let trigger = DeletionTrigger.userInitiated(confirmedOverrides: [.favorite])

    let inspection = try await store.inspectDeletion(unit, trigger: trigger)
    #expect(inspection.reclaimableBytes == 1_024)

    try await store.deleteHistoryUnit(unit, trigger: trigger)

    let inspectCalls = await store.inspectDeletionCalls
    #expect(inspectCalls.count == 1)
    #expect(inspectCalls[0].unit == unit)

    let deleteCalls = await store.deleteHistoryUnitCalls
    #expect(deleteCalls.count == 1)
    #expect(deleteCalls[0].unit == unit)
}
