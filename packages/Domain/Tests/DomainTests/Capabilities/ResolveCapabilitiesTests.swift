import Testing
@testable import Domain
import Foundation

/// Task 6: 能力解決の純粋関数（architecture.md 6.2「能力の解決」節、
/// product-decisions.md 3.1「課金訴求分類表」〈91-97行〉）。
///
/// `SubscriptionCacheState` の状態ルーティング（missing / temporarilyUnavailable /
/// loaded）、Entitlement.status × Plan の組み合わせによる `ResolvedCapabilities` の導出、
/// 失効判定（expiresAt）の優先順位、enabledStampPacksのプラン非依存な受け渡しを検証する。

private let referenceNow = Date(timeIntervalSince1970: 1_754_000_000)

private func entitlement(
    plan: Plan,
    status: PlanStatus,
    expiresAt: Date? = nil
) -> Entitlement {
    Entitlement(plan: plan, status: status, expiresAt: expiresAt, lastVerifiedAt: referenceNow, isSandbox: false)
}

private func loadedState(plan: Plan, status: PlanStatus, expiresAt: Date? = nil) -> SubscriptionCacheState {
    let value = entitlement(plan: plan, status: status, expiresAt: expiresAt)
    return .loaded(SubscriptionState(entitlement: value, willRenew: false, fetchedAt: referenceNow))
}

private func freeEquivalent(enabledStampPacks: Set<String> = []) -> ResolvedCapabilities {
    ResolvedCapabilities(
        singleExportAccess: .metered,
        canUsePremiumStamps: false,
        canUseCustomStamps: false,
        enabledStampPacks: enabledStampPacks,
        canUseProBatch: false,
        canUseBatchTrial: true,
        shouldShowAds: true
    )
}

private func standardCapabilities(enabledStampPacks: Set<String> = []) -> ResolvedCapabilities {
    ResolvedCapabilities(
        singleExportAccess: .unlimited,
        canUsePremiumStamps: true,
        canUseCustomStamps: true,
        enabledStampPacks: enabledStampPacks,
        canUseProBatch: false,
        canUseBatchTrial: true,
        shouldShowAds: false
    )
}

private func proCapabilities(enabledStampPacks: Set<String> = []) -> ResolvedCapabilities {
    ResolvedCapabilities(
        singleExportAccess: .unlimited,
        canUsePremiumStamps: true,
        canUseCustomStamps: true,
        enabledStampPacks: enabledStampPacks,
        canUseProBatch: true,
        canUseBatchTrial: false,
        shouldShowAds: false
    )
}

// MARK: - SubscriptionCacheState のルーティング

@Test(".missingはverificationRequiredになる")
func resolveCapabilitiesMissingRequiresVerification() {
    let resolution = resolveCapabilities(.missing, usageNow: referenceNow, enabledStampPacks: [])
    #expect(resolution == .verificationRequired)
}

@Test("temporarilyUnavailable(verified: nil)はコールドスタートとしてverificationRequiredになる")
func resolveCapabilitiesColdStartRequiresVerification() {
    let state = SubscriptionCacheState.temporarilyUnavailable(verified: nil)
    let resolution = resolveCapabilities(state, usageNow: referenceNow, enabledStampPacks: [])
    #expect(resolution == .verificationRequired)
}

@Test("temporarilyUnavailable(verified: 値)はメモリ上の検証済みEntitlementを使ってresolvedになる")
func resolveCapabilitiesTemporarilyUnavailableUsesVerifiedEntitlement() {
    let verified = entitlement(plan: .pro, status: .active)
    let state = SubscriptionCacheState.temporarilyUnavailable(verified: verified)

    let resolution = resolveCapabilities(state, usageNow: referenceNow, enabledStampPacks: ["seasonal"])

    #expect(resolution == .resolved(proCapabilities(enabledStampPacks: ["seasonal"])))
}

// MARK: - plan × status=.active/.grace の組み合わせ（6.2 の表）

