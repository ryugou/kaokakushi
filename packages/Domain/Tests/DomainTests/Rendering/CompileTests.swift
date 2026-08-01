import Testing
@testable import Domain
import Foundation

// Task 7: レンダリングのコンパイル純粋関数（image-pipeline.md 1章「拡張率の適用」・
// 2章「二段階コンパイル」・4章「ピクセルへの丸め」「適用順」）。
//
// test-plan.md 2.4 節のうち Task 7 スコープの項目（丸め規則・stampKeys 重複排除・
// 欠落 assets での throw・座標変換・sourceCrop 不変条件・領域の描画順）を検証する。
// `authorizeRenderSpec` / Paywall / `enabledStampPacks` / バッチの `blocked` 遷移は
// Task 8 の担当のためここでは扱わない。
//
// 数値例は、Double の丸め誤差でテストの意図（floor/ceil の方向）が揺れないよう、
// 積が整数境界へ十分近づかない値（例: 12.3, 45.6）または 2 進で厳密に表現できる
// dyadic rational（0.25, 0.5, 0.75, 0.0625 等）のいずれかを選んでいる。
//
// fit/fill の配置・背景ぼかしのテスト（sourcePlacement / background 系）は
// swiftlint file_length(400行)対応のため CompilePlacementTests.swift へ分割している。
// このファイルは丸め・stampKeys・適用順・cellSizePx・expand 等のコア変換ロジックを扱う。

// makeSize / makeRect / makeSpec は CompilePlacementTests.swift と共有する（internal）。
func makeSize(_ width: Int, _ height: Int) -> PixelSize {
    PixelSize(width: width, height: height)
}

func makeRect(left: Double, top: Double, right: Double, bottom: Double) throws -> NormalizedRect {
    try NormalizedRect(left: left, top: top, rightExclusive: right, bottomExclusive: bottom)
}

func makeSpec(
    sourceCrop: NormalizedRect,
    scaleMode: SourceScaleMode = .fill,
    background: BackgroundSpec = .none,
    regions: [RenderRegionSpec] = []
) -> RenderSpec {
    RenderSpec(sourceCrop: sourceCrop, scaleMode: scaleMode, background: background, regions: regions)
}

private func makeSolidRegion(bounds: NormalizedRect, origin: RegionOrigin, color: UInt32) throws -> RenderRegionSpec {
    RenderRegionSpec(
        bounds: bounds,
        rotationDegrees: try RotationDegrees(0),
        shape: .rectangle,
        featherRatio: try FeatherRatio(0.0),
        origin: origin,
        op: .solid(color: try VisibleColor(color), opacity: try EffectOpacity(1.0))
    )
}

// MARK: - 1. RenderDraft.canvasSize は targetSize をそのまま（比率を残さない）

@Test("compileRenderDraftはRenderDraft.canvasSizeにtargetSizeをそのまま入れる")
func compileRenderDraftSetsCanvasSizeToTargetSizeVerbatim() throws {
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1))
    let draft = try compileRenderDraft(
        spec: spec,
        sourceSize: makeSize(300, 400),
        targetSize: makeSize(150, 200)
    )
    #expect(draft.canvasSize == makeSize(150, 200))
}

// MARK: - 2. sourceSize を使った sourceCrop → sourceRect の絶対ピクセル変換

@Test("compileRenderDraftはsourceSizeを使いsourceCropを絶対ピクセルのsourceRectへ変換する")
func compileRenderDraftConvertsSourceCropToAbsoluteSourceRect() throws {
    // 0.25/0.75 は 2 の冪の逆数の和なので IEEE754 double で厳密に表現でき、
    // × 100 も厳密に 25/75 になる（0.1 や 0.55 のような 10 進小数は近似になり、
    // ceil 丸めで期待値が 1 ずれるため使わない）。crop はキャンバスと同じ正方形に
    // して、fill の cover 切り詰めが発生しない条件で純粋な座標変換だけを検証する
    // （切り詰めの挙動は CompilePlacementTests.swift が担当）。
    let spec = makeSpec(sourceCrop: try makeRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75))
    let draft = try compileRenderDraft(
        spec: spec,
        sourceSize: makeSize(100, 100),
        targetSize: makeSize(100, 100)
    )
    let expected = PixelRect(left: 25, top: 25, rightExclusive: 75, bottomExclusive: 75)
    #expect(draft.sourcePlacement.sourceRect == expected)
}

