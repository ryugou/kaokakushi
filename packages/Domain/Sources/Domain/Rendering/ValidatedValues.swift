import Foundation

// レンダリング境界の検証済み値型群（image-pipeline.md 2 章「RenderSpec / RenderDraft /
// RenderPlan」）。
//
// 「検証済みの値型としてしか作れないようにし、モデルの側も生の Double を持たない」
// （image-pipeline.md 2 章）という方針に従い、throws init 以外に生値から構築する経路を
// 持たせない。パラメータ名は正本の `v` を SwiftLint の識別子長制約（3 文字以上）のため
// `rawValue` へ変更している（外部ラベルは `_` のままなので呼び出し構文は変わらない。
// 値の意味・検証内容は正本と同一）。

/// ドメイン独自のピクセル寸法型。CGSize を使わない（image-pipeline.md 2 章）。
/// 検証なし: 正本コードブロックに throws init が無いため型に検証を追加していない
/// （設計判断ではなく正本一字一句一致の帰結）。値域（width > 0 かつ height > 0）を
/// 強制する主体は正本で未定義。compileRenderDraft（Task 7）は sourceSize/targetSize を
/// そこで検証すると見込まれるが、ImageSource.pixelSize／DetectionResult.detectionPixelSize／
/// RawBitmapDescriptor.pixelSize はアダプタ生成で compileRenderDraft を通らず未検証のまま
/// （invalidPixelSize は現時点で未使用）。
public struct PixelSize: Sendable, Hashable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// コンパイル済みの絶対ピクセル矩形（image-pipeline.md 2 章）。
/// `rightExclusive` / `bottomExclusive` は名前で排他性を示す。
/// 検証なし: 正本コードブロックに throws init が無いため型に検証を追加していない
/// （設計判断ではなく正本一字一句一致の帰結）。値域強制（left < rightExclusive 等）は
/// Task 7 の compileRenderDraft の責務。
public struct PixelRect: Sendable, Equatable {
    public let left: Int
    public let top: Int
    public let rightExclusive: Int
    public let bottomExclusive: Int

    public init(left: Int, top: Int, rightExclusive: Int, bottomExclusive: Int) {
        self.left = left
        self.top = top
        self.rightExclusive = rightExclusive
        self.bottomExclusive = bottomExclusive
    }
}

/// 検証済み値型の throws init が投げるエラー（image-pipeline.md 2 章）。
/// 12 ケース全てを転記する。`invalidPixelSize` / `emptyRegion` / `unresolvedStampAsset` /
/// `sourceCropOutOfBounds` は Task 2 時点では未使用だが、正本のコードブロック全体を
/// 転記する対象のため宣言のみ行う。
public enum RenderValidationError: Error, Sendable, Equatable {
    case invalidOpacity
    case invalidRatio
    case invalidCornerRatio
    case invalidPixelSize
    case invalidRect
    case invalidCellSize
    case invalidSigma
    case invalidFeather
    case nonVisibleColor
    case emptyRegion
    case unresolvedStampAsset
    case sourceCropOutOfBounds
}

/// エフェクト全体の適用強度。0 は「完全に透明」＝何も隠さないため範囲に含めない。
public struct EffectOpacity: Sendable, Equatable {
    public let value: Double

    public init(_ value: Double) throws {
        guard value.isFinite, value > 0, value <= 1 else {
            throw RenderValidationError.invalidOpacity
        }
        self.value = value
    }
}

// MosaicRatio と BlurRatio は「領域短辺に対する比。(0, 0.5]」という同じ制約を共有する。
// 検証を1箇所にし、片方だけ範囲を変えて他方を直し忘れる事故を防ぐ。
private func validatedShortSideRatio(_ rawValue: Double) throws -> Double {
    guard rawValue.isFinite, rawValue > 0, rawValue <= 0.5 else {
        throw RenderValidationError.invalidRatio
    }
    return rawValue
}

/// モザイクのセル比（領域短辺に対する比）。
public struct MosaicRatio: Sendable, Hashable {
    public let value: Double

    public init(_ rawValue: Double) throws {
        self.value = try validatedShortSideRatio(rawValue)
    }
}

/// ぼかしの σ 比（領域短辺に対する比）。
public struct BlurRatio: Sendable, Hashable {
    public let value: Double

    public init(_ rawValue: Double) throws {
        self.value = try validatedShortSideRatio(rawValue)
    }
}

/// フェザーの比（領域短辺に対する比）。0 を許す。
public struct FeatherRatio: Sendable, Hashable {
    public let value: Double

    public init(_ rawValue: Double) throws {
        guard rawValue.isFinite, rawValue >= 0, rawValue <= 0.5 else {
            throw RenderValidationError.invalidRatio
        }
        self.value = rawValue
    }
}

/// 顔矩形からの拡張率（仕様 8.4）。
public struct ExpansionRatio: Sendable, Hashable {
    public let value: Double

