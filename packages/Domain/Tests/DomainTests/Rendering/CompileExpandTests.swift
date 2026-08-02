import Testing
@testable import Domain
import Foundation

// Task: expand(face:effect:) のthrows化（image-pipeline.md 1章「拡張率の適用」）。
//
// NormalizedRectへ座標絶対値16以下の構造的上限を導入したことに伴い、expand内部のtry!が
// 拡張後座標が絶対値16を超える極端な入力でtrapする回帰が発生していた（reviewer Critical
// 指摘）。正本93行目「拡張後の座標がNormalizedRectの上限（絶対値16。4章）を超える場合は
// invalidRectをthrowします（クランプで黙って直さない）」に従いexpandをthrows化した後の
// 挙動を検証する。
//
// makeRect/makeSizeはCompileTests.swiftで定義されたinternal関数を共有する
// （同一テストターゲット内のため参照可能）。swiftlint file_length(400行)対応のため
// CompileTests.swiftから分割している（CompilePixelRectTests.swift等と同じ理由）。

// MARK: - 1. 通常経路: 検出結果の顔([0,1])へ既定拡張率(上25%/下15%/左右15%)を適用しても成功する

@Test("expandは検出結果の顔に既定拡張率(上25%/下15%/左右15%)を適用してもinvalidRectをthrowしない")
func expandSucceedsForDetectedFaceWithDefaultExpansionRatios() throws {
    // 検出結果の顔相当。幅0.5・高さ0.5（いずれも2進で厳密に表現できる値）。
    let face = try makeRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)
    let expansion = ExpansionRatios(
        top: try ExpansionRatio(0.25),
        bottom: try ExpansionRatio(0.15),
        leading: try ExpansionRatio(0.15),
        trailing: try ExpansionRatio(0.15)
    )
    let effect = EffectSetting(
        op: .solid(color: try VisibleColor(0xFFFF_FFFF), opacity: try EffectOpacity(1.0)),
        shape: .rectangle,
        featherRatio: try FeatherRatio(0.0),
        expansion: expansion
    )

    let expanded = try expand(face: face, effect: effect)

    #expect(expanded.left < expanded.rightExclusive)
    #expect(expanded.top < expanded.bottomExclusive)
}

// MARK: - 2. 上限超過経路: 拡張後座標が絶対値16を超えるとinvalidRectをthrowする

@Test("expandは拡張後座標が絶対値16を超えるとinvalidRectをthrowする")
func expandThrowsInvalidRectWhenExpandedCoordinateExceedsSixteen() throws {
    // width = 8 - (-8) = 16（2進で厳密）。trailing拡張率の上限2.0を掛けると
    // right = 8 + 16*2.0 = 40 となりNormalizedRectの絶対値上限16を超える。
    let face = try makeRect(left: -8.0, top: 0.0, right: 8.0, bottom: 1.0)
    let expansion = ExpansionRatios(
        top: try ExpansionRatio(0.0),
        bottom: try ExpansionRatio(0.0),
        leading: try ExpansionRatio(0.0),
        trailing: try ExpansionRatio(2.0)
    )
    let effect = EffectSetting(
        op: .solid(color: try VisibleColor(0xFFFF_FFFF), opacity: try EffectOpacity(1.0)),
        shape: .rectangle,
        featherRatio: try FeatherRatio(0.0),
        expansion: expansion
    )

    #expect(throws: RenderValidationError.invalidRect) {
        try expand(face: face, effect: effect)
    }
}
