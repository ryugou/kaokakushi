import Testing
@testable import Domain
import Foundation

// Task: pixelRectの有限性/Int範囲ガード（image-pipeline.md 4章「ピクセルへの丸め」）。
//
// 正本: 「変換結果が有限でない、またはIntで表現できない場合はcompileRenderDraftが
// invalidRectをthrowします（極端な座標×解像度の積がDoubleのオーバーフローやInt変換の
// trapになる経路を、クラッシュではなく検証エラーとして返す）」を検証する。
//
// makeSize/makeRect/makeSpecはCompileTests.swiftで定義されたinternal関数を共有する
// （同一テストターゲット内のため参照可能）。makeSolidRegionはCompileTests.swift内で
// privateのためここでは使わず、RenderRegionSpecを直接構築する。

private func makeRegion(bounds: NormalizedRect) throws -> RenderRegionSpec {
    RenderRegionSpec(
        bounds: bounds,
        rotationDegrees: try RotationDegrees(0),
        shape: .rectangle,
        featherRatio: try FeatherRatio(0.0),
        origin: .auto,
        op: .solid(color: try VisibleColor(0xFF00_0001), opacity: try EffectOpacity(1.0))
    )
}

// MARK: - 1. region.bounds経路(floor側): 座標は16以下、canvasSize側をInt.maxにしてInt範囲外にする

@Test("compileRenderDraftはregion.bounds(floor側)×canvasSizeの積がInt範囲外だとinvalidRectをthrowする")
func compileRenderDraftThrowsInvalidRectWhenRegionBoundsFloorOverflowsInt() throws {
    // NormalizedRectの絶対値上限（16）導入後は、座標自体を極端にしてDoubleの積を
    // 非有限にする経路は構築できない（16超はinit段階でinvalidRectになりpixelRectへ
    // 到達しない）。座標は16以下に保ち、canvasSize.width(Int.max)によりfloor(left)側の
    // 積がInt64表現範囲を超えることでpixelRectのInt変換ガードに到達させる。
    let region = try makeRegion(bounds: try makeRect(left: -16.0, top: 0.0, right: 16.0, bottom: 1.0))
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1), regions: [region])
    #expect(throws: RenderValidationError.invalidRect) {
        try compileRenderDraft(spec: spec, sourceSize: makeSize(100, 100), targetSize: makeSize(Int.max, 100))
    }
}

// MARK: - 2. sourceCrop経路: 積は有限だがIntで表現できない

@Test("compileRenderDraftはsourceCrop×sourceSizeの積が有限だがInt範囲外だとinvalidRectをthrowする")
func compileRenderDraftThrowsInvalidRectWhenSourceRectOverflowsInt() throws {
    // sourceCropはvalidateSourceCropBoundsで0.0〜1.0に制約されるため、極端値はsourceSize
    // 側に置く。Double(Int.max)はInt64の52bit仮数部での丸めにより2^63(9223372036854775808.0)
    // へ切り上がり、これ自体は有限値だがInt64.max(2^63-1)を1超える。sourceCrop右端=1.0との
    // 積はこの2^63をそのまま返す（ceilしても整数値なので不変）ため、有限だがInt変換できない。
    let spec = makeSpec(sourceCrop: try makeRect(left: 0.0, top: 0.0, right: 1.0, bottom: 1.0))
    let extremeSourceSize = makeSize(Int.max, Int.max)
    #expect(throws: RenderValidationError.invalidRect) {
        try compileRenderDraft(spec: spec, sourceSize: extremeSourceSize, targetSize: makeSize(100, 100))
    }
}

// MARK: - 3. region.bounds経路: 積は有限だがIntで表現できない（sourceCrop以外の経路でも同じ保護が効く）

@Test("compileRenderDraftはregion.bounds×canvasSizeの積が有限だがInt範囲外だとinvalidRectをthrowする")
func compileRenderDraftThrowsInvalidRectWhenRegionBoundsOverflowsInt() throws {
    // canvasSize(targetSize)側をInt.maxにし、region.boundsは通常範囲(0.0〜1.0)のまま使う。
    // ceil(1.0 * Double(Int.max)) は上のテストと同じ理由で 2^63 になり、Int64.max を
    // 1超えるため有限だがInt変換できない。
    let region = try makeRegion(bounds: try makeRect(left: 0.0, top: 0.0, right: 1.0, bottom: 1.0))
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1), regions: [region])
    #expect(throws: RenderValidationError.invalidRect) {
        try compileRenderDraft(spec: spec, sourceSize: makeSize(100, 100), targetSize: makeSize(Int.max, 100))
    }
}

// MARK: - 4. regionWidthの減算自体がInt64表現範囲を超えてオーバーフローする

@Test("compileRenderDraftはregionWidthの減算がオーバーフローするとinvalidRectをthrowする")
func compileRenderDraftThrowsInvalidRectWhenRegionWidthSubtractionOverflows() throws {
    // pixelRect自体は各フィールド(left/right)を個別にInt範囲内と検証済みで通過するが、
    // 正負反対側の極端な値の組み合わせでは差分(regionWidth)自体がInt64の表現範囲を
    // 超えうる。coordは16以下(絶対値8)に保ちwidthを800000000000000000にすることで、
    // left(=floor(-8*width))とright(=ceil(8*width))はそれぞれ単独ではInt64に収まるが
    // (約6.4e18 < Int64.max約9.223e18)、right - left(約1.28e19)はInt64.maxを超える。
    let bounds = try makeRect(left: -8.0, top: 0.0, right: 8.0, bottom: 1.0)
    let region = try makeRegion(bounds: bounds)
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1), regions: [region])
    let hugeCanvasSize = makeSize(800_000_000_000_000_000, 100)
    #expect(throws: RenderValidationError.invalidRect) {
        try compileRenderDraft(spec: spec, sourceSize: makeSize(100, 100), targetSize: hugeCanvasSize)
    }
}
