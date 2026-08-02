import Testing
@testable import Domain
import Foundation

// Task 2: Project 単位の能力判定・Paywall 文言（architecture.md「解約・降格後の既存データ」
// 節〈655-699行付近〉、Issue #20）。
//
// requiredPlan は表示用の Paywall 文言だけを決め、canEdit は ResolvedCapabilities の
// フラグを直接見て編集可否を決める（プラン名の比較にすり替わっていないことを固定する）。
// unknownBuiltIn を含む場合は他の能力の充足状況に関わらず常に canEdit = false になる。

private func requirement(_ stampRequirements: Set<StampRequirement>) -> ProjectCapabilityRequirement {
    ProjectCapabilityRequirement(stampRequirements: stampRequirements)
}

// capabilities(...) ビルダーは TestSupport.swift の共有ヘルパーを使う。

// MARK: - requiredPlan: premium/custom を含めば standard、それ以外は free

@Test(
    "stampRequirementsの内容でrequiredPlanが決まる",
    arguments: [
        (Set<StampRequirement>(), Plan.free),
        (Set([StampRequirement.premium(packID: "seasonal")]), Plan.standard),
        (Set([StampRequirement.custom]), Plan.standard),
        (Set([StampRequirement.free, StampRequirement.unknownBuiltIn]), Plan.free),
        (Set([StampRequirement.unknownBuiltIn]), Plan.free),
        (Set([StampRequirement.premium(packID: "seasonal"), StampRequirement.custom]), Plan.standard)
    ]
)
func requiredPlanIsStandardOnlyWhenPremiumOrCustomIsPresent(
    stampRequirements: Set<StampRequirement>,
    expectedPlan: Plan
) {
    #expect(requiredPlan(requirement(stampRequirements)) == expectedPlan)
}

// MARK: - canEdit: premium/custom はそれぞれ対応する能力フラグで判定する

@Test("premiumを要求しcanUsePremiumStampsがfalseなら編集不可")
func canEditDeniesWhenPremiumRequiredButCapabilityMissing() {
    let subject = requirement([.premium(packID: "seasonal")])

    #expect(canEdit(subject, capabilities: capabilities(canUsePremiumStamps: false)) == false)
}

@Test("premiumを要求しcanUsePremiumStampsがtrueなら編集可")
func canEditAllowsWhenPremiumRequiredAndCapabilityGranted() {
    let subject = requirement([.premium(packID: "seasonal")])

    #expect(canEdit(subject, capabilities: capabilities(canUsePremiumStamps: true)) == true)
}

@Test("customを要求しcanUseCustomStampsがtrueなら編集可")
func canEditAllowsWhenCustomRequiredAndCapabilityGranted() {
    let subject = requirement([.custom])

    #expect(canEdit(subject, capabilities: capabilities(canUseCustomStamps: true)) == true)
}

@Test("customを要求しcanUseCustomStampsがfalseなら編集不可")
func canEditDeniesWhenCustomRequiredButCapabilityMissing() {
    let subject = requirement([.custom])

    #expect(canEdit(subject, capabilities: capabilities(canUseCustomStamps: false)) == false)
}

@Test("premiumとcustomの両方を要求しpremiumのみ満たす場合は編集不可")
func canEditDeniesWhenBothRequiredButOnlyPremiumGranted() {
    let subject = requirement([.premium(packID: "seasonal"), .custom])
    let subjectCapabilities = capabilities(canUsePremiumStamps: true, canUseCustomStamps: false)

    #expect(canEdit(subject, capabilities: subjectCapabilities) == false)
}

@Test("premiumとcustomの両方を要求しcustomのみ満たす場合は編集不可")
func canEditDeniesWhenBothRequiredButOnlyCustomGranted() {
    let subject = requirement([.premium(packID: "seasonal"), .custom])
    let subjectCapabilities = capabilities(canUsePremiumStamps: false, canUseCustomStamps: true)

    #expect(canEdit(subject, capabilities: subjectCapabilities) == false)
}

// MARK: - canEdit: stampRequirementsが空なら常に編集可

@Test(
    "stampRequirementsが空ならcapabilitiesの値に関わらず常に編集可",
    arguments: [
        capabilities(),
        capabilities(canUsePremiumStamps: true, canUseCustomStamps: true, canUseProBatch: true)
    ]
)
func canEditAlwaysAllowsWhenNoStampRequirementsExist(subjectCapabilities: ResolvedCapabilities) {
    #expect(canEdit(requirement([]), capabilities: subjectCapabilities) == true)
}

@Test("freeスタンプのみを要求する場合はcapabilitiesの値に関わらず常に編集可")
func canEditAllowsFreeOnlyRequirementRegardlessOfCapabilities() {
    let subject = requirement([.free])

    #expect(canEdit(subject, capabilities: capabilities()) == true)
}

// MARK: - canEdit: unknownBuiltInを含む場合は常に編集不可（安全側）

@Test("unknownBuiltInのみを要求する場合は常に編集不可")
func canEditDeniesWhenOnlyUnknownBuiltInIsRequired() {
    let subject = requirement([.unknownBuiltIn])

    #expect(canEdit(subject, capabilities: capabilities()) == false)
}

@Test("unknownBuiltInとpremium/customを併せて要求し他の能力が全て満たされていても編集不可")
func canEditDeniesWhenUnknownBuiltInAccompaniesSatisfiedRequirements() {
    let subject = requirement([.unknownBuiltIn, .premium(packID: "seasonal"), .custom])
    let subjectCapabilities = capabilities(canUsePremiumStamps: true, canUseCustomStamps: true)

    #expect(canEdit(subject, capabilities: subjectCapabilities) == false)
}

// MARK: - canEdit: requiredPlanの戻り値比較ではなくcapabilitiesのフラグで判定する

@Test("singleExportAccessやcanUseProBatchがpro相当でもcanUsePremiumStampsがfalseなら編集不可")
func canEditIgnoresUnrelatedProSignalsAndUsesCapabilityFlagDirectly() {
    let subject = requirement([.premium(packID: "seasonal")])
    let subjectCapabilities = capabilities(
        canUsePremiumStamps: false,
        singleExportAccess: .unlimited,
        canUseProBatch: true,
        canUseBatchTrial: false,
        shouldShowAds: false
    )

    #expect(canEdit(subject, capabilities: subjectCapabilities) == false)
}