// MARK: - 3. left/top は floor、right/bottom は ceil で外側へ広がる

@Test("領域のboundsはleft/topがfloor、right/bottomがceilで外側へ広がる")
func regionBoundsRoundOutwardWithFloorAndCeil() throws {
    let region = try makeSolidRegion(
        bounds: try makeRect(left: 0.123, top: 0.456, right: 0.789, bottom: 0.891),
        origin: .auto,
        color: 0xFF00_0001
    )
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1), regions: [region])
    let draft = try compileRenderDraft(
        spec: spec,
        sourceSize: makeSize(100, 100),
        targetSize: makeSize(100, 100)
    )
    // floor(12.3)=12, floor(45.6)=45, ceil(78.9)=79, ceil(89.1)=90 — いずれも外側へ広がる。
    let expected = PixelRect(left: 12, top: 45, rightExclusive: 79, bottomExclusive: 90)
    #expect(draft.regions[0].bounds == expected)
}

// MARK: - 4. sourceCrop の不変条件違反（クランプせず throw）

@Test("compileRenderDraftはsourceCropが画像外へ出ているとsourceCropOutOfBoundsをthrowする")
func compileRenderDraftThrowsWhenSourceCropExceedsUnitRange() throws {
    // NormalizedRect自体は負数・1.0超過を許容する（expand()の結果を模した範囲外矩形）が、
    // sourceCropとして使う場合はcompileRenderDraftがクランプせずthrowする。
    let outOfBoundsCrop = try makeRect(left: -0.05, top: 0.0, right: 1.02, bottom: 1.0)
    let spec = makeSpec(sourceCrop: outOfBoundsCrop)
    #expect(throws: RenderValidationError.sourceCropOutOfBounds) {
        try compileRenderDraft(spec: spec, sourceSize: makeSize(100, 100), targetSize: makeSize(100, 100))
    }
}

// MARK: - 5. sourceSize / targetSize の width/height <= 0 で invalidPixelSize

@Test("compileRenderDraftはsourceSizeの幅または高さが0以下でinvalidPixelSizeをthrowする")
func compileRenderDraftThrowsInvalidPixelSizeForNonPositiveSourceSize() throws {
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1))
    #expect(throws: RenderValidationError.invalidPixelSize) {
        try compileRenderDraft(spec: spec, sourceSize: makeSize(0, 100), targetSize: makeSize(100, 100))
    }
    #expect(throws: RenderValidationError.invalidPixelSize) {
        try compileRenderDraft(spec: spec, sourceSize: makeSize(100, -5), targetSize: makeSize(100, 100))
    }
}

@Test("compileRenderDraftはtargetSizeの幅または高さが0以下でinvalidPixelSizeをthrowする")
func compileRenderDraftThrowsInvalidPixelSizeForNonPositiveTargetSize() throws {
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1))
    #expect(throws: RenderValidationError.invalidPixelSize) {
        try compileRenderDraft(spec: spec, sourceSize: makeSize(100, 100), targetSize: makeSize(0, 100))
    }
    #expect(throws: RenderValidationError.invalidPixelSize) {
        try compileRenderDraft(spec: spec, sourceSize: makeSize(100, 100), targetSize: makeSize(100, 0))
    }
}

// MARK: - 6. manual は auto より後の order。各区分内は元の順序を保つ

