import Foundation

// レンダリングのコンパイル純粋関数群（Task 7）。
//
// image-pipeline.md 1章「拡張率の適用」（expand）、2章「二段階コンパイル」
// （compileRenderDraft / bindRasterAssets）、4章「ピクセルへの丸め」「適用順」の規則を
// 実装する。丸め・適用順・stampKeys 重複排除・欠落 assets での throw は正本が定めるとおり、
// 正本にコードで明示されていない箇所（fit/fill の具体的な配置式）はオーケストレータが
// 確定した仕様として下記の各関数コメントに明記する。
//
// MARK: - expand（image-pipeline.md 1章「拡張率の適用」）

/// 4 方向の拡張比を矩形へ適用した生座標。image-pipeline.md 1 章の拡張式の唯一の実装で、
/// `expand(face:effect:)` と triage の境界判定（Triage.swift）が共有する
/// （別々に書くと将来の式変更で「隠す範囲」と「要確認判定」が食い違う）。
/// `NormalizedRect` にしないのは、拡張後は負数・1.0 超過を含む生の座標であることを
/// 型で区別するため。
struct ExpandedEdges {
    let left: Double
    let top: Double
    let right: Double
    let bottom: Double
}

func expandedEdges(
    of rect: NormalizedRect,
    top: Double,
    bottom: Double,
    leading: Double,
    trailing: Double
) -> ExpandedEdges {
    let width = rect.rightExclusive - rect.left
    let height = rect.bottomExclusive - rect.top
    return ExpandedEdges(
        left: rect.left - width * leading,
        top: rect.top - height * top,
        right: rect.rightExclusive + width * trailing,
        bottom: rect.bottomExclusive + height * bottom
    )
}

/// 顔矩形へ拡張率を適用する。画像外へはみ出す場合もクランプしない
/// （クランプすると顔が露出する方向へ倒れるため。はみ出しはマスク描画側で処理する）。
/// 拡張後の座標が `NormalizedRect` の上限（絶対値 16。image-pipeline.md 4 章）を超える場合は
/// `invalidRect` を throw する（クランプで黙って直さない。検出結果の顔（[0, 1]）に既定拡張率を
/// 適用する通常経路では起こらない。image-pipeline.md 1 章「拡張率の適用」）。
public func expand(face: NormalizedRect, effect: EffectSetting) throws -> NormalizedRect {
    let edges = expandedEdges(
        of: face,
        top: effect.expansion.top.value,
        bottom: effect.expansion.bottom.value,
        leading: effect.expansion.leading.value,
        trailing: effect.expansion.trailing.value
    )

    return try NormalizedRect(
        left: edges.left, top: edges.top, rightExclusive: edges.right, bottomExclusive: edges.bottom
    )
}

// MARK: - compileRenderDraft（image-pipeline.md 2章「二段階コンパイル」）

/// `RenderSpec`（正規化座標・相対強度）を、対象解像度における絶対ピクセル値のみを持つ
/// `RenderDraft` へコンパイルする。
public func compileRenderDraft(
    spec: RenderSpec,
    sourceSize: PixelSize,
    targetSize: PixelSize
) throws -> RenderDraft {
    guard sourceSize.width > 0, sourceSize.height > 0, targetSize.width > 0, targetSize.height > 0 else {
        throw RenderValidationError.invalidPixelSize
    }
    try validateSourceCropBounds(spec.sourceCrop)

    let canvasSize = targetSize
    let sourceRect = try pixelRect(from: spec.sourceCrop, in: sourceSize)
    let sourcePlacement = try makeSourcePlacement(
        sourceRect: sourceRect, canvasSize: canvasSize, scaleMode: spec.scaleMode
    )
    let background = try makeBackgroundOp(spec.background, sourceSize: sourceSize, canvasSize: canvasSize)

    var stampKeys: Set<StampRasterKey> = []
    var regions: [RenderRegionDraft] = []
    for (order, region) in orderedRegions(spec.regions).enumerated() {
        regions.append(try compileRegionDraft(region, canvasSize: canvasSize, order: order, stampKeys: &stampKeys))
    }

    return RenderDraft(
        canvasSize: canvasSize,
        sourcePlacement: sourcePlacement,
        background: background,
        regions: regions,
        stampKeys: stampKeys
    )
}

