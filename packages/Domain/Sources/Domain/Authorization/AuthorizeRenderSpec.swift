import Foundation

// RenderSpec が使う能力を抽出し、現在の能力で許されるかを判定する純粋関数
// （export-saga.md 1.2「設定内容の能力」）。
//
// `StampCatalog` protocol / `StampRequirement` enum は Accounting/ExportAuthorization.swift
// に実装済みのためここでは再宣言しない。
//
// 判定表（export-saga.md 1.2 直後の表。この通りで判断の余地なし）:
//   - mosaic / blur / solid                         : 能力なし
//   - stamp(.builtIn) かつ requirement == .free       : 能力なし
//   - stamp(.builtIn) かつ requirement == .premium    : canUsePremiumStamps（enabledStampPacksは見ない）
//   - stamp(.custom)                                 : canUseCustomStamps
// `enabledStampPacks` は認可の判定に一切使わない（UI 選択では見るが authorizeRenderSpec は見ない）。
//
// 正本に明記が無く判断した点（確定済み）:
// 1. `stampCatalog.requirement(forBuiltIn:)` が nil（カタログに無い code）の場合は
//    `.blocked(.unknownBuiltInStampCode)` とする（test-plan.md 2.4「StampCatalog に無い code を
//    blocked へ倒し、無料扱いにしないこと」）。
// 2. `requirement` が `.custom` / `.unknownBuiltIn` を builtIn 経路の requirement として
//    返してきた場合（本来 custom スタンプ用の値が builtIn 経路に来た、カタログの取り違え）は
//    安全側に倒し `.unknownBuiltInStampCode` として扱う。
// 3. `spec.regions` を配列順に走査し、1件でも blocked な region があれば最初に見つかった
//    block reason を返す（複数該当時の優先順位は正本に明記が無いため regions の配列順を採用）。
//
// 免除ロジック（export-saga.md 1.2 直後の節）はここに実装しない。免除は Application 層が
// ExportedSettingsEntry 等の永続データを参照して判定するものであり、この関数のシグネチャ
// （spec, stampCatalog, capabilities の3引数）に免除用の引数は正本に存在しない。

public enum RenderSpecAuthorization: Sendable, Equatable {
    case authorized
    case blocked(RenderSpecBlockReason)
}

public enum RenderSpecBlockReason: Sendable, Equatable {
    case premiumStampNotAvailable      // canUsePremiumStamps == false
    case customStampNotAvailable       // canUseCustomStamps == false
    case unknownBuiltInStampCode       // カタログに無い code
}

public func authorizeRenderSpec(
    _ spec: RenderSpec,
    stampCatalog: StampCatalog,
    capabilities: ResolvedCapabilities
) -> RenderSpecAuthorization {
    for region in spec.regions {
        if let reason = blockReason(forOp: region.op, stampCatalog: stampCatalog, capabilities: capabilities) {
            return .blocked(reason)
        }
    }
    return .authorized
}

private func blockReason(
    forOp renderOp: RenderOpSpec,
    stampCatalog: StampCatalog,
    capabilities: ResolvedCapabilities
) -> RenderSpecBlockReason? {
    switch renderOp {
    case .mosaic, .blur, .solid:
        return nil
    case .stamp(.custom, _):
        return capabilities.canUseCustomStamps ? nil : .customStampNotAvailable
    case .stamp(.builtIn(let code), _):
        return blockReasonForBuiltIn(code: code, stampCatalog: stampCatalog, capabilities: capabilities)
    }
}

private func blockReasonForBuiltIn(
    code: String,
    stampCatalog: StampCatalog,
    capabilities: ResolvedCapabilities
) -> RenderSpecBlockReason? {
    guard let requirement = stampCatalog.requirement(forBuiltIn: code) else {
        // カタログに無い code。無料扱いにせず blocked へ倒す（test-plan.md 2.4）。
        return .unknownBuiltInStampCode
    }
    switch requirement {
    case .free:
        return nil
    case .premium:
        return capabilities.canUsePremiumStamps ? nil : .premiumStampNotAvailable
    case .custom, .unknownBuiltIn:
        // カタログの取り違え（custom スタンプ用の値が builtIn 経路に来た）。安全側に倒す。
        return .unknownBuiltInStampCode
    }
}