    public init(_ rawValue: Double) throws {
        guard rawValue.isFinite, rawValue >= 0, rawValue <= 2.0 else {
            throw RenderValidationError.invalidRatio
        }
        self.value = rawValue
    }
}

/// 顔矩形からの拡張率（仕様 8.4）。上下左右で個別に持つ。
/// 検証なし: コンポーネント（ExpansionRatio）が既に検証済みのため追加検証は行わない。
public struct ExpansionRatios: Sendable, Hashable {
    public let top: ExpansionRatio
    public let bottom: ExpansionRatio
    public let leading: ExpansionRatio
    public let trailing: ExpansionRatio

    public init(top: ExpansionRatio, bottom: ExpansionRatio, leading: ExpansionRatio, trailing: ExpansionRatio) {
        self.top = top
        self.bottom = bottom
        self.leading = leading
        self.trailing = trailing
    }
}

/// 領域の回転角。`[-180, 180)` へ正規化して保持する（image-pipeline.md 2 章・4 章）。
public struct RotationDegrees: Sendable, Hashable {
    public let value: Double   // 正規化済み、[-180, 180)

    public init(_ rawValue: Double) throws {
        guard rawValue.isFinite else { throw RenderValidationError.invalidRatio }
        var normalized = rawValue.truncatingRemainder(dividingBy: 360)
        if normalized < -180 {
            normalized += 360
        } else if normalized >= 180 {
            normalized -= 360
        }
        self.value = normalized
    }
}

/// ガウスぼかしの σ（ピクセル）。格子整列が不要なため Double のまま持つ。
public struct SigmaPx: Sendable, Hashable {
    public let value: Double

    public init(_ rawValue: Double) throws {
        guard rawValue.isFinite, rawValue > 0 else { throw RenderValidationError.invalidSigma }
        self.value = rawValue
    }
}

/// フェザーの幅（ピクセル）。格子整列が不要なため Double のまま持つ。
public struct FeatherPx: Sendable, Hashable {
    public let value: Double

    public init(_ rawValue: Double) throws {
        guard rawValue.isFinite, rawValue >= 0 else { throw RenderValidationError.invalidFeather }
        self.value = rawValue
    }
}

/// モザイクのセルサイズ（ピクセル）。ピクセル格子に整列するため Int（image-pipeline.md 2 章）。
/// 下限 2 は「1px モザイク＝原画」を構造的に禁じる。
public struct CellSizePx: Sendable, Hashable {
    public let value: Int

    public init(_ rawValue: Int) throws {
        guard rawValue >= 2 else { throw RenderValidationError.invalidCellSize }
        self.value = rawValue
    }
}

/// 角丸の半径。領域短辺に対する比。
public struct CornerRatio: Sendable, Hashable {
    public let value: Double

    public init(_ value: Double) throws {
        guard value.isFinite, value > 0, value <= 0.5 else {
            throw RenderValidationError.invalidCornerRatio
        }
        self.value = value
    }
}

/// 元画像またはキャンバスに対する正規化矩形。左上原点（image-pipeline.md 4 章）。
/// `left` / `top` は inclusive、`right` / `bottom` は exclusive。
/// 画像外へのはみ出し（負数・1.0 超過）は許すが、各座標の絶対値は 16 以下に制限する
/// （image-pipeline.md 4 章「NormalizedRect」節。拡張率 2.0 でも正当な値は [-2, 3] に
/// 収まるため、16 は十分な余裕を持った構造的上限であり、超過は不正な入力とみなす）。
public struct NormalizedRect: Sendable, Hashable {
    public let left: Double
    public let top: Double
    public let rightExclusive: Double
    public let bottomExclusive: Double

    public init(left: Double, top: Double, rightExclusive: Double, bottomExclusive: Double) throws {
        guard left.isFinite, top.isFinite, rightExclusive.isFinite, bottomExclusive.isFinite,
              left < rightExclusive, top < bottomExclusive else {
            throw RenderValidationError.invalidRect
        }
        guard abs(left) <= 16, abs(top) <= 16, abs(rightExclusive) <= 16, abs(bottomExclusive) <= 16 else {
            throw RenderValidationError.invalidRect
        }
        self.left = left
        self.top = top
        self.rightExclusive = rightExclusive
        self.bottomExclusive = bottomExclusive
    }
}

/// sRGB の straight alpha 色。`0xAARRGGBB`（image-pipeline.md 4 章）。
/// アルファ（上位 8 bit）が 0 なら「完全に透明」＝何も隠さないため throw する。
public struct SrgbArgb8888: Sendable, Hashable {
    public let value: UInt32   // 0xAARRGGBB

    public init(_ rawValue: UInt32) throws {
        guard (rawValue >> 24) & 0xFF > 0 else { throw RenderValidationError.nonVisibleColor }
        self.value = rawValue
    }
}

/// RenderOpSpec / BackgroundSpec が使う色。別の型を作らない（image-pipeline.md 4 章）。
public typealias VisibleColor = SrgbArgb8888