/// `sourceCrop` の不変条件（image-pipeline.md 2章「`sourceCrop` の不変条件」）。
/// 顔の拡張領域と違い、`sourceCrop` が元画像の外へ出る理由はない。クランプで黙って
/// 直さず throw する。
private func validateSourceCropBounds(_ crop: NormalizedRect) throws {
    guard crop.left >= 0.0, crop.rightExclusive <= 1.0, crop.top >= 0.0, crop.bottomExclusive <= 1.0 else {
        throw RenderValidationError.sourceCropOutOfBounds
    }
}

/// 適用順（image-pipeline.md 4章）: `auto`（自動検出）を先、`manual`（利用者追加）を後に
/// する。`filter` は要素の相対順序を保つため、各区分内で `RenderSpec.regions` の並び順が
/// 保たれる。
private func orderedRegions(_ regions: [RenderRegionSpec]) -> [RenderRegionSpec] {
    regions.filter { $0.origin == .auto } + regions.filter { $0.origin == .manual }
}

private func floorToInt(_ value: Double) -> Int { Int(value.rounded(.down)) }
private func ceilToInt(_ value: Double) -> Int { Int(value.rounded(.up)) }

/// `pixelRect` 専用の丸め済み `Int` 変換。丸め後の値が非有限（`NaN`/`±Infinity`）、または
/// `Int` の表現範囲を超える場合は `nil` を返す（`Int(exactly:)` の契約どおり）。
/// 同ファイル内の `floorToInt`/`ceilToInt`（非throwing、`fillSourceRect` 専用でスコープ外）
/// とは別名にして責務を分ける。
private func safeRoundedInt(_ value: Double, rule: FloatingPointRoundingRule) -> Int? {
    Int(exactly: value.rounded(rule))
}

/// `NormalizedRect` を `size` に対して絶対ピクセルへ変換する（image-pipeline.md 4章
/// 「ピクセルへの丸め」）。`left`/`top` は floor、`right`/`bottom` は ceil。領域が必ず
/// 外側へ広がる方向へ丸められる（内側へ丸めると顔の縁が露出しうるため）。
/// 変換結果が有限でない、または `Int` で表現できない場合は `invalidRect` を throw する
/// （極端な座標×解像度の積が `Double` のオーバーフローや `Int` 変換の trap になる経路を、
/// クラッシュではなく検証エラーとして返す）。
private func pixelRect(from rect: NormalizedRect, in size: PixelSize) throws -> PixelRect {
    guard let left = safeRoundedInt(rect.left * Double(size.width), rule: .down),
          let top = safeRoundedInt(rect.top * Double(size.height), rule: .down),
          let right = safeRoundedInt(rect.rightExclusive * Double(size.width), rule: .up),
          let bottom = safeRoundedInt(rect.bottomExclusive * Double(size.height), rule: .up) else {
        throw RenderValidationError.invalidRect
    }
    return PixelRect(left: left, top: top, rightExclusive: right, bottomExclusive: bottom)
}

