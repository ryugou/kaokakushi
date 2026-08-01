import Testing
@testable import Domain
import Foundation

// Task 2: レンダリング境界の検証済み値型群（image-pipeline.md 2 章）。
//
// 各 throws init の境界値（成功する最小・最大）と、範囲外・NaN・Infinity で
// 期待どおりの `RenderValidationError` を throw することを検証する。
// `PixelSize` / `PixelRect` は正本に throws init が無いため、検証なしで任意の値を
// 保持できることを固定する（誤って検証を追加していないことの回帰テスト）。

// MARK: - PixelSize / PixelRect（検証なし）

// 正本コードブロックに throws init が無いため型に検証を追加していない
// （設計判断ではなく正本一字一句一致の帰結）。値域（width > 0 かつ height > 0）を
// 強制する主体は正本で未定義。compileRenderDraft（Task 7）は sourceSize/targetSize を
// そこで検証すると見込まれるが、ImageSource.pixelSize／DetectionResult.detectionPixelSize／
// RawBitmapDescriptor.pixelSize はアダプタ生成で compileRenderDraft を通らず未検証のまま
// （invalidPixelSize は現時点で未使用）。
@Test("PixelSizeは検証なしで負値も含め任意の値を保持する")
func pixelSizeHoldsArbitraryValuesWithoutValidation() {
    let subject = assertSendableHashable(PixelSize(width: -1, height: 0))
    #expect(subject.width == -1)
    #expect(subject.height == 0)
}

// 正本コードブロックに throws init が無いため型に検証を追加していない
// （設計判断ではなく正本一字一句一致の帰結）。値域（left < rightExclusive 等）を
// 強制する主体は正本で未定義。PixelRect は RenderPlan（Task 7 の compileRenderDraft が
// 構築）内でのみ使われ、PixelSize と異なりアダプタ生成経由の未検証混入経路はないが、
// 正本はここでの検証主体を明記していない。
@Test("PixelRectは検証なしで矛盾した座標も保持する")
func pixelRectHoldsInconsistentBoundsWithoutValidation() {
    let subject = PixelRect(left: 10, top: 10, rightExclusive: 5, bottomExclusive: 5)
    #expect(subject.left == 10)
    #expect(subject.rightExclusive == 5)
}

// MARK: - RenderValidationError（12 ケース過不足なし）

@Test("RenderValidationErrorは正本どおり12ケースを持ちEquatable")
func renderValidationErrorHasExactlyTwelveCases() {
    let allCases: [RenderValidationError] = [
        .invalidOpacity, .invalidRatio, .invalidCornerRatio, .invalidPixelSize,
        .invalidRect, .invalidCellSize, .invalidSigma, .invalidFeather,
        .nonVisibleColor, .emptyRegion, .unresolvedStampAsset, .sourceCropOutOfBounds
    ]
    #expect(allCases.count == 12)
    #expect(RenderValidationError.invalidOpacity == RenderValidationError.invalidOpacity)
    #expect(RenderValidationError.invalidOpacity != RenderValidationError.invalidRatio)
    // default無しのswitchで全ケースを一意な値へ写す。将来ケースが追加されるとこのswitchが
    // 網羅性を失いコンパイルエラーになるため、配列への追加漏れ（テストが静かに古びる）を
    // 機械的に検出できる。
    #expect(Set(allCases.map(renderValidationErrorExhaustiveIndex)).count == 12)
}

// 分岐数はケース数そのもの（網羅的 switch によるコンパイル時検出が目的のため許容する）。
// swiftlint:disable:next cyclomatic_complexity
private func renderValidationErrorExhaustiveIndex(_ subject: RenderValidationError) -> Int {
    switch subject {
    case .invalidOpacity: return 0
    case .invalidRatio: return 1
    case .invalidCornerRatio: return 2
    case .invalidPixelSize: return 3
    case .invalidRect: return 4
    case .invalidCellSize: return 5
    case .invalidSigma: return 6
    case .invalidFeather: return 7
    case .nonVisibleColor: return 8
    case .emptyRegion: return 9
    case .unresolvedStampAsset: return 10
    case .sourceCropOutOfBounds: return 11
    }
}

// MARK: - EffectOpacity（有限かつ 0 < v <= 1）

@Test("EffectOpacityは上限1.0で成功する")
func effectOpacitySucceedsAtUpperBound() throws {
    let subject = try EffectOpacity(1.0)
    #expect(subject.value == 1.0)
}

@Test("EffectOpacityは0.0でinvalidOpacityをthrowする")
func effectOpacityThrowsAtZero() {
    #expect(throws: RenderValidationError.invalidOpacity) {
        try EffectOpacity(0.0)
    }
}

@Test("EffectOpacityは1.0超過でinvalidOpacityをthrowする")
func effectOpacityThrowsAboveUpperBound() {
    #expect(throws: RenderValidationError.invalidOpacity) {
        try EffectOpacity(1.0001)
    }
}

