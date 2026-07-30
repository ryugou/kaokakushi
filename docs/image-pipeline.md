# 画像処理アーキテクチャ

| 項目 | 内容 |
| --- | --- |
| 目的 | 顔検出から書き出しまでの型と、`Domain` と `MediaKit` の責務境界を定める |
| 読者 | `Domain` のレンダリング層、`MediaKit`、`Rendering` の実装者 |
| 正本の範囲 | `RenderSpec` / `RenderDraft` / `RenderPlan`、座標・色・合成規約、スタンプラスタライズ契約、写真選択の境界型 |
| 関連 | [アーキテクチャ設計](architecture.md)（モジュール境界、`ManagedFileRef`）、[テスト計画](test-plan.md)（ゴールデン画像テスト） |

**エフェクトの数学をすべて `Domain` に置き、`MediaKit` には描画プリミティブのみを残します。** 目的は、エフェクトの計算をシミュレータなしでテストできる状態に保つことです。Core Image を呼び出す層に強度計算が混ざると、そのテストに実機が要ります。

```
MediaKit   Vision で顔検出 → 正規化座標の矩形群 + 頭部回転角 + 信頼度 + 小顔フラグ（1 章）
    ↓
Domain     拡張率適用、形状決定、切り抜きと背景処理の決定
           → RenderSpec（正規化座標・相対強度のまま）
    ↓
Domain     compileRenderDraft(spec, sourceSize, targetSize)
           相対強度 → 絶対ピクセル値、正規化座標 → 元画像 / キャンバス基準のピクセル
           → RenderDraft（stampKeys の rasterSize 算出済み）
    ↓
Rendering  StampRasterizer でスタンプ画像をビットマップ化
           → [StampRasterKey: RasterizedStampAsset]
    ↓
Domain     bindRasterAssets(draft, assets) → RenderPlan
    ↓
MediaKit   RenderPlan を受け取り、4 プリミティブのみ実行
           ①マスク内モザイク ②マスク内ぼかし ③単色塗り ④画像貼り付け
```

**永続化するのは `RenderSpec` 側の値だけ**で、ピクセル座標は保存しません。同じ設定を解像度の異なる出力（プレビューと原寸）へ一貫して適用できます。

インタラクティブなプレビューも書き出しも同じ `ImageEffectRenderer` が処理し、違うのは `targetSize` だけです。顔の枠・ハンドル・選択状態だけは SwiftUI `Canvas` が描き、書き出しには含めません。

## 1. 顔検出境界

処理手順は仕様 8.3 に従います。

1. 元画像の向き情報を正規化する
2. `FaceDetector` の内側で、検出用に長辺 1,920 ピクセル程度へ縮小する（中間ファイルを作らない。5 章）
3. `DetectFaceRectanglesRequest` を実行する
4. **`MediaKit` で正規化座標へ変換して返す**（Y 軸の反転を含む。4 章）
5. 以降、`Domain` は顔領域をピクセル座標として保持しない

検出用画像上で顔の短辺が 24 ピクセル未満の検出結果には `isSmallFace` を立てます（仕様 8.5）。

##### 顔単位の共通モデル

Vision の型（`FaceObservation`）を `Domain` へ流しません。

```swift
struct DetectedFace: Sendable, Equatable {
    let faceTrackID: FaceTrackID  // 6.6
    let bounds: NormalizedRect    // 左上原点へ変換済み（4 章）
    let confidence: Double        // 0.0〜1.0
    let yawDegrees: Double
    let pitchDegrees: Double
    let rollDegrees: Double
    let isSmallFace: Bool         // 検出用画像上の短辺で判定
}
```

`MediaKit` での変換は次のとおりです。

```swift
DetectedFace(
    faceTrackID: FaceTrackID(rawValue: observation.uuid),
    bounds: convertBounds(observation.boundingBox),   // Y 軸反転（4 章）
    confidence: Double(observation.confidence),
    yawDegrees: observation.yaw.converted(to: .degrees).value,
    pitchDegrees: observation.pitch.converted(to: .degrees).value,
    rollDegrees: observation.roll.converted(to: .degrees).value,
    isSmallFace: isSmallFace
)
```

**角度は非 Optional です。** `FaceObservation` の `yaw` / `pitch` / `roll` は `Measurement<UnitAngle>` です。新旧 Vision API の型を混在させません。Optional な角度が必要になった場合は、全体を旧 API（`VNDetectFaceRectanglesRequest` / `VNFaceObservation`）へ戻します。

##### `confidence` の受入条件

**Vision の `confidence` は、常に意味のある値とは限りません。** `lowConfidence` を有効にする前に、採用する `Revision` について実素材で分布を確認し、値が変動し検出品質と相関することを確かめます。満たさない場合は `lowConfidence` をトリアージから外します（意味のない値で警告を出すと `smallFace` や `extremePose` まで流し読みされます）。閾値の決定は [アーキテクチャ設計](architecture.md) の未決事項を正本とします。

##### 拡張率の適用

```swift
func expand(face: NormalizedRect, effect: EffectSetting) -> NormalizedRect
```

既定値は上 25% / 下 15% / 左右 15%（仕様 8.4）。スタンプはモザイクより大きめの拡張率を用います。

**画像外へはみ出す場合もクランプしません。** クランプすると顔が露出する方向へ倒れます。はみ出しはマスク描画側で処理します。

## 2. RenderSpec / RenderDraft / RenderPlan

**記述（`RenderSpec`）とコンパイル済み命令（`RenderPlan`）を分けます。** `RenderPlan` に相対値を残すと Core Image を呼ぶ層が比率計算を持ち、そのテストに実機が必要になります。

```swift
struct PixelSize: Sendable, Hashable {   // ドメイン独自型。CGSize を使わない
    let width: Int
    let height: Int
}

/// 永続化・編集の対象。解像度に依存しない
struct RenderSpec: Sendable, Equatable {
    let sourceCrop: NormalizedRect       // 元画像のどこを切り出すか
    let scaleMode: SourceScaleMode       // fit / fill
    let background: BackgroundSpec
    let regions: [RenderRegionSpec]      // 順序に意味がある（[正準スキーマ](canonical-schema.md) の ordered）
}

struct RenderRegionSpec: Sendable, Equatable {
    let bounds: NormalizedRect           // 拡張率適用済み。出力キャンバス基準（4 章）
    let rotationDegrees: RotationDegrees
    let shape: MaskShape                 // ellipse / circle / rectangle / rounded(cornerRatio)
    let featherRatio: FeatherRatio       // 領域短辺に対する比。0 を許す
    let origin: RegionOrigin             // auto / manual（描画順に使う）
    let op: RenderOpSpec
}

/// 組み込みスタンプとカスタムスタンプを文字列で混ぜない
enum StampSource: Sendable, Hashable {
    case builtIn(code: String)
    case custom(assetHash: StampAssetHash)   // 32 バイト固定（正準スキーマ 5.1）
}

enum RenderOpSpec: Sendable, Equatable {
    case mosaic(cellRatio: MosaicRatio)                   // 領域短辺に対するセル比
    case blur(sigmaRatio: BlurRatio)                      // 領域短辺に対する σ 比
    case solid(color: VisibleColor, opacity: EffectOpacity)
    case stamp(source: StampSource, opacity: EffectOpacity)
}

enum BackgroundSpec: Sendable, Equatable {
    case none
    case blur(sigmaRatio: BlurRatio)                      // キャンバス短辺に対する比
    case solid(color: VisibleColor)
}
```

##### 二段階コンパイル

`StampRasterKey.rasterSize` は対象解像度における領域のピクセル寸法から決まり、それを計算するのはコンパイル処理です。しかし `RenderPlan` の構築には `bitmapID` が要ります。**一段階では依存が循環するため、コンパイルを 2 つに分けます。**

```swift
struct StampRasterKey: Sendable, Hashable {
    let source: StampSource
    let rasterSize: PixelSize
}

/// 第1段階: 解像度は確定したが、スタンプ実体はまだ束ねていない
struct RenderDraft: Sendable {
    let canvasSize: PixelSize
    let sourcePlacement: SourcePlacement
    let background: BackgroundOp
    let regions: [RenderRegionDraft]
    let stampKeys: Set<StampRasterKey>   // rasterSize 算出済み。重複排除済み
}

/// RenderRegion との違いは op だけ。bitmapID の代わりに StampRasterKey を持つ
struct RenderRegionDraft: Sendable {
    let bounds: PixelRect
    let rotationDegrees: RotationDegrees
    let shape: MaskShape
    let featherPx: FeatherPx
    let order: Int
    let op: RenderOpDraft
}

enum RenderOpDraft: Sendable {
    case mosaic(cellSizePx: CellSizePx)
    case blur(sigmaPx: SigmaPx)
    case solid(color: VisibleColor, opacity: EffectOpacity)
    case stamp(key: StampRasterKey, opacity: EffectOpacity)
}

func compileRenderDraft(
    spec: RenderSpec,
    sourceSize: PixelSize,      // 向き正規化後の元画像のピクセル寸法
    targetSize: PixelSize
) throws -> RenderDraft

/// 第2段階: ラスタ実体を束ねて RenderPlan にする
func bindRasterAssets(
    draft: RenderDraft,
    assets: [StampRasterKey: RasterizedStampAsset]
) throws -> RenderPlan
```

`bindRasterAssets` は `RenderOpDraft.stamp(key:opacity:)` の `key` で `assets` を引き、`RenderOp.stamp(bitmapID:opacity:)` へ置換します。それ以外の `case` は値をそのまま移します。**`draft.stampKeys` に対応する `assets` が 1 件でも欠けていれば `throw` します。** 未解決のまま `RenderPlan` を作れません。

##### コンパイル済みの命令

