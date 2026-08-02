import Testing
@testable import Domain
import Foundation

// Task 1: CustomerInfoSnapshot → Entitlement の導出（architecture.md 6.2 のシグネチャと
// 「`resolve` の導出規則」節、コミット dddc18d で正本化）。
//
// plan 優先順位（pro > standard > free）、status（free は常に active、有料は
// isInBillingRetry で pending/active）、expiresAt の該当 ID 引き当て、lastVerifiedAt /
// isSandbox の転写、そして grace/expired/revoked を一切生成しないことを検証する。

private let referenceNow = Date(timeIntervalSince1970: 1_754_000_000)
private let standardID = "standard_entitlement"
private let proID = "pro_entitlement"

private func snapshot(
    activeEntitlementIDs: Set<String>,
    expirationDates: [String: Date] = [:],
    isInBillingRetry: Bool = false,
    isSandbox: Bool = false
) -> CustomerInfoSnapshot {
    CustomerInfoSnapshot(
        activeEntitlementIDs: activeEntitlementIDs,
        expirationDates: expirationDates,
        willRenew: false,
        isInBillingRetry: isInBillingRetry,
        isSandbox: isSandbox
    )
}

// MARK: - 導出規則1: plan の優先順位（pro > standard > free）

@Test(
    "activeEntitlementIDsの組み合わせでplanがpro優先で決まる",
    arguments: [
        (Set([proID]), Plan.pro),
        (Set([proID, standardID]), Plan.pro),
        (Set([standardID]), Plan.standard),
        (Set<String>(), Plan.free),
        (Set(["unrelated"]), Plan.free)
    ]
)
func resolvePlanFollowsProStandardFreePriority(activeIDs: Set<String>, expectedPlan: Plan) {
    let subject = snapshot(activeEntitlementIDs: activeIDs)

    let entitlement = resolve(
        snapshot: subject,
        usageNow: referenceNow,
        standardEntitlementID: standardID,
        proEntitlementID: proID
    )

    #expect(entitlement.plan == expectedPlan)
}

// MARK: - 導出規則2: status（free は常にactive、有料はisInBillingRetryで分岐）

@Test(
    "freeはisInBillingRetryの値に関わらず常にactiveでexpiresAtがnil",
    arguments: [true, false]
)
func resolveFreeIsAlwaysActiveWithNilExpiresAt(isInBillingRetry: Bool) {
    let subject = snapshot(
        activeEntitlementIDs: [],
        expirationDates: [standardID: referenceNow, proID: referenceNow],
        isInBillingRetry: isInBillingRetry
    )

    let entitlement = resolve(
        snapshot: subject,
        usageNow: referenceNow,
        standardEntitlementID: standardID,
        proEntitlementID: proID
    )

    #expect(entitlement.plan == .free)
    #expect(entitlement.status == .active)
    #expect(entitlement.expiresAt == nil)
}

@Test(
    "有料プランはisInBillingRetryがtrueならpending falseならactiveになる",
    arguments: [
        (Set([standardID]), true, PlanStatus.pending),
        (Set([standardID]), false, PlanStatus.active),
        (Set([proID]), true, PlanStatus.pending),
        (Set([proID]), false, PlanStatus.active)
    ]
)
func resolvePaidPlanStatusFollowsBillingRetry(
    activeIDs: Set<String>,
    isInBillingRetry: Bool,
    expectedStatus: PlanStatus
) {
    let subject = snapshot(activeEntitlementIDs: activeIDs, isInBillingRetry: isInBillingRetry)

    let entitlement = resolve(
        snapshot: subject,
        usageNow: referenceNow,
        standardEntitlementID: standardID,
        proEntitlementID: proID
    )

    #expect(entitlement.status == expectedStatus)
}

// MARK: - 導出規則3: expiresAt が該当entitlement IDのexpirationDatesの値になる

@Test("standardのexpiresAtがexpirationDatesのstandard IDの値になる")
func resolveStandardExpiresAtUsesStandardEntitlementDate() {
    let expiration = referenceNow.addingTimeInterval(3600)
    let subject = snapshot(
        activeEntitlementIDs: [standardID],
        expirationDates: [standardID: expiration, proID: referenceNow.addingTimeInterval(7200)]
    )

    let entitlement = resolve(
        snapshot: subject,
        usageNow: referenceNow,
        standardEntitlementID: standardID,
        proEntitlementID: proID
    )

    #expect(entitlement.expiresAt == expiration)
}

