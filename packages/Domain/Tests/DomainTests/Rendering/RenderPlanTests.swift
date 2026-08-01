import Testing
@testable import Domain
import Foundation

// Task 2: RenderDraft / RenderPlan 系のコンパイル済み型群（image-pipeline.md 2 章
// 「二段階コンパイル」「コンパイル済みの命令」）。
//
// 絶対ピクセル値のみを持つこと、各 RenderOp* の case が検証済み値型で構築できること、
// `RenderDraft.stampKeys` が `Set` として重複排除されることを検証する。
//
// `RenderDraft` / `RenderRegionDraft` / `RenderPlan` / `SourcePlacement` / `RenderRegion` /
// `RenderOp` / `RenderOpDraft` / `BackgroundOp` は正本のコードブロックに `Equatable` が
// 無く `Sendable` のみを宣言している（Domain のコンパイラがそれを強制する。`==` を書けば
// コンパイルが通らないため、ここでは実行時テストではなくソース宣言（本ファイルが依存する
// Rendering/RenderPlan.swift）でその不在を保証する）。

private func makePixelSize(width: Int = 100, height: Int = 100) -> PixelSize {
    PixelSize(width: width, height: height)
}

private func makePixelRect(left: Int = 0, top: Int = 0, right: Int = 100, bottom: Int = 100) -> PixelRect {
    PixelRect(left: left, top: top, rightExclusive: right, bottomExclusive: bottom)
}

// MARK: - StampRasterKey

@Test("StampRasterKeyはsourceとrasterSizeでHashableに区別される")
func stampRasterKeyDistinguishesBySourceAndSize() {
    let source = StampSource.builtIn(code: "cat")
    let first = StampRasterKey(source: source, rasterSize: makePixelSize(width: 64, height: 64))
    let second = StampRasterKey(source: source, rasterSize: makePixelSize(width: 128, height: 128))
    #expect(first != second)
    #expect(Set([first, second]).count == 2)
}

// MARK: - RenderOpDraft / RenderOp（検証済み値型で各caseを構築できる）

@Test("RenderOpDraft.mosaicはCellSizePxで構築できる")
func renderOpDraftMosaicHoldsCellSize() throws {
    let cellSize = try CellSizePx(4)
    let subject = RenderOpDraft.mosaic(cellSizePx: cellSize)
    guard case let .mosaic(cellSizePx) = subject else {
        Issue.record("mosaic caseであるべき")
        return
    }
    #expect(cellSizePx.value == 4)
}

@Test("RenderOpDraft.stampはStampRasterKeyとEffectOpacityで構築できる")
func renderOpDraftStampHoldsKeyAndOpacity() throws {
    let key = StampRasterKey(source: .builtIn(code: "dog"), rasterSize: makePixelSize())
    let opacity = try EffectOpacity(0.9)
    let subject = RenderOpDraft.stamp(key: key, opacity: opacity)
    guard case let .stamp(resolvedKey, resolvedOpacity) = subject else {
        Issue.record("stamp caseであるべき")
        return
    }
    #expect(resolvedKey == key)
    #expect(resolvedOpacity.value == 0.9)
}

@Test("RenderOp.stampはbitmapID文字列とEffectOpacityで構築できる")
func renderOpStampHoldsBitmapIDAndOpacity() throws {
    let opacity = try EffectOpacity(0.7)
    let subject = RenderOp.stamp(bitmapID: "raster-001", opacity: opacity)
    guard case let .stamp(bitmapID, resolvedOpacity) = subject else {
        Issue.record("stamp caseであるべき")
        return
    }
    #expect(bitmapID == "raster-001")
    #expect(resolvedOpacity.value == 0.7)
}

@Test("RenderOp.blurはSigmaPxで構築できる")
func renderOpBlurHoldsSigma() throws {
    let sigma = try SigmaPx(3.5)
    let subject = RenderOp.blur(sigmaPx: sigma)
    guard case let .blur(sigmaPx) = subject else {
        Issue.record("blur caseであるべき")
        return
    }
    #expect(sigmaPx.value == 3.5)
}

@Test("RenderOp.solidはVisibleColorとEffectOpacityで構築できる")
func renderOpSolidHoldsColorAndOpacity() throws {
    let color = try VisibleColor(0xFFAA00FF)
    let opacity = try EffectOpacity(1.0)
    let subject = RenderOp.solid(color: color, opacity: opacity)
    guard case let .solid(resolvedColor, resolvedOpacity) = subject else {
        Issue.record("solid caseであるべき")
        return
    }
    #expect(resolvedColor == color)
    #expect(resolvedOpacity.value == 1.0)
}

// MARK: - BackgroundOp