```swift
/// 特定解像度へコンパイル済み。絶対ピクセル値のみを持つ
struct RenderPlan: Sendable {
    let canvasSize: PixelSize
    let sourcePlacement: SourcePlacement
    let background: BackgroundOp
    let regions: [RenderRegion]
}

struct PixelRect: Sendable, Equatable {
    let left: Int
    let top: Int
    let rightExclusive: Int
    let bottomExclusive: Int
}

struct SourcePlacement: Sendable {
    let sourceRect: PixelRect            // 元画像のどこを使うか（元画像のピクセル）
    let destinationRect: PixelRect       // キャンバス上のどこへ置くか
    let scaleMode: SourceScaleMode
}

enum SourceScaleMode: Sendable, Hashable { case fit, fill }

struct RenderRegion: Sendable {
    let bounds: PixelRect                // 出力キャンバス基準の絶対ピクセル
    let rotationDegrees: RotationDegrees
    let shape: MaskShape
    let featherPx: FeatherPx
    let order: Int                       // 描画順（4 章）
    let op: RenderOp
}

enum RenderOp: Sendable {
    case mosaic(cellSizePx: CellSizePx)
    case blur(sigmaPx: SigmaPx)
    case solid(color: VisibleColor, opacity: EffectOpacity)
    case stamp(bitmapID: String, opacity: EffectOpacity)
}

enum BackgroundOp: Sendable {
    case none

    /// 何をどうぼかして背景へ敷くかを明示する
    case blurFromSource(
        sourceRect: PixelRect,           // 元画像のピクセル
        sigmaPx: SigmaPx,
        scaleMode: SourceScaleMode
    )

    case solid(color: VisibleColor)
}
```

| 型 | 座標 |
| --- | --- |
| `RenderSpec` の全フィールド | 正規化（解像度非依存） |
| `RenderDraft` / `RenderPlan` の全フィールド | **絶対ピクセル** |

**`RenderPlan` は正規化座標を 1 つも持ちません。** そのため `compileRenderDraft` は向き正規化後の寸法である `sourceSize` を受け取ります。これが無ければ比率計算と丸め規則が `MediaKit` 側へ漏れます。

##### 合成の契約

| 概念 | 保持する型 |
| --- | --- |
| 出力キャンバスの実サイズ | `RenderPlan.canvasSize` |
| 元画像のどこを使うか | `SourcePlacement.sourceRect`（元画像基準の絶対ピクセル） |
| キャンバス上のどこへ置くか | `SourcePlacement.destinationRect` |
| Fit か Fill か | `SourcePlacement.scaleMode` |
| 余白の埋め方 | `RenderPlan.background` |
| 背景ぼかしの**元範囲** | `BackgroundOp.blurFromSource` の `sourceRect` |
| 顔領域の位置 | `RenderRegion.bounds`（**出力キャンバス基準の絶対ピクセル**） |

`BackgroundOp.blur(sigmaPx:)` ではなく `blurFromSource` にしたのは、`sigma` だけでは「元画像全体をぼかすのか、切り抜き範囲をぼかすのか、どの倍率で敷くのか」が決まらないためです。一般的な用途では `sourceRect` に元画像全体を指定し、`fill` でキャンバス全面へ拡大します。

`RenderRegion.bounds` の基準を出力キャンバスに確定します。元画像基準にすると `MediaKit` が切り抜き変換を再実装することになります。

##### `sourceCrop` の不変条件

顔の拡張領域と違い、`sourceCrop` が元画像の外へ出る理由はありません。

- `width > 0` かつ `height > 0`
- `0.0 <= left`、`right <= 1.0`、`0.0 <= top`、`bottom <= 1.0`
- 違反は `compileRenderDraft` が `throw` する（クランプで黙って直さない）

`PixelRect` の `rightExclusive` / `bottomExclusive` は名前で排他性を示します。

##### 何も隠さない `RenderOp` を作れないようにする

`isMasked == true` の顔に対して、次はいずれも「加工したことになっているが、実際には何も隠れていない」出力を作ります。

| 値 | 結果 |
| --- | --- |
| `opacity = 0` | 完全に透明な塗り・スタンプ |
| `sigmaRatio = 0` | ぼかしゼロ |
| `cellRatio = 0`（または `cellSizePx < 2`） | モザイクのセルが 1 ピクセル＝原画のまま |
| 幅または高さ 0 の `bounds` | 描画対象が無い |
| `NaN` / 無限大の座標 | 描画が未定義 |
| 完全に透明なカスタムスタンプ画像 | 貼っても何も隠れない |

**検証済みの値型としてしか作れないようにし、モデルの側も生の `Double` を持ちません。**

```swift
struct EffectOpacity: Sendable, Equatable {
    let value: Double

    init(_ value: Double) throws {
        // 0 は「完全に透明」＝何も隠さない。範囲に含めない
        guard value.isFinite, value > 0, value <= 1 else {
            throw RenderValidationError.invalidOpacity
        }
        self.value = value
    }
}
```

**すべて `struct` として宣言し、`throws` の initializer だけを公開します。** 値域の表だけでは、実装が生の `Double` を通します。

```swift
struct MosaicRatio: Sendable, Hashable {         // 領域短辺に対するセル比
    let value: Double
    init(_ v: Double) throws { /* 有限かつ 0 < v <= 0.5 */ }
}
struct BlurRatio: Sendable, Hashable {           // 領域短辺に対する σ 比
    let value: Double
    init(_ v: Double) throws { /* 有限かつ 0 < v <= 0.5 */ }
}
struct FeatherRatio: Sendable, Hashable {        // 領域短辺に対する比
    let value: Double
    init(_ v: Double) throws { /* 有限かつ 0 <= v <= 0.5 */ }
}
struct ExpansionRatio: Sendable, Hashable {      // 顔矩形からの拡張率
    let value: Double
    init(_ v: Double) throws { /* 有限かつ 0 <= v <= 2.0 */ }
}
struct RotationDegrees: Sendable, Hashable {
    let value: Double                            // 正規化済み
    init(_ v: Double) throws { /* 有限。-180 <= v < 180 へ正規化して保持 */ }
}
struct SigmaPx: Sendable, Hashable {
    let value: Double
    init(_ v: Double) throws { /* 有限かつ > 0 */ }
}
struct FeatherPx: Sendable, Hashable {
    let value: Double
    init(_ v: Double) throws { /* 有限かつ >= 0 */ }
}
struct CellSizePx: Sendable, Hashable {
    let value: Int
    init(_ v: Int) throws { /* v >= 2 */ }
}

/// 元画像またはキャンバスに対する正規化矩形。左上原点
struct NormalizedRect: Sendable, Hashable {
    let left: Double
    let top: Double
    let rightExclusive: Double
    let bottomExclusive: Double

    init(left: Double, top: Double, rightExclusive: Double, bottomExclusive: Double) throws {
        // すべて有限。left < rightExclusive、top < bottomExclusive
        // 画像外へのはみ出し（負数・1.0 超過）は許す
    }
}
```

| 型 | 表現 | 条件 |
| --- | --- | --- |
| `EffectOpacity` | `Double` | 有限かつ **`0 < v <= 1`** |
| `PixelSize` | `Int` × 2 | `width > 0` かつ `height > 0` |
| `PixelRect` | `Int` × 4 | `left < rightExclusive`、`top < bottomExclusive` |
| `VisibleColor` | **`SrgbArgb8888` の別名**（下記） | **アルファが 0 より大きい** |
| カスタムスタンプ画像 | — | 最大アルファ値が 0 なら取り込み時に拒否する |

##### `CellSizePx` を `Int` にする理由と丸め

**モザイクのセルはピクセル格子に整列するため `Int` です。** `cellRatio` からの変換規則を固定します。

```
cellSizePx = max(2, Int(floor(cellRatio.value * min(bounds.width, bounds.height))))
```

| 項目 | 規則 |
| --- | --- |
| 丸め | **floor** |
| 下限 | **2**。floor の結果が 1 以下なら 2 へ引き上げる |
| 例外 | 引き上げても領域が 2px 未満なら `throw`（隠せない） |

**floor に固定するのは、セルを大きくする方向へ倒すと利用者の指定より粗くなるためです。** 下限 2 は「1px モザイク＝原画」を構造的に禁じます。

**`sigmaPx` と `featherPx` は `Double` のままです。** どちらもガウス分布のパラメータであり、格子に整列する必要がありません。

##### `RotationDegrees` の範囲

**`[-180, 180)` へ正規化します。** `RenderRegion` の回転規約（4 章）と同じ範囲であり、2 か所で別の範囲を定めません。`370` と `10` が別の値として `ProjectSettingsHash` に入ると、見た目が同じでも「設定を変えた」と判定されます。

##### `VisibleColor` は `SrgbArgb8888` の別名

**別の型を 2 つ持ちません。** `RenderOpSpec.solid` と `BackgroundSpec.solid` が使う色は、4 章で定めた `SrgbArgb8888`（`0xAARRGGBB`、straight alpha）そのものです。「アルファが 0 より大きい」という制約は `SrgbArgb8888` の initializer が検証します。

列挙型です。

```swift
enum MaskShape: Sendable, Hashable {
    case ellipse
    case circle
    case rectangle
    case rounded(cornerRatio: CornerRatio)
}

/// 角丸の半径。領域短辺に対する比
struct CornerRatio: Sendable, Hashable {
    let value: Double            // 有限かつ 0 < v <= 0.5

    init(_ value: Double) throws {
        guard value.isFinite, value > 0, value <= 0.5 else {
            throw RenderValidationError.invalidCornerRatio
        }
        self.value = value
    }
}

enum RegionOrigin: Sendable, Hashable {
    case auto      // Vision による検出
    case manual    // 利用者が追加した領域
}

enum RenderValidationError: Error, Sendable, Equatable {
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
    case unresolvedStampAsset      // bindRasterAssets で asset が欠けた
    case sourceCropOutOfBounds
}

/// 顔ごとの隠し方の設定。RenderRegionSpec の生成元
struct EffectSetting: Sendable, Equatable {
    let op: RenderOpSpec
    let shape: MaskShape
    let featherRatio: FeatherRatio
    let expansion: ExpansionRatios
}

/// 顔矩形からの拡張率（仕様 8.4）
struct ExpansionRatios: Sendable, Hashable {
    let top: ExpansionRatio
    let bottom: ExpansionRatio
    let leading: ExpansionRatio
    let trailing: ExpansionRatio
}
```

**`cornerRatio` も他の比率と同じく検証済みの値型にします。** 生の `Double` のままだと `NaN` や範囲外の値がそのまま Core Graphics へ渡り、描画結果が未定義になります。


**検証を迂回できないようにします。** Swift は `struct` へ memberwise initializer を自動生成するため、同一モジュール内からは検証を飛ばせます。