@Test("manual領域はauto領域より後のorderになり各区分内で元の順序を保つ")
func manualRegionsComeAfterAutoRegionsPreservingRelativeOrder() throws {
    let autoFirst = try makeSolidRegion(
        bounds: try makeRect(left: 0.1, top: 0.1, right: 0.3, bottom: 0.3), origin: .auto, color: 0xFF00_0001
    )
    let manualFirst = try makeSolidRegion(
        bounds: try makeRect(left: 0.15, top: 0.15, right: 0.35, bottom: 0.35), origin: .manual, color: 0xFF00_0002
    )
    let autoSecond = try makeSolidRegion(
        bounds: try makeRect(left: 0.2, top: 0.2, right: 0.4, bottom: 0.4), origin: .auto, color: 0xFF00_0003
    )
    let manualSecond = try makeSolidRegion(
        bounds: try makeRect(left: 0.25, top: 0.25, right: 0.45, bottom: 0.45), origin: .manual, color: 0xFF00_0004
    )

    let spec = makeSpec(
        sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1),
        regions: [autoFirst, manualFirst, autoSecond, manualSecond]
    )
    let draft = try compileRenderDraft(spec: spec, sourceSize: makeSize(100, 100), targetSize: makeSize(100, 100))

    let colors: [UInt32] = draft.regions.map { region in
        guard case let .solid(color, _) = region.op else {
            Issue.record("solid caseであるべき")
            return 0
        }
        return color.value
    }

    #expect(colors == [0xFF00_0001, 0xFF00_0003, 0xFF00_0002, 0xFF00_0004])
    #expect(draft.regions.map(\.order) == [0, 1, 2, 3])
}

// MARK: - 7. cellSizePx = floor(cellRatio × 短辺)。1以下なら2へ引き上げ

@Test("cellSizePxはfloor(cellRatio×領域短辺)で求まり1以下なら2へ引き上げられる")
func cellSizePxFlooredAndClampedToMinimumTwo() throws {
    let region = RenderRegionSpec(
        bounds: try makeRect(left: 0, top: 0, right: 0.25, bottom: 0.5),
        rotationDegrees: try RotationDegrees(0),
        shape: .rectangle,
        featherRatio: try FeatherRatio(0.0),
        origin: .auto,
        op: .mosaic(cellRatio: try MosaicRatio(0.01))
    )
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1), regions: [region])
    // canvasSize(targetSize) = 200x100。boundsPx = (0,0,50,50) → shortSide=50。
    // raw = floor(0.01 * 50) = floor(0.5) = 0 → max(2,0) = 2。
    let draft = try compileRenderDraft(spec: spec, sourceSize: makeSize(100, 100), targetSize: makeSize(200, 100))

    guard case let .mosaic(cellSizePx) = draft.regions[0].op else {
        Issue.record("mosaic caseであるべき")
        return
    }
    #expect(cellSizePx.value == 2)
}

// MARK: - 8. 引き上げても2px未満なら invalidCellSize を throw

@Test("領域短辺が2px未満なら引き上げてもinvalidCellSizeをthrowする")
func cellSizePxThrowsWhenShortSideBelowTwoPixelsEvenAfterClamp() throws {
    let region = RenderRegionSpec(
        bounds: try makeRect(left: 0, top: 0, right: 0.1, bottom: 0.5),
        rotationDegrees: try RotationDegrees(0),
        shape: .rectangle,
        featherRatio: try FeatherRatio(0.0),
        origin: .auto,
        op: .mosaic(cellRatio: try MosaicRatio(0.3))
    )
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1), regions: [region])
    // canvasSize = 10x10。boundsPx = (0,0,1,5) → shortSide=1 < 2。
    #expect(throws: RenderValidationError.invalidCellSize) {
        try compileRenderDraft(spec: spec, sourceSize: makeSize(100, 100), targetSize: makeSize(10, 10))
    }
}

// MARK: - 9. bindRasterAssets は asset が1件でも欠けると throw