@Test("proのexpiresAtがexpirationDatesのpro IDの値になる")
func resolveProExpiresAtUsesProEntitlementDate() {
    let expiration = referenceNow.addingTimeInterval(7200)
    let subject = snapshot(
        activeEntitlementIDs: [proID],
        expirationDates: [standardID: referenceNow.addingTimeInterval(3600), proID: expiration]
    )

    let entitlement = resolve(
        snapshot: subject,
        usageNow: referenceNow,
        standardEntitlementID: standardID,
        proEntitlementID: proID
    )

    #expect(entitlement.expiresAt == expiration)
}

@Test(
    "該当entitlement IDのキーがexpirationDatesに無ければexpiresAtはnilになる",
    arguments: [Set([standardID]), Set([proID])]
)
func resolveExpiresAtIsNilWhenKeyMissing(activeIDs: Set<String>) {
    let subject = snapshot(activeEntitlementIDs: activeIDs, expirationDates: [:])

    let entitlement = resolve(
        snapshot: subject,
        usageNow: referenceNow,
        standardEntitlementID: standardID,
        proEntitlementID: proID
    )

    #expect(entitlement.expiresAt == nil)
}

// MARK: - 導出規則4: lastVerifiedAt / isSandbox の転写

@Test(
    "lastVerifiedAtはfree/standard/proいずれのplanでもusageNowになる",
    arguments: [Set<String>(), Set([standardID]), Set([proID])]
)
func resolveLastVerifiedAtEqualsUsageNow(activeIDs: Set<String>) {
    let subject = snapshot(activeEntitlementIDs: activeIDs)
    let usageNow = referenceNow.addingTimeInterval(42)

    let entitlement = resolve(
        snapshot: subject,
        usageNow: usageNow,
        standardEntitlementID: standardID,
        proEntitlementID: proID
    )

    #expect(entitlement.lastVerifiedAt == usageNow)
}

@Test(
    "isSandboxはfree/standard/proいずれのplanでもsnapshotの値のまま写る",
    arguments: [
        (Set<String>(), true),
        (Set<String>(), false),
        (Set([standardID]), true),
        (Set([standardID]), false),
        (Set([proID]), true),
        (Set([proID]), false)
    ]
)
func resolveIsSandboxIsCopiedFromSnapshot(activeIDs: Set<String>, isSandbox: Bool) {
    let subject = snapshot(activeEntitlementIDs: activeIDs, isSandbox: isSandbox)

    let entitlement = resolve(
        snapshot: subject,
        usageNow: referenceNow,
        standardEntitlementID: standardID,
        proEntitlementID: proID
    )

    #expect(entitlement.isSandbox == isSandbox)
}

// MARK: - grace / expired / revoked を一切生成しない（網羅的switchで固定）

@Test(
    "resolveが生成するstatusはactiveかpendingのみでgrace/expired/revokedは生成しない",
    arguments: [
        (Set<String>(), false),
        (Set<String>(), true),
        (Set([standardID]), false),
        (Set([standardID]), true),
        (Set([proID]), false),
        (Set([proID]), true)
    ]
)
func resolveNeverProducesGraceExpiredOrRevoked(activeIDs: Set<String>, isInBillingRetry: Bool) {
    let subject = snapshot(activeEntitlementIDs: activeIDs, isInBillingRetry: isInBillingRetry)

    let entitlement = resolve(
        snapshot: subject,
        usageNow: referenceNow,
        standardEntitlementID: standardID,
        proEntitlementID: proID
    )

    // この網羅的 switch は2つの検出経路を持つ。
    // 1. PlanStatus に新しい case が追加された場合: 網羅性チェックによりコンパイルエラーで気づける。
    // 2. resolve が既存の禁止 case（.grace / .expired / .revoked）を返すよう変更された場合:
    //    該当 case の Issue.record が実行され、実行時失敗で検出する。
    switch entitlement.status {
    case .active, .pending:
        break
    case .grace:
        Issue.record("resolveはgraceを生成しない契約のはずが生成された")
    case .expired:
        Issue.record("resolveはexpiredを生成しない契約のはずが生成された")
    case .revoked:
        Issue.record("resolveはrevokedを生成しない契約のはずが生成された")
    }
}