- 検証前の initializer をモジュール外へ公開しない（`public` は `throws` 版だけ）
- 同一モジュール内でも直接生成しない規約とし、lint で検出する
- **永続データのデコード時にも同じ検証を通す**（`Decodable` の `init(from:)` で `throws` 版を呼ぶ）

**利用者が「この顔は隠さない」と選ぶ経路は別に存在します。** `isMasked = false` にするか、`ReviewResolution.unmaskedExportConfirmed` を記録するか（[アーキテクチャ設計](architecture.md) の 6.1）です。`isMasked == true` の顔に no-op 相当の値が渡された場合、`compileRenderDraft` が `throw` します。

## 3. スタンプラスタライズ

ラスタライズは Core Graphics を使うため `Domain` の責務にできません。**幾何情報は `RenderRegion` だけに持たせます。** ラスタライズ側にも `bounds` / `rotationDegrees` / `opacity` を持たせると二重適用されます。

```swift
// Domain — Foundation のみ。要求の同一性は StampRasterKey で表す
protocol StampRasterizer: Sendable {
    /// 1 回の render セッションに必要なラスタを一括で作る
    func rasterize(
        _ keys: Set<StampRasterKey>
    ) async throws -> [StampRasterKey: RasterizedStampAsset]
}
```

**`Set` を 1 回渡す形にすることで、次がすべて型で決まります。**

| 責務 | 担当 |
| --- | --- |
| 重複排除 | `Set` の型そのもの（`compileRenderDraft` が構築する） |
| `bitmapID` の採番 | `StampRasterizer` の実装。1 回の呼び出し内で一意な値を振る |
| 実体の寿命 | 1 回の `render` セッション。**グローバルキャッシュを持たない** |
| 戻り値の完全性 | 与えた `keys` の全要素に対応する値を返す。1 件でも欠ければ `throw` |

1 件ずつの API では、呼び出し元が自前でキャッシュを持つか実装側がグローバルキャッシュを持つかになり、後者は並列レンダリング時に他方の解放と競合します。

`StampRasterizer` が**行わないこと**を明示します。

| 項目 | 適用場所 |
| --- | --- |
| 画面上の位置 | `RenderRegion.bounds` |
| 回転 | `RenderRegion.rotationDegrees` |
| 不透明度 | `RenderOp.stamp.opacity` |
| 顔領域の形状 | `RenderRegion.shape` |

##### ラスタ画像の受け渡し契約

`CGImage` を `Domain` の型へ入れられないため、実体を指す形式を定めます。

```swift
struct RasterizedStampAsset: Sendable {
    let bitmapID: String
    let rasterFile: RasterFileRef
    let descriptor: RawBitmapDescriptor
}
```

`ImageEffectRenderer` はこの型を `rasterAssets: [String: RasterizedStampAsset]` として受け取ります。**プロトコルの宣言は 5 章が正本です**（下記の検証済み境界の節）。ここでは受け渡す値の形だけを定めます。

**実体はファイル経由で渡します。** 1 バッチ 50 枚では、原寸スタンプのビットマップを複数枚同時にメモリへ載せることになります。一時ファイルにすれば `CGDataProvider(url:)` でメモリマップして読めます。

| 項目 | 規約 |
| --- | --- |
| 構造 | **ヘッダなしの raw bytes** |
| 行の順序 | 上から下 |
| 各行の順序 | 左から右 |
| チャネル順 | R, G, B, A |
| ファイルサイズ | `rowBytes * height` に厳密に一致する |
| `rowBytes` | `>= width * 4`（アライメントのため大きくてよい） |
| 行末パディング | **ゼロ初期化する** |
| アルファ | **straight alpha**。保存前に premultiplied から変換する |
| 色空間 | sRGB |

**パディングをゼロ初期化しないと、未初期化メモリの内容がファイルへ書かれます。** `CGContext` が確保するバッファは行末のアライメント領域の初期化を保証しないため、`CGBitmapContextGetData` の全域を明示的にゼロ埋めしてから描画します。

##### 寿命とスコープ

| 項目 | 規約 |
| --- | --- |
| ID スコープ | `bitmapID` は**1 回の `render` 呼び出し内でのみ**一意 |
| 寿命 | `render` の呼び出し開始から復帰までの間、`rasterAssets` の全要素が有効 |
| 解放 | 成功・失敗にかかわらず復帰後に**呼び出し元が**削除する。**解放は冪等** |
| 再利用 | 同じ `StampRasterKey` には同一の `bitmapID` を返し、複数の `RenderRegion` から参照してよい |
| 未解決 ID | `plan` が参照する `bitmapID` が無い場合は描画を開始せず `throw` する |

**ID スコープを呼び出し内に閉じるのは、同時レンダリングのためです。** グローバルなレジストリを共有すると、片方の完了時の解放がもう片方の参照中実体を消します。

**未解決 ID を無視しません。** スタンプが 1 つ欠けたまま書き出すと、顔が隠れていない出力が完成扱いになります。

## 4. 座標・色・合成規約

##### `NormalizedRect`

| 項目 | 規約 |
| --- | --- |
| 原点 | **向き正規化後**の画像の左上 |
| +X | 右方向 |
| +Y | **下方向** |
| `left` / `top` | 含む（inclusive） |
| `right` / `bottom` | **含まない（exclusive）** |

原点を「向き正規化後」と明記するのは、EXIF の回転を適用する前後で左上の位置が変わるためです。

値域は段階によって異なります。

| 段階 | 値域 |
| --- | --- |
| `DetectedFace.bounds`（検出直後） | 0.0〜1.0 に収まる。アダプタが保証する |
| `expand()` 適用後 | **負数および 1.0 超過を許容する。** クランプしない |
| `RenderPlan.regions[].bounds` | 出力キャンバス基準のピクセル。キャンバス外の値を含みうる |
| 最終的なクリップ | **レンダラーがキャンバス境界で行う** |

##### ピクセルへの丸め

| 値 | 丸め |
| --- | --- |
| `left` / `top` | **floor** |
| `right` / `bottom` | **ceil** |
| `featherPx` / `sigmaPx` | 丸めない（`Double` のまま渡す） |
| `cellSizePx` | **floor し、下限 2 へ引き上げる**（3 章） |

領域が必ず**外側へ広がる**方向に丸められます。内側へ丸めると顔の縁が 1 ピクセル露出しえます。

##### 適用順

1. `sourceCrop` で元画像を切り出す
2. `canvasSize` のキャンバスへ配置し、余白を `background` で埋める
3. `regions` を `order` の昇順に、前の結果へ重ねて適用する

**背景処理が先です。** 顔エフェクトを先に適用すると、背景ぼかしが加工済みの顔へも掛かり、モザイクの粒がにじみます。

後のエフェクトは**加工済み画像**に対して作用します（元画像ではありません）。`order` は `compileRenderDraft` が決定します。

| 優先 | 対象 |
| --- | --- |
| 1（先） | `RegionOrigin.auto`（自動検出された顔） |
| 2（後） | `RegionOrigin.manual`（利用者が追加した手動領域） |

同一区分内は `RenderSpec.regions` の並び順を保ちます。**手動領域を後に置くのは、利用者の明示的な指示を最終結果にするためです。**

##### クリップと回転の順序

**クリップは回転の後に行います。**

1. `RenderRegion` の形状を、領域中心を基準に `rotationDegrees` だけ回転する
2. 回転後の形状をキャンバス境界でクリップする

順序を逆にすると、キャンバス端の顔を回転させたときに、本来隠れるべき部分が切り落とされたあとで回転して露出します。

##### `rotationDegrees`

| 項目 | 規約 |
| --- | --- |
| 正方向 | **時計回り** |
| 範囲 | `-180.0` 以上 `180.0` 未満へ正規化する |
| 回転中心 | 画像中心ではなく、**その `RenderRegion` の中心** |

##### 色

```swift
struct SrgbArgb8888: Sendable, Hashable {
    let value: UInt32    // 0xAARRGGBB

    init(_ v: UInt32) throws { /* アルファ（上位 8 bit）が 0 なら throw */ }
}

/// RenderOpSpec / BackgroundSpec が使う色。別の型を作らない
typealias VisibleColor = SrgbArgb8888
```

| 項目 | 規約 |
| --- | --- |
| 色空間 | sRGB |
| ビット配置 | `0xAARRGGBB` |
| アルファ | **straight alpha**（premultiplied ではない） |
| `opacity` の乗算 | **レンダラーが 1 回だけ**乗算する。ドメインは色へ焼き込まない |
| premultiplied への変換 | `MediaKit` / `Rendering` 側で行う |

`SrgbArgb8888` のアルファ（色そのものの不透明度）と `RenderOp` の `opacity`（エフェクト全体の適用強度）は別の概念で、レンダラーが両方を掛け合わせます。

##### `Domain` から Core Image への変換責務

Core Image の API は **`CIImage` 自身の Cartesian 座標系（左下原点）** の矩形を受け取ります。`Domain` の `PixelRect`（左上原点）をそのまま `CGRect` にすると上下が反転します。

```swift
// MediaKit
func makeCIRect(_ rect: PixelRect, canvasHeight: Int) -> CGRect {
    CGRect(
        x: rect.left,
        y: canvasHeight - rect.bottomExclusive,   // ← Y 軸の反転
        width: rect.rightExclusive - rect.left,
        height: rect.bottomExclusive - rect.top
    )
}
```

| 項目 | 規約 |
| --- | --- |
| 回転方向 | `Domain` は時計回り正。**Core Image は反時計回り正**なので符号を反転する |
| `extent` の原点 | 向き正規化後の `CIImage.extent` を **`(0, 0)` へ移す**。`cropped(to:)` の結果は原点を保つため |
| ぼかしの端 | `CIGaussianBlur` の**前に `CIAffineClamp` で端を伸ばし**、処理後にキャンバスの `extent` で `cropped(to:)` する |
| マスク | **同じ `makeCIRect` を通す。** マスクだけ別の変換を書かない |
| 出力 | エンコード時に**再度上下反転しない** |

**`CIAffineClamp` を省くと、画像端の顔のぼかしが薄くなります。** Core Image はキャンバス外を透明として扱うため、端の領域では透明とブレンドされて隠蔽が弱まります。