@Test("BackgroundOp.blurFromSourceはsourceRect/sigmaPx/scaleModeを保持する")
func backgroundOpBlurFromSourceHoldsAllFields() throws {
    let sourceRect = makePixelRect(right: 200, bottom: 200)
    let sigma = try SigmaPx(12.0)
    let subject = BackgroundOp.blurFromSource(sourceRect: sourceRect, sigmaPx: sigma, scaleMode: .fill)
    guard case let .blurFromSource(resolvedRect, resolvedSigma, resolvedScaleMode) = subject else {
        Issue.record("blurFromSource caseであるべき")
        return
    }
    #expect(resolvedRect == sourceRect)
    #expect(resolvedSigma.value == 12.0)
    #expect(resolvedScaleMode == .fill)
}

@Test("BackgroundOp.solidはVisibleColorを保持する")
func backgroundOpSolidHoldsColor() throws {
    let color = try VisibleColor(0xFF112233)
    let subject = BackgroundOp.solid(color: color)
    guard case let .solid(resolvedColor) = subject else {
        Issue.record("solid caseであるべき")
        return
    }
    #expect(resolvedColor == color)
}

// MARK: - RenderRegionDraft / RenderDraft（絶対ピクセル値のみ）

@Test("RenderRegionDraftは絶対ピクセルのboundsとorderを保持する")
func renderRegionDraftHoldsPixelBoundsAndOrder() throws {
    let bounds = makePixelRect(left: 10, top: 20, right: 110, bottom: 220)
    let subject = RenderRegionDraft(
        bounds: bounds,
        rotationDegrees: try RotationDegrees(0),
        shape: .circle,
        featherPx: try FeatherPx(2.0),
        order: 3,
        op: .mosaic(cellSizePx: try CellSizePx(5))
    )
    #expect(subject.bounds == bounds)
    #expect(subject.order == 3)
}

@Test("RenderDraftはstampKeysをSetとして重複排除して保持する")
func renderDraftDeduplicatesStampKeysAsSet() throws {
    let source = StampSource.builtIn(code: "cat")
    let key = StampRasterKey(source: source, rasterSize: makePixelSize())
    let placement = SourcePlacement(
        sourceRect: makePixelRect(),
        destinationRect: makePixelRect(),
        scaleMode: .fit
    )
    let region = RenderRegionDraft(
        bounds: makePixelRect(),
        rotationDegrees: try RotationDegrees(0),
        shape: .rectangle,
        featherPx: try FeatherPx(0),
        order: 0,
        op: .stamp(key: key, opacity: try EffectOpacity(1.0))
    )

    let subject = RenderDraft(
        canvasSize: makePixelSize(),
        sourcePlacement: placement,
        background: .none,
        regions: [region],
        stampKeys: [key, key]
    )

    #expect(subject.stampKeys.count == 1)
    #expect(subject.regions.count == 1)
    #expect(subject.canvasSize == makePixelSize())
}

// MARK: - SourcePlacement / RenderRegion / RenderPlan（第2段階。絶対ピクセルのみ）

@Test("SourcePlacementはsourceRect/destinationRect/scaleModeを保持する")
func sourcePlacementHoldsAllFields() {
    let sourceRect = makePixelRect(right: 300, bottom: 300)
    let destinationRect = makePixelRect(right: 150, bottom: 150)
    let subject = SourcePlacement(sourceRect: sourceRect, destinationRect: destinationRect, scaleMode: .fit)
    #expect(subject.sourceRect == sourceRect)
    #expect(subject.destinationRect == destinationRect)
    #expect(subject.scaleMode == .fit)
}

@Test("RenderRegionは出力キャンバス基準の絶対ピクセルboundsを保持する")
func renderRegionHoldsCanvasRelativeBounds() throws {
    let bounds = makePixelRect(left: 5, top: 5, right: 55, bottom: 55)
    let subject = RenderRegion(
        bounds: bounds,
        rotationDegrees: try RotationDegrees(45),
        shape: .rounded(cornerRatio: try CornerRatio(0.2)),
        featherPx: try FeatherPx(1.5),
        order: 1,
        op: .blur(sigmaPx: try SigmaPx(2.0))
    )
    #expect(subject.bounds == bounds)
    #expect(subject.order == 1)
}

@Test("RenderPlanはcanvasSize/sourcePlacement/background/regionsを保持する")
func renderPlanHoldsAllTopLevelFields() throws {
    let placement = SourcePlacement(
        sourceRect: makePixelRect(),
        destinationRect: makePixelRect(),
        scaleMode: .fill
    )
    let region = RenderRegion(
        bounds: makePixelRect(),
        rotationDegrees: try RotationDegrees(0),
        shape: .ellipse,
        featherPx: try FeatherPx(0),
        order: 0,
        op: .solid(color: try VisibleColor(0xFFFFFFFF), opacity: try EffectOpacity(1.0))
    )

    let subject = RenderPlan(
        canvasSize: makePixelSize(width: 400, height: 300),
        sourcePlacement: placement,
        background: .none,
        regions: [region]
    )

    #expect(subject.canvasSize == makePixelSize(width: 400, height: 300))
    #expect(subject.regions.count == 1)
}
