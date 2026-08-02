import Foundation

// CustomerInfoSnapshot → Entitlement の導出（architecture.md 6.2 のシグネチャコードブロックと
// 「`resolve` の導出規則」節、コミット dddc18d で正本化）。
//
// `standardEntitlementID` / `proEntitlementID` は設定定数（architecture.md 10 章）を引数で
// 注入する（Domain は設定定数の型を参照しないため）。
//
// この関数が生成しうる status は `.active` / `.pending` の2値のみ（正本の導出規則2に明記）。
// Entitlement を生成するのはこの関数だけであり、`.grace` / `.expired` / `.revoked` は
// 現状どこからも生成されない（PlanStatus の扱いは Issue #22 で確定する）。

public func resolve(
    snapshot: CustomerInfoSnapshot,
    usageNow: Date,
    standardEntitlementID: String,
    proEntitlementID: String
) -> Entitlement {
    let plan = resolvePlan(
        snapshot: snapshot,
        standardEntitlementID: standardEntitlementID,
        proEntitlementID: proEntitlementID
    )
    let resolvedEntitlementID = entitlementID(
        forPlan: plan,
        standardEntitlementID: standardEntitlementID,
        proEntitlementID: proEntitlementID
    )

    return Entitlement(
        plan: plan,
        status: resolveStatus(plan: plan, snapshot: snapshot),
        expiresAt: resolvedEntitlementID.flatMap { snapshot.expirationDates[$0] },
        lastVerifiedAt: usageNow,
        isSandbox: snapshot.isSandbox
    )
}

// 導出規則1: pro ID があれば .pro、なければ standard ID があれば .standard、
// どちらも無ければ .free
private func resolvePlan(
    snapshot: CustomerInfoSnapshot,
    standardEntitlementID: String,
    proEntitlementID: String
) -> Plan {
    if snapshot.activeEntitlementIDs.contains(proEntitlementID) {
        return .pro
    }
    if snapshot.activeEntitlementIDs.contains(standardEntitlementID) {
        return .standard
    }
    return .free
}

// 導出規則2: free は常に active。有料プランは isInBillingRetry なら pending（仕様5.4）、
// それ以外は active。
private func resolveStatus(plan: Plan, snapshot: CustomerInfoSnapshot) -> PlanStatus {
    switch plan {
    case .free:
        return .active
    case .standard, .pro:
        return snapshot.isInBillingRetry ? .pending : .active
    }
}

// 導出規則3で expirationDates を引き当てるための entitlement ID。free には対応する ID が無い。
private func entitlementID(forPlan plan: Plan, standardEntitlementID: String, proEntitlementID: String) -> String? {
    switch plan {
    case .free:
        return nil
    case .standard:
        return standardEntitlementID
    case .pro:
        return proEntitlementID
    }
}
