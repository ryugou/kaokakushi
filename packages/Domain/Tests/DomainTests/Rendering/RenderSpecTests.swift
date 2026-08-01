import Testing
@testable import Domain
import Foundation

// Task 2: RenderSpec 系の記述型群（image-pipeline.md 2 章）。
//
// 正規化座標・相対強度のまま保持する型（RenderSpec / RenderRegionSpec / EffectSetting /
// RenderOpSpec / BackgroundSpec / MaskShape / RegionOrigin / StampSource /
// SourceScaleMode）を、各 case が検証済み値型で構築できることを中心に検証する。

private func makeNormalizedRect() throws -> NormalizedRect {
    try NormalizedRect(left: 0.1, top: 0.1, rightExclusive: 0.9, bottomExclusive: 0.9)
}

// MARK: - MaskShape / RegionOrigin / SourceScaleMode（Sendable & Hashable の列挙）

@Test("MaskShapeの各caseはSendable/Hashableで区別される")
func maskShapeCasesAreDistinctAndHashable() throws {
    let cornerRatio = try CornerRatio(0.25)
    let cases: [MaskShape] = [.ellipse, .circle, .rectangle, .rounded(cornerRatio: cornerRatio)]
    for shape in cases {
        _ = assertSendableHashable(shape)
    }
    #expect(Set(cases).count == 4)
}

@Test("RegionOriginはautoとmanualを区別する")
func regionOriginDistinguishesAutoAndManual() {
    let subject = assertSendableHashable(RegionOrigin.auto)
    #expect(subject != .manual)
}

@Test("SourceScaleModeはfitとfillを区別する")
func sourceScaleModeDistinguishesFitAndFill() {
    let subject = assertSendableHashable(SourceScaleMode.fit)
    #expect(subject != .fill)
}

// MARK: - StampSource（組み込みとカスタムを文字列で混ぜない）

@Test("StampSourceはbuiltInとcustomを別の値として区別する")
func stampSourceDistinguishesBuiltInAndCustom() throws {
    let builtIn = assertSendableHashable(StampSource.builtIn(code: "cat"))
    let custom = StampSource.custom(assetHash: try StampAssetHash(bytes: Data(repeating: 0x11, count: 32)))
    #expect(builtIn != custom)
}

// MARK: - RenderOpSpec（各caseを検証済み値型で構築できる）

@Test("RenderOpSpec.mosaicはMosaicRatioで構築できる")
func renderOpSpecMosaicHoldsRatio() throws {
    let ratio = try MosaicRatio(0.2)
    let subject = RenderOpSpec.mosaic(cellRatio: ratio)
    #expect(subject == .mosaic(cellRatio: ratio))
}

@Test("RenderOpSpec.blurはBlurRatioで構築できる")
func renderOpSpecBlurHoldsRatio() throws {
    let ratio = try BlurRatio(0.3)
    let subject = RenderOpSpec.blur(sigmaRatio: ratio)
    #expect(subject == .blur(sigmaRatio: ratio))
}

@Test("RenderOpSpec.solidはVisibleColorとEffectOpacityで構築できる")
func renderOpSpecSolidHoldsColorAndOpacity() throws {
    let color = try VisibleColor(0xFFAABBCC)
    let opacity = try EffectOpacity(0.8)
    let subject = RenderOpSpec.solid(color: color, opacity: opacity)
    #expect(subject == .solid(color: color, opacity: opacity))
}

@Test("RenderOpSpec.stampはStampSourceとEffectOpacityで構築できる")
func renderOpSpecStampHoldsSourceAndOpacity() throws {
    let source = StampSource.builtIn(code: "dog")
    let opacity = try EffectOpacity(1.0)
    let subject = RenderOpSpec.stamp(source: source, opacity: opacity)
    #expect(subject == .stamp(source: source, opacity: opacity))
}

// MARK: - BackgroundSpec（各caseを検証済み値型で構築できる）

@Test("BackgroundSpec.noneはcase一致で判定できる")
func backgroundSpecNoneEquality() {
    #expect(BackgroundSpec.none == BackgroundSpec.none)
}

@Test("BackgroundSpec.blurはBlurRatioで構築できる")
func backgroundSpecBlurHoldsRatio() throws {
    let ratio = try BlurRatio(0.1)
    let subject = BackgroundSpec.blur(sigmaRatio: ratio)
    #expect(subject == .blur(sigmaRatio: ratio))
}

@Test("BackgroundSpec.solidはVisibleColorで構築できる")
func backgroundSpecSolidHoldsColor() throws {
    let color = try VisibleColor(0xFF000000)
    let subject = BackgroundSpec.solid(color: color)
    #expect(subject == .solid(color: color))
}

// MARK: - RenderRegionSpec / RenderSpec / EffectSetting（全フィールドを保持する）

@Test("RenderRegionSpecは全フィールドをそのまま保持する")
func renderRegionSpecHoldsAllFields() throws {
    let bounds = try makeNormalizedRect()
    let rotation = try RotationDegrees(15)
    let feather = try FeatherRatio(0.05)
    let renderOp = RenderOpSpec.mosaic(cellRatio: try MosaicRatio(0.2))

    let subject = RenderRegionSpec(
        bounds: bounds,
        rotationDegrees: rotation,
        shape: .ellipse,
        featherRatio: feather,
        origin: .auto,
        op: renderOp
    )

    #expect(subject.bounds == bounds)
    #expect(subject.rotationDegrees == rotation)
    #expect(subject.shape == .ellipse)
    #expect(subject.featherRatio == feather)
    #expect(subject.origin == .auto)
    #expect(subject.op == renderOp)
}

@Test("RenderSpecは順序ありのregions配列を保持する")
func renderSpecHoldsOrderedRegions() throws {
    let region = RenderRegionSpec(
        bounds: try makeNormalizedRect(),
        rotationDegrees: try RotationDegrees(0),
        shape: .circle,
        featherRatio: try FeatherRatio(0.0),
        origin: .manual,
        op: .solid(color: try VisibleColor(0xFFFFFFFF), opacity: try EffectOpacity(0.5))
    )

    let subject = RenderSpec(
        sourceCrop: try makeNormalizedRect(),
        scaleMode: .fill,
        background: .none,
        regions: [region, region]
    )

    #expect(subject.scaleMode == .fill)
    #expect(subject.background == .none)
    #expect(subject.regions.count == 2)
    #expect(subject.regions[0] == region)
}

@Test("EffectSettingは顔ごとの隠し方設定を全フィールド保持する")
func effectSettingHoldsAllFields() throws {
    let expansion = ExpansionRatios(
        top: try ExpansionRatio(0.25),
        bottom: try ExpansionRatio(0.15),
        leading: try ExpansionRatio(0.15),
        trailing: try ExpansionRatio(0.15)
    )
    let renderOp = RenderOpSpec.blur(sigmaRatio: try BlurRatio(0.1))
    let feather = try FeatherRatio(0.05)

    let subject = EffectSetting(op: renderOp, shape: .rectangle, featherRatio: feather, expansion: expansion)

    #expect(subject.op == renderOp)
    #expect(subject.shape == .rectangle)
    #expect(subject.featherRatio == feather)
    #expect(subject.expansion == expansion)
}
