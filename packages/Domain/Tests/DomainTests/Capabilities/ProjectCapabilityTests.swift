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

// MARK: - canEdit と authorizeRenderSpec の判定材料共有（architecture.md 6.2）
//
// 同じ ProjectCapabilityRequirement を共有し UI（canEdit）と認可（authorizeRenderSpec）で
// 判定材料を一致させる意図（正本コミット 0c38430）を、片側だけの変更で壊れたら落ちる
// 形で固定する。StampRequirement 4ケース × capabilities 4通り = 16通りを検証する。

// (stampRequirement, canUsePremiumStamps, canUseCustomStamps) の16通り。
// テスト引数の網羅表であり要素の意味はコメントで固定している。
// swiftlint:disable:next large_tuple
private let stampRequirementCapabilityMatrix: [(StampRequirement, Bool, Bool)] = [
    (.free, true, true),
    (.free, true, false),
    (.free, false, true),
    (.free, false, false),
    (.premium(packID: "seasonal"), true, true),
    (.premium(packID: "seasonal"), true, false),
    (.premium(packID: "seasonal"), false, true),
    (.premium(packID: "seasonal"), false, false),
    (.custom, true, true),
    (.custom, true, false),
    (.custom, false, true),
    (.custom, false, false),
    (.unknownBuiltIn, true, true),
    (.unknownBuiltIn, true, false),
    (.unknownBuiltIn, false, true),
    (.unknownBuiltIn, false, false)
]

private func makeSharedNormalizedRect() throws -> NormalizedRect {
    try NormalizedRect(left: 0.1, top: 0.1, rightExclusive: 0.9, bottomExclusive: 0.9)
}

private func makeSharedRegion(renderOp: RenderOpSpec) throws -> RenderRegionSpec {
    RenderRegionSpec(
        bounds: try makeSharedNormalizedRect(),
        rotationDegrees: try RotationDegrees(0),
        shape: .ellipse,
        featherRatio: try FeatherRatio(0.05),
        origin: .auto,
        op: renderOp
    )
}

private func makeSharedSpec(renderOp: RenderOpSpec) throws -> RenderSpec {
    RenderSpec(
        sourceCrop: try makeSharedNormalizedRect(),
        scaleMode: .fit,
        background: .none,
        regions: [try makeSharedRegion(renderOp: renderOp)]
    )
}

/// テストのみで完結する固定カタログ実装（production コードには含まれない）。
private struct FixedStampCatalog: StampCatalog {
    let requirements: [String: StampRequirement]

    func requirement(forBuiltIn code: String) -> StampRequirement? {
        requirements[code]
    }
}

// stampRequirement を表す ProjectCapabilityRequirement と、同じスタンプ要求を含む
// RenderSpec + StampCatalog を組み立てる。custom は StampCatalog を経由しないため
// カタログは空のまま渡す（authorizeRenderSpec 側が参照しない経路）。
// テストフィクスチャ3点を一括で返す（呼び出し側で分解する）。
// swiftlint:disable large_tuple
private func makeSharedStampCase(
    _ stampRequirement: StampRequirement
) throws -> (subject: ProjectCapabilityRequirement, spec: RenderSpec, catalog: FixedStampCatalog) {
    // swiftlint:enable large_tuple
    let subject = requirement([stampRequirement])
    switch stampRequirement {
    case .custom:
        let assetHash = try StampAssetHash(bytes: Data(repeating: 0x44, count: 32))
        let renderOp = RenderOpSpec.stamp(source: .custom(assetHash: assetHash), opacity: try EffectOpacity(1.0))
        return (subject, try makeSharedSpec(renderOp: renderOp), FixedStampCatalog(requirements: [:]))
    case .free, .premium, .unknownBuiltIn:
        let code = "shared-stamp-code"
        let renderOp = RenderOpSpec.stamp(source: .builtIn(code: code), opacity: try EffectOpacity(1.0))
        let catalog = FixedStampCatalog(requirements: [code: stampRequirement])
        return (subject, try makeSharedSpec(renderOp: renderOp), catalog)
    }
}

@Test(
    "同じスタンプ要求はcanEditとauthorizeRenderSpecで一致する結果を返す（UIと認可の判定材料共有）",
    arguments: stampRequirementCapabilityMatrix
)
func canEditAndAuthorizeRenderSpecAgreeOnSameStampRequirement(
    stampRequirement: StampRequirement,
    canUsePremiumStamps: Bool,
    canUseCustomStamps: Bool
) throws {
    let sharedCase = try makeSharedStampCase(stampRequirement)
    let subjectCapabilities = capabilities(
        canUsePremiumStamps: canUsePremiumStamps,
        canUseCustomStamps: canUseCustomStamps
    )

    let editAllowed = canEdit(sharedCase.subject, capabilities: subjectCapabilities)
    let authorization = authorizeRenderSpec(
        sharedCase.spec,
        stampCatalog: sharedCase.catalog,
        capabilities: subjectCapabilities
    )

    #expect(editAllowed == (authorization == .authorized))
}
