import Testing
@testable import Domain
import Foundation

// Task 7: レンダリングのコンパイル純粋関数のうち、前景配置（`SourcePlacement`）と
// 背景ぼかし（`BackgroundOp`）を検証する。CompileTests.swift からの分割（swiftlint
// file_length(400行)対応）。丸め・stampKeys・適用順・cellSizePx・expand 等のコア変換
// ロジックは CompileTests.swift 側を参照。
//
// fit/fill の配置式・背景ぼかしの sourceRect/scaleMode 決定の正本は image-pipeline.md
// 2 章「SourcePlacement の配置規則」。
//
// 数値例は、Double の丸め誤差でテストの意図（floor/ceil の方向）が揺れないよう、
// 積が整数境界へ十分近づかない値、または 2 進で厳密に表現できる dyadic rational
// （0.5 等）のいずれかを選んでいる（CompileTests.swift 冒頭の方針を踏襲）。
//
// makeSize / makeRect / makeSpec は CompileTests.swift の共有ヘルパーを使う。

// MARK: - 1. scaleMode=fill / fit の destinationRect

@Test("scaleMode=fillはdestinationRectをキャンバス全面にする")
func sourcePlacementFillCoversEntireCanvas() throws {
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1), scaleMode: .fill)
    let draft = try compileRenderDraft(spec: spec, sourceSize: makeSize(200, 100), targetSize: makeSize(100, 100))

    #expect(draft.sourcePlacement.scaleMode == .fill)
    let fullCanvas = PixelRect(left: 0, top: 0, rightExclusive: 100, bottomExclusive: 100)
    #expect(draft.sourcePlacement.destinationRect == fullCanvas)
}

@Test("scaleMode=fitは縦横比を保ち中央配置したdestinationRectを作る")
func sourcePlacementFitCentersScaledRect() throws {
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1), scaleMode: .fit)
    let draft = try compileRenderDraft(spec: spec, sourceSize: makeSize(200, 100), targetSize: makeSize(100, 100))

    // scale = min(100/200, 100/100) = 0.5 → scaledWidth=100, scaledHeight=50 → 中央配置。
    let expected = PixelRect(left: 0, top: 25, rightExclusive: 100, bottomExclusive: 75)
    #expect(draft.sourcePlacement.scaleMode == .fit)
    #expect(draft.sourcePlacement.destinationRect == expected)
}

// MARK: - 2. scaleMode=fill は真の cover。sourceRect をキャンバス縦横比へ中央で切り詰める
//
// Critical #2 の修正: fill が sourceRect をそのまま使うと sourceCrop とキャンバスの
// 縦横比が異なる場合に非一様な引き伸ばしが起きる。オーケストレータが確定した cover 仕様
// （fillSourceRect）の回帰を検証する。

@Test("scaleMode=fillはsourceが横長のとき幅方向を中央で切り詰める")
func sourcePlacementFillCropsHorizontalSourceToCanvasAspectRatio() throws {
    // sourceSize=200x100 → sourceRect=(0,0,200,100)。srcAspect=2.0 > canvasAspect=1.0 なので
    // 幅方向を切り詰める。cropWidth = srcH * canvasAspect = 100。insetX = (200-100)/2 = 50。
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1), scaleMode: .fill)
    let draft = try compileRenderDraft(spec: spec, sourceSize: makeSize(200, 100), targetSize: makeSize(100, 100))

    let expectedSourceRect = PixelRect(left: 50, top: 0, rightExclusive: 150, bottomExclusive: 100)
    let expectedDestinationRect = PixelRect(left: 0, top: 0, rightExclusive: 100, bottomExclusive: 100)
    #expect(draft.sourcePlacement.sourceRect == expectedSourceRect)
    #expect(draft.sourcePlacement.destinationRect == expectedDestinationRect)
}

@Test("scaleMode=fillはsourceが縦長のとき高さ方向を中央で切り詰める")
func sourcePlacementFillCropsVerticalSourceToCanvasAspectRatio() throws {
    // sourceSize=100x200 → sourceRect=(0,0,100,200)。srcAspect=0.5 < canvasAspect=1.0 なので
    // 高さ方向を切り詰める。cropHeight = srcW / canvasAspect = 100。insetY = (200-100)/2 = 50。
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1), scaleMode: .fill)
    let draft = try compileRenderDraft(spec: spec, sourceSize: makeSize(100, 200), targetSize: makeSize(100, 100))

    let expectedSourceRect = PixelRect(left: 0, top: 50, rightExclusive: 100, bottomExclusive: 150)
    let expectedDestinationRect = PixelRect(left: 0, top: 0, rightExclusive: 100, bottomExclusive: 100)
    #expect(draft.sourcePlacement.sourceRect == expectedSourceRect)
    #expect(draft.sourcePlacement.destinationRect == expectedDestinationRect)
}

@Test("scaleMode=fillのcropはleft/topがfloor、right/bottomがceilで外側へ広がる")
func sourcePlacementFillCropRoundsOutwardWithFloorAndCeil() throws {
    // sourceSize=306x101 → sourceRect=(0,0,306,101)。srcAspect=306/101≈3.03 > canvasAspect=1.0
    // なので幅方向を切り詰める。cropWidth = srcH * canvasAspect = 101。
    // insetX = (306-101)/2 = 102.5（2進で厳密に表現できる dyadic rational）。
    // left = 0+102.5 → floor=102。right = 102.5+101=203.5 → ceil=204。
    // 単純な四捨五入（102.5→102 or 103 の丸め方式に依存）と異なり、floor/ceil で
    // 外側へ広がることを固定するテスト。
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1), scaleMode: .fill)
    let draft = try compileRenderDraft(spec: spec, sourceSize: makeSize(306, 101), targetSize: makeSize(100, 100))

    let expectedSourceRect = PixelRect(left: 102, top: 0, rightExclusive: 204, bottomExclusive: 101)
    let expectedDestinationRect = PixelRect(left: 0, top: 0, rightExclusive: 100, bottomExclusive: 100)
    #expect(draft.sourcePlacement.sourceRect == expectedSourceRect)
    #expect(draft.sourcePlacement.destinationRect == expectedDestinationRect)
}

// MARK: - 3. background=.blur は元画像全体を常に fill でぼかす

@Test("background=.blurは元画像全体をfillでぼかし、sigmaPxはキャンバス短辺に対する比になる")
func backgroundBlurUsesWholeSourceAndCanvasShortSide() throws {
    let spec = makeSpec(
        sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1),
        background: .blur(sigmaRatio: try BlurRatio(0.1))
    )
    let draft = try compileRenderDraft(spec: spec, sourceSize: makeSize(300, 200), targetSize: makeSize(100, 50))

    guard case let .blurFromSource(sourceRect, sigmaPx, scaleMode) = draft.background else {
        Issue.record("blurFromSource caseであるべき")
        return
    }
    #expect(sourceRect == PixelRect(left: 0, top: 0, rightExclusive: 300, bottomExclusive: 200))
    #expect(sigmaPx.value == 5.0)
    #expect(scaleMode == .fill)
}
