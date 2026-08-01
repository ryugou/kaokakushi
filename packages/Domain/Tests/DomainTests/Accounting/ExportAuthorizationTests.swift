import Testing
@testable import Domain
import Foundation

/// Task 3: 書き出し認可の型群（export-saga.md 1.1 / 1.2 / 1.3）。
///
/// `PreviewConfirmation` / `BatchReviewState` のフィールド保持、`StampRequirement` の
/// 4ケース、`StampCatalog` プロトコルへの最小準拠、`ExportAccountingMode` の3ケース、
/// `ExportStartBlockReason` の3ケース、`ExportStartBlock` のフィールド保持を検証する。

@Test("PreviewConfirmationが全フィールドを保持する")
func previewConfirmationHoldsAllFields() {
    let projectID = ProjectID(rawValue: UUID())
    let hash = PreviewRenderHash(bytes: Data(repeating: 0x01, count: 32))
    let subject = assertSendableEquatable(PreviewConfirmation(
        projectID: projectID,
        detectionRevision: 3,
        previewRenderHash: hash
    ))
    #expect(subject.projectID == projectID)
    #expect(subject.detectionRevision == 3)
    #expect(subject.previewRenderHash == hash)
}

@Test("BatchReviewStateが全フィールドを保持する")
func batchReviewStateHoldsAllFields() {
    let batchID = BatchID(rawValue: UUID())
    let subject = assertSendableEquatable(BatchReviewState(batchID: batchID, overviewConfirmed: true))
    #expect(subject.batchID == batchID)
    #expect(subject.overviewConfirmed == true)
}

@Test(
    "StampRequirementはfree/premium/custom/unknownBuiltInの4ケースを持ちHashableである",
    arguments: [StampRequirement.free, .premium(packID: "seasonal"), .custom, .unknownBuiltIn]
)
func stampRequirementHasFourCases(requirement: StampRequirement) {
    #expect(Set([requirement]).contains(requirement))
}

/// StampCatalog の最小準拠テスト用実装（テストのみで完結し、production コードには含まれない）
private struct FixedStampCatalog: StampCatalog {
    func requirement(forBuiltIn code: String) -> StampRequirement? {
        code == "star" ? .free : nil
    }
}

@Test("StampCatalogプロトコルへの準拠がコンパイルでき期待どおりに解決する")
func stampCatalogMinimalConformanceResolves() {
    let catalog = FixedStampCatalog()
    #expect(catalog.requirement(forBuiltIn: "star") == .free)
    #expect(catalog.requirement(forBuiltIn: "unknown-code") == nil)
}

@Test("ExportAuthorizationが全フィールドを保持する")
func exportAuthorizationHoldsAllFields() {
    let entitlement = Entitlement(
        plan: .standard,
        status: .active,
        expiresAt: nil,
        lastVerifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
        isSandbox: false
    )
    let authorizedAt = Date(timeIntervalSince1970: 1_700_000_500)
    let subject = ExportAuthorization(
        entitlementSnapshot: entitlement,
        accountingMode: .freeMonthlyConsume,
        authorizedAt: authorizedAt
    )
    #expect(subject.entitlementSnapshot == entitlement)
    #expect(subject.accountingMode == .freeMonthlyConsume)
    #expect(subject.authorizedAt == authorizedAt)
}

@Test(
    "ExportAccountingModeはpaidUnlimited/freeMonthlyConsume/batchTrialの3ケースを持つ",
    arguments: [ExportAccountingMode.paidUnlimited, .freeMonthlyConsume, .batchTrial]
)
func exportAccountingModeHasThreeCases(mode: ExportAccountingMode) {
    #expect(Set([mode]).contains(mode))
}

@Test(
    "ExportStartBlockReasonは3ケース（monthlyLimitReached/trialCreditsUnavailable/capabilityVerificationRequired）を持つ",
    arguments: [
        ExportStartBlockReason.monthlyLimitReached,
        .trialCreditsUnavailable,
        .capabilityVerificationRequired
    ]
)
func exportStartBlockReasonHasThreeCases(reason: ExportStartBlockReason) {
    let subject = assertSendableEquatable(reason)
    #expect(subject == reason)
}

@Test("ExportStartBlockがreasonとnon-nilなlimitを保持する")
func exportStartBlockHoldsNonNilLimit() {
    let subject = assertSendableEquatable(ExportStartBlock(reason: .monthlyLimitReached, limit: 10))
    #expect(subject.reason == .monthlyLimitReached)
    #expect(subject.limit == 10)
}

@Test("ExportStartBlockがlimitにnilを保持できる（capabilityVerificationRequiredのように上限概念がない理由）")
func exportStartBlockHoldsNilLimit() {
    let subject = assertSendableEquatable(
        ExportStartBlock(reason: .capabilityVerificationRequired, limit: nil)
    )
    #expect(subject.reason == .capabilityVerificationRequired)
    #expect(subject.limit == nil)
}