@Test(
    "planとstatus=.active/.graceの組み合わせで6.2の表どおりの能力になる",
    arguments: [
        (Plan.free, PlanStatus.active, freeEquivalent()),
        (Plan.free, PlanStatus.grace, freeEquivalent()),
        (Plan.standard, PlanStatus.active, standardCapabilities()),
        (Plan.standard, PlanStatus.grace, standardCapabilities()),
        (Plan.pro, PlanStatus.active, proCapabilities()),
        (Plan.pro, PlanStatus.grace, proCapabilities())
    ]
)
func resolveCapabilitiesMatchesTableForActiveAndGrace(plan: Plan, status: PlanStatus, expected: ResolvedCapabilities) {
    let state = loadedState(plan: plan, status: status)

    let resolution = resolveCapabilities(state, usageNow: referenceNow, enabledStampPacks: [])

    #expect(resolution == .resolved(expected))
}

// MARK: - pending / expired / revoked

@Test("plan=.proでもstatus=.pendingなら通常一括(canUseProBatch)を含む有料機能を付与しない")
func resolveCapabilitiesPendingProDoesNotGrantProBatch() {
    let state = loadedState(plan: .pro, status: .pending)

    let resolution = resolveCapabilities(state, usageNow: referenceNow, enabledStampPacks: [])

    #expect(resolution == .resolved(freeEquivalent()))
}

@Test("plan=.standardでもstatus=.pendingならsingleExportAccessがmeteredになる")
func resolveCapabilitiesPendingStandardIsMetered() {
    let state = loadedState(plan: .standard, status: .pending)

    let resolution = resolveCapabilities(state, usageNow: referenceNow, enabledStampPacks: [])

    guard case .resolved(let capabilities) = resolution else {
        Issue.record("resolved を期待したが verificationRequired だった")
        return
    }
    #expect(capabilities.singleExportAccess == .metered)
}

@Test(
    "status=.expired/.revokedはplanに関わらずFree相当になる",
    arguments: [
        (Plan.standard, PlanStatus.expired),
        (Plan.pro, PlanStatus.expired),
        (Plan.standard, PlanStatus.revoked),
        (Plan.pro, PlanStatus.revoked)
    ]
)
func resolveCapabilitiesExpiredOrRevokedIsFreeEquivalent(plan: Plan, status: PlanStatus) {
    let state = loadedState(plan: plan, status: status)

    let resolution = resolveCapabilities(state, usageNow: referenceNow, enabledStampPacks: [])

    #expect(resolution == .resolved(freeEquivalent()))
}

// MARK: - 失効判定（expiresAt）

@Test("expiresAtがusageNowより過去ならstatus=.activeでもFree相当になる（失効判定優先）")
func resolveCapabilitiesExpiredTimestampOverridesActiveStatus() {
    let past = referenceNow.addingTimeInterval(-60)
    let state = loadedState(plan: .pro, status: .active, expiresAt: past)

    let resolution = resolveCapabilities(state, usageNow: referenceNow, enabledStampPacks: [])

    #expect(resolution == .resolved(freeEquivalent()))
}

@Test("expiresAtがusageNowと等しい瞬間は失効として扱う（>=判定）")
func resolveCapabilitiesExpiresAtEqualToUsageNowIsExpired() {
    let state = loadedState(plan: .pro, status: .active, expiresAt: referenceNow)

    let resolution = resolveCapabilities(state, usageNow: referenceNow, enabledStampPacks: [])

    #expect(resolution == .resolved(freeEquivalent()))
}

@Test(
    "expiresAtがusageNowより未来またはnilなら失効とみなさない",
    arguments: [nil, referenceNow.addingTimeInterval(60)] as [Date?]
)
func resolveCapabilitiesFutureOrNilExpiresAtIsNotExpired(expiresAt: Date?) {
    let state = loadedState(plan: .pro, status: .active, expiresAt: expiresAt)

    let resolution = resolveCapabilities(state, usageNow: referenceNow, enabledStampPacks: [])

    #expect(resolution == .resolved(proCapabilities()))
}

// MARK: - enabledStampPacks の受け渡し

@Test(
    "enabledStampPacksはplanやstatusに関わらずそのままResolvedCapabilitiesへ反映される",
    arguments: [Plan.free, Plan.standard, Plan.pro]
)
func resolveCapabilitiesPassesThroughEnabledStampPacksRegardlessOfPlan(plan: Plan) {
    let packs: Set<String> = ["seasonal", "holiday"]
    let state = loadedState(plan: plan, status: .active)

    let resolution = resolveCapabilities(state, usageNow: referenceNow, enabledStampPacks: packs)

    guard case .resolved(let capabilities) = resolution else {
        Issue.record("resolved を期待したが verificationRequired だった")
        return
    }
    #expect(capabilities.enabledStampPacks == packs)
}
