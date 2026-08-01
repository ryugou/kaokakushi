import Testing
@testable import Domain
import Foundation

// Task 8: RenderSpec が使う能力を抽出し認可する純粋関数（export-saga.md 1.2
// 「設定内容の能力」、test-plan.md 2.4 の該当行）。
//
// 判定表（有料スタンプ/カスタムスタンプ/カタログ未知code/no-opエフェクト）どおりに
// 分岐すること、`enabledStampPacks` を一切見ないこと、複数regionの先頭一致を優先すること
// を検証する。

private func makeNormalizedRect() throws -> NormalizedRect {
    try NormalizedRect(left: 0.1, top: 0.1, rightExclusive: 0.9, bottomExclusive: 0.9)
}

private func makeRegion(renderOp: RenderOpSpec) throws -> RenderRegionSpec {
    RenderRegionSpec(
        bounds: try makeNormalizedRect(),
        rotationDegrees: try RotationDegrees(0),
        shape: .ellipse,
        featherRatio: try FeatherRatio(0.05),
        origin: .auto,
        op: renderOp
    )
}

private func makeSpec(ops: [RenderOpSpec]) throws -> RenderSpec {
    RenderSpec(
        sourceCrop: try makeNormalizedRect(),
        scaleMode: .fit,
        background: .none,
        regions: try ops.map { try makeRegion(renderOp: $0) }
    )
}

private func makeCapabilities(
    canUsePremiumStamps: Bool = true,
    canUseCustomStamps: Bool = true,
    enabledStampPacks: Set<String> = []
) -> ResolvedCapabilities {
    ResolvedCapabilities(
        singleExportAccess: .metered,
        canUsePremiumStamps: canUsePremiumStamps,
        canUseCustomStamps: canUseCustomStamps,
        enabledStampPacks: enabledStampPacks,
        canUseProBatch: false,
        canUseBatchTrial: true,
        shouldShowAds: true
    )
}

/// テストのみで完結する固定カタログ実装（production コードには含まれない）。
private struct FixedStampCatalog: StampCatalog {
    let requirements: [String: StampRequirement]

    func requirement(forBuiltIn code: String) -> StampRequirement? {
        requirements[code]
    }
}

// MARK: - premium builtIn stamp

@Test("有料スタンプはcanUsePremiumStampsがfalseならblocked(.premiumStampNotAvailable)になる")
func premiumBuiltInStampBlockedWhenCapabilityMissing() throws {
    let catalog = FixedStampCatalog(requirements: ["seasonal-cat": .premium(packID: "seasonal")])
    let spec = try makeSpec(ops: [.stamp(source: .builtIn(code: "seasonal-cat"), opacity: try EffectOpacity(1.0))])
    let capabilities = makeCapabilities(canUsePremiumStamps: false)

    let subject = authorizeRenderSpec(spec, stampCatalog: catalog, capabilities: capabilities)
    #expect(subject == .blocked(.premiumStampNotAvailable))
}

@Test("有料スタンプはcanUsePremiumStampsがtrueならauthorizedになる")
func premiumBuiltInStampAuthorizedWhenCapabilityPresent() throws {
    let catalog = FixedStampCatalog(requirements: ["seasonal-cat": .premium(packID: "seasonal")])
    let spec = try makeSpec(ops: [.stamp(source: .builtIn(code: "seasonal-cat"), opacity: try EffectOpacity(1.0))])
    let capabilities = makeCapabilities(canUsePremiumStamps: true)

    let subject = authorizeRenderSpec(spec, stampCatalog: catalog, capabilities: capabilities)
    #expect(subject == .authorized)
}

@Test("enabledStampPacksに該当packを含めてもcanUsePremiumStampsがfalseならblockedになる（enabledStampPacksを見ない証明）")
func premiumBuiltInStampIgnoresEnabledStampPacks() throws {
    let catalog = FixedStampCatalog(requirements: ["seasonal-cat": .premium(packID: "seasonal")])
    let spec = try makeSpec(ops: [.stamp(source: .builtIn(code: "seasonal-cat"), opacity: try EffectOpacity(1.0))])
    let capabilities = makeCapabilities(canUsePremiumStamps: false, enabledStampPacks: ["seasonal"])

    let subject = authorizeRenderSpec(spec, stampCatalog: catalog, capabilities: capabilities)
    #expect(subject == .blocked(.premiumStampNotAvailable))
}

// MARK: - custom stamp

@Test("カスタムスタンプはcanUseCustomStampsがfalseならblocked(.customStampNotAvailable)になる")
func customStampBlockedWhenCapabilityMissing() throws {
    let assetHash = try StampAssetHash(bytes: Data(repeating: 0x22, count: 32))
    let spec = try makeSpec(ops: [.stamp(source: .custom(assetHash: assetHash), opacity: try EffectOpacity(1.0))])
    let capabilities = makeCapabilities(canUseCustomStamps: false)
    let catalog = FixedStampCatalog(requirements: [:])

    let subject = authorizeRenderSpec(spec, stampCatalog: catalog, capabilities: capabilities)
    #expect(subject == .blocked(.customStampNotAvailable))
}

