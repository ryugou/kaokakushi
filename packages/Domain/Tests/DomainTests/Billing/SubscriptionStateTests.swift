import Testing
@testable import Domain
import Foundation

/// Task 3: 課金・購読状態の型群（architecture.md 6.2）。
///
/// `Plan` の Comparable が宣言順（free < standard < pro）であること、各 struct が
/// Sendable + Equatable でありフィールドを保持すること、`SubscriptionCacheState` の
/// 3 ケースが構築できることを検証する。

private func assertSendableEquatable<T: Sendable & Equatable>(_ value: T) -> T { value }

// MARK: - Plan の Comparable（宣言順: free < standard < pro）

@Test(
    "Planは宣言順で比較されfreeが最小pro が最大",
    arguments: [
        (Plan.free, Plan.standard, true),
        (Plan.standard, Plan.pro, true),
        (Plan.free, Plan.pro, true),
        (Plan.standard, Plan.free, false),
        (Plan.pro, Plan.standard, false),
        (Plan.free, Plan.free, false)
    ]
)
func planComparableFollowsDeclarationOrder(lhs: Plan, rhs: Plan, expectedLessThan: Bool) {
    #expect((lhs < rhs) == expectedLessThan)
}

// MARK: - Plan / PlanStatus の DB 列値（architecture.md 6.2 の表が正本）

@Test(
    "PlanのrawValueが正本どおり",
    arguments: [
        (Plan.free, UInt32(1)),
        (Plan.standard, UInt32(2)),
        (Plan.pro, UInt32(3))
    ]
)
func planRawValueMatchesCanonicalDoc(plan: Plan, expected: UInt32) {
    #expect(plan.rawValue == expected)
}

@Test(
    "PlanStatusのrawValueが正本どおり",
    arguments: [
        (PlanStatus.active, UInt32(1)),
        (PlanStatus.grace, UInt32(2)),
        (PlanStatus.pending, UInt32(3)),
        (PlanStatus.expired, UInt32(4)),
        (PlanStatus.revoked, UInt32(5))
    ]
)
func planStatusRawValueMatchesCanonicalDoc(status: PlanStatus, expected: UInt32) {
    #expect(status.rawValue == expected)
}

// MARK: - CustomerInfoSnapshot / Entitlement / SubscriptionState のフィールド保持

@Test("CustomerInfoSnapshotがSendable/Equatableで全フィールドを保持する")
func customerInfoSnapshotHoldsAllFields() {
    let expiration = Date(timeIntervalSince1970: 1_700_000_000)
    let subject = assertSendableEquatable(CustomerInfoSnapshot(
        activeEntitlementIDs: ["pro"],
        expirationDates: ["pro": expiration],
        willRenew: true,
        isInBillingRetry: false,
        isSandbox: true
    ))
    #expect(subject.activeEntitlementIDs == ["pro"])
    #expect(subject.expirationDates == ["pro": expiration])
    #expect(subject.willRenew == true)
    #expect(subject.isInBillingRetry == false)
    #expect(subject.isSandbox == true)
}

@Test("Entitlementがフィールドを保持しplanで比較できる")
func entitlementHoldsFields() {
    let verifiedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let expiresAt = Date(timeIntervalSince1970: 1_700_100_000)
    let subject = assertSendableEquatable(Entitlement(
        plan: .standard,
        status: .active,
        expiresAt: expiresAt,
        lastVerifiedAt: verifiedAt,
        isSandbox: false
    ))
    #expect(subject.plan == .standard)
    #expect(subject.status == .active)
    #expect(subject.expiresAt == expiresAt)
    #expect(subject.lastVerifiedAt == verifiedAt)
    #expect(subject.isSandbox == false)
}

@Test("SubscriptionStateがEntitlementとfetchedAtを保持する")
func subscriptionStateHoldsFields() {
    let fetchedAt = Date(timeIntervalSince1970: 1_700_000_200)
    let entitlement = Entitlement(
        plan: .pro,
        status: .active,
        expiresAt: nil,
        lastVerifiedAt: fetchedAt,
        isSandbox: false
    )
    let subject = assertSendableEquatable(SubscriptionState(
        entitlement: entitlement,
        willRenew: true,
        fetchedAt: fetchedAt
    ))
    #expect(subject.entitlement == entitlement)
    #expect(subject.willRenew == true)
    #expect(subject.fetchedAt == fetchedAt)
}

// MARK: - ResolvedCapabilities / CapabilityResolution

@Test("ResolvedCapabilitiesが全フィールドを保持する")
func resolvedCapabilitiesHoldsFields() {
    let subject = assertSendableEquatable(ResolvedCapabilities(
        singleExportAccess: .metered,
        canUsePremiumStamps: false,
        canUseCustomStamps: false,
        enabledStampPacks: ["seasonal"],
        canUseProBatch: false,
        canUseBatchTrial: true,
        shouldShowAds: true
    ))
    #expect(subject.singleExportAccess == .metered)
    #expect(subject.enabledStampPacks == ["seasonal"])
    #expect(subject.canUseBatchTrial == true)
    #expect(subject.shouldShowAds == true)
}

@Test("CapabilityResolutionはresolvedとverificationRequiredの2ケースを持つ")
func capabilityResolutionHasTwoCases() {
    let capabilities = ResolvedCapabilities(
        singleExportAccess: .unlimited,
        canUsePremiumStamps: true,
        canUseCustomStamps: true,
        enabledStampPacks: [],
        canUseProBatch: true,
        canUseBatchTrial: false,
        shouldShowAds: false
    )
    let resolved = assertSendableEquatable(CapabilityResolution.resolved(capabilities))
    let verificationRequired = assertSendableEquatable(CapabilityResolution.verificationRequired)
    #expect(resolved != verificationRequired)
}

// MARK: - SubscriptionCacheState の3ケース（Sendableのみ。Equatableではない）

@Test("SubscriptionCacheStateはloaded/missing/temporarilyUnavailableの3ケースを構築できる")
func subscriptionCacheStateHasThreeCases() {
    let entitlement = Entitlement(
        plan: .free,
        status: .expired,
        expiresAt: nil,
        lastVerifiedAt: Date(timeIntervalSince1970: 0),
        isSandbox: false
    )
    let state = SubscriptionState(entitlement: entitlement, willRenew: false, fetchedAt: Date(timeIntervalSince1970: 0))

    let loaded: SubscriptionCacheState = .loaded(state)
    let missing: SubscriptionCacheState = .missing
    let unavailableWithVerified: SubscriptionCacheState = .temporarilyUnavailable(verified: entitlement)
    let unavailableWithoutVerified: SubscriptionCacheState = .temporarilyUnavailable(verified: nil)

    // Sendable のみでコンパイルできること自体が検証（Equatable ではないため switch で分岐確認する）
    for cacheState in [loaded, missing, unavailableWithVerified, unavailableWithoutVerified] {
        switch cacheState {
        case .loaded(let value):
            #expect(value.willRenew == false)
        case .missing:
            #expect(Bool(true))
        case .temporarilyUnavailable(let verified):
            #expect(verified == nil || verified?.plan == .free)
        }
    }
}
