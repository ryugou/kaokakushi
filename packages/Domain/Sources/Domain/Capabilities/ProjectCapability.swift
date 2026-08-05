import Foundation

// 能力判定と Paywall 文言のための Project 単位の入力型・純粋関数（architecture.md
// 「解約・降格後の既存データ」節、「canEdit / requiredPlan の判定規則を
// 正本化」コミット 0c38430 で正本化。Task 2, Issue #20）。
//
// StampRequirement は書き出し認可（export-saga.md 1.2）で定義済みの型を再利用する
// （Accounting/ExportAuthorization.swift）。RenderSpec を直接受け取らないのは、判定に
// 必要なのはスタンプの必要能力だけであり座標や強度は無関係なため。書き出し認可の
// authorizeRenderSpec（export-saga.md 1.3、Authorization/AuthorizeRenderSpec.swift）は
// RenderSpec + StampCatalog + ResolvedCapabilities を入力に取り、この
// ProjectCapabilityRequirement 型そのものは受け取らない。共有しているのは型ではなく
// premium→canUsePremiumStamps / custom→canUseCustomStamps / unknownBuiltIn→否という
// 判定規則であり、これを UI の編集可否判定と書き出し認可の間で一致させる。

/// 能力判定と Paywall 文言の入力。Project とその子行から組み立てる
public struct ProjectCapabilityRequirement: Sendable, Equatable {
    /// この Project の RenderSpec が使う全スタンプの必要能力（export-saga.md 1.2）
    public let stampRequirements: Set<StampRequirement>

    public init(stampRequirements: Set<StampRequirement>) {
        self.stampRequirements = stampRequirements
    }
}

/// 表示用。Paywall の文言を組み立てるためだけに使う。
///
/// premium または custom を含めば standard、いずれも無ければ free（スタンプ能力は
/// standard と pro で同一のため pro を要求する組み合わせは存在しない）。unknownBuiltIn は
/// 課金で解消しないため対象外（Paywall を提示しない）。**この戻り値で canEdit の可否を
/// 決めない**（プラン名の比較だと status = pending が素通りする。正本の判定規則節）。
public func requiredPlan(_ requirement: ProjectCapabilityRequirement) -> Plan {
    let needsStandard = requirement.stampRequirements.contains { stampRequirement in
        switch stampRequirement {
        case .premium, .custom:
            return true
        case .free, .unknownBuiltIn:
            return false
        }
    }
    return needsStandard ? .standard : .free
}

/// 実装上の判定。プラン名ではなく能力で決める。
///
/// premium は canUsePremiumStamps、custom は canUseCustomStamps で判定する。
/// unknownBuiltIn を含む場合は常に否（どの能力でも解消しない。認可側の
/// unknownBuiltInStampCode と同じ安全側）。requiredPlan の戻り値とは比較しない
/// （ResolvedCapabilities のフラグを直接見る）。
public func canEdit(_ requirement: ProjectCapabilityRequirement, capabilities: ResolvedCapabilities) -> Bool {
    requirement.stampRequirements.allSatisfy { stampRequirement in
        switch stampRequirement {
        case .free:
            return true
        case .premium:
            return capabilities.canUsePremiumStamps
        case .custom:
            return capabilities.canUseCustomStamps
        case .unknownBuiltIn:
            return false
        }
    }
}