/// 前景の配置（`SourcePlacement`）。配置規則は image-pipeline.md 2 章が正本。fit経路はthrows（`fitDestinationRect`参照）。
private func makeSourcePlacement(
    sourceRect: PixelRect,
    canvasSize: PixelSize,
    scaleMode: SourceScaleMode
) throws -> SourcePlacement {
    switch scaleMode {
    case .fill:
        // fill: 真の cover。destinationRect はキャンバス全面。sourceRect はそのまま使うと
        // sourceCrop とキャンバスの縦横比が異なる場合に非一様な引き伸ばしが起きるため、
        // キャンバス縦横比に合わせて中央で切り詰める（image-pipeline.md 2 章
        // 「SourcePlacement の配置規則」）。
        let destinationRect = PixelRect(
            left: 0, top: 0, rightExclusive: canvasSize.width, bottomExclusive: canvasSize.height
        )
        return SourcePlacement(
            sourceRect: fillSourceRect(sourceRect: sourceRect, canvasSize: canvasSize),
            destinationRect: destinationRect,
            scaleMode: .fill
        )
    case .fit:
        // fit: 縦横比を保ったままキャンバスへ収まる最大サイズへ縮小し、中央配置する。
        return SourcePlacement(
            sourceRect: sourceRect,
            destinationRect: try fitDestinationRect(sourceRect: sourceRect, canvasSize: canvasSize),
            scaleMode: .fit
        )
    }
}

/// fit の配置式（image-pipeline.md 2 章）。scale後の幅・高さを最近接整数へ丸め中央配置する。
/// 非有限/`Int`範囲外・加算overflowの可能性があるため `safeRoundedInt`/`addingChecked` で検証し `invalidRect` を throw。
private func fitDestinationRect(sourceRect: PixelRect, canvasSize: PixelSize) throws -> PixelRect {
    let sourceWidth = sourceRect.rightExclusive - sourceRect.left
    let sourceHeight = sourceRect.bottomExclusive - sourceRect.top
    let scale = min(
        Double(canvasSize.width) / Double(sourceWidth),
        Double(canvasSize.height) / Double(sourceHeight)
    )
    guard let scaledWidth = safeRoundedInt(Double(sourceWidth) * scale, rule: .toNearestOrAwayFromZero),
          let scaledHeight = safeRoundedInt(Double(sourceHeight) * scale, rule: .toNearestOrAwayFromZero) else {
        throw RenderValidationError.invalidRect
    }
    let left = (canvasSize.width - scaledWidth) / 2
    let top = (canvasSize.height - scaledHeight) / 2
    let right = try addingChecked(left, scaledWidth)
    let bottom = try addingChecked(top, scaledHeight)
    return PixelRect(left: left, top: top, rightExclusive: right, bottomExclusive: bottom)
}

/// fill（cover）用に `sourceRect` をキャンバス縦横比へ中央で切り詰める。`fitDestinationRect`
/// が fit の配置式を担うのに対し、こちらは fill の切り詰め式を担う。
/// 計算は元画像ピクセル空間の `Double` で行い、最終結果のみ `floorToInt`/`ceilToInt`
/// （4章「ピクセルへの丸め」と同じ外側へ広がる丸め）で `PixelRect` 化する。丸め後は入力
/// `sourceRect` の範囲へクランプし、縦横比がほぼ一致するケースの浮動小数点誤差で
/// 切り詰め結果が入力より広がらないことを保証する。
private func fillSourceRect(sourceRect: PixelRect, canvasSize: PixelSize) -> PixelRect {
    let sourceWidth = Double(sourceRect.rightExclusive - sourceRect.left)
    let sourceHeight = Double(sourceRect.bottomExclusive - sourceRect.top)
    let canvasAspect = Double(canvasSize.width) / Double(canvasSize.height)
    let sourceAspect = sourceWidth / sourceHeight

    let cropWidth: Double
    let cropHeight: Double
    if sourceAspect > canvasAspect {
        // source の方がキャンバスより横長 → 幅方向を切り詰める。
        cropHeight = sourceHeight
        cropWidth = sourceHeight * canvasAspect
    } else {
        // source の方がキャンバスより縦長（または同じ縦横比） → 高さ方向を切り詰める。
        cropWidth = sourceWidth
        cropHeight = sourceWidth / canvasAspect
    }

    let insetX = (sourceWidth - cropWidth) / 2
    let insetY = (sourceHeight - cropHeight) / 2
    let left = Double(sourceRect.left) + insetX
    let top = Double(sourceRect.top) + insetY

    // cropWidth/cropHeightが浮動小数点誤差でsourceWidth/sourceHeightをごくわずかに上回ると、
    // floor/ceil後のleft/topが負に、right/bottomがsourceRectの外にはみ出しうる。「中央で
    // 切り詰める」契約は出力が入力の部分集合であることを要求するため、その方向にのみ
    // クランプする（丸め方向floor/ceil自体はここでは変更しない）。
    let clampedLeft = max(floorToInt(left), sourceRect.left)
    let clampedTop = max(floorToInt(top), sourceRect.top)
    let clampedRight = min(ceilToInt(left + cropWidth), sourceRect.rightExclusive)
    let clampedBottom = min(ceilToInt(top + cropHeight), sourceRect.bottomExclusive)

    return PixelRect(
        left: clampedLeft,
        top: clampedTop,
        rightExclusive: clampedRight,
        bottomExclusive: clampedBottom
    )
}