## 5. 写真選択と PhotoKit 境界

##### `Domain` のプロトコル

| プロトコル | 責務 | 実装モジュール | 使用 API |
| --- | --- | --- | --- |
| `PickedPhotoLoader` | **物質化済みファイル**の読み込み、向き正規化、検出用縮小、HEIC 対応 | `MediaKit` | Image I/O |
| `FaceDetector` | 顔検出。正規化座標で返す | `MediaKit` | Vision |
| `ImageEffectRenderer` | `RenderPlan` の 4 プリミティブ実行 | `MediaKit` | Core Image |
| `ImageEncoder` | JPEG / HEIC エンコード、メタデータ除去 | `MediaKit` | Image I/O |
| `MediaSaver` | 写真ライブラリ保存、登録日時の指定 | `MediaKit` | PhotoKit |
| `StampRasterizer` | スタンプのラスタライズ（3 章） | `Rendering` | Core Graphics |
| `ProtectedDataAvailability` | 保護データの利用可否と復帰待ち | `App` | `UIApplication` と 2 つの通知 |

永続化・課金・排他のプロトコル（`CryptoKeyStore` / `ProtectedBlobStore` / `ManagedFileStore` / `UsageLedgerStore` / `ExportStartGate` / `CrashReporter`）は [アーキテクチャ設計](architecture.md) が正本です。

##### 境界型

**プロトコル署名に現れる型は、`ShareResult` を除きすべてここで定義します**（`ShareResult` は受け渡しの結果分類であり [書き出し Saga](export-saga.md) の 8 が正本）。特に `OutputFile` を「パス文字列を持つ型」として実装すると、`ManagedFileRef` の境界（[アーキテクチャ設計](architecture.md) の `ManagedFileStore`）を迂回します。

```swift
// Domain — すべて Foundation のみ。CGImage / CIImage / URL を持たない

enum ImageFormat: Sendable, Hashable { case jpeg, heic, png }

/// レンダラーへ渡す入力画像。実体は ManagedFileRef からのみ解決する。
/// この型を作れる時点で向きは正規化済み。未正規化の画像は表現できない
struct ImageSource: Sendable {
    let file: ManagedFileRef
    let pixelSize: PixelSize          // 向き正規化後
    let format: ImageFormat
}

/// PickedPhotoLoader の戻り値
struct LoadedPhoto: Sendable {
    let source: ImageSource           // 向き正規化済みの原寸。WorkingSourceRecord が指す実体
    let capture: OriginalCaptureMetadata  // EXIF 由来（正準スキーマ 5.1.1）
}

/// FaceDetector の戻り値
struct DetectionResult: Sendable, Equatable {
    let faces: [DetectedFace]
    let detectionPixelSize: PixelSize   // 検出器が内部で縮小した後の実寸。isSmallFace の判定に使う
    let revision: FaceDetectorRevision  // 採用した Vision リビジョン
}

/// Vision のリビジョン。Vision の型を Domain へ持ち込まない
struct FaceDetectorRevision: Sendable, Hashable {
    let rawValue: Int      // DetectFaceRectanglesRequest.Revision の生値
}

/// 生ビットマップの形式。RenderedImage と RasterizedStampAsset が共有する
struct RawBitmapDescriptor: Sendable, Equatable {
    let pixelSize: PixelSize
    let rowBytes: Int                 // >= pixelSize.width * 4
    let channelOrder: RawChannelOrder
    let alpha: RawAlphaMode
    let bitDepth: RawBitDepth
    let colorSpace: RawColorSpace
}

enum RawChannelOrder: Sendable, Equatable { case rgba, bgra }
enum RawAlphaMode: Sendable, Equatable { case straight, premultiplied }
enum RawBitDepth: Sendable, Equatable { case eightPerChannel }
enum RawColorSpace: Sendable, Equatable { case sRGB }

/// ImageEffectRenderer の戻り値。エンコード前のビットマップ
struct RenderedImage: Sendable {
    let file: RasterFileRef
    let descriptor: RawBitmapDescriptor
}

/// 受け渡し対象。MediaSaver と SharePresenter が受け取る
struct OutputFile: Sendable {
    let exportID: ExportID
    let file: OutputFileRef
    let format: ImageFormat
    let byteSize: Int64
    let suggestedCreationDate: Date?  // 写真ライブラリ保存時の creationDate（5 章）
}
```

| 規約 | 内容 |
| --- | --- |
| 実体の参照 | **`ManagedFileRef` のみ。** `URL` もパス文字列も持たない |
| 向き | `ImageSource` を作れる時点で正規化済み。**未正規化を表す case を持たない** |
| 寸法 | すべて向き正規化後の値。`compileRenderDraft` の `sourceSize` はここから取る |
| メタデータ | `ImageSource` / `RenderedImage` / `OutputFile` は EXIF を保持しない。読み取った撮影日時は `LoadedPhoto.capture`（`OriginalCaptureMetadata`）が持ち、書き出しでは `ImageEncoder` が `OutputMetadata` に従って付与する |

**`OutputFile` に `suggestedCreationDate` を持たせるのは、`MediaSaver` が `PHAssetCreationRequest.creationDate` を設定するために必要だからです。** 取得できなかった場合は `nil` とし、`MediaSaver` は `creationDate` を設定しません（5 章）。

##### 生ビットマップの形式を型で固定する

**「RGBA8888」だけでは実装が一意に定まりません。** チャネル順、アルファの前乗算、色空間、bit depth のどれか 1 つでも食い違うと、半透明のスタンプが暗くなる、色がずれる、といった形で表面化します。

v1 が生成する生ビットマップは常に次の値をとります。

| フィールド | v1 の値 |
| --- | --- |
| `channelOrder` | `.rgba` |
| `alpha` | **`.straight`**（Core Graphics の既定は premultiplied。保存前に変換する） |
| `bitDepth` | `.eightPerChannel` |
| `colorSpace` | `.sRGB` |
| `rowBytes` | `>= width * 4`。アライメントのため大きくてよい |

**型として持つのは、将来 BGRA や premultiplied を扱う経路が増えたときに、暗黙の前提で壊れないようにするためです。** 読み手は `descriptor` を見て変換の要否を判断します。

ファイルの構造（ヘッダなし raw bytes、上から下、左から右、`rowBytes * height` に一致、行末パディングのゼロ初期化）は 3 章が正本です。

##### プロトコルのシグネチャ

```swift
protocol PickedPhotoLoader: Sendable {
    /// 取り込み時のみ。まだ binding が無い新しいファイルを読み、向きを正規化する。
    /// 既存 Project の素材には使わない（5 章の検証済み境界）
    func load(_ file: ManagedFileRef) async throws -> LoadedPhoto
}

protocol ImageEncoder: Sendable {
    /// メタデータは許可リストで構築する（アーキテクチャ設計 7.5）
    func encode(
        _ image: RenderedImage,
        format: ImageFormat,
        quality: Double,
        metadata: OutputMetadata
    ) async throws -> OutputFileRef
}

protocol MediaSaver: Sendable {
    /// 追加のみの権限で足りる。読み取り権限を要求しない（5 章）
    func saveToPhotoLibrary(_ file: OutputFile) async throws
}

```

`StampRasterizer` の宣言は 3 章が正本であり、ここでは列挙しません。同じプロトコルを 2 か所に置くと、片方だけ更新される事故につながります。

`OutputMetadata` は許可リストで構築した出力メタデータで、ICC プロファイルの有無、ピクセル寸法、保持する場合の `OriginalCaptureMetadata`（ローカル日時・小数秒・UTC オフセット・算出済み `utcMillis`）だけを持ちます（[アーキテクチャ設計](architecture.md) の 7.5）。**`ImageEncoder` は元画像のメタデータ辞書を受け取りません。** 受け取れる形にすると、コピーして削除する実装が可能になります。

##### `@MainActor` のプロトコル

```swift
@MainActor
protocol SharePresenter: AnyObject {
    func share(_ file: OutputFile) async -> ShareResult
}

@MainActor
protocol AdPresenter: AnyObject {
    // バナー / 全画面広告
}
```

| プロトコル | 実装モジュール | 使用 API |
| --- | --- | --- |
| `SharePresenter` | `MediaKit` | `UIActivityViewController`（[書き出し Saga](export-saga.md) の 8。`ShareResult` の定義も同章） |
| `AdPresenter` | `Ads` | Google Mobile Ads |

`OutputDeliveryCoordinator`（`actor`）から `await` して呼びます。`@MainActor` の型はアクタによって状態が保護されるため `Sendable` として扱えます。

##### `App` が所有するもの

`PhotosPicker` と `fileImporter` は SwiftUI の modifier であり、画面上の `Binding` と提示状態を必要とします。`Application` から呼ぶ非 UI サービスとして表現できません。

| 対象 | 所有者 | 備考 |
| --- | --- | --- |
| `PhotosPicker` の提示 | `App` | `PhotosPickerItem` は `App` の外へ出さない |
| `fileImporter` の提示 | `App` | 外部 `URL` は `App` の外へ出さない |
| `PrivacyShield` | `App` | `scenePhase` に紐づく（[アーキテクチャ設計](architecture.md) の 9.3） |

```swift
// App — 境界サービス。View から呼べるのはこの 2 つだけ（[アーキテクチャ設計](architecture.md) の 3.2）
@MainActor final class PhotoSelectionBridge { }   // PhotosPickerItem → PickedPhotoInput
@MainActor final class FileSelectionBridge { }    // security-scoped URL → ManagedFileRef
```

##### `PickedPhotoInput`

```swift
// Domain — プラットフォーム非依存
struct PickedPhotoInput: Sendable {
    let importedFile: ManagedFileRef          // 7.3 で物質化済み
    let providerAssetIdentifier: String?      // 一時的にのみ保持。保存・ログ禁止
    let libraryCreationDate: Date?
    let representation: SourceRepresentation  // 6.4
}

```

`PickedPhotoLoader` の宣言は上記のプロトコル署名の節が正本です。

