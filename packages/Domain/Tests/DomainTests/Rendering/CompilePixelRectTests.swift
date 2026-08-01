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

// MARK: - 1. region.bounds経路: 座標自体を極端にして積がDoubleの範囲を超え非有限になる

@Test("compileRenderDraftはregion.bounds×canvasSizeの積が非有限だとinvalidRectをthrowする")
func compileRenderDraftThrowsInvalidRectWhenRegionBoundsIsNonFinite() throws {
    // region.boundsはsourceCropと違い0.0〜1.0への範囲制約を受けない（NormalizedRect.init
    // は有限性とleft<right/top<bottomのみ検証）。1.5e308（Double.greatestFiniteMagnitude
    // 未満で有効）× canvasSize.width(100) は Double の最大有限値を超え +infinity になる。
    let region = try makeRegion(bounds: try makeRect(left: 1.5e308, top: 0.0, right: 1.6e308, bottom: 1.0))
    let spec = makeSpec(sourceCrop: try makeRect(left: 0, top: 0, right: 1, bottom: 1), regions: [region])
    #expect(throws: RenderValidationError.invalidRect) {
        try compileRenderDraft(spec: spec, sourceSize: makeSize(100, 100), targetSize: makeSize(100, 100))
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
