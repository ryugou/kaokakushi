import Foundation

// 課金・購読状態の型群（architecture.md 6.2「能力と課金状態」）。
//
// RevenueCat の `CustomerInfo` をアプリ全体に流さず、純粋関数で畳み込むための入出力型
// （関数本体 `resolve` / `resolveCapabilities` は Task 6 の担当。ここでは値型・enum のみ
// を転記する）。
//
// `CustomStringConvertible` には適合させない（architecture.md 6.5 の指示を全識別子・
// 値型へ適用する。文字列補間で自動的にログや診断へ流れる経路を作らないため）。

/// Billing が CustomerInfo から抽出する、Domain が扱える値だけの写像
public struct CustomerInfoSnapshot: Sendable, Equatable {
    public let activeEntitlementIDs: Set<String>
    public let expirationDates: [String: Date]
    public let willRenew: Bool
    public let isInBillingRetry: Bool
    public let isSandbox: Bool

    public init(
        activeEntitlementIDs: Set<String>,
        expirationDates: [String: Date],
        willRenew: Bool,
        isInBillingRetry: Bool,
        isSandbox: Bool
    ) {
        self.activeEntitlementIDs = activeEntitlementIDs
        self.expirationDates = expirationDates
        self.willRenew = willRenew
        self.isInBillingRetry = isInBillingRetry
        self.isSandbox = isSandbox
    }
}

/// 契約の等級。DB 列値は architecture.md 6.2 の表が正本
/// （SubscriptionState の DB 列としてスキーマ移行をまたぐため case 宣言順に依存させない）。
public enum Plan: UInt32, Sendable, Hashable, Comparable {
    case free = 1
    case standard = 2
    case pro = 3

    // Swift は enum の Comparable を合成しない（YearMonth と同じ事情。CommonValues.swift）。
    // 宣言順（free < standard < pro）を正とし、料金プランの序列として自然な比較を素直に書く。
    public static func < (lhs: Plan, rhs: Plan) -> Bool {
        switch (lhs, rhs) {
        case (.free, .standard), (.free, .pro), (.standard, .pro):
            return true
        default:
            return false
        }
    }
}

/// 契約の状態。pending は支払い保留（仕様 5.4）。DB 列値は architecture.md 6.2 の表が正本。
public enum PlanStatus: UInt32, Sendable, Hashable {
    case active = 1
    case grace = 2
    case pending = 3
    case expired = 4
    case revoked = 5
}

public struct Entitlement: Sendable, Equatable {
    public let plan: Plan
    public let status: PlanStatus
    public let expiresAt: Date?
    public let lastVerifiedAt: Date
    public let isSandbox: Bool

    public init(plan: Plan, status: PlanStatus, expiresAt: Date?, lastVerifiedAt: Date, isSandbox: Bool) {
        self.plan = plan
        self.status = status
        self.expiresAt = expiresAt
        self.lastVerifiedAt = lastVerifiedAt
        self.isSandbox = isSandbox
    }
}

/// app.db の平文テーブルへ保存する購入状態キャッシュ（ADR 0005）
public struct SubscriptionState: Sendable, Equatable {
    public let entitlement: Entitlement
    public let willRenew: Bool
    public let fetchedAt: Date

    public init(entitlement: Entitlement, willRenew: Bool, fetchedAt: Date) {
        self.entitlement = entitlement
        self.willRenew = willRenew
        self.fetchedAt = fetchedAt
    }
}

public enum SingleExportAccess: Sendable, Equatable {
    case metered
    case unlimited
}

public struct ResolvedCapabilities: Sendable, Equatable {
    public let singleExportAccess: SingleExportAccess
    public let canUsePremiumStamps: Bool
    public let canUseCustomStamps: Bool
    public let enabledStampPacks: Set<String>
    public let canUseProBatch: Bool
    public let canUseBatchTrial: Bool
    public let shouldShowAds: Bool

    public init(
        singleExportAccess: SingleExportAccess,
        canUsePremiumStamps: Bool,
        canUseCustomStamps: Bool,
        enabledStampPacks: Set<String>,
        canUseProBatch: Bool,
        canUseBatchTrial: Bool,
        shouldShowAds: Bool
    ) {
        self.singleExportAccess = singleExportAccess
        self.canUsePremiumStamps = canUsePremiumStamps
        self.canUseCustomStamps = canUseCustomStamps
        self.enabledStampPacks = enabledStampPacks
        self.canUseProBatch = canUseProBatch
        self.canUseBatchTrial = canUseBatchTrial
        self.shouldShowAds = shouldShowAds
    }
}

public enum CapabilityResolution: Sendable, Equatable {
    case resolved(ResolvedCapabilities)
    case verificationRequired
}

/// 能力解決の入力。正本は Sendable のみで Equatable は宣言していない（Entitlement は
/// Equatable だが SubscriptionCacheState 自体を比較する用途が正本コードブロックに無いため
/// 追加しない）。
public enum SubscriptionCacheState: Sendable {
    /// キャッシュがある
    case loaded(SubscriptionState)
    /// キャッシュが存在しない（初回起動・再インストール直後）
    case missing
    /// DB が一時的に読めない
    case temporarilyUnavailable(verified: Entitlement?)
}