| 順 | 操作 | 実行場所 |
| --- | --- | --- |
| 1 | `PhotosPickerItem` を受け取る | `App` |
| 2 | `loadTransferable` を実行する | `App`（bridge） |
| 3 | **`Data` のまま保持せず、`ManagedFileStore` で処理用ファイルへ物質化する** | `App` → `Persistence` |
| 4 | `PhotosPickerItem` を破棄する | `App` |
| 5 | `PickedPhotoInput` だけを `Application` へ渡す | `App` → `Application` |
| 6 | `providerAssetIdentifier` を HMAC 化して `SourceIdentity` を作る | `Application` / `Persistence` |

**手順 3 が要点です。** 48 メガピクセルの画像を `Data` のまま抱えると、50 枚の一括処理でメモリが尽きます。

**`providerAssetIdentifier` は `PickedPhotoInput` の寿命の中でのみ使います。** ログへ出さず、永続化しません。ハッシュ化した値だけが台帳へ入ります。

##### ピッカー固有の契約

**`PhotosPicker` の `itemIdentifier` は `Optional` です。** `photoLibrary` を指定せずに作成した場合は `nil` になります。

```swift
.photosPicker(
    isPresented: $isPresented,
    selection: $selection,
    matching: .images,
    preferredItemEncoding: .current,   // 可能ならトランスコードを避ける
    photoLibrary: .shared()            // これが無いと itemIdentifier が nil になる
)
```

それでも `Optional` として扱い、取得できない場合は `SourceIdentity.providerAssetKeyHash` を `nil` として `contentFingerprint` だけで判定します（[アーキテクチャ設計](architecture.md) の 6.4）。

**`fileImporter` が返す `URL` は security-scoped です。** 利用前にアクセスを開始し、処理後に必ず解放します。start と stop を均衡させないとカーネル資源をリークします。

```swift
let accessed = url.startAccessingSecurityScopedResource()
defer {
    if accessed {
        url.stopAccessingSecurityScopedResource()
    }
}
// この区間内で FileSelectionBridge がアプリ領域へコピーする
```

**外部の `URL` を永続保存しません。** ブックマークを保存して後から再アクセスする方式は採りません。カスタムスタンプは取り込み時点で複製すれば足ります。

##### 処理用ファイルの寿命を DB で管理する

`PickedPhotoInput` は一時値であり、再起動後には残りません。一方、未完了キューは再起動後に復元します（[アーキテクチャ設計](architecture.md) のバッチ処理）。復元したキュー項目が参照する処理用ファイルを表す永続モデルが無ければ、**復元しても加工を再開できません。**

```swift
struct WorkingSourceRecord: Sendable {
    let projectID: ProjectID
    let sourceFile: WorkingSourceFileRef
    let createdAt: Date               // 保持期限の起点（下記）
}
```

| 項目 | 規約 |
| --- | --- |
| 保存先 | `app.db`。実体は `working/` |
| 参照 | キュー項目・編集中プロジェクトの元素材 |
| 削除 | 書き出し完了時またはプロジェクト破棄時に `PendingFileDeletion` へ |
| 起動時 | どのプロジェクトからも参照されない行を回収し、実体も削除する |
| 実体が欠けている | そのキュー項目を **`paused(.sourceReselectionRequired)`** へ遷移させる。エラーで止めない |

`tmp/` に置くと OS がいつでも削除でき、再起動のたびにキューの復元が失敗します。それでもディスク不足で消える可能性はゼロにならないため、`paused(.sourceReselectionRequired)` を逃げ道として残し、**該当項目だけを再選択対象としてバッチ全体を失いません。**

##### インポート Saga

**ファイルシステムと SQLite、および DB と `ProtectedBlobStore` は、それぞれ同一トランザクションに参加できないため、補償可能な 1 つのインポート Saga として順序を固定して定義します。** 取り込みファイルは bridge がすでに物質化済み（選択手順 3）であり、Saga はそれを作り直しません。**手順 1 は所有権の移管です。**

| 順 | 操作 | 保存先 | 失敗時 |
| --- | --- | --- | --- |
| 1 | `PickedPhotoInput.importedFile` の**所有権を受け取る**（以降の削除責務は Saga 側） | — | ファイルを削除して選択を失敗として返す |
| 2 | `contentFingerprint` と EXIF を読む | — | 同上 |
| 3 | **向きを正規化した原寸ファイルを作成し、その SHA-256 とサイズを測る** | ファイルシステム | 手順 8 へ |
| 4 | **台帳トランザクションで、素材 identity を `SourceRecord` へ解決（無ければ作成）し、`ProjectSourceSnapshot` と `WorkingSourceBinding` を保存する** | ProtectedBlobStore | 手順 8 へ |
| 5 | **DB トランザクションで `Project`・キュー項目・`WorkingSourceRecord`（正規化ファイルを指す）を作成する** | DB | 手順 7 へ |
| 6 | **取り込みファイルを削除する。** 削除に失敗したら `PendingFileDeletion` へ積む | ファイルシステム | 起動時 GC へ委ねる |
| 7 | 手順 5 が失敗したら、**snapshot と binding を補償削除し、参照されなくなった `SourceRecord` も同じトランザクションで削除する** | ProtectedBlobStore | 起動時 GC へ委ねる |
| 8 | 失敗したら、作成済みのファイル（取り込み・正規化の両方）を削除するか `PendingFileDeletion` へ追加する | ファイルシステム | 起動時 GC へ委ねる |
| 9 | **手順 5 の完了後にのみ、選択処理の成功を呼び出し元へ返す** | — | — |

**手順 6 を DB 確定の後に置くのは、先に消すと手順 5 失敗時に再試行できないためです。** DB が確定していれば取り込みファイルはもう誰からも参照されないため、残っても孤児 GC が回収します。取り込みファイルは残しません。正規化後の原寸があれば処理は成立し、未加工の顔画像を端末へ二重に置く理由がありません。

**手順 4 で `SourceRecord` も作るのは、台帳の不変条件 9（全 `ProjectSourceSnapshot.identity` の alias がいずれかの `SourceRecord` に存在する）を満たすためです**（[アーキテクチャ設計](architecture.md) の 6.4）。snapshot 自体に `sourceID` は持たせず identity のまま持ち、解決は開始ゲートの内側で行います。統合後に古い `sourceID` を握ることを避けるためです。snapshot を DB より先に保存するのは、逆順だと「DB 行はあるが identity が無い」状態が生まれ `sourceID` を解決できなくなるためで、この順なら余るのは「snapshot はあるが `Project` が無い」状態だけです。これは起動時復旧の手順 5.5 で、`exportedSettingsEntries` の孤児と同じ走査により GC します（[書き出し Saga](export-saga.md) の 5）。

**`WorkingSourceRecord` は最初から向き正規化済みの原寸ファイルを指し、取り込みファイルを登録してから差し替える構成は採りません。** 差し替えの正誤規則が追加で必要になるためです。`contentFingerprint` は取り込みファイル（ピッカーが返した実データ）から計算します（[アーキテクチャ設計](architecture.md) の 6.4）。正規化後から計算すると、デコード実装の変更で同じ写真が別素材になります。

**手順 1〜4 の途中終了ではファイルがどの `WorkingSourceRecord` からも参照されず、起動時の孤児 GC が回収します。** 逆順（行を先に作る）は採りません。実体の無い `WorkingSourceRecord` を参照するキュー項目ができ、復元時に必ず `paused(.sourceReselectionRequired)` へ落ちるためです。**失っても復旧できない側を避ける**という原則（[アーキテクチャ設計](architecture.md) の DB とファイルの更新順序）に従います。

##### 素材スナップショットを署名して保存する

**`WorkingSourceRecord` だけでは、再起動後に `sourceID` を解決できません。** 選択・検出のあと書き出し開始前に終了すると、次がすべて失われます。

| 失われる値 | 影響 |
| --- | --- |
| `SourceIdentity`（`providerAssetKeyHash` / `contentFingerprint`） | 正規 `sourceID` を解決できない |
| `SourceRepresentation` | 診断の区分値が欠ける |
| EXIF 由来の撮影日時 | `suggestedCreationDate` を組み立てられない |
| 写真ライブラリの登録日時 | 同上 |

正規化済みファイルからは再計算できません。`contentFingerprint` は取り込みファイル基準の規約であり、取り込みファイルは手順 6 で削除済みだからです。**これらを未署名の DB 行へ置くと、`SourceIdentity` を書き換えて「別素材」を装い無料枠を回避できてしまいます。** `ProtectedBlobStore` の署名対象へ持たせます。型定義は [アーキテクチャ設計](architecture.md) の 6.3 が正本です。

| 契機 | 操作 |
| --- | --- |
| インポート Saga の手順 4 | **同じ台帳トランザクション**で追加する |
| 書き出しの手順 −2 | この snapshot から `sourceID` を解決する |
| 再選択 Saga の手順 3 | 候補の `SourceIdentity` と照合する |
| 履歴からの再編集・「変更せず再書き出し」 | 素材が同じであることの根拠にする |
| **`Project` の削除** | **ここでのみ削除する**（[アーキテクチャ設計](architecture.md) の 7.5） |

書き出しの完了でも保持期限到達でも削除しません。どちらで消しても再選択の照合元と再編集時の素材同一性が失われるためです。`sourceID` まで確定させない理由は上記インポート Saga のとおりで、alias 統合が認可と同じトランザクションで起こるためです（[アーキテクチャ設計](architecture.md) の 6.4）。要素数は履歴の保存期間内の `Project` 数で上限があります（同 6.3）。

##### 検出用の縮小画像の寿命

**縮小画像をファイルにしません。** `FaceDetector` の実装がメモリ内で作り、呼び出しの復帰時に解放します（5 章）。

| 項目 | 規約 |
| --- | --- |
| 生成 | **`FaceDetector` の実装の中。** `VerifiedImageSource.handle` から `withMappedBytes` で読む |
| 実体 | **メモリのみ。** `ManagedFileStore` へ書かない |
| 寿命 | `detect` の呼び出しから復帰までのスコープ |
| DB への登録 | **しない。** `WorkingSourceRecord` が指すのは原寸だけ |
| 再検出 | そのつど作り直す |

再検出は利用者が明示的に行う操作で頻度が低く、原寸から作り直す費用は 1 回の縮小だけです。**縮小をファイル化すると、binding を持たない派生ファイルへの読み取り経路が生まれ、検証済み境界（下記）を迂回した差し替えが可能になります。** 検出器の内側へ閉じ込めることで、この経路自体を無くします。