@Test("カスタムスタンプはcanUseCustomStampsがtrueならauthorizedになる")
func customStampAuthorizedWhenCapabilityPresent() throws {
    let assetHash = try StampAssetHash(bytes: Data(repeating: 0x22, count: 32))
    let spec = try makeSpec(ops: [.stamp(source: .custom(assetHash: assetHash), opacity: try EffectOpacity(1.0))])
    let capabilities = makeCapabilities(canUseCustomStamps: true)
    let catalog = FixedStampCatalog(requirements: [:])

    let subject = authorizeRenderSpec(spec, stampCatalog: catalog, capabilities: capabilities)
    #expect(subject == .authorized)
}

// MARK: - カタログに無いcode / requirementの取り違え

@Test("StampCatalogに無いcodeはcanUsePremiumStamps/canUseCustomStampsの値に関わらずblocked(.unknownBuiltInStampCode)になる")
func unknownBuiltInCodeAlwaysBlocked() throws {
    let spec = try makeSpec(ops: [.stamp(source: .builtIn(code: "not-in-catalog"), opacity: try EffectOpacity(1.0))])
    let catalog = FixedStampCatalog(requirements: [:])

    let grantedCapabilities = makeCapabilities(canUsePremiumStamps: true, canUseCustomStamps: true)
    let deniedCapabilities = makeCapabilities(canUsePremiumStamps: false, canUseCustomStamps: false)

    #expect(authorizeRenderSpec(spec, stampCatalog: catalog, capabilities: grantedCapabilities)
        == .blocked(.unknownBuiltInStampCode))
    #expect(authorizeRenderSpec(spec, stampCatalog: catalog, capabilities: deniedCapabilities)
        == .blocked(.unknownBuiltInStampCode))
}

@Test("カタログがbuiltIn経路にcustom/unknownBuiltInを返す取り違えは安全側に倒しunknownBuiltInStampCodeになる")
func misclassifiedRequirementFallsBackToUnknownBuiltInStampCode() throws {
    let spec = try makeSpec(ops: [.stamp(source: .builtIn(code: "misfiled"), opacity: try EffectOpacity(1.0))])
    let capabilities = makeCapabilities(canUsePremiumStamps: true, canUseCustomStamps: true)

    let customMisfiled = FixedStampCatalog(requirements: ["misfiled": .custom])
    let unknownMisfiled = FixedStampCatalog(requirements: ["misfiled": .unknownBuiltIn])

    #expect(authorizeRenderSpec(spec, stampCatalog: customMisfiled, capabilities: capabilities)
        == .blocked(.unknownBuiltInStampCode))
    #expect(authorizeRenderSpec(spec, stampCatalog: unknownMisfiled, capabilities: capabilities)
        == .blocked(.unknownBuiltInStampCode))
}

// MARK: - 能力を必要としない操作

@Test("requirementがfreeのbuiltInスタンプはどの能力も無くてもauthorizedになる")
func freeBuiltInStampAuthorizedWithoutAnyCapability() throws {
    let catalog = FixedStampCatalog(requirements: ["stamp-free": .free])
    let spec = try makeSpec(ops: [.stamp(source: .builtIn(code: "stamp-free"), opacity: try EffectOpacity(1.0))])
    let capabilities = makeCapabilities(canUsePremiumStamps: false, canUseCustomStamps: false)

    let subject = authorizeRenderSpec(spec, stampCatalog: catalog, capabilities: capabilities)
    #expect(subject == .authorized)
}

@Test("mosaic/blur/solidのみのRenderSpecは能力に関わらずauthorizedになる")
func mosaicBlurSolidAuthorizedWithoutAnyCapability() throws {
    let ops: [RenderOpSpec] = [
        .mosaic(cellRatio: try MosaicRatio(0.2)),
        .blur(sigmaRatio: try BlurRatio(0.2)),
        .solid(color: try VisibleColor(0xFFAABBCC), opacity: try EffectOpacity(0.5))
    ]
    let spec = try makeSpec(ops: ops)
    let capabilities = makeCapabilities(canUsePremiumStamps: false, canUseCustomStamps: false)
    let catalog = FixedStampCatalog(requirements: [:])

    let subject = authorizeRenderSpec(spec, stampCatalog: catalog, capabilities: capabilities)
    #expect(subject == .authorized)
}

// MARK: - 複数regionの優先順位

@Test("複数regionのうち先頭で見つかったblock理由が返る（regions配列順を採用）")
func firstBlockedRegionReasonWins() throws {
    let assetHash = try StampAssetHash(bytes: Data(repeating: 0x33, count: 32))
    let ops: [RenderOpSpec] = [
        .stamp(source: .custom(assetHash: assetHash), opacity: try EffectOpacity(1.0)),
        .stamp(source: .builtIn(code: "seasonal-cat"), opacity: try EffectOpacity(1.0))
    ]
    let spec = try makeSpec(ops: ops)
    let catalog = FixedStampCatalog(requirements: ["seasonal-cat": .premium(packID: "seasonal")])
    let capabilities = makeCapabilities(canUsePremiumStamps: false, canUseCustomStamps: false)

    let subject = authorizeRenderSpec(spec, stampCatalog: catalog, capabilities: capabilities)
    #expect(subject == .blocked(.customStampNotAvailable))
}

// MARK: - 型そのものの検証

@Test("RenderSpecBlockReasonは3ケースを持ちEquatableである")
func renderSpecBlockReasonHasThreeCases() {
    let allCases: [RenderSpecBlockReason] = [
        .premiumStampNotAvailable,
        .customStampNotAvailable,
        .unknownBuiltInStampCode
    ]
    #expect(allCases.count == 3)
    #expect(Set(allCases.map { String(describing: $0) }).count == 3)
}