@Test("bindRasterAssetsはdraft.stampKeysに対応するassetが1件でも欠けるとunresolvedStampAssetをthrowする")
func bindRasterAssetsThrowsWhenAssetMissing() throws {
    let region = RenderRegionSpec(
        bounds: try makeRect(left: 0.1, top: 0.1, right: 0.5, bottom: 0.5),
        rotationDegrees: try RotationDegrees(0),
        shape: .rectangle,
        featherRatio: try FeatherRatio(0.0),
        origin: .auto,
        op: .stamp(source: .builtIn(code: "cat"), opacity: try EffectOpacity(1.0))
    )
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1), regions: [region])
    let draft = try compileRenderDraft(spec: spec, sourceSize: makeSize(100, 100), targetSize: makeSize(100, 100))

    #expect(draft.stampKeys.count == 1)
    #expect(throws: RenderValidationError.unresolvedStampAsset) {
        try bindRasterAssets(draft: draft, assets: [:])
    }
}

// MARK: - 10. bindRasterAssets は .stamp(key:) を .stamp(bitmapID:) へ正しく解決する

@Test("bindRasterAssetsは.stamp(key:)を.stamp(bitmapID:)へ正しく解決する")
func bindRasterAssetsResolvesStampKeyToBitmapID() throws {
    let region = RenderRegionSpec(
        bounds: try makeRect(left: 0.1, top: 0.1, right: 0.5, bottom: 0.5),
        rotationDegrees: try RotationDegrees(0),
        shape: .rectangle,
        featherRatio: try FeatherRatio(0.0),
        origin: .auto,
        op: .stamp(source: .builtIn(code: "cat"), opacity: try EffectOpacity(0.8))
    )
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1), regions: [region])
    let draft = try compileRenderDraft(spec: spec, sourceSize: makeSize(100, 100), targetSize: makeSize(100, 100))

    guard let key = draft.stampKeys.first else {
        Issue.record("stampKeysが空であるべきではない")
        return
    }

    let fileRef = try #require(
        RasterFileRef(ManagedFileRef(kind: .rasterTemporary, fileID: ManagedFileID(rawValue: UUID())))
    )
    let descriptor = RawBitmapDescriptor(
        pixelSize: key.rasterSize,
        rowBytes: key.rasterSize.width * 4,
        channelOrder: .rgba,
        alpha: .straight,
        bitDepth: .eightPerChannel,
        colorSpace: .sRGB
    )
    let asset = RasterizedStampAsset(bitmapID: "raster-001", rasterFile: fileRef, descriptor: descriptor)

    let plan = try bindRasterAssets(draft: draft, assets: [key: asset])

    guard case let .stamp(bitmapID, opacity) = plan.regions[0].op else {
        Issue.record("stamp caseであるべき")
        return
    }
    #expect(bitmapID == "raster-001")
    #expect(opacity.value == 0.8)
}

// MARK: - 10b. bindRasterAssetsはdraft.stampKeysと矛盾するregionsを渡されてもクラッシュせずthrowする
//
// RenderDraftはpublic initを公開しており、compileRenderDraftを経由しない不整合な入力
// （stampKeysに含まれないstamp opを持つregions）を構築できる。外側のguardは
// draft.stampKeys基準のため素通りしうるが、内部のresolveOpがthrowすることを確認する。