##### 再選択後の Saga

**`paused(.sourceReselectionRequired)` と履歴からの再編集は、どちらも「素材を選び直して既存 `Project` へ結び直す」操作です。** 定めないと、別の写真を選び直しても以前の顔座標・`ReviewIssue`・`ReviewDecision` を保持したまま再開できてしまいます。通常のインポート Saga は新しい `Project` を作り `ProjectSourceSnapshot` を上書きするため、比較対象を比較前に壊してしまい再利用できません。前半（手順 1〜4）は共通で、後半だけが分岐します。

| 順 | 操作 | 失敗時 |
| --- | --- | --- |
| 1 | 候補ファイルを**一時的に**物質化し、`contentFingerprint` と EXIF を読む | 候補ファイルを削除して終了 |
| 2 | **旧 `ProjectSourceSnapshot` は変更しない** | — |
| 3 | `transact` の内側で、候補の `SourceIdentity` と snapshot の `identity` が**同じ alias 連結成分へ解決されるか**を判定する（[アーキテクチャ設計](architecture.md) の 6.4） | 候補ファイルを削除して終了 |
| 4 | 不一致なら候補ファイルを削除し、選び直しを求める | — |
| 5 | 一致したら、**同じ台帳トランザクションで候補の alias を勝者 `SourceRecord` へ追加する** | 候補ファイルを削除して終了 |
| 6 | 向きを正規化した原寸ファイルを作り、SHA-256 とサイズを測る | 手順 10 へ |
| 7 | **台帳トランザクション**で `WorkingSourceBinding` を新しい値へ置換する。**置換前の値を保持しておく** | 手順 10 へ |
| 8 | **DB トランザクション**で後半（下記）を実行する | 手順 9 へ |
| 9 | 手順 8 が失敗したら、**台帳トランザクションで binding を置換前の値へ戻す** | 起動時の照合へ委ねる |
| 10 | 失敗経路では、作成済みの正規化ファイルと候補ファイルを `PendingFileDeletion` へ積む | — |
| 11 | 成功したら**候補ファイル（正規化前）を削除する。** 失敗したら `PendingFileDeletion` へ積む | — |

後半（手順 8）は `WorkingSourceRecord` の有無で決まります。**「再選択」と「再編集」を利用者の導線ではなく、DB の状態で分岐させます。**

| 現在の状態 | 呼ぶメソッド | 内容 |
| --- | --- | --- |
| `WorkingSourceRecord` **あり**（実体が欠損している場合を含む） | `replaceWorkingSource` | `sourceFile` を置換し、**トランザクション内で読んだ現在値**を `PendingFileDeletion` へ入れる。`createdAt` を `replacedAt` へ更新する |
| `WorkingSourceRecord` **なし**（24 時間で削除済み・履歴から開いた） | `attachWorkingSourceToExistingProject` | 行を新規作成する。`createdAt` は `attachedAt` |

どちらも同一 DB トランザクションで `FaceTrack` / `ReviewIssue` / `ReviewDecision` / `ReviewStatus` を破棄し、`detectionRevision` / `projectRevision` を増加させます。完了後に顔検出をやり直し、新しい確認が完了するまで書き出しできません。**`PreviewConfirmation` は DB に無くセッション内の値のため**（[正準スキーマ](canonical-schema.md) の 5.2）、`detectionRevision` が増えた時点で不一致になり、破棄操作自体が不要です。

##### 台帳と DB は同時に更新できない

**`WorkingSourceBinding` は署名済み台帳に、`WorkingSourceRecord` は `app.db` にあり、DB トランザクションの内側から台帳を更新することはできません**（[アーキテクチャ設計](architecture.md) の 7.1）。そのため手順 7 と 8 の間には片側だけが進んだ区間が必ず存在し、専用の変更ジャーナルを設ける代わりに起動時に安全側へ回復させます。

| 中断位置 | 台帳 | DB | 起動時の判定 |
| --- | --- | --- | --- |
| 手順 7 の前 | 旧 binding | 旧 record | 一致。**何も起きない** |
| **手順 7 と 8 の間** | **新 binding** | **旧 record** | 不一致。**`paused(.sourceReselectionRequired)` へ倒し、選び直しからやり直す** |
| 手順 8 の後 | 新 binding | 新 record | 一致。**完了している** |
| 手順 9（補償）の後 | 旧 binding | 旧 record | 一致。**何も起きない** |

中断区間では再選択の操作だけがやり直しになり、素材・設定・検出結果は壊れず、別画像が正規の binding として通ることもありません。**逆順（DB を先）にはできません。** 新しいファイルが binding に無い状態で `WorkingSourceRecord` から参照される区間が生まれ、「binding があって record が無い」＝孤児、「record があって binding が無い」＝差し替え、という一意な解釈が崩れるためです。**更新は台帳先行、削除は DB 先行で固定します（この原則は他の更新・削除経路すべてに適用します）。**

`createdAt` は保持期限の起点であるため更新します。更新しないと再選択直後に 24 時間期限へ到達し再び削除されます。`previousSourceFile` は呼び出し側から渡さず、置換対象は DB トランザクション内で読みます。読んだ時点とトランザクションの間に別経路が置換すると、現在使用中のファイルを削除対象として渡しかねないためです。手順 8 以降は再検出の既存規則（[アーキテクチャ設計](architecture.md) の 6.1）と同じで、再選択は再検出を伴うため確認状態の破棄も自動的に成立します。

##### 実装の所在

**インポート・再選択・再接続・複製の 4 つの Saga と、検証失敗時の無効化は `Application` の `SourceImportCoordinator` が所有します。** いずれもファイル・DB・台帳を協調させるため、`App` の境界サービスにも `Domain` にも置けません（[アーキテクチャ設計](architecture.md) の 4.3）。

```swift
// Domain — 永続化ポート
protocol WorkingSourceStore: Sendable {
    /// インポート Saga の手順 5。単一 DB トランザクション
    func createProjectWithWorkingSource(_ input: CreateWorkingSourceInput) async throws

    /// 素材更新 Saga の手順 8（DB 側）。単一 DB トランザクション
    func replaceWorkingSource(_ input: ReplaceWorkingSourceInput) async throws

    /// 履歴の既存 Project へ処理用素材を再接続する（下記）
    func attachWorkingSourceToExistingProject(
        _ input: AttachWorkingSourceInput
    ) async throws

    /// 保持期限と台帳修復での破棄
    func deleteWorkingSource(_ projectID: ProjectID) async throws
}
```

**`WorkingSourceStore` は DB トランザクションだけを実装します。** 入力に署名済み台帳の値（`WorkingSourceBinding` や解決済み `SourceID`）を持たせません。持たせると、DB アダプタが台帳を書けるかのような契約になり、**「同一トランザクションで両方を更新する」という実装できない読み方**を招きます。台帳の更新は Saga 側が別トランザクションで行います（インポートは手順 4、再選択・再接続は手順 3・5・7）。

```swift

struct CreateWorkingSourceInput: Sendable {
    let projectID: ProjectID
    let batchID: BatchID?
    let queueItemID: ExportQueueItemID?
    let sourceFile: WorkingSourceFileRef      // 向き正規化済みの原寸
    let createdAt: Date
    let sourceLocator: ProjectSourceLocator
    let initialSpec: RenderSpec
}

struct ReplaceWorkingSourceInput: Sendable {
    let projectID: ProjectID
    let newSourceFile: WorkingSourceFileRef
    let replacedAt: Date       // createdAt もこの値へ更新する
    // 旧ファイルは DB トランザクション内で読む。呼び出し側から渡さない
}

struct AttachWorkingSourceInput: Sendable {
    let projectID: ProjectID
    let sourceFile: WorkingSourceFileRef
    let attachedAt: Date
}
```

##### 実体と署名済み identity を結び付ける

**`ProjectSourceSnapshot` は署名済みですが、実体側の `WorkingSourceRecord` は未署名の DB 行です。** `sourceFile` を別プロジェクトの `.processingTemporary` ファイルへ差し替えると、次の状態を作れます（`kind` の検査ではどちらも `.processingTemporary` のため防げません）。

| 参照するもの | 値 |
| --- | --- |
| クォータ・トライアルの判定 | 元の署名済み `identity` |
| 実際にレンダリングする画像 | 差し替えた別の写真 |

署名対象へ、実体との結び付きを持たせます。

```swift
/// UsageLedger の一部。projectID ごとに 0 件または 1 件
struct WorkingSourceBinding: Sendable, Equatable {
    let projectID: ProjectID
    let sourceFile: WorkingSourceFileRef
    let normalizedFileSHA256: Data     // 32 バイト。正規化後ファイルの全バイト
    let byteSize: Int64
}
```

| 契機 | 操作 |
| --- | --- |
| インポート（手順 4）・再選択・再接続 | 正規化ファイルの作成後、**その台帳トランザクションで追加または置換する** |
| 起動時復旧（手順 4.5） | `WorkingSourceRecord` を持つ全 `Project` について実体と照合する |
| **書き出しの手順 −2** | 認可の内側で照合する。不一致なら開始しない |
| `WorkingSourceRecord` の削除 | **DB を先に消す。** 残った binding は孤児として台帳側で回収する（下記） |

| 照合結果 | 扱い |
| --- | --- |
| 一致 | 続行する |
| `sourceFile` が binding と違う | **差し替え。** その `Project` の `WorkingSourceRecord` を破棄し、`paused(.sourceReselectionRequired)` へ |
| ハッシュまたはサイズが違う | 同上 |
| **`WorkingSourceRecord` があり binding が無い** | 同上。**照合できないものを通しません** |
| **binding があり `WorkingSourceRecord` が無い** | **孤児。** 台帳トランザクションで binding を削除する |

起動時と書き出し開始時の 2 回照合します。起動時だけでは起動後の差し替えを検出できず、書き出し開始時だけでは編集画面が差し替え後の画像を表示したまま操作できてしまうためです。

##### binding は DB を先に消す

**`WorkingSourceRecord`（DB）と binding（台帳）は同一トランザクションで消せないため、上記の原則どおり DB を先に消します。**