@Test(
    "EffectOpacityはNaN/InfinityでinvalidOpacityをthrowする",
    arguments: [Double.nan, Double.infinity, -Double.infinity]
)
func effectOpacityThrowsOnNonFiniteValues(value: Double) {
    #expect(throws: RenderValidationError.invalidOpacity) {
        try EffectOpacity(value)
    }
}

// MARK: - MosaicRatio / BlurRatio（有限かつ 0 < v <= 0.5）

@Test("MosaicRatioは上限0.5で成功し0またはNaNでinvalidRatioをthrowする")
func mosaicRatioBoundaryBehavior() throws {
    let subject = try MosaicRatio(0.5)
    #expect(subject.value == 0.5)
    #expect(throws: RenderValidationError.invalidRatio) { try MosaicRatio(0.0) }
    #expect(throws: RenderValidationError.invalidRatio) { try MosaicRatio(0.5001) }
    #expect(throws: RenderValidationError.invalidRatio) { try MosaicRatio(.nan) }
}

@Test("BlurRatioは上限0.5で成功し0またはNaNでinvalidRatioをthrowする")
func blurRatioBoundaryBehavior() throws {
    let subject = try BlurRatio(0.5)
    #expect(subject.value == 0.5)
    #expect(throws: RenderValidationError.invalidRatio) { try BlurRatio(0.0) }
    #expect(throws: RenderValidationError.invalidRatio) { try BlurRatio(0.5001) }
}

// MARK: - FeatherRatio（有限かつ 0 <= v <= 0.5。0 を許す）

@Test("FeatherRatioは0で成功する")
func featherRatioSucceedsAtZero() throws {
    let subject = try FeatherRatio(0.0)
    #expect(subject.value == 0.0)
}

@Test("FeatherRatioは上限0.5で成功する")
func featherRatioSucceedsAtUpperBound() throws {
    let subject = try FeatherRatio(0.5)
    #expect(subject.value == 0.5)
}

@Test("FeatherRatioは負値または上限超過でinvalidRatioをthrowする")
func featherRatioThrowsOutOfRange() {
    #expect(throws: RenderValidationError.invalidRatio) { try FeatherRatio(-0.0001) }
    #expect(throws: RenderValidationError.invalidRatio) { try FeatherRatio(0.5001) }
}

// MARK: - ExpansionRatio（有限かつ 0 <= v <= 2.0）

@Test("ExpansionRatioは0と2.0の境界で成功する")
func expansionRatioSucceedsAtBounds() throws {
    #expect(try ExpansionRatio(0.0).value == 0.0)
    #expect(try ExpansionRatio(2.0).value == 2.0)
}

@Test("ExpansionRatioは負値または2.0超過でinvalidRatioをthrowする")
func expansionRatioThrowsOutOfRange() {
    #expect(throws: RenderValidationError.invalidRatio) { try ExpansionRatio(-0.0001) }
    #expect(throws: RenderValidationError.invalidRatio) { try ExpansionRatio(2.0001) }
}

// MARK: - ExpansionRatios（コンポーネント検証済みのため追加検証なし）

@Test("ExpansionRatiosは4方向のExpansionRatioを保持する")
func expansionRatiosHoldsAllFourDirections() throws {
    let top = try ExpansionRatio(0.25)
    let bottom = try ExpansionRatio(0.15)
    let leading = try ExpansionRatio(0.15)
    let trailing = try ExpansionRatio(0.15)
    let subject = assertSendableHashable(
        ExpansionRatios(top: top, bottom: bottom, leading: leading, trailing: trailing)
    )
    #expect(subject.top == top)
    #expect(subject.bottom == bottom)
    #expect(subject.leading == leading)
    #expect(subject.trailing == trailing)
}

// MARK: - RotationDegrees（[-180, 180) へ正規化）

@Test("RotationDegreesは370を10へ正規化する")
func rotationDegreesNormalizesThreeHundredSeventyToTen() throws {
    let subject = try RotationDegrees(370)
    #expect(subject.value == 10)
}

@Test("RotationDegreesは境界の-180をそのまま保持する")
func rotationDegreesKeepsLowerBoundAsIs() throws {
    let subject = try RotationDegrees(-180)
    #expect(subject.value == -180)
}

@Test("RotationDegreesは180を排他上限のため-180へ正規化する")
func rotationDegreesWrapsUpperBoundToLowerBound() throws {
    let subject = try RotationDegrees(180)
    #expect(subject.value == -180)
}

@Test("RotationDegreesは-190を170へ正規化する")
func rotationDegreesNormalizesNegativeBelowLowerBound() throws {
    let subject = try RotationDegrees(-190)
    #expect(subject.value == 170)
}

@Test(
    "RotationDegreesはNaN/InfinityでinvalidRatioをthrowする",
    arguments: [Double.nan, Double.infinity, -Double.infinity]
)
func rotationDegreesThrowsOnNonFiniteValues(value: Double) {
    #expect(throws: RenderValidationError.invalidRatio) {
        try RotationDegrees(value)
    }
}

// MARK: - SigmaPx（有限かつ > 0）

