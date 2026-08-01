import Foundation

// コンパイル済みの命令型群（image-pipeline.md 2 章「RenderSpec / RenderDraft /
// RenderPlan」）。
//
// 「一段階では依存が循環するため、コンパイルを 2 つに分ける」（image-pipeline.md 2 章
// 「二段階コンパイル」）方針に従い、このファイルには以下の 2 段階を置く。
//   第1段階: RenderDraft（解像度は確定したが、スタンプ実体はまだ束ねていない）
//   第2段階: RenderPlan（ラスタ実体を束ねた最終形）
// いずれも絶対ピクセル値のみを持つ（正規化座標を持たない）。
// `compileRenderDraft` / `bindRasterAssets` 関数本体は Task 7 の担当のためここには置かない。

/// スタンプのラスタ実体を引くためのキー。`rasterSize` は対象解像度における領域の
/// ピクセル寸法から決まる（image-pipeline.md 2 章）。
public struct StampRasterKey: Sendable, Hashable {
    public let source: StampSource
    public let rasterSize: PixelSize

    public init(source: StampSource, rasterSize: PixelSize) {
        self.source = source
        self.rasterSize = rasterSize
    }
}

/// 第1段階: 解像度は確定したが、スタンプ実体はまだ束ねていない（image-pipeline.md 2 章）。
public struct RenderDraft: Sendable {
    public let canvasSize: PixelSize
    public let sourcePlacement: SourcePlacement
    public let background: BackgroundOp
    public let regions: [RenderRegionDraft]
    public let stampKeys: Set<StampRasterKey>   // rasterSize 算出済み。重複排除済み

    public init(
        canvasSize: PixelSize,
        sourcePlacement: SourcePlacement,
        background: BackgroundOp,
        regions: [RenderRegionDraft],
        stampKeys: Set<StampRasterKey>
    ) {
        self.canvasSize = canvasSize
        self.sourcePlacement = sourcePlacement
        self.background = background
        self.regions = regions
        self.stampKeys = stampKeys
    }
}

/// RenderRegion との違いは op だけ。bitmapID の代わりに StampRasterKey を持つ
/// （image-pipeline.md 2 章）。
public struct RenderRegionDraft: Sendable {
    public let bounds: PixelRect
    public let rotationDegrees: RotationDegrees
    public let shape: MaskShape
    public let featherPx: FeatherPx
    public let order: Int
    public let op: RenderOpDraft

    public init(
        bounds: PixelRect,
        rotationDegrees: RotationDegrees,
        shape: MaskShape,
        featherPx: FeatherPx,
        order: Int,
        op: RenderOpDraft
    ) {
        self.bounds = bounds
        self.rotationDegrees = rotationDegrees
        self.shape = shape
        self.featherPx = featherPx
        self.order = order
        self.op = op
    }
}

/// 第1段階のエフェクト種別。スタンプは `StampRasterKey` で未解決のまま持つ。
public enum RenderOpDraft: Sendable {
    case mosaic(cellSizePx: CellSizePx)
    case blur(sigmaPx: SigmaPx)
    case solid(color: VisibleColor, opacity: EffectOpacity)
    case stamp(key: StampRasterKey, opacity: EffectOpacity)
}

/// 特定解像度へコンパイル済み。絶対ピクセル値のみを持つ（image-pipeline.md 2 章）。
public struct RenderPlan: Sendable {
    public let canvasSize: PixelSize
    public let sourcePlacement: SourcePlacement
    public let background: BackgroundOp
    public let regions: [RenderRegion]

    public init(
        canvasSize: PixelSize,
        sourcePlacement: SourcePlacement,
        background: BackgroundOp,
        regions: [RenderRegion]
    ) {
        self.canvasSize = canvasSize
        self.sourcePlacement = sourcePlacement
        self.background = background
        self.regions = regions
    }
}

/// 元画像のどこを使い、キャンバス上のどこへ置くか（image-pipeline.md 2 章「合成の契約」）。
public struct SourcePlacement: Sendable {
    public let sourceRect: PixelRect            // 元画像のどこを使うか（元画像のピクセル）
    public let destinationRect: PixelRect       // キャンバス上のどこへ置くか
    public let scaleMode: SourceScaleMode

    public init(sourceRect: PixelRect, destinationRect: PixelRect, scaleMode: SourceScaleMode) {
        self.sourceRect = sourceRect
        self.destinationRect = destinationRect
        self.scaleMode = scaleMode
    }
}

/// コンパイル済みの顔単位領域。`bounds` は出力キャンバス基準の絶対ピクセル
/// （image-pipeline.md 2 章「合成の契約」）。
public struct RenderRegion: Sendable {
    public let bounds: PixelRect                // 出力キャンバス基準の絶対ピクセル
    public let rotationDegrees: RotationDegrees
    public let shape: MaskShape
    public let featherPx: FeatherPx
    public let order: Int                       // 描画順（4 章）
    public let op: RenderOp

    public init(
        bounds: PixelRect,
        rotationDegrees: RotationDegrees,
        shape: MaskShape,
        featherPx: FeatherPx,
        order: Int,
        op: RenderOp
    ) {
        self.bounds = bounds
        self.rotationDegrees = rotationDegrees
        self.shape = shape
        self.featherPx = featherPx
        self.order = order
        self.op = op
    }
}

/// 第2段階のエフェクト種別。スタンプは `bitmapID` に解決済み。
public enum RenderOp: Sendable {
    case mosaic(cellSizePx: CellSizePx)
    case blur(sigmaPx: SigmaPx)
    case solid(color: VisibleColor, opacity: EffectOpacity)
    case stamp(bitmapID: String, opacity: EffectOpacity)
}

/// キャンバス余白の埋め方。`blurFromSource` は「元画像全体をぼかすのか、切り抜き範囲を
/// ぼかすのか、どの倍率で敷くのか」を明示する（image-pipeline.md 2 章）。
public enum BackgroundOp: Sendable {
    case none

    /// 何をどうぼかして背景へ敷くかを明示する
    case blurFromSource(
        sourceRect: PixelRect,           // 元画像のピクセル
        sigmaPx: SigmaPx,
        scaleMode: SourceScaleMode
    )

    case solid(color: VisibleColor)
}