| 順 | 操作 |
| --- | --- |
| 1 | DB トランザクションで `WorkingSourceRecord` を削除し、実体を `PendingFileDeletion` へ積む |
| 2 | 台帳トランザクションで binding を削除する（または起動時の孤児回収に委ねる） |

逆順にすると「record があり binding が無い」状態になり、正常な削除の途中経過が差し替えとして誤検出されます。DB を先に消せば余るのは孤児 binding だけで、照合の判定に影響しません。**この順序は書き出しの手順 7、24 時間期限の削除、`Project` 削除 Saga、台帳修復のすべてに適用します。**

照合は起動時復旧の手順 4.5 で行います。コミット復旧（手順 4）より前に置くと、手順 7 完了で消えるはずの `WorkingSourceRecord` を差し替えとして誤検出するためです（[書き出し Saga](export-saga.md) の 5）。

##### 検証済み境界を通してのみ実体を開く

**起動時と書き出し開始時の 2 点だけでは足りません。** その間に DB の `sourceFile` を別画像へ差し替えられると、起動時照合を通過した `Project` でもプレビュー・再検出・「Free 版として複製」が別画像を読み、複製先に誤って新しい正規 binding が作られてしまいます（本書内で扱う差し替え系の脅威はすべてこの 1 パターンです）。**そのため `WorkingSourceRecord` を直接読ませず、原寸ファイルを開くすべての入口を検証済み境界へ集約します。**

```swift
enum WorkingSourceInvalidity: Sendable, Hashable {
    case fileMismatch        // sourceFile が binding と違う
    case contentMismatch     // ハッシュまたはサイズ不一致
    case bindingMissing      // record があり binding が無い
    case recordMissing       // 行が無い（再接続が必要）
    case entityMissing       // 実体ファイルが無い
}

```

`VerifiedWorkingSource` と `withVerifiedSource` の定義は下記です。

| 入口 | 検証 |
| --- | --- |
| プレビュー表示 | 必須 |
| 顔検出・再検出 | 必須 |
| 書き出し（手順 −2 と手順 1） | 必須 |
| **「Free 版として複製」のコピー元** | **必須** |
| 履歴サムネイルの生成 | 必須 |
| その他の原寸ファイル読み込み | 必須 |

##### 検証と無効化を分ける

**resolver は永続状態を変更しません。** 検証失敗の後始末（`WorkingSourceRecord` の破棄・削除予約・`paused` 遷移・binding 削除）は DB・台帳・ファイルへの書き込みであり、読み取り専用の契約と両立しないためです。

| 役割 | 主体 | 内容 |
| --- | --- | --- |
| 検証 | `WorkingSourceVerifier`（resolver の実装） | 照合して `body` を実行する。**`projectID` ごとに直列化する**（下記） |
| **無効化** | **`SourceImportCoordinator` の `invalidateWorkingSource(projectID:)`** | DB（record 破棄・キュー遷移・`PendingFileDeletion`）→ 台帳（binding 削除）の順で実行する |

**無効化を新しい Coordinator にしません。** 無効化は同じ `projectID` の再選択・再接続と競合するため、**`SourceImportCoordinator` の `projectID` 待機キューで直列化する必要があります**（[アーキテクチャ設計](architecture.md) の 4.3）。別の actor に置くと、2 つの排他機構が同じ `Project` を同時に触ります。

| `withVerifiedSource` の結果 | 呼び出し側の対応 |
| --- | --- |
| `completed(R)` | 続行する |
| `invalid(.recordMissing)` | 再接続の導線を出す（無効化は不要。壊れた状態ではない） |
| `invalid`（それ以外） | **`invalidateWorkingSource(projectID:)` を呼ぶ** |

##### 無効化は理由を受け取らず、内側で再判定する

**呼び出し側が観測した理由を無効化の根拠にしません。** 再選択 Saga の手順 7（台帳）と手順 8（DB）の間に読み取りが挟まると `.fileMismatch` が返りますが、待機キュー取得時点では再選択が正常完了している可能性があり、陳腐化した理由で破棄すると正しく張り替えられた `WorkingSourceRecord` を壊してしまいます。

```swift
// Application — SourceImportCoordinator。projectID ごとに直列化する
func invalidateWorkingSource(projectID: ProjectID) async throws -> InvalidationOutcome

enum InvalidationOutcome: Sendable, Equatable {
    case invalidated(WorkingSourceInvalidity)   // 再判定でも無効だったので破棄した
    case nowValid                               // 再判定で有効。何もしなかった
    case alreadyAbsent                          // 既に record が無い
}
```

| 規則 | 内容 |
| --- | --- |
| 引数 | **`projectID` だけ。** `reason` を受け取らない |
| 最初の操作 | **排他区間の内側で照合をやり直す**（DB の現在値・台帳の現在値・実体） |
| 再判定で有効 | **`nowValid` を返して何もしない。** 破棄しない |
| 再判定でも無効 | DB → 台帳の順で破棄し、`invalidated` を返す |
| 冪等性 | 2 回目以降は `alreadyAbsent` を返す |

**この原則は `replaceWorkingSource` の `previousSourceFile`（上記）と `deleteHistoryUnit` の `DeletionContext`（[アーキテクチャ設計](architecture.md) の 7.5）にも共通します。** 実装主体は `Application` です。DB・台帳・ファイルの 3 者を読むため `Persistence` の単一アダプタにも `Domain` にも置けません（同 4.3）。プロトコルは `Domain` が定義します。

**`VerifiedWorkingSource` を `body` の引数にするのは、検証を通らずに `WorkingSourceFileRef` を得る経路を無くすためです。** ハッシュは正規化後ファイル（`contentFingerprint` とは別物）に対して取ります。照合したいのは「いま処理しようとしている実体」だからです。

##### 照合と読み取りを 1 つのスコープへ閉じる

**「ハッシュを読む」と「実体を開く」が別の読み取りだと、その間に差し替えられます。** 24 時間以内の再書き出しは `freeMonthlyReexport` で消費 0 のため、検証直後に別画像へ差し替えれば 1 枠の消費で任意枚数を書き出せてしまいます。**照合と利用を同じスコープへ閉じ、`VerifiedWorkingSource` を外へ持ち出せない形にします。**

```swift
// Domain — 処理用実体を開く唯一の入口
protocol VerifiedWorkingSourceResolver: Sendable {
    /// 照合してから body を実行する。body の実行中だけ実体が有効。
    /// 照合が成立しなければ body を呼ばず WorkingSourceInvalidity を返す
    func withVerifiedSource<R: Sendable>(
        _ projectID: ProjectID,
        _ body: @Sendable (VerifiedWorkingSource) async throws -> R
    ) async throws -> VerifiedUseResult<R>
}

enum VerifiedUseResult<R: Sendable>: Sendable {
    case completed(R)
    case invalid(WorkingSourceInvalidity)
}
```

**照合したディスクリプタを、消費側へそのまま渡します。** 開き直す経路を残すと、その間に inode を差し替えられるためです。

```swift
/// 検証済みの実体。開いたファイルそのものを表す
struct VerifiedWorkingSource: Sendable {
    let projectID: ProjectID
    let binding: WorkingSourceBinding      // 照合に使った値
    let verifiedAt: Date

    /// 照合に使ったのと同一のディスクリプタから読み出す。
    /// パスを解決し直さない。body のスコープ内でのみ有効
    let handle: OpenFileHandle
}

/// 開いたファイルの読み取り口。Domain は fd の値を見ない
protocol OpenFileHandle: Sendable {
    var byteSize: Int64 { get }

    /// ハッシュ計算などの逐次読み出し
    func read(offset: Int64, length: Int) async throws -> Data

    /// 全体を一括で参照する。Image I/O / Core Image への受け渡しに使う。
    /// 同期・非エスケープ。ポインタは body の外へ持ち出せない
    func withMappedBytes<R>(
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) throws -> R
}
```

`withMappedBytes` は `Domain` が参照できない `CoreGraphics` / `CoreImage` に触れずにメモリマップした領域を渡すための入口で、`Adapters` 側が `CFData` / `CGDataProvider` を組み立てます（[アーキテクチャ設計](architecture.md) の 3.3）。`read` だけでは 48 メガピクセルの原寸を `Data` として抱えることになり 50 枚の一括処理でメモリが尽きるため、マップ経由の入口が必要です。

| 規則 | 内容 |
| --- | --- |
| 同期にする | `async` にすると `UnsafeRawBufferPointer` を `Sendable` 境界へ通すことになる。**マップ中に中断点を作らない** |
| 非エスケープ | `body` の外でポインタを保持したら未定義動作とする |
| 実装 | 照合に使ったのと同じディスクリプタを `mmap` する。**パスを解決し直さない** |
| **`body` の役割** | **「バイト列 → デコード済みピクセルバッファ」の変換だけ**（下記） |

**`body` の外へ持ち出すのは、デコード済みピクセルではなく圧縮バイト列のコピーです。** 検出では縮小済み `CGImage`、書き出しでは圧縮バイト列を `Data` へコピーして返し、デコードは `body` の外（マップ解除後）で行います。デコード結果を持ち出すと 48 メガピクセルの RGBA8 を合成・エンコードの全期間抱えることになるため採りません（3 章が退けたのはラスタ化済みスタンプのビットマップ（非圧縮）についてであり、原寸写真の圧縮バイト列とは区別します）。`CIImage` はタイル単位で評価されるため `CGContext` へ原寸を描き込む方式より使用量が小さく、`batchConcurrencyLimit = 1`（v1）で同時に処理するのは 1 枚です。

処理用素材のファイルは書き込みが一度きりで、既存の inode へ追記も切り詰めも行う経路が存在しません。削除は `PendingFileDeletion` 経由の `unlink` であり、開いているディスクリプタのマップは無効化されません。

| 規則 | 内容 |
| --- | --- |
| `VerifiedWorkingSource` の寿命 | **`body` の実行中のみ。** `handle` を外へ保持したら未定義動作とする |
| ファイルを開く主体 | **`WorkingSourceVerifier` が 1 回だけ開く。** 消費側は開かない |
| 照合の位置 | **開いた `handle` からハッシュを計算する。** パスを解決し直さない |
| 消費側への受け渡し | **`handle` を渡す。** `ManagedFileRef` や `URL` を渡して開き直させない |
| 復帰後の再利用 | **禁止。** 別の操作は `withVerifiedSource` を再度呼ぶ |
| 編集セッション中の使い回し | **禁止。** プレビューの再描画も、そのつどこの入口を通る |