@Test("bindRasterAssetsはstampKeysに含まれないstamp opがregionsにあってもクラッシュせずunresolvedStampAssetをthrowする")
func bindRasterAssetsThrowsInsteadOfCrashingOnInconsistentDraft() throws {
    let key = StampRasterKey(source: .builtIn(code: "cat"), rasterSize: makeSize(10, 10))
    let regionDraft = RenderRegionDraft(
        bounds: PixelRect(left: 0, top: 0, rightExclusive: 10, bottomExclusive: 10),
        rotationDegrees: try RotationDegrees(0),
        shape: .rectangle,
        featherPx: try FeatherPx(0.0),
        order: 0,
        op: .stamp(key: key, opacity: try EffectOpacity(1.0))
    )
    let draft = RenderDraft(
        canvasSize: makeSize(10, 10),
        sourcePlacement: SourcePlacement(
            sourceRect: PixelRect(left: 0, top: 0, rightExclusive: 10, bottomExclusive: 10),
            destinationRect: PixelRect(left: 0, top: 0, rightExclusive: 10, bottomExclusive: 10),
            scaleMode: .fill
        ),
        background: .none,
        regions: [regionDraft],
        stampKeys: []
    )

    #expect(throws: RenderValidationError.unresolvedStampAsset) {
        try bindRasterAssets(draft: draft, assets: [:])
    }
}

// MARK: - 11. expand() は負数・1.0超過を許容しクランプしない

@Test("expandは拡張後に負数・1.0超過を許容しクランプしない")
func expandDoesNotClampOutOfUnitRangeResults() throws {
    // すべて 2 進で厳密に表現できる値にする（10 進小数の近似だと演算結果の
    // 厳密比較が -0.049999... のように期待値とずれる）。
    // width = 0.1875, height = 0.125。
    let face = try makeRect(left: 0.75, top: 0.0625, right: 0.9375, bottom: 0.1875)
    let expansion = ExpansionRatios(
        top: try ExpansionRatio(1.0),
        bottom: try ExpansionRatio(0.0),
        leading: try ExpansionRatio(0.0),
        trailing: try ExpansionRatio(1.0)
    )
    let effect = EffectSetting(
        op: .solid(color: try VisibleColor(0xFFFF_FFFF), opacity: try EffectOpacity(1.0)),
        shape: .rectangle,
        featherRatio: try FeatherRatio(0.0),
        expansion: expansion
    )

    let expanded = expand(face: face, effect: effect)

    #expect(expanded.top == -0.0625)
    #expect(expanded.rightExclusive == 1.125)
    #expect(expanded.left == 0.75)
    #expect(expanded.bottomExclusive == 0.1875)
}

// MARK: - 12. RenderOpDraftはCellSizePx/SigmaPxを保持し生のDoubleを残さない（型レベル）

@Test("compileRenderDraftはmosaicとblurをCellSizePx/SigmaPxで保持し生のDoubleを残さない")
func compiledOpsHoldValidatedValueTypesNotRawDouble() throws {
    let mosaicRegion = RenderRegionSpec(
        bounds: try makeRect(left: 0.0, top: 0.0, right: 0.5, bottom: 0.5),
        rotationDegrees: try RotationDegrees(0),
        shape: .rectangle,
        featherRatio: try FeatherRatio(0.0),
        origin: .auto,
        op: .mosaic(cellRatio: try MosaicRatio(0.2))
    )
    let blurRegion = RenderRegionSpec(
        bounds: try makeRect(left: 0.5, top: 0.5, right: 1.0, bottom: 1.0),
        rotationDegrees: try RotationDegrees(0),
        shape: .rectangle,
        featherRatio: try FeatherRatio(0.0),
        origin: .auto,
        op: .blur(sigmaRatio: try BlurRatio(0.3))
    )
    let spec = makeSpec(
        sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1),
        regions: [mosaicRegion, blurRegion]
    )
    let draft = try compileRenderDraft(spec: spec, sourceSize: makeSize(100, 100), targetSize: makeSize(100, 100))

    guard case let .mosaic(cellSizePx) = draft.regions[0].op, case let .blur(sigmaPx) = draft.regions[1].op else {
        Issue.record("mosaic/blur caseであるべき")
        return
    }
    let cellSizePxTyped: CellSizePx = cellSizePx
    let sigmaPxTyped: SigmaPx = sigmaPx
    #expect(cellSizePxTyped.value >= 2)
    #expect(sigmaPxTyped.value > 0)
}
