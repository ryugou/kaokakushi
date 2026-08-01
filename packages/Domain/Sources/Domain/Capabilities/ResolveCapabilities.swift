import Foundation

// 能力解決の純粋関数（architecture.md 6.2「能力と課金状態」の「能力の解決」節、
// 「purchase 状態キャッシュの読み込み失敗」節、product-decisions.md 3.1「課金訴求分類表」
// 〈91-97行〉から確定した Entitlement → ResolvedCapabilities の導出規則）。
//
// `enabledStampPacks` は設定定数（architecture.md 10 章）を引数で注入する
// （Domain は設定定数の型を参照しないため。シグネチャは architecture.md 6.2 が正本）。

public func resolveCapabilities(
    _ state: SubscriptionCacheState,
    usageNow: Date,
    enabledStampPacks: Set<String>
) -> CapabilityResolution {
    switch state {
    case .missing:
        // このシグネチャに来る時点でオフライン/未解決を意味する（architecture.md 6.2）。
        // オンライン問い合わせに成功した場合は、呼び出し側が結果を .loaded へ変換してから渡す。
        return .verificationRequired
    case .temporarilyUnavailable(verified: nil):
        // コールドスタート。メモリ上に維持すべき検証済み値が存在しない。
        return .verificationRequired
    case .temporarilyUnavailable(verified: let verifiedEntitlement?):
        // セッション中の一時障害。メモリ上に検証済みの Entitlement があるため維持する。
        return .resolved(
            resolveEntitlement(verifiedEntitlement, usageNow: usageNow, enabledStampPacks: enabledStampPacks)
        )
    case .loaded(let subscriptionState):
        return .resolved(
            resolveEntitlement(subscriptionState.entitlement, usageNow: usageNow, enabledStampPacks: enabledStampPacks)
        )
    }
}

// Entitlement → ResolvedCapabilities の導出（architecture.md 6.2 本文 +
// product-decisions.md 3.1 の課金訴求分類表から確定）。
private func resolveEntitlement(
    _ entitlement: Entitlement,
    usageNow: Date,
    enabledStampPacks: Set<String>
) -> ResolvedCapabilities {
    // 失効判定を最初に行う（architecture.md 6.2「Entitlement.expiresAt を過ぎたキャッシュは
    // 失効として扱う以外の鮮度判定は行わない」）。失効していれば status に関わらず権限なし。
    let isExpired = entitlement.expiresAt.map { usageNow >= $0 } ?? false
    if isExpired {
        return freeEquivalentCapabilities(enabledStampPacks: enabledStampPacks)
    }

    switch entitlement.status {
    case .pending, .expired, .revoked:
        // pending では有料機能を付与しない（仕様 5.4）。expired / revoked も同様に権限なし。
        return freeEquivalentCapabilities(enabledStampPacks: enabledStampPacks)
    case .active, .grace:
        return capabilities(forPlan: entitlement.plan, enabledStampPacks: enabledStampPacks)
    }
}

private func freeEquivalentCapabilities(enabledStampPacks: Set<String>) -> ResolvedCapabilities {
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

private func capabilities(forPlan plan: Plan, enabledStampPacks: Set<String>) -> ResolvedCapabilities {
    switch plan {
    case .free:
        return freeEquivalentCapabilities(enabledStampPacks: enabledStampPacks)
    case .standard:
        return ResolvedCapabilities(
            singleExportAccess: .unlimited,
            canUsePremiumStamps: true,
            canUseCustomStamps: true,
            enabledStampPacks: enabledStampPacks,
            canUseProBatch: false,
            canUseBatchTrial: true,
            shouldShowAds: false
        )
    case .pro:
        return ResolvedCapabilities(
            singleExportAccess: .unlimited,
            canUsePremiumStamps: true,
            canUseCustomStamps: true,
            enabledStampPacks: enabledStampPacks,
            canUseProBatch: true,
            canUseBatchTrial: false,
            shouldShowAds: false
        )
    }
}