**`FaceDetector` と `ImageEffectRenderer` の引数を `ImageSource` から `VerifiedImageSource` へ変えます。** `ManagedFileRef` を受け取る限り実装が自分でパスから開き直せてしまうため、型の上で開き直せないようにします。**`PickedPhotoLoader` は対象外です。** 取り込み時点では `WorkingSourceBinding` がまだ存在せず照合対象が無いため、`ManagedFileRef` のままとします（「まだどこからも参照されていない新しいファイル」しか読まないため安全です。既存 `Project` の素材を読む経路には使いません）。

```swift
/// レンダラーと検出器へ渡す入力。開いたディスクリプタを持つ
struct VerifiedImageSource: Sendable {
    let handle: OpenFileHandle
    let pixelSize: PixelSize          // 向き正規化後
    let format: ImageFormat
}

protocol FaceDetector: Sendable {
    func detect(_ source: VerifiedImageSource) async throws -> DetectionResult
}

protocol ImageEffectRenderer: Sendable {
    func render(
        source: VerifiedImageSource,
        plan: RenderPlan,
        rasterAssets: [String: RasterizedStampAsset]
    ) async throws -> RenderedImage
}
```

検出用の縮小は `FaceDetector` の内側で行います。縮小画像は `.processingTemporary` の派生ファイルであり binding を持たないため `VerifiedImageSource` を作れず、呼び出し側で縮小する構成にはできません。

| 項目 | 規約 |
| --- | --- |
| 縮小の実行者 | **`FaceDetector` の実装（`Adapters`）** |
| 入力 | **`VerifiedImageSource`**（原寸。`handle` 経由） |
| 縮小の方法 | `withMappedBytes` で得たバイト列から `CGImageSourceCreateThumbnailAtIndex`（`kCGImageSourceThumbnailMaxPixelSize = 1920`） |
| 中間ファイル | **作らない。** メモリ内で完結する |
| 報告 | `DetectionResult.detectionPixelSize` に**実際に検出へ渡した寸法**を入れる |

`LoadedPhoto` から `detectionSource` は外し、再検出も `withVerifiedSource` → `VerifiedImageSource` → `detect` の 1 経路に統一します（`PickedPhotoLoader` は通りません）。**`ImageSource` は残します。** 処理用素材以外（ラスタ一時ファイル、履歴サムネイルの入力）には binding が無く照合の対象にならないためで、`VerifiedImageSource` を要求するのは `WorkingSourceRecord` が指す原寸を読む経路だけです。

**上書き（同じ inode への書き込み）も防ぎます。** `body` の完了後、同じ `handle` からハッシュを再計算して開始時の値と一致することを確認し、不一致なら `R` を破棄し `invalid(.contentMismatch)` を返します。

| 段階 | 照合 |
| --- | --- |
| `body` の開始前（`handle` を開いた直後） | ハッシュとサイズを binding と照合する |
| **`body` の完了後（`handle` を閉じる前）** | **同じ `handle` で再計算し、開始時の値と一致することを確認する** |

この 2 段構えが成立するのは `body` 内のすべての読み取りが同じ `handle` を経由するからで、消費側が開き直せる設計では旧 inode を見続け差し替えを構造的に検出できません。**排他が必要です。** `body` は書き出しやプレビュー描画の全体を包む長時間スコープであり、その間に `replaceWorkingSource` や `invalidateWorkingSource` が走ると開いている実体が削除対象になります。`WorkingSourceVerifier` も `projectID` ごとに直列化し、`SourceImportCoordinator` と同じ待機キューを共有します（[アーキテクチャ設計](architecture.md) の 4.3）。**プレビューも同じ規則に従い、1 回の `withVerifiedSource` の内側で描画を完結させ、パラメータ変更ごとに入口を通り直します。**

##### 照合に使ってよいもの・使ってはいけないもの

| 使う | 使わない |
| --- | --- |
| 署名済み `ProjectSourceSnapshot.identity` と台帳の alias グラフ | `ProjectSourceLocator`（未署名の平文参照。ファイル取り込みでは `nil`） |
| `transact` の内側での解決 | `SourceIdentity` 同士の直接比較（取得経路の差で同じ写真が不一致になる） |

**別の写真での続行を許しません。** バッチの一項目が別素材へ差し替わると、`sourceID` が変わってクォータの前提が崩れ、利用者にとっても「どの写真を処理したか」が分からなくなります。新しい写真を処理したい場合は、新しいバッチを作ります。

**検出結果を再利用しません。** 元素材のバイト列が同じでも、正規化の実装が更新されていれば座標がずれます。再選択・再接続はいずれも再検出を伴います。

**`ProjectSourceSnapshot` は `Project` の削除でのみ消します。** 素材の欠損・保持期限の到達・書き出しの完了のいずれでも削除しません。どれで消しても比較対象が失われます。

##### 未完了作業の保持期限

**`createdAt` を期限判定に使います。** 書き出しも破棄もされないプロジェクトを放置すると、未加工の顔画像が無期限に残るためです。

| 項目 | 規約 |
| --- | --- |
| 保持期限 | `createdAt` から **24 時間** |
| 判定に使う時刻 | `retentionNow`。`nil` の間は削除しない（[アーキテクチャ設計](architecture.md) の 6.3） |
| 期限到達時 | **DB トランザクションで `WorkingSourceRecord` を削除**し、実体を `PendingFileDeletion` へ積む。台帳の binding はその後に削除する（順序は上記） |
| キュー項目 | `paused(.sourceReselectionRequired)` へ遷移させる |
| `Project` | **削除しない。** 設定と検出結果は履歴の保存期間に従う |
| `ProjectSourceSnapshot` | **削除しない。** 再選択の照合元として必要 |
| 判定の契機 | 起動時の孤児 GC と同じタイミング |

期限で消すのは実体だけです。snapshot まで消すと再選択直後に「同じ写真か」を判定する材料が無くなり `paused(.sourceReselectionRequired)` から復帰できません。24 時間は未受け渡し出力の保持期間と揃え、利用者から見た「作業を再開できる窓」を 1 つにします。`Project` を残すのは設定と検出結果が未加工画像を含まないためで、同じ写真を選び直せば `sourceID` が一致し無料の再書き出しも成立します。

##### 写真ライブラリの読み取り権限

**`PhotosPicker` そのものは権限を必要としません。** 一方、`PHAsset.fetchAssets` で `creationDate` や永続的な素材参照を取得する処理には明示的な PhotoKit 権限が要ります。

| 場面 | 権限 |
| --- | --- |
| 新規加工の開始 | **要求しない。** `PhotosPicker` だけで完結する |
| `providerAssetIdentifier` | `itemIdentifier` が得られる場合だけ使う |
| 写真ライブラリへの保存 | `PHAssetCreationRequest`。**追加のみの権限**で足りる |
| **履歴から元素材を直接読み込む** | **この時点で読み取り権限を要求する** |

**撮影日時の取得元は用途ごとに分けます。**

| 用途 | 取得元 |
| --- | --- |
| `ProjectSourceSnapshot.capture`（`OriginalCaptureMetadata`） | **EXIF のみ**（[正準スキーマ](canonical-schema.md) の 5.1.1）。無ければ各フィールドが `nil` |
| 出力 EXIF への書き戻し（[アーキテクチャ設計](architecture.md) の 7.5） | 同上。ローカル表記のまま往復させる |
| 写真ライブラリ保存時の `creationDate` | `PHAsset.creationDate`（権限がある場合のみ）→ EXIF → 設定しない |

**`contentFingerprint` には撮影日時を含めません**（[アーキテクチャ設計](architecture.md) の 6.4）。日時は同一性の判定材料ではなく出力メタデータの材料であり、EXIF パーサの差が fingerprint を動かす経路を作らないため、入力はファイルの全バイトだけに限ります。`capture` を権限に依存させないのは、権限取得の前後で撮影日時が変わると出力 EXIF と `suggestedCreationDate` が起動ごとに揺れるためです。

##### 再編集にはハッシュではなく平文の参照が要る

**`providerAssetKeyHash` から `PHAsset` は取得できません。** クォータ用の alias は復元不能なハッシュです。これしか保存していなければ、履歴からの再編集は権限があっても実行できません。

```swift
/// 再編集のための参照。クォータ用の SourceAlias とは別物
struct ProjectSourceLocator: Sendable, Equatable {
    /// PHAsset.localIdentifier。ファイル取り込み等で取得できない場合は nil
    let photoLibraryLocalIdentifier: String?
}
```

| 項目 | 規約 |
| --- | --- |
| 保存先 | **`app.db` の `Project` のみ** |
| バックアップ | 対象外（[アーキテクチャ設計](architecture.md) の 7.4） |
| ログ・分析・診断 | **一切出さない。** 分析イベントのフィールド型にしない（[アーキテクチャ設計](architecture.md) の 9.2） |
| `UsageLedger` への保存 | **しない。** クォータ側は `providerAssetKeyHash` のまま |
| `nil` の場合 | 再編集で再選択を求める |
| `Project` の削除 | 同じ行なので同時に消える |

**クォータ側を平文に戻しません。** 仕様 14.5 が制限しているのは不正利用防止のための識別子収集です。再編集は利用者自身が要求する機能であり、その実現に必要な最小の参照を利用者のデータと同じ寿命・同じ保護で持つことは目的が異なります。**2 つを 1 つのフィールドへまとめないことが要点です。**

## 6. 手動領域

手動領域はすべて `Domain` 側で扱います。**`MediaKit` は手動領域を認識せず**、`RenderPlan` の `RenderRegion` として渡されたものを描画するだけです。手動指定領域は `FaceTrack`（`createdManually = true`）として扱い、自動検出された顔と同じ経路を通ります。

描画順だけが異なります。`compileRenderDraft` は `RegionOrigin.manual` を `auto` より後の `order` に置きます（4 章）。

**動画向けの契約は v1 の実装対象外です。** 契約案は [商品面の決定](product-decisions.md) の v2 ロードマップにあります。

---