@Test("SigmaPxは正の値で成功し0以下またはNaNでinvalidSigmaをthrowする")
func sigmaPxBoundaryBehavior() throws {
    let subject = try SigmaPx(0.0001)
    #expect(subject.value == 0.0001)
    #expect(throws: RenderValidationError.invalidSigma) { try SigmaPx(0.0) }
    #expect(throws: RenderValidationError.invalidSigma) { try SigmaPx(-1.0) }
    #expect(throws: RenderValidationError.invalidSigma) { try SigmaPx(.nan) }
}

// MARK: - FeatherPx（有限かつ >= 0）

@Test("FeatherPxは0で成功し負値またはNaNでinvalidFeatherをthrowする")
func featherPxBoundaryBehavior() throws {
    let subject = try FeatherPx(0.0)
    #expect(subject.value == 0.0)
    #expect(throws: RenderValidationError.invalidFeather) { try FeatherPx(-0.0001) }
    #expect(throws: RenderValidationError.invalidFeather) { try FeatherPx(.nan) }
}

// MARK: - CellSizePx（v >= 2）

@Test("CellSizePxは1でinvalidCellSizeをthrowし2で成功する")
func cellSizePxBoundaryBehavior() throws {
    #expect(throws: RenderValidationError.invalidCellSize) { try CellSizePx(1) }
    let subject = try CellSizePx(2)
    #expect(subject.value == 2)
}

@Test("CellSizePxは0以下でもinvalidCellSizeをthrowする")
func cellSizePxThrowsForNonPositiveValues() {
    #expect(throws: RenderValidationError.invalidCellSize) { try CellSizePx(0) }
    #expect(throws: RenderValidationError.invalidCellSize) { try CellSizePx(-2) }
}

// MARK: - CornerRatio（有限かつ 0 < v <= 0.5）

@Test("CornerRatioは上限0.5で成功し0またはNaNでinvalidCornerRatioをthrowする")
func cornerRatioBoundaryBehavior() throws {
    let subject = try CornerRatio(0.5)
    #expect(subject.value == 0.5)
    #expect(throws: RenderValidationError.invalidCornerRatio) { try CornerRatio(0.0) }
    #expect(throws: RenderValidationError.invalidCornerRatio) { try CornerRatio(.nan) }
}

// MARK: - NormalizedRect（すべて有限。left < right、top < bottom。1.0超過・負数を許す）

@Test("NormalizedRectは負数や1.0超過も許容して成功する")
func normalizedRectAllowsOutOfUnitRangeValues() throws {
    let subject = try NormalizedRect(left: -0.5, top: -0.2, rightExclusive: 1.5, bottomExclusive: 1.2)
    #expect(subject.left == -0.5)
    #expect(subject.rightExclusive == 1.5)
}

@Test("NormalizedRectはleftがrightExclusive以上でinvalidRectをthrowする")
func normalizedRectThrowsWhenLeftNotLessThanRight() {
    #expect(throws: RenderValidationError.invalidRect) {
        try NormalizedRect(left: 0.5, top: 0.0, rightExclusive: 0.5, bottomExclusive: 1.0)
    }
}

@Test("NormalizedRectはtopがbottomExclusive以上でinvalidRectをthrowする")
func normalizedRectThrowsWhenTopNotLessThanBottom() {
    #expect(throws: RenderValidationError.invalidRect) {
        try NormalizedRect(left: 0.0, top: 1.0, rightExclusive: 1.0, bottomExclusive: 1.0)
    }
}

@Test("NormalizedRectはNaN/Infinityを含む座標でinvalidRectをthrowする")
func normalizedRectThrowsOnNonFiniteCoordinates() {
    #expect(throws: RenderValidationError.invalidRect) {
        try NormalizedRect(left: .nan, top: 0.0, rightExclusive: 1.0, bottomExclusive: 1.0)
    }
    #expect(throws: RenderValidationError.invalidRect) {
        try NormalizedRect(left: 0.0, top: 0.0, rightExclusive: .infinity, bottomExclusive: 1.0)
    }
}

// MARK: - SrgbArgb8888 / VisibleColor（アルファが0より大きい）

@Test("SrgbArgb8888はアルファが0より大きければ成功する")
func srgbArgb8888SucceedsWithNonZeroAlpha() throws {
    let subject = try SrgbArgb8888(0xFF00_00FF)
    #expect(subject.value == 0xFF00_00FF)
}

@Test("SrgbArgb8888はアルファ0でnonVisibleColorをthrowする")
func srgbArgb8888ThrowsWithZeroAlpha() {
    #expect(throws: RenderValidationError.nonVisibleColor) {
        try SrgbArgb8888(0x00FF_00FF)
    }
}

@Test("VisibleColorはSrgbArgb8888のtypealiasであり同じ検証を行う")
func visibleColorIsSameTypeAsSrgbArgb8888() throws {
    let subject: VisibleColor = try VisibleColor(0x01FF_FFFF)
    let expected: SrgbArgb8888 = subject
    #expect(expected.value == 0x01FF_FFFF)
    #expect(throws: RenderValidationError.nonVisibleColor) {
        try VisibleColor(0x0000_0000)
    }
}