/// 背景の変換（`BackgroundSpec` → `BackgroundOp`）。`.blur` は正本 L266「一般的な用途では
/// sourceRect に元画像全体を指定し、fill でキャンバス全面へ拡大します」に従い、
/// `sourceRect` は元画像全体・`scaleMode` は常に `.fill`（前景の `spec.scaleMode` に関わらず）。
/// `sigmaPx` は「キャンバス短辺に対する比」（image-pipeline.md 2章コメント）。
private func makeBackgroundOp(
    _ background: BackgroundSpec,
    sourceSize: PixelSize,
    canvasSize: PixelSize
) throws -> BackgroundOp {
    switch background {
    case .none:
        return .none
    case .solid(let color):
        return .solid(color: color)
    case .blur(let sigmaRatio):
        let shortSide = min(canvasSize.width, canvasSize.height)
        let sigmaPx = try SigmaPx(sigmaRatio.value * Double(shortSide))
        let wholeSourceRect = PixelRect(
            left: 0, top: 0, rightExclusive: sourceSize.width, bottomExclusive: sourceSize.height
        )
        return .blurFromSource(sourceRect: wholeSourceRect, sigmaPx: sigmaPx, scaleMode: .fill)
    }
}

/// `Int` の checked 二項演算共通部。overflowならtrapではなく`invalidRect`をthrow（`subtractingChecked`/`addingChecked`が使用）。
private func checkedInt(_ result: (partialValue: Int, overflow: Bool)) throws -> Int {
    guard !result.overflow else {
        throw RenderValidationError.invalidRect
    }
    return result.partialValue
}

/// `pixelRect` は `left`/`rightExclusive` 等を個別に Int 範囲内と検証済みだが、正負反対側の
/// 極端な値の組み合わせでは差分自体が範囲を超えうるため checked 減算を使う。
private func subtractingChecked(_ minuend: Int, _ subtrahend: Int) throws -> Int {
    try checkedInt(minuend.subtractingReportingOverflow(subtrahend))
}

/// `fitDestinationRect` の destinationRect 計算（`left + scaledWidth` 等）で使う checked 加算。
private func addingChecked(_ augend: Int, _ addend: Int) throws -> Int {
    try checkedInt(augend.addingReportingOverflow(addend))
}

private func compileRegionDraft(
    _ region: RenderRegionSpec,
    canvasSize: PixelSize,
    order: Int,
    stampKeys: inout Set<StampRasterKey>
) throws -> RenderRegionDraft {
    let boundsPx = try pixelRect(from: region.bounds, in: canvasSize)
    let regionWidth = try subtractingChecked(boundsPx.rightExclusive, boundsPx.left)
    let regionHeight = try subtractingChecked(boundsPx.bottomExclusive, boundsPx.top)
    let shortSide = min(regionWidth, regionHeight)
    // featherPx は「領域短辺に対する比」（image-pipeline.md 2章コメント）。
    let featherPx = try FeatherPx(region.featherRatio.value * Double(shortSide))
    let opDraft = try makeOpDraft(
        region.op,
        shortSide: shortSide,
        regionWidth: regionWidth,
        regionHeight: regionHeight,
        stampKeys: &stampKeys
    )

    return RenderRegionDraft(
        bounds: boundsPx,
        rotationDegrees: region.rotationDegrees,
        shape: region.shape,
        featherPx: featherPx,
        order: order,
        op: opDraft
    )
}

