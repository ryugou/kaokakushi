import Foundation

// 永続化・編集対象の記述型群（image-pipeline.md 2 章「RenderSpec / RenderDraft /
// RenderPlan」）。
//
// 「記述（RenderSpec）とコンパイル済み命令（RenderPlan）を分ける」方針（image-pipeline.md
// 2 章）に従い、このファイルの型は解像度非依存（正規化座標・相対強度）のまま持つ。
// 絶対ピクセル値を持つコンパイル済み型は RenderPlan.swift に置く。

/// 角丸の半径（CornerRatio）を除き、マスク形状を列挙する。
public enum MaskShape: Sendable, Hashable {
    case ellipse
    case circle
    case rectangle
    case rounded(cornerRatio: CornerRatio)
}

/// 描画順の決定に使う領域の由来（image-pipeline.md 4 章「適用順」）。
public enum RegionOrigin: Sendable, Hashable {
    case auto      // Vision による検出
    case manual    // 利用者が追加した領域
}

/// 組み込みスタンプとカスタムスタンプを文字列で混ぜない（image-pipeline.md 2 章）。
public enum StampSource: Sendable, Hashable {
    case builtIn(code: String)
    case custom(assetHash: StampAssetHash)   // 32 バイト固定（正準スキーマ 5.3）
}

/// Fit か Fill か。
public enum SourceScaleMode: Sendable, Hashable {
    case fit
    case fill
}

/// 領域単位のエフェクト種別。相対強度（比）のまま保持する。
public enum RenderOpSpec: Sendable, Equatable {
    case mosaic(cellRatio: MosaicRatio)                   // 領域短辺に対するセル比
    case blur(sigmaRatio: BlurRatio)                      // 領域短辺に対する σ 比
    case solid(color: VisibleColor, opacity: EffectOpacity)
    case stamp(source: StampSource, opacity: EffectOpacity)
}

/// キャンバス余白の埋め方。相対強度（比）のまま保持する。
public enum BackgroundSpec: Sendable, Equatable {
    case none
    case blur(sigmaRatio: BlurRatio)                      // キャンバス短辺に対する比
    case solid(color: VisibleColor)
}

/// 顔単位の隠し方。正規化座標のまま保持する。
public struct RenderRegionSpec: Sendable, Equatable {
    public let bounds: NormalizedRect           // 拡張率適用済み。出力キャンバス基準（4 章）
    public let rotationDegrees: RotationDegrees
    public let shape: MaskShape                 // ellipse / circle / rectangle / rounded(cornerRatio)
    public let featherRatio: FeatherRatio       // 領域短辺に対する比。0 を許す
    public let origin: RegionOrigin             // auto / manual（描画順に使う）
    public let op: RenderOpSpec

    public init(
        bounds: NormalizedRect,
        rotationDegrees: RotationDegrees,
        shape: MaskShape,
        featherRatio: FeatherRatio,
        origin: RegionOrigin,
        op: RenderOpSpec
    ) {
        self.bounds = bounds
        self.rotationDegrees = rotationDegrees
        self.shape = shape
        self.featherRatio = featherRatio
        self.origin = origin
        self.op = op
    }
}

/// 永続化・編集の対象。解像度に依存しない（image-pipeline.md 2 章）。
public struct RenderSpec: Sendable, Equatable {
    public let sourceCrop: NormalizedRect       // 元画像のどこを切り出すか
    public let scaleMode: SourceScaleMode       // fit / fill
    public let background: BackgroundSpec
    public let regions: [RenderRegionSpec]      // 順序に意味がある（正準スキーマの ordered）

    public init(
        sourceCrop: NormalizedRect,
        scaleMode: SourceScaleMode,
        background: BackgroundSpec,
        regions: [RenderRegionSpec]
    ) {
        self.sourceCrop = sourceCrop
        self.scaleMode = scaleMode
        self.background = background
        self.regions = regions
    }
}

/// 顔ごとの隠し方の設定。RenderRegionSpec の生成元（image-pipeline.md 2 章）。
public struct EffectSetting: Sendable, Equatable {
    public let op: RenderOpSpec
    public let shape: MaskShape
    public let featherRatio: FeatherRatio
    public let expansion: ExpansionRatios

    public init(op: RenderOpSpec, shape: MaskShape, featherRatio: FeatherRatio, expansion: ExpansionRatios) {
        self.op = op
        self.shape = shape
        self.featherRatio = featherRatio
        self.expansion = expansion
    }
}