private func makeOpDraft(
    _ op: RenderOpSpec,
    shortSide: Int,
    regionWidth: Int,
    regionHeight: Int,
    stampKeys: inout Set<StampRasterKey>
) throws -> RenderOpDraft {
    switch op {
    case .mosaic(let cellRatio):
        return .mosaic(cellSizePx: try makeCellSizePx(cellRatio: cellRatio, shortSide: shortSide))
    case .blur(let sigmaRatio):
        return .blur(sigmaPx: try SigmaPx(sigmaRatio.value * Double(shortSide)))
    case .solid(let color, let opacity):
        return .solid(color: color, opacity: opacity)
    case .stamp(let source, let opacity):
        let key = StampRasterKey(source: source, rasterSize: PixelSize(width: regionWidth, height: regionHeight))
        stampKeys.insert(key)
        return .stamp(key: key, opacity: opacity)
    }
}

/// `cellSizePx = max(2, floor(cellRatio * shortSide))`（image-pipeline.md 3章）。
/// 引き上げても領域が 2px 未満なら隠せないため throw する。
private func makeCellSizePx(cellRatio: MosaicRatio, shortSide: Int) throws -> CellSizePx {
    guard shortSide >= 2 else {
        throw RenderValidationError.invalidCellSize
    }
    let raw = Int((cellRatio.value * Double(shortSide)).rounded(.down))
    let clamped = max(2, raw)
    return try CellSizePx(clamped)
}

// MARK: - bindRasterAssets（image-pipeline.md 2章「二段階コンパイル」）

/// `RenderDraft` のスタンプ実体を束ねて `RenderPlan` にする（第2段階）。
/// `draft.stampKeys` に対応する `assets` が1件でも欠けていれば throw する。
public func bindRasterAssets(
    draft: RenderDraft,
    assets: [StampRasterKey: RasterizedStampAsset]
) throws -> RenderPlan {
    guard draft.stampKeys.allSatisfy({ assets[$0] != nil }) else {
        throw RenderValidationError.unresolvedStampAsset
    }

    let regions = try draft.regions.map { regionDraft in
        RenderRegion(
            bounds: regionDraft.bounds,
            rotationDegrees: regionDraft.rotationDegrees,
            shape: regionDraft.shape,
            featherPx: regionDraft.featherPx,
            order: regionDraft.order,
            op: try resolveOp(regionDraft.op, assets: assets)
        )
    }

    return RenderPlan(
        canvasSize: draft.canvasSize,
        sourcePlacement: draft.sourcePlacement,
        background: draft.background,
        regions: regions
    )
}

/// `RenderDraft` は `public init` を公開しており、`compileRenderDraft` を経由しない
/// 不整合な入力（`stampKeys` に含まれない `.stamp` op を持つ `regions`）を呼び出し元が
/// 構築できてしまう。`bindRasterAssets` の外側 guard は `draft.stampKeys` 基準のため、
/// そのケースをすり抜けうる。回復不能な `preconditionFailure` ではなく、他の不変条件違反と
/// 同じ `throw` で扱う。
private func resolveOp(_ op: RenderOpDraft, assets: [StampRasterKey: RasterizedStampAsset]) throws -> RenderOp {
    switch op {
    case .mosaic(let cellSizePx):
        return .mosaic(cellSizePx: cellSizePx)
    case .blur(let sigmaPx):
        return .blur(sigmaPx: sigmaPx)
    case .solid(let color, let opacity):
        return .solid(color: color, opacity: opacity)
    case .stamp(let key, let opacity):
        guard let asset = assets[key] else {
            throw RenderValidationError.unresolvedStampAsset
        }
        return .stamp(bitmapID: asset.bitmapID, opacity: opacity)
    }
}
