# 顔かくし 技術スタックおよびアーキテクチャ設計

| 項目 | 内容 |
| --- | --- |
| 文書名 | 顔かくし 技術スタックおよびアーキテクチャ設計 |
| バージョン | 1.29 |
| 作成日 | 2026-07-27 |
| 対象 | 写真・動画向け顔匿名化アプリ（iOS / Android） |
| 上位文書 | 写真・動画向け顔匿名化アプリ 仕様書 v0.1 |
| 本書の範囲 | 技術選定、モジュール構成、境界設計、データフロー、エラー設計、テスト戦略、リリース段階 |
| 本書の対象外 | 画面ごとの視覚デザイン（配色・余白・タイポグラフィは `ui-mock/` を参照）、スタンプの意匠 |

本書は上位仕様書からいくつかの点で逸脱します。逸脱の一覧と理由は 15 節に集約しています。

挙動の定義については **本書が正であり、`ui-mock/` は本書に追従します**（14 節）。

---

## 1. 前提

### 1.1 実装体制

本プロジェクトの実装者は Claude Code 単独です。この制約が技術選定を支配します。

同一のドメインロジックを二度実装すると、実装コストが倍になるだけでなく、両者が徐々に乖離して仕様差異バグを生みます。したがって **共有できる層を最大化する構成** を最優先とします。

### 1.2 上位仕様からの変更点

仕様書 4.2 は iOS / Android のフルネイティブ二本立て（Swift + SwiftUI / Kotlin + Jetpack Compose）を指定していますが、本設計ではこれを変更します。変更理由は 3 節に記述します。

仕様書のドメイン要件（プラン、課金、プライバシー、エラー、性能、テスト条件）は、15 節に列挙する逸脱を除いて変更しません。

---

## 2. 確定した技術スタック

### 2.1 全体

| 領域 | 採用技術 |
| --- | --- |
| 共有基盤 | Kotlin Multiplatform (KMP) |
| 共有 UI | Compose Multiplatform (CMP) |
| iOS プラットフォームアダプタ | Swift |
| Android プラットフォームアダプタ | Kotlin |
| ローカル DB | Room KMP |
| DI | Koin |
| 課金 | RevenueCat KMP SDK (`purchases-kmp`) |
| 広告 | Google Mobile Ads（`expect`/`actual` で自前ラップ） |
| クラッシュ解析 | Sentry KMP SDK |
| バックエンド | Rust + Axum（リモート設定と診断のみ） |
| 対応 OS | iOS 17 以降 / Android 10 (API 29) 以降 |

### 2.2 iOS プラットフォームアダプタ

| 用途 | 採用 API |
| --- | --- |
| 顔検出 | Vision |
| 写真選択 | PhotosPicker |
| 画像読み込み・向き正規化 | Image I/O |
| エフェクト描画 | Core Image（`CIPixellate` / `CIGaussianBlur`） |
| エンコード・メタデータ除去 | Image I/O |
| 写真ライブラリ保存 | PhotoKit（`PHAssetCreationRequest`） |
| 署名鍵の保管 | Keychain（**鍵のみ**。データ本体は置かない） |
| 署名付きデータの保管 | アプリ専用ディレクトリ上のファイル（HMAC 付き） |
| 動画（次リリース） | AVFoundation / AVAssetWriter |

### 2.3 Android プラットフォームアダプタ

| 用途 | 採用 API |
| --- | --- |
| 顔検出 | ML Kit Face Detection |
| 写真選択 | Android Photo Picker |
| 画像読み込み・向き正規化 | ImageDecoder |
| エフェクト描画 | OpenGL ES 2.0（フラグメントシェーダ） |
| エンコード・メタデータ除去 | `Bitmap.compress` + ExifInterface |
| 写真ライブラリ保存 | MediaStore |
| 署名鍵の保管 | Android Keystore（**鍵のみ**。エクスポート不可の HMAC 鍵） |
| 署名付きデータの保管 | Proto DataStore（HMAC 付き） |
| 動画（次リリース） | Jetpack Media3 Transformer |

Android の最低対応が API 29 のため、`RenderEffect`（API 31 以降）は使用できません。ぼかしとモザイクは OpenGL ES 2.0 のフラグメントシェーダで実装します。

**鍵とデータ本体を分けます。** Android Keystore は任意長のデータを格納する場所ではなく、鍵の保管とその鍵による暗号処理を提供する仕組みです。`UsageLedger` や `SubscriptionState` の本体は DataStore 側に置き、Keystore の鍵で HMAC を付けます。iOS の Keychain も同じ扱いとし、両 OS で `CryptoKeyStore`（鍵）と `ProtectedBlobStore`（署名付きデータ）の 2 契約に分けます（4 章）。

---

## 3. 技術選定の根拠

### 3.1 アプリの構造的な分割

本アプリは、共有できない層と共有すべき層が明確に分かれます。

| 層 | 内容 | 共有可否 |
| --- | --- | --- |
| メディアエンジン | 顔検出、デコード、GPU 加工、エンコード、写真ライブラリ保存 | 不可 |
| ドメイン | トラック関連付け、キーフレーム補間、座標正規化、プラン判定、月次クォータ、キュー状態機械、ストレージ推定 | 可 |
| UI | 顔レビュー、エフェクト選択、スタンプ、Paywall、履歴、バッチ | 可 |
| 周辺 | 課金、広告、DB、分析、リモート設定 | 可 |

共有できないのは全体の 3〜4 割です。残り 6〜7 割を二重実装するかどうかが、単独実装での成否を決めます。

### 3.2 検討した選択肢

| 案 | UI コードベース | Android UI | iOS UI | 判定 |
| --- | --- | --- | --- | --- |
| A: Flutter + ネイティブメディア層 | 1 本 | 自前描画 | 自前描画 | 不採用 |
| **B-1: KMP + CMP** | **1 本** | **ネイティブ** | 自前描画 | **採用** |
| B-2: KMP のみ（UI は二本） | 2 本 | ネイティブ | ネイティブ | 不採用 |
| C: フルネイティブ二本立て（仕様書 4.2） | 2 本 | ネイティブ | ネイティブ | 不採用 |

### 3.3 採用理由

**案 C を採らない理由。** キーフレーム補間、トラック関連付け、クォータ判定といった誤りやすいロジックを二重実装することになり、仕様差異バグの温床となります。単独実装では最も割に合いません。

**案 A を採らない理由。** Flutter と CMP は UI の実現方式が同質です。どちらもネイティブコードへコンパイルされ、UI は自前のレンダリングエンジンが直接描画します（Flutter は Impeller、CMP は Skia）。ウェブ技術は使いません。両者の実質的な差は次の 2 点です。

- Android では Jetpack Compose がプラットフォーム純正の UI ツールキットそのものであるため、CMP の Android は自前描画ではなく本物のネイティブになります。Flutter は Android でも自前描画です
- 使用言語が Flutter は 3 つ（Dart / Swift / Kotlin）、CMP は 2 つ（Kotlin / Swift）になります

**案 B-2 を採らない理由。** UI がこのアプリの実装量の最大部分を占めます。どの画面で iOS 純正の見た目が必要かが判明していない段階で全画面を二重化するのは過剰投資です。加えて本アプリの主画面（顔レビュー、エフェクト調整）は Canvas による自前描画が主体であり、B-2 を選んでも純正の見た目にはなりません。

**案 B-1 を採る理由。** 上記に加えて、選択のリスクが片側にしか開かないためです。

- KMP のドメイン層は B-1 / B-2 / C のいずれでもそのまま使える資産です。UI 戦略を変更しても破棄せずに済みます
- CMP は `ComposeUIViewController` として組み込まれるため、iOS では画面単位で SwiftUI と混在できます。B-1 で開始し、純正感が必要な画面のみ後から SwiftUI へ差し替える段階移行が成立します
- 対して Flutter は全か無かであり、後からネイティブへ寄せる経路が存在しません

### 3.4 選定時に確認した外部事実

- Compose Multiplatform for iOS は 1.8.0（2025年5月）で Stable
- KMP は Google が I/O 2024 で公式サポートを表明。Room が KMP 対応済み
- ただし Google が支援しているのは KMP（ロジック共有）であり、CMP（iOS UI）は JetBrains 単独である。KMP の採用実績を CMP の実績と同一視しない
- RevenueCat は公式 KMP SDK を提供。v3.0.0（2026年5月）で iOS フレームワークの手動リンクが不要化
- Sentry KMP SDK は 0.26.0（2026年5月）でメジャーバージョン前。各プラットフォーム SDK のラッパー

### 3.5 CMP 採用に伴い受け入れるリスク

| リスク | 内容 | 緩和策 |
| --- | --- | --- |
| iOS の OS デザイン刷新に自動追随しない | CMP は自前描画のため、iOS 側の意匠変更にはフレームワークの対応を待つ | 影響は設定・履歴・Paywall 等に限定。必要なら当該画面のみ SwiftUI へ差し替える |
| iOS のアクセシビリティ | Canvas 自前描画部分は `semantics` の明示的な付与が必須 | 仕様 29 章を受入条件とし、12 節のテスト戦略で担保 |
| CMP は JetBrains 単独支援 | 将来の開発継続性が Google 支援の KMP ほど堅くない | ドメイン層を CMP に依存させない。UI 差し替え経路を確保しておく |
| 広告 SDK の自前ラップ | 公式 KMP SDK が存在しない | `expect`/`actual` の薄いポートに閉じ込め、契約テストで両 OS の挙動を揃える |

---

## 4. モジュール構成

```
kaokakushi/
├── composeApp/              CMP アプリ本体（共有 UI とエントリポイント）
│   ├── commonMain/          全画面の Compose UI、ナビゲーション、StampRasterizer 実装（5.1.1）
│   ├── androidMain/         Activity、AndroidView（広告バナー）
│   └── iosMain/             ComposeUIViewController、UIKitViewController 埋め込み
│
├── shared/
│   ├── domain/              純粋 Kotlin。プラットフォーム依存ゼロ
│   ├── data/                Room KMP、ファイル管理、ProtectedBlobStore
│   │   └── security/        CryptoKeyStore（HMAC 鍵のみ）
│   ├── media/               画像選択・読み込み・検出・描画・エンコード・保存・共有
│   ├── billing/             RevenueCat ラッパと権限解決
│   ├── ads/                 AdPresenter
│   └── analytics/           イベント定義と送信
│
├── iosApp/                  Xcode プロジェクト
│   ├── App/                 SwiftUI シェル（画面単位の差し替え点）
│   └── Media/               Vision / Core Image / PhotoKit 実装
│
├── server/                  Rust + Axum（リモート設定と診断のみ）
│
└── ui-mock/                 Next.js による UI モック（参照専用。実装には流用しない）
```

### 4.1 依存の向き

依存は **UI → domain ← 各アダプタ** の一方向とします。`domain` がポート（インターフェース）を定義し、`data` / `media` / `billing` / `ads` / `analytics` がそれを実装します。

`domain` は他のいかなるモジュールにも依存しません。Kotlin 標準ライブラリと `kotlinx-datetime` 以外の依存を持ちません。**Compose の型（`IntSize`、`Color`、`Offset` 等）も使いません。** 必要な値型は `PixelSize` のようにドメイン側で定義します（5.2）。

この制約により、仕様書 30.1 が要求する単体テスト項目がすべて `commonTest` に収まり、JVM 上でエミュレータなしに実行できます。

### 4.2 ナビゲーションと iOS 差し替え経路

ナビゲーションは Compose 側が所有します。画面は `Route` の sealed class で表現し、`Route` から Composable への解決を 1 箇所の `when` に集約します。

v1 では全画面を Compose で実装します。iOS の特定画面を SwiftUI へ差し替える必要が生じた時点で、その `when` に分岐を追加し、`UIKitViewController` 経由で SwiftUI をホストする `UIViewController` を描画します。差し替え機構を先回りして実装することはしません（YAGNI）。設計上の要件は「`Route` を sealed class にすること」「画面解決を 1 箇所に集約すること」の 2 点のみです。

---

## 5. ネイティブ境界の設計

### 5.1 基本方針

**エフェクトの数学をすべてドメイン側に置き、ネイティブには描画プリミティブのみを残します。**

```
ネイティブ  顔検出 → 正規化座標の矩形群 + 頭部回転角 + 小顔フラグ（5.7.1）
    ↓
ドメイン    拡張率適用（上 25% / 下 15% / 左右 15%）
            形状決定（楕円 / 円 / 矩形 / 角丸）
            切り抜きと背景処理の決定
            → RenderSpec（正規化座標・相対強度のまま）
    ↓
ドメイン    compileRenderDraft(spec, targetSize)
            相対強度 → 絶対ピクセル値へ換算
            正規化座標 → 出力キャンバス基準へ変換
            → RenderDraft（stampRequests の rasterSize 算出済み）
    ↓
アプリ層    StampRasterizer でスタンプ画像をビットマップ化
            → RasterizedStampAsset（実体つき）を得る
    ↓
ドメイン    bindRasterAssets(draft, assets) → RenderPlan
    ↓
ネイティブ  RenderPlan を受け取り、4 プリミティブのみ実行
            ①マスク内モザイク ②マスク内ぼかし ③単色塗り ④画像貼り付け
```

顔領域の位置と大きさは、`RenderSpec` の段階では 0〜1 の正規化座標で保持します（仕様 19.3 と一致）。**永続化するのは `RenderSpec` 側の値だけ**で、ピクセル座標は保存しません。これにより拡張率やマージンの計算がプラットフォーム間でずれず、同じ設定を解像度の異なる出力へ適用できます。

#### 5.1.1 スタンプのラスタライズをドメインへ置かない

**ラスタライズは Compose Canvas を使うため、`domain` の責務にできません。** 4.1 の「`domain` は Compose の型を使わない」と直接矛盾します。

**幾何情報は `RenderRegion` だけに持たせます。** ラスタライズ側にも `bounds` / `rotationDegrees` / `opacity` を持たせると、ラスタライズ時とネイティブ描画時に**二重適用**されます。`StampRasterizer` は「スタンプ画像そのものを、指定ピクセルサイズで作る」ことだけを行います。

```kotlin
// domain — プラットフォーム非依存
data class StampRasterRequest(
    val source: StampSource,      // BuiltIn(code) または Custom(contentHash)（5.2）
    val rasterSize: PixelSize,    // compileRenderDraft が算出する
)

// domain がポートを定義し、composeApp が実装する
interface StampRasterizer {
    suspend fun rasterize(request: StampRasterRequest): RasterizedStampAsset
}
```

`StampRasterizer` が**行わないこと**を明示します。

| 項目 | 適用場所 |
| --- | --- |
| 画面上の位置 | `RenderRegion.bounds` |
| 回転 | `RenderRegion.rotationDegrees` |
| 不透明度 | `RenderOp.Stamp.opacity` |
| 顔領域の形状 | `RenderRegion.shape` |

いずれも `RenderPlan` 側で**1 回だけ**適用します。

`RenderOp.Stamp(bitmapId)` を組み立てる順序は次のとおりです（5.2 の二段階コンパイル）。

1. `domain` が `compileRenderDraft` で寸法を確定し、`StampRasterRequest` の一覧を得る
2. アプリケーション層が `StampRasterizer` でラスタライズし、`RasterizedStampAsset` を得る
3. `domain` が `bindRasterAssets` で `RenderPlan` を生成する

`domain` はポート（`StampRasterizer`）を定義するだけで、実装を持ちません。4.1 の依存の向きと一致します。

スタンプをベクターで自作する方針の利点は変わりません。ネイティブ側は「画像を貼る」1 プリミティブで全スタンプを処理でき、スタンプの種類が増えてもネイティブコードは増えません。ラスタライズが Compose 側にあることで、**両 OS で同じ描画結果**になる点も維持されます。

#### 5.1.2 ラスタ画像の受け渡し契約

**ID とサイズだけでは、モジュール境界を越えて実体へ到達できません。** Compose の画像オブジェクト、Android の `Bitmap`、iOS の `CGImage` を共通型へ直接入れることはできないため、**OS 境界を越えられる形式**を定めます。

```kotlin
data class RasterizedStampAsset(
    val bitmapId: String,
    val rasterFileId: String,      // 専用ディレクトリ配下の一時ファイル
    val pixelSize: PixelSize,
    val rowBytes: Int,
)

interface ImageEffectRenderer {
    suspend fun render(
        source: ImageSource,
        plan: RenderPlan,
        rasterAssets: Map<String, RasterizedStampAsset>,   // bitmapId → 実体
    ): RenderedImage
}
```

**実体はファイル経由で渡します。** バイト配列を直接持たせる方式（`rgba8888: ByteArray`）も成立しますが、Pro の 1 バッチ 50 枚では、原寸スタンプのビットマップを複数枚同時にメモリへ載せることになります。専用ディレクトリの一時ファイルにすれば、ネイティブ側がメモリマップで読み、必要な範囲だけを GPU へ転送できます。`outputFileId` と同じく ID からパスを解決し、パス文字列は渡しません（7.4.3）。

| 項目 | 規約 |
| --- | --- |
| ピクセル形式 | RGBA8888、**straight alpha**、sRGB（5.2.1） |
| 行ストライド | `rowBytes`。`pixelSize.width * 4` と一致しない場合がある（アライメント） |
| ID スコープ | `bitmapId` は**1 回の `render` 呼び出し内でのみ**一意。呼び出しをまたいで同じ ID が別実体を指してよい |
| 寿命 | `render` の呼び出し開始から復帰までの間、`rasterAssets` の全要素が有効であること |
| 解放 | `render` の成功・失敗にかかわらず、復帰後に**呼び出し元が**一時ファイルを削除する。**解放は冪等**とし、二重解放と未解放の再解放をエラーにしない |
| 再利用 | 同じ `StampRasterKey`（`source` と `rasterSize` の組）に対しては同一の `bitmapId` を返し、1 回の `render` 内で複数の `RenderRegion` から参照してよい |
| 未解決 ID | `plan` が参照する `bitmapId` が `rasterAssets` に無い場合は描画を開始せず、エラーを返す（無視して描き飛ばさない）。`bindRasterAssets` が通っていれば起こりませんが、契約として残します |

**ID スコープを呼び出し内に閉じるのは、同時レンダリングのためです。** 一括処理は将来 2 並列になります（6.5.8）。グローバルなレジストリを共有すると、片方の完了時の解放がもう片方の参照中実体を消します。呼び出しごとに集合が閉じていれば、この競合が起きません。

**未解決 ID を無視しません。** スタンプが 1 つ欠けたまま書き出すと、顔が隠れていない出力が完成扱いになります。これは 6.1 の安全側の既定と同じ思想です。

再利用の単位を `StampRasterKey`（`source` と `rasterSize` の組）にするのは、同じスタンプでも顔の大きさが異なれば必要な解像度が変わるためです。1 枚に同じスタンプを 10 個置く場合、サイズが揃っていればラスタライズは 1 回で済みます。

異常終了で一時ファイルが残った場合は、起動時の孤児ファイル掃除で回収します（7.4.3 の手順 0 と同じ扱い）。

### 5.2 RenderSpec と RenderPlan

**記述（`RenderSpec`）とコンパイル済み命令（`RenderPlan`）を分けます。**

以前の版は `RenderPlan` に `cellRatio` / `sigmaRatio` / `featherRatio` という**相対値**を入れたまま、5.1 では「強度の相対値をドメインで絶対値へ換算する」と書いていました。相対値のままネイティブへ渡せば、Core Image と OpenGL がそれぞれピクセル値へ換算するため OS 差が出ます。

同時に、「低解像度プレビューと原寸書き出しで**同じ `RenderPlan`**を使う」という表現も成立しません。`canvasSize` が異なる以上、別物です。

```kotlin
data class PixelSize(                   // ドメイン独自型。Compose の IntSize を使わない
    val width: Int,
    val height: Int,
)

/** 永続化・編集の対象。解像度に依存しない */
data class RenderSpec(
    val sourceCrop: NormalizedRect,     // 元画像のどこを切り出すか（出力比率の適用結果）
    val scaleMode: SourceScaleMode,     // Fit / Fill
    val background: BackgroundSpec,
    val regions: List<RenderRegionSpec>,
)

data class RenderRegionSpec(
    val bounds: NormalizedRect,         // 拡張率適用済み。出力キャンバス基準（5.2.1）
    val rotationDegrees: Float,
    val shape: MaskShape,               // Ellipse / Circle / Rectangle / Rounded(cornerRatio)
    val featherRatio: Float,            // 領域短辺に対する比
    val origin: RegionOrigin,           // Auto / Manual（描画順に使う）
    val op: RenderOpSpec,
)

/** 組み込みスタンプとカスタムスタンプを文字列で混ぜない */
sealed interface StampSource {
    data class BuiltIn(val code: String) : StampSource
    data class Custom(val contentHash: String) : StampSource
}

sealed interface RenderOpSpec {
    data class Mosaic(val cellRatio: Float) : RenderOpSpec    // 領域短辺に対するセル比
    data class Blur(val sigmaRatio: Float) : RenderOpSpec     // 領域短辺に対する σ 比
    data class Solid(val color: SrgbArgb8888, val opacity: Float) : RenderOpSpec
    data class Stamp(val source: StampSource, val opacity: Float) : RenderOpSpec
}

sealed interface BackgroundSpec {
    data object None : BackgroundSpec
    data class Blur(val sigmaRatio: Float) : BackgroundSpec     // キャンバス短辺に対する比
    data class Solid(val color: SrgbArgb8888) : BackgroundSpec
}
```

##### 二段階コンパイル

**一段階では依存が循環します。** `StampRasterRequest.rasterSize` は、対象解像度における `RenderRegion` のピクセル寸法から決まります。その寸法を計算するのはコンパイル処理です。一方で以前の `compileRenderPlan` は、先に `bitmapId` を要求していました。

コンパイルを 2 つに分けます。

```kotlin
/** 第1段階: 解像度は確定したが、スタンプ実体はまだ束ねていない */
data class RenderDraft(
    val canvasSize: PixelSize,
    val sourcePlacement: SourcePlacement,
    val background: BackgroundOp,
    val regions: List<RenderRegionDraft>,
    val stampRequests: List<StampRasterRequest>,   // rasterSize は算出済み
)

data class StampRasterKey(
    val source: StampSource,
    val rasterSize: PixelSize,
)

fun compileRenderDraft(
    spec: RenderSpec,
    targetSize: PixelSize,
): RenderDraft

/** 第2段階: ラスタ実体を束ねて RenderPlan にする */
fun bindRasterAssets(
    draft: RenderDraft,
    assets: Map<StampRasterKey, RasterizedStampAsset>,
): RenderPlan
```

処理の順序は次のとおりです。

1. `compileRenderDraft(spec, targetSize)` で寸法を確定し、`stampRequests` を得る
2. アプリケーション層が各 `StampRasterRequest` をラスタライズする
3. `bindRasterAssets(draft, assets)` で `RenderPlan` を得る

`bindRasterAssets` は、`draft.stampRequests` に対応する `assets` が 1 件でも欠けていれば失敗します。未解決のまま `RenderPlan` を作れません（5.1.2 の「未解決 ID を無視しない」を型で保証します）。

##### コンパイル済みの命令

```kotlin
/** 特定解像度へコンパイル済み。絶対ピクセル値のみを持つ */
data class RenderPlan(
    val canvasSize: PixelSize,
    val sourcePlacement: SourcePlacement,
    val background: BackgroundOp,
    val regions: List<RenderRegion>,
)

data class PixelRect(
    val left: Int,
    val top: Int,
    val rightExclusive: Int,
    val bottomExclusive: Int,
)

data class SourcePlacement(
    val sourceRect: NormalizedRect,     // 元画像のどこを使うか
    val destinationRect: PixelRect,     // キャンバス上のどこへ置くか
    val scaleMode: SourceScaleMode,
)

enum class SourceScaleMode { Fit, Fill }

data class RenderRegion(
    val bounds: PixelRect,              // 出力キャンバス基準の絶対ピクセル
    val rotationDegrees: Float,
    val shape: MaskShape,
    val featherPx: Float,
    val order: Int,                     // 描画順（5.2.1）
    val op: RenderOp,
)

sealed interface RenderOp {
    data class Mosaic(val cellSizePx: Float) : RenderOp
    data class Blur(val sigmaPx: Float) : RenderOp
    data class Solid(val color: SrgbArgb8888, val opacity: Float) : RenderOp
    data class Stamp(val bitmapId: String, val opacity: Float) : RenderOp
}

sealed interface BackgroundOp {
    data object None : BackgroundOp

    /** 何をどうぼかして背景へ敷くかを明示する */
    data class BlurFromSource(
        val sourceRect: NormalizedRect,
        val sigmaPx: Float,
        val scaleMode: SourceScaleMode,
    ) : BackgroundOp

    data class Solid(val color: SrgbArgb8888) : BackgroundOp
}
```

**プレビュー用と書き出し用は、同じ `RenderSpec` から別々の `RenderPlan` を生成します。** 相対値は `RenderSpec` にあるため、両者の見た目は一致します。ゴールデン画像テストが成立する根拠もここです。

##### 合成の契約

**`sourceCrop` と `sigma` だけでは合成が決まりません。** 元画像をキャンバスのどこへ、どの拡縮方式で置くか、背景ぼかしが**何をぼかすのか**が未定義だと、レンダラーが独自に決めることになります。

| 概念 | 保持する型 |
| --- | --- |
| 出力キャンバスの実サイズ | `RenderPlan.canvasSize` |
| 元画像のどこを使うか | `SourcePlacement.sourceRect` |
| キャンバス上のどこへ置くか | `SourcePlacement.destinationRect` |
| Fit か Fill か | `SourcePlacement.scaleMode` |
| 余白の埋め方 | `RenderPlan.background` |
| 背景ぼかしの**元範囲** | `BackgroundOp.BlurFromSource.sourceRect` |
| 顔領域の位置 | `RenderRegion.bounds`（**出力キャンバス基準の絶対ピクセル**） |

`BackgroundOp.Blur(sigmaPx)` から `BlurFromSource` へ変えたのは、`sigma` だけでは「元画像全体をぼかすのか、切り抜き範囲をぼかすのか、どの倍率で敷くのか」が決まらないためです。一般的な用途では `sourceRect` に元画像全体を指定し、`Fill` でキャンバス全面へ拡大します。

`RenderRegion.bounds` の基準を**出力キャンバス**に確定します。元画像基準にすると、ネイティブ側が切り抜き変換を再実装することになり、「数学はドメイン」の方針に反します。`compileRenderDraft` が `sourcePlacement` を適用したあとの座標へ変換します。

##### `sourceCrop` の不変条件

顔の拡張領域（5.3）と違い、**`sourceCrop` が元画像の外へ出る理由はありません。**

- `width > 0` かつ `height > 0`
- `0.0 <= left`、`right <= 1.0`、`0.0 <= top`、`bottom <= 1.0`
- 違反は `compileRenderDraft` が例外とする（クランプで黙って直さない）

黙ってクランプすると、比率計算の誤りが出力の見た目としてしか現れず、原因の特定が遅れます。

`PixelRect` の `rightExclusive` / `bottomExclusive` は名前で排他性を示します。`right` / `bottom` という名前だと、包含のつもりで実装される余地が残ります。

#### 5.2.1 座標・回転・色の共通規約

**同じ `RenderPlan` を両 OS へ渡してゴールデン画像テストで一致させる以上、数値の解釈を規約として固定します。** 未定義のままだと、OS アダプタがそれぞれ独自に解釈し、同じ数値でも位置・回転・色・境界がずれます。

##### `NormalizedRect`

| 項目 | 規約 |
| --- | --- |
| 原点 | **向き正規化後**の画像の左上 |
| +X | 右方向 |
| +Y | **下方向** |
| `left` / `top` | 含む（inclusive） |
| `right` / `bottom` | **含まない（exclusive）** |

原点を「向き正規化後」と明記するのは、EXIF の回転を適用する前後で左上の位置が変わるためです。`ImageLoader` が向きを正規化したあとの画像が、すべての座標の基準です。

値域は**段階によって異なります。** 「0.0〜1.0」と「はみ出しを許容」を同じ型の規約として並べることはできません。

| 段階 | 値域 |
| --- | --- |
| `DetectedFace.bounds`（検出直後） | **0.0〜1.0 に収まる。** アダプタが保証する |
| `expand()` 適用後（5.3） | **負数および 1.0 超過を許容する。** クランプしない |
| `RenderPlan.regions[].bounds` | 出力キャンバス基準のピクセル。キャンバス外の値を含みうる |
| 最終的なクリップ | **レンダラーがキャンバス境界で行う** |

はみ出しをドメインで潰さない理由は 5.3 のとおりです。クランプすると顔が露出する方向へ倒れます。

##### ピクセルへの丸め

`compileRenderDraft` が正規化値をピクセルへ変換する規則を固定します。両 OS が独自に丸めると、1 ピクセルの差でゴールデン画像テストが落ちます。

| 値 | 丸め |
| --- | --- |
| `left` / `top` | **floor** |
| `right` / `bottom` | **ceil** |
| `featherPx` / `cellSizePx` / `sigmaPx` | 丸めない（`Float` のまま渡す） |

`left` / `top` を floor、`right` / `bottom` を ceil にすると、領域は必ず**外側へ広がる**方向に丸められます。内側へ丸めると顔の縁が 1 ピクセル露出しうるため、安全側へ倒します。

##### クリップと回転の順序

**クリップは回転の後に行います。**

1. `RenderRegion` の形状を、領域中心を基準に `rotationDegrees` だけ回転する
2. 回転後の形状をキャンバス境界でクリップする

順序を逆にすると、キャンバス端の顔を回転させたときに、本来隠れるべき部分が切り落とされたあとで回転して露出します。

##### 描画順

**`regions` は `order` の昇順に、前の結果へ重ねて適用します。** つまり後のエフェクトは、**加工済み画像**に対して作用します（元画像ではありません）。

`order` は `compileRenderDraft` が次の規則で決定します。

| 優先 | 対象 |
| --- | --- |
| 1（先） | `RegionOrigin.Auto`（自動検出された顔） |
| 2（後） | `RegionOrigin.Manual`（利用者が追加した手動領域） |

同一区分内は `RenderSpec.regions` の並び順を保ちます。

**手動領域を後に置くのは、利用者の明示的な指示を最終結果にするためです。** 自動検出の結果に不足があって手動で足した領域が、自動領域に上書きされては意味がありません。

`OverlappingFaces` を正式なトリアージ理由として扱い、ゴールデンテストにも含める以上（6.5.2）、重なり順をテスト実装任せにはできません。

##### 背景処理と顔エフェクトの適用順

1. `sourceCrop` で元画像を切り出す
2. `canvasSize` のキャンバスへ配置し、余白を `background` で埋める
3. `regions` を `order` 順に適用する

**背景処理が先です。** 顔エフェクトを先に適用すると、背景ぼかしが加工済みの顔へも掛かり、モザイクの粒がにじみます。

##### `rotationDegrees`

| 項目 | 規約 |
| --- | --- |
| 正方向 | **時計回り** |
| 範囲 | `-180.0` 以上 `180.0` 未満へ正規化する |
| 回転中心 | 画像中心ではなく、**その `RenderRegion` の中心** |

回転中心を領域中心にするのは、顔ごとに独立して傾きを合わせるためです。画像中心を基準にすると、領域の位置によって見え方が変わります。

##### 色

```kotlin
@JvmInline
value class SrgbArgb8888(
    val value: UInt,    // 0xAARRGGBB
)
```

| 項目 | 規約 |
| --- | --- |
| 色空間 | sRGB |
| ビット配置 | `0xAARRGGBB` |
| アルファ | **straight alpha**（premultiplied ではない） |
| `opacity` の乗算 | **レンダラーが 1 回だけ**乗算する。ドメインは色へ焼き込まない |
| premultiplied への変換 | Core Image / OpenGL が必要とする場合、**OS アダプタ側で**変換する |

`Long` ではなく専用の value class にするのは、符号やビット幅の解釈をアダプタ任せにしないためです。

`opacity` を「1 回だけ」と定めるのは、`SrgbArgb8888` のアルファと `RenderOp.Solid.opacity` の両方があるためです。前者は色そのものの不透明度、後者はエフェクト全体の適用強度で、レンダラーが両方を掛け合わせます。ドメイン側で事前に畳み込みません。

##### `FaceDetector` の変換責務

**両 OS の実装は、OS API の座標系と角度をこの規約へ変換してから `DetectedFace` を返します。**

Vision は左下原点の正規化座標を返し、ML Kit は左上原点のピクセル座標を返します。角度の符号も一致しません。この差を吸収するのはアダプタの責務であり、ドメインへ持ち込みません。契約テストで両 OS の変換結果が一致することを検証します（12.1）。

エフェクト強度は **`RenderSpec` の段階で領域サイズに対する相対値** として保持します（仕様 11.1）。`compileRenderDraft` が対象解像度で絶対ピクセルへ換算するため、低解像度プレビューと原寸書き出しで見た目が一致し、ゴールデン画像テストが成立します。**ネイティブ側は比率計算を一切行いません。**

### 5.3 拡張率の適用

```kotlin
fun expand(face: NormalizedRect, effect: EffectSetting): NormalizedRect
```

既定値は上 25% / 下 15% / 左右 15%（仕様 8.4）。スタンプはモザイクより大きめの拡張率を用います。

**画像外へはみ出す場合もクランプしません。** クランプすると顔が露出する方向へ倒れるためです。はみ出しはマスク描画側で処理します。これは仕様 9.5 の「平滑化によって顔が露出する場合は、領域を小さくするのではなく拡張する」と同じ思想です。

### 5.4 ネイティブ契約（v1 = 写真のみ）

**12 のプラットフォーム契約がありますが、すべてが「メディア」ではありません。** 実装先モジュールを契約ごとに指定します。

| 契約 | 責務 | 実装モジュール | iOS | Android |
| --- | --- | --- | --- | --- |
| `PhotoPicker` | OS 標準ピッカー。画像のみ | `shared/media` | PhotosPicker | Photo Picker |
| `FilePicker` | カスタムスタンプ用画像の取り込み。対応形式は 8.1 に従う | `shared/media` | UIDocumentPicker | SAF |
| `ImageLoader` | 読み込み、向き正規化、検出用縮小、HEIC 対応 | `shared/media` | Image I/O | ImageDecoder |
| `FaceDetector` | 顔検出。正規化座標で返す | `shared/media` | Vision | ML Kit |
| `ImageEffectRenderer` | RenderPlan の 4 プリミティブ実行 | `shared/media` | Core Image | OpenGL ES 2.0 |
| `ImageEncoder` | JPEG / PNG エンコード、メタデータ除去 | `shared/media` | Image I/O | Bitmap.compress + ExifInterface |
| `MediaSaver` | 写真ライブラリ保存、登録日時の指定 | `shared/media` | PhotoKit | MediaStore |
| `SharePresenter` | OS 共有シートの提示と結果の返却 | `shared/media` | UIActivityViewController | `Intent.ACTION_SEND` |
| `CryptoKeyStore` | HMAC 鍵の生成と保持。**鍵のみ扱う** | `shared/data`（`security` パッケージ） | Keychain | Android Keystore |
| `ProtectedBlobStore` | 署名済み状態の原子的な読み書き | `shared/data` | 保護ファイル（原子的置換） | Proto DataStore |
| `AdPresenter` | バナー・全画面広告 | `shared/ads` | GADBannerView | AdView |
| `PrivacyShield` | 画面スナップショット対策（7.7） | `composeApp`（アプリシェル） | `sceneWillResignActive` | `onPause` |

`CryptoKeyStore` と `ProtectedBlobStore` を `shared/media` へ置きません。`shared/media` は画像の入出力に閉じた責務であり、ここへ鍵と台帳の保管を混ぜると、写真処理のテストダブルが鍵ストアまで抱えることになります。`PrivacyShield` はライフサイクルに紐づくため、アプリシェル側の責務です。

### 5.5 動画対応で追加する契約（v2）

以下 4 契約を **v1 の設計時点で定義**し、実装のみ v2 に回します。

| 契約 | 責務 | iOS | Android |
| --- | --- | --- | --- |
| `VideoProbe` | 長さ、解像度、コーデック、回転、HDR 判定 | AVAsset | MediaExtractor |
| `VideoFrameSource` | 時刻指定のフレーム取得 | AVAssetReader | MediaCodec |
| `PreviewRenderer` | エフェクト適用済みテクスチャ出力 | MTKView | GLSurfaceView |
| `VideoExporter` | 書き出し | AVAssetWriter | Media3 Transformer |

##### v1 で先取りする範囲

当初は顔トラック関連付け・平滑化・シーン切替判定まで v1 で実装する方針でしたが、**絞ります。**

| 対象 | v1 | 理由 |
| --- | --- | --- |
| 動画用データモデル（`FaceKeyframe` 等） | **実装する** | スキーマを後から足すより安い |
| 5.5 の 4 契約のインターフェース定義 | **実装する** | 境界を先に切る意味がある |
| キーフレーム補間 | **実装する** | 仕様 10.3 で挙動が確定している純粋関数 |
| 顔トラック関連付け | v2 | 実際の検出結果の特性に依存する |
| 平滑化 | v2 | 同上 |
| シーン切替判定 | v2 | 同上 |

**検出結果の特性に依存するものを、実物なしに作るのは YAGNI に反します。** 「テストできる」ことと「正しく作れる」ことは別です。閾値やヒューリスティクスは実際の `VideoFrameSource` の出力を見ないと決まらず、先に作れば v2 で作り直す確率が高くなります。

先取りするのは、仕様が確定していて後から足すコストが高いものだけに限ります。

### 5.6 プレビューと書き出しの一致

インタラクティブなプレビューは低解像度で `composeApp` の Compose Canvas により両 OS 共通で描画し、書き出しのみ原寸でネイティブが処理します。これは仕様 8.3 の「検出用縮小画像を使い、書き出し時は元解像度へ適用する」と整合します。

両者の乖離を防ぐため、**同一の `RenderSpec` から生成したプレビュー用と原寸用の `RenderPlan`** に対するゴールデン画像テストで、差分を許容誤差内に抑えます。解像度が異なる以上、`RenderPlan` そのものは別物です（5.2）。一致の根拠は `RenderSpec` の共通性と `compileRenderDraft` の決定性にあります。

### 5.7 顔検出の座標処理

仕様 8.3 の手順に従います。

1. 元画像の向き情報を正規化する
2. 検出用に長辺 1,920 ピクセル程度へ縮小する
3. 顔検出を実行する
4. **ネイティブ側で正規化座標へ変換して返す**
5. 以降、ドメインは顔領域をピクセル座標として保持しない（出力サイズは `RenderPlan` 生成時にのみ受け取る。5.1）

検出用画像上で顔の短辺が 24 ピクセル未満の検出結果には、顔単位のフラグ `isSmallFace` を立てます（仕様 8.5）。

#### 5.7.1 顔単位の共通モデル

`FaceDetector` が返す顔は、**両 OS が等しく提供できる値だけ**で構成します。片方にしかない値をドメインへ流すと、OS ごとに挙動が変わります（6.5.2 参照）。

```kotlin
data class DetectedFace(
    val bounds: NormalizedRect,   // Vision: boundingBox / ML Kit: getBoundingBox
    val yawDegrees: Float,        // Vision: yaw        / ML Kit: getHeadEulerAngleY
    val pitchDegrees: Float,      // Vision: pitch      / ML Kit: getHeadEulerAngleX
    val rollDegrees: Float,       // Vision: roll       / ML Kit: getHeadEulerAngleZ
    val isSmallFace: Boolean,     // 検出用画像上の短辺で判定
)
```

これらの顔単位の値と、ドメイン側で計算する端接触・重なりが、6.5.2 の `triage` の入力になります。写真単位の `ReviewRequired` と名前が重ならないよう、顔単位では `requiresReview` という名称を使いません。

iOS の `confidence` はこのモデルに含めません。Android に対応する値がないためです（6.5.2）。

---

## 6. ドメイン設計

### 6.1 顔の初期状態と安全側の既定

**検出された顔は、すべて加工対象の状態で初期化します。** これはドメインの不変条件とし、UI の慣習に委ねません。

```kotlin
// FaceTrack の生成時、isMasked は常に true
// 「残す」は利用者の明示的な操作によってのみ false になる
```

理由は、誤りの方向を制御するためです。初期状態が「全部残す」だと、一人選び忘れただけで顔が公開されます。初期状態が「全部隠す」なら、選び忘れは「隠しすぎ」に倒れます。取り返しがつかない方向へ倒さない設計を採ります。

派生する規則は以下とします。

- **検出品質に関する内部値を理由に、顔を自動除外しません。** 向きや大きさが理由で「たぶん誤検出だろう」と切り捨てる経路を持ちません
- **小さい顔には「確認が必要」と表示しますが、加工対象からは外しません**（仕様 8.5）
- **書き出し前に加工後プレビューを必ず表示します**（仕様 10.4）
- **「自動検出に失敗したので何も隠さずに保存」という経路を持ちません**

#### 6.1.1 単体処理で顔が 1 つも検出されない場合

**この節は単体処理に限ります。** 一括処理の顔 0 件は `NoFaceDetected`（6.5.2）と、トライアルを含む勘定の規則（7.4.3）に従います。文言をここで共通化すると、月間枠を使わない一括トライアルの写真に「今月の無料枠を 1 枚使用します」と誤表示します。

利用不可にはしません。以下から選べるようにします。

- 手動で隠す範囲を追加する
- そのまま縦横比変更やメタデータ削除だけを行う
- 編集を終了する

加工なしの書き出しも、仕様 14.2 の定義では消費対象です。不意打ちを避けるため書き出し前に明示しますが、**文言は 6.2 の `QuotaDecision` で分岐させます。** 一律に「枠を使います」と表示すると、24 時間以内の再書き出しで誤った案内になります。

| `QuotaDecision` | 表示 |
| --- | --- |
| `Consume` | 顔は検出されませんでした。このまま保存すると、今月の無料枠を 1 枚使用します。 |
| `FreeReexport` | 顔は検出されませんでした。24 時間以内の再書き出しのため、無料枠は使用しません。 |
| `Unlimited` | 顔は検出されませんでした。（無料枠についての記述は出さない） |
| `Blocked(MonthlyLimitReached)` | 今月の無料保存を使い切りました。Standard なら 1 枚ずつ無制限で保存できます。 |
| `Blocked(LedgerIntegrityFailure)` | 保存回数の記録を確認できないため、今月は無料での保存を利用できません。来月から再開します。Standard なら今すぐ 1 枚ずつ無制限で保存できます。 |

### 6.2 無料枠の消費判定（QuotaPolicy）

仕様 14 章に対応します。UI モックは書き出しのたびに無条件で残数を 1 減らしていますが、実装ではこれを純粋関数の判定に置き換えます。

##### 台帳は 1 つ

**通常クォータ、`ExportGrant`、トライアル台帳を別々の値として持ちません。1 つの署名済みオブジェクトとして原子的に置き換えます。**

```kotlin
data class UsageLedger(
    val period: YearMonth,                       // 消費を計上している年月
    val consumedExportIds: Set<String>,          // 計上済みの書き出し
    val grants: Map<String, GrantEntry>,         // sourceHash → 権利
    val trialEntries: Map<String, TrialEntry>,   // sourceHash → トライアル消費
    val trialReservations: Map<String, String>,  // sourceHash → exportId。認可時の予約（6.5.6.1）
    val lastObservedAt: Instant,                 // 後退させない基準時刻（6.2.2.5）
    val monthlyBlockedPeriod: YearMonth?,        // 破損修復により当月を封じた場合の年月
    val trialIntegrityLocked: Boolean,           // 破損修復によりトライアルを封じたか
)

data class GrantEntry(
    val firstSuccessAt: Instant,
    val ownerExportId: String,   // この要素を作った書き出し
)

data class TrialEntry(val ownerExportId: String)

val UsageLedger.consumed: Int get() = consumedExportIds.size
```

**各要素に `ownerExportId` を持たせます。** 7.4.3 のロールバックで「この書き出しが追加したもの」と「以前から存在したもの」を、**台帳そのものから**判別するためです。Room 側の記録だけに頼ると、台帳を書いた直後に落ちた場合に判別できません。

**消費を件数ではなく書き出し ID の集合で持ちます。** 単なる `Int` では、7.4.3 が要求する「同じ `exportId` の再適用を弾く」も「特定の書き出しの消費だけ取り消す」も実装できません。集合にすれば、再適用は自然に冪等になり、ロールバックは該当 ID の削除で済みます。

`grants` を `Map<sourceHash, GrantEntry>` にしたのも同じ理由です。同一 `sourceHash` への追記が上書きにならず、`firstSuccessAt` を維持できます（6.2.0）。

3 つを別々の ProtectedBlobStore 値として更新すると、片方だけ書けた状態が生じます。1 つの署名済みオブジェクトなら、置き換えは全部か無かです。

##### 判定

```kotlin
sealed interface QuotaDecision {
    object Unlimited : QuotaDecision        // Standard / Pro
    object FreeReexport : QuotaDecision     // 24 時間以内の再書き出し。消費しない
    object Consume : QuotaDecision          // 1 消費する
    data class Blocked(val reason: QuotaBlockReason, val limit: Int?) : QuotaDecision
}

enum class QuotaBlockReason {
    MonthlyLimitReached,      // 通常の月間上限
    LedgerIntegrityFailure,   // 台帳破損による当月封鎖（6.2.5）
}

data class QuotaEvaluation(
    val decision: QuotaDecision,
    val updatedLedger: UsageLedger,   // 時刻更新・月次更新・期限切れ grant の整理を含む
)

fun evaluate(
    ledger: UsageLedger,
    access: SingleExportAccess,       // Plan ではない。6.3 が解決した能力を受け取る
    sourceHash: String,
    effectiveNow: Instant,            // 6.2.2.5 で正規化済み。端末時刻を直接渡さない
    zone: TimeZone,
): QuotaEvaluation
```

**判定結果だけでなく更新後の台帳も返します。** `QuotaDecision` しか返さないと、`lastObservedAt` の前進、月次更新、期限切れ `grant` の削除を永続化できません。

##### `Plan` を直接受け取らない

6.3 は「権限は `plan` と `status` から導出し、`plan` から直接導出しない」と定めています。特に `pending`（支払い保留）では有料機能を付与しません。

**`QuotaPolicy` が `Plan` を受け取ると、この規則を迂回します。** `plan = Standard` かつ `status = pending` でも `plan != Free` が成立し、`Unlimited` になります。

`EntitlementResolver` が確定した能力を渡します。

```kotlin
enum class SingleExportAccess {
    Metered,      // 月間枠の対象
    Unlimited,    // 月間枠の対象外
}

data class ResolvedCapabilities(
    val singleExportAccess: SingleExportAccess,
    val canUsePremiumStamps: Boolean,
    val canUseCustomStamps: Boolean,
    val canUseProBatch: Boolean,      // 制限なしの一括処理
    val canUseBatchTrial: Boolean,    // クレジット消費による一括トライアル
    val shouldShowAds: Boolean,
)
```

`Plan` を参照してよいのは能力解決の内側だけです。`QuotaPolicy`、`AdFrequencyPolicy`、開始ゲート、一括処理の可否判定、既存作品の編集可否、UI の活性制御は、すべて `ResolvedCapabilities` を見ます。

##### 「確認できない」を型で表す

`ResolvedCapabilities` を必ず返す関数では、「購入状態を確認できない」を表現できません。`Metered` を返せば暗黙降格になり、`Unlimited` を返せば未検証で有料機能を付与します。

解決そのものを状態型にします。

```kotlin
sealed interface CapabilityResolution {
    data class Resolved(val capabilities: ResolvedCapabilities) : CapabilityResolution
    data object VerificationRequired : CapabilityResolution
}

fun resolveCapabilities(state: SubscriptionCacheState): CapabilityResolution
```

`VerificationRequired` の間の挙動を定めます。

- **書き出しの認可を開始しない**（`ExportStartGate` を通さない）
- **有料機能を新規に付与しない**
- **Free へ降格したとも表示しない**
- 再試行と購入の復元を提示する

##### `Missing` を Free として扱ってよい条件

`SubscriptionState` が `Missing` のとき（6.3）、それが**初回インストールなのか、再インストールした有料利用者なのか**は、キャッシュの不在だけでは区別できません。ここを曖昧にすると「有料利用者が再インストール直後に Free 扱いで書き出しを消費する」経路ができます。

v1 では次を規則とします。

| 状況 | 解決結果 |
| --- | --- |
| `Missing` かつ RevenueCat への問い合わせが**成功**（購読なし） | `Resolved(Free 相当の能力)` |
| `Missing` かつ RevenueCat への問い合わせが**成功**（購読あり） | `Resolved(該当プランの能力)` |
| `Missing` かつ**オフライン等で問い合わせ不能** | **`VerificationRequired`** |
| `Valid` かつオフライン | `Resolved`（キャッシュで維持。6.3） |

**キャッシュが無い状態でオフラインなら、書き出しを止めます。** Free として進めると、有料利用者の再インストール直後に無料枠を消費させ、しかもその消費は台帳へ記録されます。逆に `Unlimited` として進めると未検証で有料機能を渡します。どちらも取れないため、確認完了まで待つ以外にありません。

この待ちは初回インストール時にも発生しますが、購読の確認は初回起動時に一度行えば済み、以降はキャッシュが `Valid` になります。オフラインでの初回起動という限られた場面だけの制約です。

判定順序は以下とします。

1. `lastObservedAt` を `effectiveNow` へ前進させる
2. 期間更新と期限切れ `grant` の整理を適用する（6.2.3）
3. `access == Unlimited` なら `Unlimited`
4. **`monthlyBlockedPeriod == period` なら `Blocked(LedgerIntegrityFailure)`**（6.2.5）
5. `grants[sourceHash]` があり `effectiveNow - it.firstSuccessAt < 24h` なら `FreeReexport`
6. `consumed >= limit` なら `Blocked(MonthlyLimitReached, limit)`
7. それ以外は `Consume`

**手順 4 を月間上限の判定より前に置きます。** 破損修復後は `consumedExportIds` が空なので、上限判定だけでは通過してしまいます。

**理由を型で分けるのは、文言が異なるためです。** 破損時に「今月の無料保存を使い切りました」と表示するのは事実に反します。

**有料プランで `Unlimited` を返す場合も、手順 1 と 2 は必ず実施してから返します。** 有料期間中に時刻更新と grant 整理を止めると、降格した瞬間に古い状態から判定が始まります。

#### 6.2.0 ExportGrant の作成規則

**`ExportGrant` は、書き出し時のプランにかかわらず作成します。**

| 動作 | 条件 |
| --- | --- |
| `grants` へ `sourceHash` を追加する | 利用可能な出力の生成が正常に完了した時点＝コミット手順 8 の完了（7.4.3）。プランを問わない |
| `consumedExportIds` へ `exportId` を追加する | `QuotaDecision` が `Consume` のときだけ |
| `firstSuccessAt` を更新する | しない。同一 `sourceHash` の有効な grant があれば、そのまま維持する |

有料プランでの書き出し時に grant を作らないと、次の経路が破綻します。

1. Standard で写真 A を書き出す
2. 1 時間後に Free へ降格する
3. 写真 A を再書き出しする

grant がなければ `FreeReexport` にならず枠を 1 枚消費します。これは 6.7 の「降格した事実はクォータ判定に影響しない。判定に使うのは `sourceHash` と経過時間だけ」と矛盾します。

`firstSuccessAt` を更新しないのは、再書き出しのたびに窓が延びると 24 時間の上限が意味を失うためです。

**この規則は「認可時に有効な grant があったか」ではなく「会計時に有効な grant があるか」で判断すると破れます。** 認可から会計までの間に窓が切れると、grant が存在しない状態として新規作成されるためです。`FreeMonthlyReexport` は認可時の `firstSuccessAt` を保存して維持します（7.4.3 の preserve）。

#### 6.2.1 消費の確定タイミング

**消費は「利用可能な加工済み出力の生成が正常に完了した時点」で確定します。** 写真ライブラリへの保存時点ではありません。

仕様 14.2 は消費条件を「書き出し処理が正常終了した」「出力ファイルが生成された」「**保存処理または共有可能な状態になった**」と定めています。写真ライブラリ保存を確定条件にすると、加工済み画像を生成して保存せずに OS 共有から他アプリへ渡す経路で無料枠を回避できてしまい、仕様の文言にも反します。

確定点は **7.4.3 のコミット手順 8 が完了した時点**とします。一時パスへの生成・サイズと SHA-256 の確認・デコード確認（7.4.1）を通過し、会計を台帳へ適用し、コミット行を削除して成果物を公開できる状態になった時点です。**写真ライブラリへの保存は含みません**（7.4.2）。その後の操作は追加消費しません。

手順 8 より前は成果物を公開せず、ロールバックが可能です（7.4.1 の「確定点は 1 つだけ」）。

- 写真ライブラリへ保存する
- OS 共有から他アプリへ渡す
- 上記を何度繰り返す

以下では消費しません。検出のみ、プレビューのみ、キャンセル、生成の失敗、生成前の空き容量不足、**生成中の**異常終了、対応外形式。

**生成が完了したあとの異常終了では消費が確定したままです。** 6.2.2 の出力状態は永続化されるため、生成完了後にアプリが落ちても出力は残り、再起動後に受け取れます（6.2.2.1）。ここで消費を戻すと、出力を保持したまま枠も返す二重取りになります。

#### 6.2.2 未保存出力の保持

消費を確定した以上、**生成直後の失敗や異常終了によって利用者が成果物を失う経路を作りません。**

ただし未受け渡し出力の保持は無期限ではなく、**24 時間で削除します。** 「失わせない」と「永久に持ち続ける」は別です。「あとで保存」を選ぶ場面では、この期限を明示します。

**保存や共有が 1 回成功しても、その場では削除しません。** 7.4.2 が「何度実行しても追加消費しない」と定める以上、1 回目の受け渡しでファイルを消すと、共有したあとに写真ライブラリへも保存する、という操作が成立しなくなります。

**出力に状態を持たせます。** 状態は永続化し、異常終了をまたいでも保たれます。

```kotlin
enum class OutputState { Generated, Delivered, Discarded }
```

| 状態 | 意味 | 保持する期間 |
| --- | --- | --- |
| `Generated` | 生成済み。受け渡しは未成功 | 利用者が明示的に破棄するまで、または 24 時間経過するまで |
| `Delivered` | 保存または共有が 1 回以上成功した | **完了画面を離れるまで** |
| `Discarded` | 利用者が明示的に破棄した | 直ちに削除する |

**状態は写真ごとの出力レコードに保持します。バッチ単位では持ちません。**

一括処理では部分的な成功が起こるためです。32 枚のうち 20 枚を写真ライブラリへ保存し、12 枚が空き容量不足で保存できなかった状態でアプリが終了する、という場面が現実に生じます。バッチ全体に 1 つだけ状態を持つと、この状況を表現できません。

バッチの状態は、各 `OutputRecord`（型定義は 7.4.3）の状態から集計して導出します。

```kotlin
// バッチの未受け渡し枚数 = records.count { it.batchId == id && it.state == Generated }
```

一括保存が部分的に成功した場合、**すでに `Delivered` の写真を再保存せず、`Generated` の写真だけを再試行**します。

したがって完了画面を開いているあいだは、保存と共有を任意の順序で何度でも実行できます。画面を離れた時点で、受け渡し済みの出力を削除します。

「あとで保存」を選んだ場合は未受け渡しのままなので、24 時間以内であれば履歴から再開できます。

**状態は写真ごとに持ちますが、保持できる処理単位は 1 つだけです。** 単体処理なら直近 1 件、一括処理なら直近 1 バッチ分（その全写真）です。粒度と個数の制限は別の話であり、混同しません。

**`Generated` の出力が 1 枚以上残った状態で完了画面を離れようとした場合、確認を表示します。** これは全利用者に適用します。

「保存も共有もしていない場合」ではありません。一括処理では 32 枚中 20 枚を保存した時点で「保存はした」ことになりますが、残る 12 枚は受け取れていません。判定は **`Generated` の残数** で行います。

文言にも枚数を含めます。

> 保存していない加工済み写真が 12 枚あります

| 履歴の設定 | 提示する選択肢 |
| --- | --- |
| 保存する（7.2.3） | 「あとで保存」「破棄する」「戻る」。あとで保存を選ぶと履歴に未保存として残り、24 時間以内は再開できる |
| 保存しない（7.2.3） | 「破棄する」「戻る」。あとで保存は提示しない |

選択肢の対象は `Generated` の写真だけです。`Delivered` の写真は完了画面を離れる時点で一時ファイルを削除します。

履歴を保存する設定では、履歴一覧に「未保存の加工済み写真があります」を表示し、そこから保存や共有を再開できます。

この保持により、写真ライブラリ保存が空き容量不足で失敗しても **再書き出しは不要**です。空き容量を作って同じファイルを保存し直せます。

未保存出力の一時領域は、7.2.3 の履歴使用容量上限とは別勘定とします。上限は加工後サムネイルを対象とするものであり、原寸の出力ファイルを含めません。

#### 6.2.2.1 異常終了後の復旧

出力ファイルが残った状態でアプリが異常終了した場合、起動時の扱いを **写真ごとに 6.2.2 の状態で分けます。**

| 状態 | 起動時の動作 |
| --- | --- |
| `Generated` | **復旧案内の対象に含める** |
| `Delivered` | 一時ファイルを削除し、**復旧案内の対象に含めない** |
| `Discarded` | 残存ファイルを削除する |

先の例（20 枚が `Delivered`、12 枚が `Generated`）では、20 枚ぶんの一時ファイルを削除し、案内は 12 枚だけを対象とします。

> 保存していない加工済み写真が 12 枚あります

`Delivered` で案内を出すと、すでに写真ライブラリへ保存済みの利用者に対して「保存していない加工済み写真があります」と表示することになり、事実と異なります。完了画面を離れる前に落ちただけであり、受け渡しは完了しているためです。

案内の文言は、`Generated` の枚数で決めます。

| 対象 | 文言 |
| --- | --- |
| 1 枚 | 保存していない加工済み写真があります |
| 複数枚 | 保存していない加工済み写真が N 枚あります |

N は `Generated` の枚数であり、バッチの総枚数ではありません。選択肢は「保存する」「共有する」「破棄する」の 3 つです。

これは履歴の復元ではなく、**未完了の受け渡し処理の復旧**として扱います。したがって「履歴を保存しない」を選んでいる利用者にも表示します。7.2.3 が定めるとおり、未受け渡しの出力はその設定の例外だからです。

#### 6.2.2.2 未保存出力の容量制限

Pro は 1 バッチ 50 枚のため、高解像度写真の完成物が数百 MB から 1GB を超えることがあります。端末内処理のため運営側の原価には影響しませんが、利用者の空き容量を圧迫します。

**一括処理の開始前に、以下を推定して確認します。**

- 推定出力容量
- 一時処理容量
- 未保存出力として保持する容量
- 現在の空き容量

開始条件は **推定必要容量の 1.2 倍以上の空き容量**とします（仕様 24.4）。満たさない場合は開始せず、素材数を減らすよう案内します。

未保存出力そのものにも制限を設けます。

- 保持できる未保存バッチは **最大 1 件**
- 保持期間は最大 24 時間
- 空き容量が一定値を下回った場合、保存または破棄を促す
- **新しいバッチを開始する際、前の未保存バッチが残っていれば先に処理を求める**

未保存バッチを無制限に積み上げる経路は作りません。

#### 6.2.2.3 未保存出力がある状態での新規加工

**未保存出力は、単体・一括を問わず一度に 1 つの処理単位までとします。**

未保存出力が残っている状態で新しい加工を始めようとした場合、先に解消を求めます。組み合わせ（単体の未保存で一括を開始、一括の未保存で単体を開始、など）ごとに規則を分けません。

> 保存していない加工済み写真があります

選択肢は「保存する」「共有する」「破棄する」「加工をやめる」の 4 つです。

#### 6.2.2.4 破棄と消費の関係

消費は出力の生成完了時点で確定します（6.2.1）。**したがって、その後に利用者が明示的に破棄しても消費は戻りません。**

生成に失敗した場合は消費しないため、境界は「正常に生成されたか」に一本化されます。破棄は生成後の任意操作であり、生成の失敗ではありません。

不意打ちを避けるため、破棄の確認に明記します。

> この加工済み写真を破棄します。使用した無料枠は戻りません。

トライアルクレジットを使用した場合は、その旨を表示します。

> この加工済み写真を破棄します。使用した一括処理クレジットは戻りません。

#### 6.2.2.5 時間判定の基準時刻

**すべての時間判定に端末時刻をそのまま使いません。単調増加する基準時刻を通します。**

時刻の正規化を独立した処理として 1 か所に置きます。各判定が個別に `maxOf` を書くと、書き忘れた箇所だけ防御が抜けます。

```kotlin
data class TimeAnchor(val lastObservedAt: Instant)

data class ObservedTime(
    val effectiveNow: Instant,
    val updatedAnchor: TimeAnchor,
)

fun observeTime(now: Instant, anchor: TimeAnchor): ObservedTime {
    val effectiveNow = maxOf(now, anchor.lastObservedAt)
    return ObservedTime(effectiveNow, anchor.copy(lastObservedAt = effectiveNow))
}
```

`now - firstSuccessAt < 24h` に端末時刻を直接使うと、**書き出し後に時計を 1 週間戻せば差が負になり、常に 24 時間未満と判定されます。** 時計が元の日時へ追いつくまで `FreeReexport` が残り続けます。

**アンカーは `UsageLedger.lastObservedAt` として保持します**（6.2）。型を分けているのは責務を示すためで、保存先は台帳と同一です。

6.2.3 では月次期間の後退を防いでいますが、24 時間の窓には同じ防御がありませんでした。基準時刻を 1 つに集約して両方へ適用します。

適用対象は以下です。

- `ExportGrant` の 24 時間判定（6.2）
- 未受け渡し出力の 24 時間保持（6.2.2）
- やり直しのための 24 時間保持保証（7.2.4）
- 履歴の保存期間判定（7.2.3）

これをしないと、クォータだけでなく**未保存出力の削除期限まで端末時刻の変更で延長されます**。

**`domain` の時間判定は `now` を引数に取りません。`effectiveNow` だけを受け取ります。** 端末時刻に触れてよいのは `observeTime` の呼び出し口 1 か所だけとし、それ以外へ `Instant.now()` 相当を渡さないことを規約とします。

#### 6.2.3 月初リセットと時刻巻き戻し

仕様 14.4 の「端末時刻が過去へ戻された場合、最後に確認した年月より前へ戻さない」を、期間の単調増加を強制することで実現します。

**月初にリセットするのは `consumed` だけです。`grants` は月をまたいで保持します。**

```kotlin
fun rollPeriod(ledger: UsageLedger, effectiveNow: Instant, zone: TimeZone): UsageLedger {
    val current = effectiveNow.toLocalDateTime(zone).yearMonth
    // 24時間を過ぎた権利だけを落とす。月の境界とは無関係
    val activeGrants = ledger.grants.filterValues { effectiveNow - it.firstSuccessAt < 24.hours }

    return if (current > ledger.period) {
        ledger.copy(period = current, consumedExportIds = emptySet(), grants = activeGrants)
    } else {
        ledger.copy(grants = activeGrants)   // 同一または過去 → 期間はリセットしない
    }
}
```

引数は `effectiveNow` です。`now` を直接受け取ると 6.2.2.5 の防御が抜けます。

`grants` を月初に空にすると、**7 月 31 日 23:59 に書き出して 8 月 1 日 00:01 に再書き出しした場合、2 分しか経っていないのに `FreeReexport` になりません。** 24 時間の窓は月の境界と無関係であり、両者を連動させる理由はありません。

タイムゾーンを西へ移動して月をまたぎ戻しても、端末時計を手動で戻しても、`period` は後退しません。

#### 6.2.4 同一素材の判定

仕様 14.3 は「新しいプロジェクトとして作り直しても、元素材識別子とローカルハッシュが一致すれば同一素材として扱う」と定めます。`PHAsset.localIdentifier` や MediaStore の URI は再インストールや再選択で変わりうるため、**ハッシュを主、識別子を従**とします。

ハッシュは `ファイルサイズ + 先頭 64KB + 末尾 64KB + 撮影日時` の複合とします。48 メガピクセルの HEIC を全読みする負荷を避けるためです。

理論上の衝突時は「別素材なのに無料で再書き出しできる」方向へ倒れます。これはユーザーに有利な安全側であり許容します。逆方向（同一素材なのに二重消費）へ倒れる設計は採りません。

##### 正準化規則

**「複合」だけでは実装が一意に定まりません。** バイト順やフィールド境界が違えば、同じ写真から別のハッシュが出ます。`sourceHash` は無料枠の判定に直結するため、規則を固定します。

| 項目 | 規則 |
| --- | --- |
| アルゴリズム | **SHA-256** |
| 形式 | 長さ前置きのバイナリ連結（下記） |
| 整数のバイト順 | **ビッグエンディアン** |
| スキーマバージョン | 先頭に `UInt32` で含める（現行 `1`） |
| 撮影日時 | **UTC の epoch milliseconds を `Int64`** |
| 撮影日時が無い | 長さ 0 のフィールドとして書く（値 0 で埋めない） |
| 対象データ | **ピッカーが返した実データ**。表示用に変換された派生画像ではない |

連結の形式は次とします。各フィールドを `UInt32` の長さで前置きします。

```
schemaVersion : UInt32
fileSize      : UInt32(8)  + Int64
headChunk     : UInt32(n)  + bytes    // 先頭 min(65536, fileSize) バイト
tailChunk     : UInt32(n)  + bytes    // 末尾 min(65536, fileSize) バイト
capturedAt    : UInt32(8)  + Int64    // 無ければ UInt32(0) のみ
```

長さを前置きするのは、フィールド境界を曖昧にしないためです。単純連結だと、末尾チャンクの終わりと日時の始まりを区別できず、異なる入力が同じバイト列になりえます。

**64KB 未満のファイル**では、先頭チャンクと末尾チャンクが重なります。**重なりを許容し、両方ともファイル全体を書きます。** 「重複を除く」規則を入れると分岐が増え、境界（ちょうど 64KB、65537 バイト）で取り違えます。

##### 入力の取得契約

**バイト列の組み立てを固定しても、入力の取得元が曖昧なら同じ写真から別のハッシュが出ます。**

```kotlin
data class SourceFingerprintInput(
    val fileSize: Long,
    val headBytes: ByteArray,
    val tailBytes: ByteArray,
    val capturedAtUtcMillis: Long?,
    val representation: SourceRepresentation,
)

enum class SourceRepresentation {
    Original,      // プロバイダーが返した原データ
    Transcoded,    // OS が変換した派生データしか取得できなかった
}
```

**撮影日時の優先順位を固定します。**

1. **写真ライブラリの撮影日時**（iOS は `PHAsset.creationDate`、Android は `MediaStore.Images.DATE_TAKEN`）
2. 無ければ **EXIF の撮影日時**（`DateTimeOriginal`）
3. どちらも無ければ **`null`**（長さ 0 のフィールド）

**ファイル更新日時は使いません。** コピーや同期で容易に変わり、同一素材の判定を壊します。

**原データを取得できない場合の扱い**も定めます。iOS の PhotosPicker は要求形式によっては HEIC を JPEG へ変換して返し、iCloud 上の原本を取得できない場合もあります。

| 状況 | 扱い |
| --- | --- |
| 原データを取得できる | `Original` としてハッシュを計算する |
| 原データを取得できない | **`Transcoded` として、取得できた表現からハッシュを計算する。処理は拒否しない** |

**処理自体を拒否しません。** 利用者にとって「この写真は加工できません」は理解不能な失敗です。`Transcoded` では同一素材の保証が弱まり、同じ写真を別素材と判定して**無料枠を余分に消費する**ことがありえますが、これは 6.2.4 が既に許容している「別素材なのに無料で再書き出しできる」の逆方向ではなく、利用者に不利な方向です。

そのため `representation` を `sourceHash` の**入力には含めません**。含めると、同じ写真が取得経路によって別ハッシュになります。`Transcoded` は診断のための区分値としてのみ記録し（`LogValue` の列挙、9.2）、変換が発生する頻度を計測します。頻度が高ければ、v1.x で原データ取得の再試行を強化します。

##### プロジェクト設定ハッシュ

6.7 の「変更せず再書き出し」の判定にも正準化が必要です。**同じ設定なのに別ハッシュになる要因**が複数あります。

| 要因 | 規則 |
| --- | --- |
| `Map` の反復順 | **キーの辞書順**でソートしてから書く |
| 浮動小数の表現 | `Float` は **IEEE 754 の 32 ビット表現をビッグエンディアンで**書く（文字列化しない） |
| DB の自動採番 ID | **含めない。** アプリ更新やデータ移行で変わる |
| スタンプの参照 | DB ID ではなく **`StampAsset` の内容ハッシュ**（8.4） |
| 欠損値 | 長さ 0 のフィールドとして明示する |
| フィールド順 | スキーマで固定する。追加は末尾のみ |

アルゴリズムと形式は `sourceHash` と同じ（SHA-256、長さ前置き、スキーマバージョン付き）です。

`Float` を文字列化しない理由は、`toString` の桁数が実装依存だからです。同じ値が `0.15` と `0.15000001` になれば別ハッシュになります。ビット表現なら一意です。

#### 6.2.5 改ざん耐性

`UsageLedger` を平文で DB に保存すると、DB を書き換えるだけで無料枠が無制限になります。一方で仕様 14.5 は、不正利用防止のためだけに端末固有識別子や過剰な個人情報を収集することを禁じています。

折衷案として、Keychain / Keystore の鍵で `UsageLedger` に HMAC 署名を付与します。サーバー照合も端末識別子の収集も行いません。

##### 読み込み結果の分類

読み込みが失敗する理由は 1 つではありません。初回起動・改ざん・ストレージの一時障害・スキーマ更新を同じ結果にまとめると、**初回起動の利用者が最初から Free 枠とトライアルを封じられ**、逆に**一時障害のたびに正常な台帳を保守状態で上書きします**。

`ProtectedBlobStore` の読み込み結果を、原因ごとに分けた型で返します。

```kotlin
sealed interface ProtectedLoadResult<out T> {
    data class Valid<T>(val value: T) : ProtectedLoadResult<T>
    data object Missing : ProtectedLoadResult<Nothing>                    // まだ存在しない
    data object IntegrityFailure : ProtectedLoadResult<Nothing>           // HMAC 不一致
    data object TemporarilyUnavailable : ProtectedLoadResult<Nothing>     // Keychain/Keystore/ファイルの一時障害
    data class UnsupportedSchema(val version: Int) : ProtectedLoadResult<Nothing>
}
```

| 結果 | 扱い |
| --- | --- |
| `Valid` | そのまま使う |
| `Missing` | **新規利用者用の通常台帳を作る**（`monthlyBlockedPeriod = null`、`trialIntegrityLocked = false`） |
| `IntegrityFailure` | 後述の保守的台帳へ修復する |
| `TemporarilyUnavailable` | **上書きしない。** 再試行し、書き出しの開始を一時停止する（`ExportStartGate` を通さない）。利用者には再試行可能なエラーを提示する |
| `UnsupportedSchema` | 定義済みの移行処理を実行する。移行後に再検証する |
| 移行不能 | 復旧エラー（7.4.3）として扱う。**自動初期化しない** |

**`TemporarilyUnavailable` と `IntegrityFailure` を混同しないことが要点です。** 鍵ストアが一時的に利用できないだけの状態を改ざんとして修復すると、正常な利用者の枠を消します。両者は「署名検証まで到達したか」で区別できます。データを読めて HMAC が一致しない場合のみ `IntegrityFailure` です。読み込み自体が失敗した場合、鍵を取得できなかった場合は `TemporarilyUnavailable` です。

HMAC 鍵そのものが失われた、または無効化された場合（生体認証の登録変更等で Keystore の鍵が破棄された場合を含む）は、データを検証できないため `IntegrityFailure` として扱います。鍵の喪失と改ざんは端末側から区別できないためです。

##### 検証失敗時の扱い

以下は `IntegrityFailure` に対する規則です。

**空の `UsageLedger` を作り直しません。** 台帳は消費件数だけでなく、どの `sourceHash` が grant を持ちトライアルを消費したかを保持しています。空にすると**無料枠もトライアルも全回復**し、改ざんの動機になります。

**`IntegrityFailure` を一時的な読み取り結果のままにしません。保守的に修復した永続状態へ変換します。**

読み取り失敗のたびに判断すると、正しい `lastObservedAt` を失っているため `effectiveNow` を算出できず、「当月だけ `Blocked`」を翌月に解除する手立てもなく、Standard / Pro が成功しても grant を書き込む先がありません。

検出した時点で、次の内容の**新しい署名済み台帳**を作ります。

| フィールド | 値 |
| --- | --- |
| `lastObservedAt` | **署名失敗を検出した時点の端末時刻**。正しいアンカーを失っているため、ここを新しい基準時刻とする |
| `monthlyBlockedPeriod` | 現在月 |
| `trialIntegrityLocked` | `true` |
| `grants` | 空 |
| `consumedExportIds` | 空 |
| `trialEntries` | 空 |
| `period` | 現在月 |

結果として次のようになります。

- **現在月の Free 単体書き出しは不可。翌月になれば月間枠は再開する**（`monthlyBlockedPeriod != period` になるため）
- **一括処理トライアルは再インストールまで不可**（`trialIntegrityLocked` は解除しない）
- Standard / Pro の通常書き出しは許可。月間枠に依存しない
- 成功した書き出しの grant は、この修復済み台帳へ通常どおり追加できる
- `FreeReexport` は grant が空なので当面成立しない

**改ざんされた値を根拠に枠やクレジットを付与しません。** 空の台帳をそのまま作ると無料枠もトライアルも全回復するため、封じるフラグを同時に立てます。

##### 封鎖フラグを実際に効かせる箇所

フラグを立てるだけでは効果がありません。次の 2 箇所で参照します。

| フラグ | 参照箇所 | 効果 |
| --- | --- | --- |
| `monthlyBlockedPeriod` | `QuotaPolicy.evaluate` の手順 4（6.2 判定順） | 月間上限の判定より前に `Blocked(LedgerIntegrityFailure)` を返す |
| `trialIntegrityLocked` | `remainingCredits` の導出（6.5.6.1） | 残数を 0 とし、一括トライアル画面への進入・写真選択・認可をすべて禁止する |

`monthlyBlockedPeriod` を上限判定より前に置く理由は、修復後の `consumedExportIds` が空だからです。上限判定だけでは `consumed(0) >= limit` が成立せず、そのまま通過します。

再インストールで枠が戻ることは仕様 14.5 が明示的に許容しているため、追跡しません。

##### バックアップ対象からの除外

**署名済みデータと HMAC 鍵のライフサイクルを一致させます。** データだけがクラウドバックアップや端末移行で復元され、鍵が復元されないと、**通常の再インストールでも `IntegrityFailure` になり、当月枠とトライアルが封鎖されます。** これは直前の「再インストールで枠が戻る」方針と正反対の結果です。

v1 では次を規則とします。

| 対象 | 規則 |
| --- | --- |
| `ProtectedBlobStore` のファイル / DataStore | **クラウドバックアップ対象外**（iOS は `isExcludedFromBackup`、Android は `data_extraction_rules.xml` で除外） |
| HMAC 鍵 | **端末外へ移行しない**（Android Keystore はエクスポート不可。iOS の Keychain は `ThisDeviceOnly` 系のアクセシビリティを指定） |
| 再インストール・端末移行後 | 両方とも消えるため `Missing` となり、**新規台帳を作る**（6.2.5 の読み込み結果の分類） |

鍵とデータの**どちらか一方だけが残る状態を作らない**ことが要点です。両方消えれば `Missing`、両方残れば `Valid` となり、`IntegrityFailure` は実際の改ざんか鍵の破棄に限定されます。

### 6.3 権限解決（EntitlementResolver）

RevenueCat の `CustomerInfo` をアプリ全体に流さず、純粋関数で畳み込みます。

```kotlin
fun resolve(snapshot: CustomerInfoSnapshot, effectiveNow: Instant): Entitlement

data class Entitlement(
    val plan: Plan,                     // free / standard / pro
    val status: PlanStatus,             // active / grace / pending / expired / revoked
    val expiresAt: Instant?,
    val lastVerifiedAt: Instant,
)
```

要件は 3 点です。

- **`pending`（支払い保留）では有料機能を付与しません**（仕様 5.4）。個々の権限フラグ（追加スタンプ、カスタムスタンプ、一括処理、広告非表示、月間枠の対象か）はすべて `Entitlement` から導出し、`plan` から直接導出しません。導出結果は `ResolvedCapabilities`（6.2）として 1 箇所にまとめ、**下流のポリシーへ `Plan` を渡しません**
- **オフライン耐性**（仕様 25.3 / 27.3）。最後に検証成功した `Entitlement` を `lastVerifiedAt` とともに ProtectedBlobStore へ保存します。ネットワーク不通時はこのキャッシュで有料機能を維持し、復元失敗を理由に Free へ強制降格させません。失効が明示的に確認された場合のみ剥奪します
- **バックエンド障害で編集を止めません**（仕様 21.6）。リモート設定が取得できない場合はアプリ内の安全な既定値を使用します

##### 購入状態キャッシュの読み込み失敗

`SubscriptionState` も `ProtectedBlobStore` 上の署名付きデータであり、6.2.5 と同じ `ProtectedLoadResult` を返します。有効なキャッシュがある場合のオフライン動作だけでは不足です。

| 結果 | 扱い |
| --- | --- |
| `Valid` | オフラインでもこのキャッシュで有料機能を維持する |
| `Missing` | RevenueCat へ問い合わせる。**成功するまでは `VerificationRequired` とし、Free の能力も有料の能力も付与しない**（6.2） |
| `IntegrityFailure` / `UnsupportedSchema`（移行不能） | キャッシュを信頼しない。RevenueCat から**再取得する** |
| `TemporarilyUnavailable` | 上書きせず再試行する。判定は保留し、既存のメモリ上の `Entitlement` を維持する |

再取得を要する場合の規則は次のとおりです。

- 取得に成功すればキャッシュを置き換える
- **オフラインで再取得できない場合、有料権限を新規に付与しません**。改ざんによる権限詐取を防ぐためです
- **カスタムスタンプ、履歴、プリセットなどのデータは削除しません**（6.7 と同じ扱い）
- 利用者へは「購入状態を確認できません」と提示し、**再試行**と**購入の復元**への導線を出します

**Free へ降格したと表示しません。** 検証できない状態と失効した状態は異なります。前者で「無料プランになりました」と表示すると、支払い済みの利用者に対する誤った通知になります。

Pro は月単位で契約と解約を繰り返す利用者が一定数いると想定します。継続率の中心は Standard です。この前提から、**解約や降格によってカスタムスタンプと一括設定プリセットを失わせません**（仕様 12.6 をプリセットへ拡張）。再契約時にそのまま再利用できます。

### 6.4 広告表示頻度（AdFrequencyPolicy）

仕様 15.3 / 15.4 を純粋関数として実装します。

- 検出中、顔選択中、編集中、書き出し中、書き出しエラー対応中、課金処理中は表示しない
- 初回書き出し完了時には全画面広告を表示しない
- 全画面広告は最大でも 2〜3 回の書き出しにつき 1 回
- 同一セッションで連続表示しない
- 広告取得失敗でアプリ処理を止めない

判定を純粋関数に閉じることで `commonTest` で網羅できます。

### 6.5 一括処理とトリアージ

**一括処理の制限なし利用は `canUseProBatch` が必要です。** `canUseBatchTrial` だけを持つ利用者は、次のいずれかを満たす場合にトライアルとして利用できます。

- 未使用クレジットの範囲で、新しい写真を処理する
- **消費済み台帳に登録されている写真を、再度処理する**（6.5.6.1）

したがって **残クレジットが 0 でも、消費済み台帳に写真があれば一括処理画面を閉じません。** 「クレジットを使い切ったら一切使えない」とすると、6.5.6.1 が定める「同じ 5 枚は期限なく何度でも試せる」が成立しません。

進入条件を式で示します。

```kotlin
val canEnterBatch =
    capabilities.canUseProBatch ||
    (
        capabilities.canUseBatchTrial &&
        !usageLedger.trialIntegrityLocked &&
        (
            remainingCredits > 0 ||
            usageLedger.trialEntries.isNotEmpty()
        )
    )
```

**`canUseBatchTrial` を条件へ明示します。** これが無いと、能力を持たない利用者でも残クレジットや過去の entry があれば進入できる読みになります。`trialIntegrityLocked` も同様で、台帳修復後は `trialEntries` が空になるため、フラグを見なければ「残 5 枚」として通過します（6.2.5）。

**判定に `Plan` を使いません。** プラン名で書くと、`plan = Pro` かつ `status = pending` の利用者を Pro の通常一括として扱う実装が入ります。能力は 6.2 の `ResolvedCapabilities` から取ります。料金表や説明文でプラン名を使うことは構いません。**実装上の条件式はすべて能力で書きます。**

v1 では写真のみを対象とします。

#### 6.5.1 中核となる価値

一括処理の価値は「複数選択できること」ではありません。**50 枚を一枚ずつ編集画面で開かずに済むこと**です。

そのため処理フローを以下とします。

1. 写真を選択する
   - Pro — 最大 50 枚
   - Free / Standard のトライアル — 最大 5 枚。ただし新しい写真は残クレジット数以内（6.5.6）
2. 全写真の顔を自動検出する
3. 検出した全顔を加工対象にする（6.1 の不変条件）
4. **選択した確認モードに応じて、全写真に目を通す**
   - おまかせ一括 — 全写真を加工後サムネイルの一覧で確認する
   - 1 枚ずつ確認 — 全写真を順番に大きく表示して確認する
5. `ReviewRequired` の写真について対応方法を記録し、必要な確認を完了する（6.5.4）
6. 一括書き出しする

**手順 4 は、どちらのモードでも省略できません。** 見せ方がモードで異なるだけで、「全写真に一度は目を通す」という要件は共通です。理由は 6.5.2 に記述します。モードごとの成立条件は 6.5.3 に定義します。

#### 6.5.2 トリアージ判定（BatchTriagePolicy）

写真単位の要確認理由を純粋関数で判定します。

```kotlin
enum class ReviewReason {
    NoFaceDetected,      // 顔を 1 つも検出できなかった
    SmallFace,           // 検出用画像上で短辺 24px 未満の顔がある
    ExtremePose,         // 横や上下を大きく向いた顔がある
    FaceAtEdge,          // 拡張後の領域が画像境界に接する顔がある
    OverlappingFaces,    // 領域同士が重なる顔がある
}

/** 警告 1 件。理由ではなく「発生」を表す */
data class ReviewIssueId(
    val detectionRevision: Long,
    val reason: ReviewReason,
    val affectedFaceTrackIds: List<String>,   // 辞書順にソート済み
)

data class ReviewIssue(
    val issueId: ReviewIssueId,
    val affectedFaceTrackIds: Set<String>,
)

fun triage(result: DetectionResult, detectionRevision: Long): List<ReviewIssue>
```

##### 警告は発生単位で持つ

**`Set<ReviewReason>` では、同じ理由を持つ複数の顔を区別できません。** これは匿名化確認の安全性に直接影響します。

小さい顔が 3 人写っている写真を考えます。`Set` では `SmallFace` が 1 件に集約されるため、**1 人に手動領域を追加しただけで** `SmallFace → ManualRegionAdded` を記録でき、3 人すべてに対応したものとして `Reviewed` へ進めます。残り 2 人は隠れていません。

`ReviewIssue` を発生単位で列挙します。

| 理由 | 発生単位 |
| --- | --- |
| `SmallFace` | **顔ごと**に 1 件 |
| `ExtremePose` | **顔ごと**に 1 件 |
| `FaceAtEdge` | **顔ごと**に 1 件 |
| `OverlappingFaces` | **重なる顔の組み合わせごと**に 1 件 |
| `NoFaceDetected` | **写真ごと**に 1 件（対象の顔が存在しないため `affectedFaceTrackIds` は空） |

##### 再検出時は対応づけを試みない

**「再検出しても同じ顔へ同じ ID が付く」とは保証できません。** 新旧の顔を対応づけるアルゴリズムが必要になりますが、検出順が変わっただけでも別の `faceTrackId` になりえます。誤った対応づけは「別人の顔に対する判断を、この顔の判断として扱う」ことを意味し、匿名化確認としては最悪の失敗です。

v1 では対応づけを試みません。

- `issueId` に **`detectionRevision`** を含める
- **再検出のたびに `detectionRevision` を増やす**
- 再検出時は、その写真の **`ReviewIssue` / `ReviewDecision` / `Reviewed` をすべて破棄する**

利用者はやり直しになりますが、対応づけを誤って安全側を崩すよりも確実です。再検出は利用者が明示的に行う操作であり、頻度も高くありません。

`affectedFaceTrackIds` の生成規則を固定します。

| 理由 | `affectedFaceTrackIds` |
| --- | --- |
| `SmallFace` / `ExtremePose` / `FaceAtEdge` | 対象の `faceTrackId` 1 件 |
| `OverlappingFaces` | 重なる 2 件を**辞書順に並べる**（順序で別 ID にならないように） |
| `NoFaceDetected` | 空。ID は写真 ID と `detectionRevision` から生成する |

**判定に使えるのは、両 OS が等しく提供する値だけです。**

当初は「検出信頼度が閾値未満」を理由の 1 つに置いていましたが、これは実現できません。iOS の `VNFaceObservation` は `confidence`（0〜1）を持つ一方、**ML Kit の `Face` には検出信頼度のアクセサが存在しない**ためです（`getBoundingBox` / `getHeadEulerAngleX・Y・Z` / `getLandmark` / `getSmilingProbability` / `getLeftEyeOpenProbability` / `getTrackingId` のみ）。

片方だけで判定すると、同じ写真で Android だけ警告が出ない非対称が生じます。警告の量が OS で変わることは、安全性の非対称そのものです。12.1 の契約テスト（両 OS で同一スイート）とも矛盾します。

そこで **頭部回転角** に置き換えました。両 OS が対称に提供します。

| 値 | iOS | Android |
| --- | --- | --- |
| yaw（左右の向き） | `VNFaceObservation.yaw` | `getHeadEulerAngleY()` |
| pitch（上下の向き） | `VNFaceObservation.pitch` | `getHeadEulerAngleX()` |
| roll（傾き） | `VNFaceObservation.roll` | `getHeadEulerAngleZ()` |

横や上下を大きく向いた顔は検出枠が実際の顔を覆いきれないことがあり、警告する価値は信頼度と同等です。`ExtremePose` は yaw または pitch の絶対値が閾値を超えたときに立てます。

`confidence` は iOS でのみ取得できるため、**トリアージには使いません**。12.2 の検出品質の回帰監視でのみ、iOS 側の参考値として記録します。

`triage` の結果が写真の **検出ステータス**（6.5.3）を決めます。空集合なら `Normal`、空でなければ `ReviewRequired` です。閾値はリモート設定で調整可能とします。

**このトリアージは、検出された顔の品質しか評価できません。** 検出されなかった顔の存在は、いかなる警告条件にも現れません。

たとえば 3 人が写る写真で 2 人を十分な大きさ・正面向き・画像中央で検出し、残る 1 人を完全に見落とした場合、`triage` は空集合を返します。顔は検出されており、小さくもなく、大きく向いてもおらず、端でもなく、重なってもいないためです。この写真は `Normal` に分類されますが、実際には 1 人の顔が露出したまま書き出されます。

したがって `Normal` は安全の保証ではなく、**検出結果の上で警告すべき点がないこと**を意味するに過ぎません。この限界があるため、6.5.3 の確認を必須とします（モードごとの満たし方は 6.5.3 に定義）。

**アプリ側が `Reviewed` を立てることはありません。** 検出漏れを判定できない以上、アプリが確認済みと宣言することはできません。`Reviewed` は利用者の操作によってのみ成立します。

#### 6.5.3 写真の状態と確認の成立条件

**写真の状態を 2 つの軸で持ちます。** 「アプリが何を検出したか」と「利用者が何を確認したか」は別の情報であり、1 つの状態へ混ぜると「通常なのに確認済み」「要確認を確認済みへ変更する」といった意味の混線が生じます。

```kotlin
enum class DetectionStatus { Normal, ReviewRequired }   // triage の結果
enum class ReviewStatus { Unreviewed, Reviewed }        // 利用者の操作
```

| 軸 | 値 | 決まり方 |
| --- | --- | --- |
| 検出ステータス | `Normal` | `triage` が空集合を返した |
| | `ReviewRequired` | `triage` が 1 つ以上の警告を返した |
| 確認ステータス | `Unreviewed` | 初期値 |
| | `Reviewed` | 利用者の操作によってのみ遷移する（6.5.4） |

検出ステータスは利用者の操作で変わりません。確認ステータスはアプリの判断で変わりません。

##### 書き出しの成立条件

条件は 6.5.5 のモードで異なります。同じ確認を二度求めないためです。

**おまかせ一括**

1. 全サムネイルの生成が完了している（生成中は書き出しボタンを無効化する）
2. **バッチ内の全写真を加工後サムネイルの一覧として表示し**、一覧の末尾まで到達している
3. `ReviewRequired` の写真がすべて `Reviewed` になっている
4. 利用者が「一覧の仕上がりを確認しました」を明示的に押している

`Normal` の写真に個別の `Reviewed` 操作は求めません。一覧へ目を通し、手順 4 を押すことが全写真に対する確認にあたります。

**1 枚ずつ確認**

1. 全サムネイルの生成が完了している
2. `Normal` / `ReviewRequired` を問わず、**全写真が `Reviewed` になっている**
3. `ReviewRequired` の写真について、**対応方法が記録されている**（6.5.4）
4. 完了サマリを表示する

条件 3 を「警告が解消されている」とは書きません。利用者が内容を見て問題ないと判断しても、顔を隠さず保存すると選んでも、**警告そのものは消えていません**。扱いを決めただけです。

このモードでは 1 枚ずつ大きく表示して個別に確認するため、末尾到達と確認ボタンは求めません。最終の一覧は任意の見直し用として提供します。

いずれのモードでも、**全写真に一度は目を通す**という要件は共通です（6.5.1 の手順 4）。満たし方が異なるだけです。これにより仕様 10.4 の「書き出し前にユーザーが加工結果を確認できること」を全写真について満たします。

##### 一覧の実装制約

**サムネイルは検出漏れを目視で発見できる大きさとします。** タップで全画面プレビューへ遷移でき、一覧上でもピンチ操作で拡大できることを要件とします。未検出の顔は加工されていないため、一覧上では顔が露出した状態で見えます。この視認性が仕組みの前提です。

要確認だけを表示して他を隠す既定の表示は採りません。絞り込みは利用者が明示的に選ぶフィルターとしてのみ提供します。

##### バッチ全体の確認状態

おまかせ一括の「一覧の仕上がりを確認しました」は写真単位ではなくバッチ全体の操作なので、独立して持ちます。

```kotlin
data class BatchReviewState(val overviewConfirmed: Boolean)
```

##### 確認状態の解除

**一律に全解除はしません。** 50 枚のうち 1 枚を直しただけで残り 49 枚まで再確認になると、一括処理の価値そのものが失われます。変更が実際に見た目へ影響する写真だけを `Unreviewed` へ戻します。

**判定は設定名の列挙ではなく、原則で行います。** 設定項目を数え上げる形にすると、項目が増えたときに漏れます（背景処理がその例でした）。

> **匿名化結果または構図に影響する変更**が行われた場合、その変更の影響を受ける写真を `Unreviewed` へ戻し、`overviewConfirmed` を `false` にする。

基準を「見た目」ではなく「匿名化結果」とします。圧縮品質を上げ下げすれば見た目は厳密には変わりますが、**顔が隠れているかどうかの確認をやり直す必要はありません。** 確認の目的は匿名化の妥当性であり、画質の良し悪しではないためです。

| 変更 | 写真の `ReviewStatus` | `overviewConfirmed` |
| --- | --- | --- |
| 匿名化結果・構図に影響する変更（個別） | その写真だけ `Unreviewed` | `false` |
| 匿名化結果・構図に影響する変更（共通） | 影響を受ける写真を `Unreviewed`。`hasOverride` の写真は共通設定の影響を受けないため維持（6.5.9） | `false` |
| 影響しない変更 | 維持 | 維持 |

**影響する変更**の例です。

- 顔のエフェクト、エフェクト強度、スタンプ
- 顔領域の追加・移動・削除
- 縦横比、切り抜き位置（構図が変わり、隠すべき顔が枠外へ出うる）
- 背景ぼかしなどの背景処理

**影響しない変更**の例です。位置情報の削除、撮影日時の保持、圧縮品質。

**写真の増減は表に含めません。** 確認状態が存在するのは検出が終わったあと、すなわち実行開始後です。6.5.8 のとおり v1 では実行開始後のバッチへ写真を追加できず、後述のとおり削除もできません。写真を変えたい場合はバッチごと作り直します。実行中の増減を実装する際に、追加と削除の行を戻します。

##### 設定へ戻る経路

**確認段階から設定段階へ戻れます。検出結果は保持し、再検出は行いません。**

共通設定を変える手段は設定段階の 1 か所だけとし、確認画面に別の設定 UI を置きません。同じ設定が 2 か所にあると、どちらが正かという問題が生まれます。

**v1 では、この経路から写真の選択は変更できません。** 変更できるのはエフェクト、強度、スタンプ、縦横比などの設定だけです。写真を変えたい場合は「選びなおす」を実行し、現在のバッチを破棄して新しいバッチを作ります。

検出後に写真を出し入れできると、6.5.8 の「実行開始後はバッチを固定する」と両立しません。設定だけを変えられる経路と、バッチごと作り直す経路に分けます。

戻って設定を変更した場合、上の解除規則を適用します。変更せずに戻ってきた場合は確認状態を維持します。

`overviewConfirmed` は、**匿名化結果または構図に影響する変更で必ず `false` にします。** 一覧で見渡した内容と書き出す内容が一致しない状態を作らないためです。

検出ステータスは検出をやり直したときにのみ再計算します。`ReviewResolution`（6.5.4）は `Unreviewed` へ戻した時点で破棄します。

おまかせ一括の末尾到達判定は、スクロールだけでなく VoiceOver や TalkBack による走査でも成立させます。支援技術の利用者が確認操作へ到達できない実装は、仕様 29 章に反します。

なお **末尾までの到達も `Reviewed` も、安全の保証ではありません。** 見落としを減らすための手順として扱い、6.5.2 のとおり「確認済みだから安全」とは表現しません。いかなる場合も「安全」という語を状態表示に用いません（仕様 34.5）。

#### 6.5.4 要確認への対応

**`ReviewRequired` かつ `Unreviewed` の写真が 1 枚でも残っている間は、一括書き出しを開始できません。**

**警告を消すのではなく、警告に対する利用者の判断を記録します。** 検出結果は事実であり、利用者が確認したからといって事実が変わるわけではないためです。

```kotlin
sealed interface ReviewResolution {
    /** 内容を見て、このままでよいと判断した */
    data object AcceptedAsIs : ReviewResolution

    /** 手動で隠す範囲を追加した。どの領域かを保持する */
    data class ManualRegionAdded(val regionId: String) : ReviewResolution

    /** 顔を隠さずそのまま保存すると選んだ */
    data object UnmaskedExportConfirmed : ReviewResolution
}

data class ReviewDecision(
    val resolutions: Map<ReviewIssueId, ReviewResolution>,
)
```

**`ManualRegionAdded` は `regionId` を持ちます。** 単なる列挙値だと、どの手動領域を追加したのかが分かりません。あとから利用者がその領域を削除した場合に、判断だけが残って「対応済み」と表示されます。

領域の作成と判断の記録は、**1 つのドメインコマンドで原子的に**行います。片方だけが成立する状態を作りません。

- 手動領域の作成が失敗すれば、判断も記録しない
- `regionId` の領域が削除されたら、対応する `ReviewResolution` も破棄して `Unreviewed` へ戻す

**判断は `ReviewIssue` ごとに記録します（理由ごとではありません）。** 1 枚の写真には複数の警告が同時に付き、同じ理由が複数件つくこともあります（6.5.2）。

```kotlin
ReviewDecision(
    resolutions = mapOf(
        // 1 人目の小さい顔に範囲を足した
        ReviewIssueId(rev, SmallFace, listOf("face-1")) to ManualRegionAdded("region-9"),
        // 2 人目はそのままでよいと判断した
        ReviewIssueId(rev, SmallFace, listOf("face-2")) to AcceptedAsIs,
        // 端の顔はそのままでよいと判断した
        ReviewIssueId(rev, FaceAtEdge, listOf("face-5")) to AcceptedAsIs,
    )
)
```

`ReviewRequired` の写真が `Reviewed` になる条件は、**その写真の `List<ReviewIssue>` すべてに対して `ReviewResolution` が記録されていること**です。1 件でも未記録なら `Unreviewed` のままです。

理由単位ではなく発生単位にすることで、「3 人の小さい顔のうち 1 人だけ対応して先へ進む」経路がなくなります。

##### `Normal` の写真の確認

`Normal` の写真には `ReviewIssue` がないため `ReviewDecision` を作れません。確認の成立はモードで分かれます。

| モード | `Normal` 写真の扱い |
| --- | --- |
| おまかせ一括 | 個別の操作を求めない。一覧へ目を通し「一覧の仕上がりを確認しました」を押すことが確認にあたる（6.5.3） |
| 1 枚ずつ確認 | 利用者が **「確認して次へ」** を実行すると、`ReviewDecision` なしで `Reviewed` へ遷移する |

これを定めないと、1 枚ずつ確認で `Normal` の写真が永久に `Unreviewed` のままになり、書き出しへ進めません。

理由別の一括対応（後述）では、対象の理由に属する `ReviewIssue` すべてへ `AcceptedAsIs` をまとめて記録します。**その理由の発生を 1 件でも取りこぼしません。** 他の理由の `ReviewIssue` が残っていれば、その写真は `Unreviewed` のままです。

**`DetectionStatus` と `ReviewIssue` は変化しません。** 警告の理由は書き出し後も記録として残ります。あとから履歴を見たとき、どの写真のどの顔にどんな警告があり、利用者がどう判断したかを辿れます。

アプリが自動的に `Reviewed` にすることはありません（6.5.2）。

**一括対応は理由別のグループ単位でのみ許可します。** 50 枚中 30 枚が「小さい顔がある」で警告された場合に個別対応を強いるのは現実的でないためです。この場合の `ReviewResolution` は `AcceptedAsIs` になります。ただし条件を 2 つ課します。

- そのグループのサムネイル一覧を表示した状態からのみ実行できる
- **`NoFaceDetected` は一括対応の対象外とする。** 顔が 1 つも検出されていない写真は、何も加工されないまま通過する最も危険な経路であり、個別の判断を要する

#### 6.5.5 一括処理モード

2 種類を定義します。名称は実際の挙動と一致させます。

**おまかせ一括**

1. 全写真の検出顔へ同じ加工を適用する
2. 全写真をサムネイル一覧で確認する
3. 警告のある写真だけを開いて修正する

**1 枚ずつ確認**

1. 全写真を順番に大きく表示する
2. 利用者が一枚ずつ確認する
3. 確認後に一括保存する

速度を重視する利用者と安全性を重視する利用者を分けられます。「写真ごとに確認してから隠す」という名称は、実際には要確認のみを確認するフローであるため使用しません。

#### 6.5.6 一括処理の体験提供

Free および Standard の利用者は、Pro の中核である一括処理を一度も試さずに月 980 円を判断することになります。これを避けるため、**一括処理でのみ使える 5 枚分のクレジット**を付与します。

付与は全プランに対して行いますが、実際に消費するのは Free と Standard だけです。Pro は 6.5 のとおり通常利用ができるため、クレジットを消費しません。

**月間の無料枠とは別勘定とします。** 月間枠から引くと、Free の利用者は一括処理を試しただけでその月の枠を使い切り、通常の単体処理が一か月できなくなります。試用のために本来の機能を奪う形になり、転換率をかえって下げます。端末内処理のため限界原価はなく、一度限りの付与であれば継続的な無料利用にもなりません。

**回数制ではなくクレジット制とします。**

- **同じ元写真について、初回の正常生成時にだけ 1 クレジットを消費する**
- 使い切るまで有効
- 失敗した写真では消費しない
- 全件失敗または利用者が中止した場合、クレジットは減らない
- Pro へ加入済みの場合は消費しない

##### 選択枚数の条件

制限は **2 つの独立した条件** です。1 つにまとめると 6.5.6.1 の「同じ 5 枚は何度でも試せる」が成立しません。残クレジット 0 の状態で消費済みの写真すら選べなくなるためです。

| 条件 | 上限 |
| --- | --- |
| 1 バッチの総枚数 | 5 枚 |
| **選択中のうち、消費済み台帳にない写真の枚数** | 残クレジット数 |

例を挙げます。

| 状況 | 可否 |
| --- | --- |
| 残 0 枚 ＋ 過去に試した写真 3 枚 | **可**（新規 0 枚） |
| 残 2 枚 ＋ 過去に試した写真 3 枚 ＋ 新しい写真 2 枚 | **可**（新規 2 枚 ≤ 残 2 枚、総数 5 枚） |
| 残 2 枚 ＋ 新しい写真 3 枚 | 不可（新規 3 枚 > 残 2 枚） |

##### 案内の出しどころ

2 つの条件はそれぞれ別の案内に対応します。**総枚数の上限は、現在の利用権限によって変わります。**

| 分類 | 発火条件 | 誘導 |
| --- | --- | --- |
| `batch-credit` | Free / Standard が、残クレジットを超える**新しい写真**を選ぼうとした | Pro |
| `batch-size` | Free / Standard が**総数 5 枚**を超えて選ぼうとした | Pro |
| `batch-limit` | Pro が**総数 50 枚**を超えて選ぼうとした | 誘導なし。上限の通知のみ |

`batch-size` と `batch-limit` を分ける理由は、同じ「総枚数超過」でも意味が違うためです。前者はアップグレードで解消できる制限、後者は仕様上の上限であり、Pro に対してアップグレードを促す先はありません。

`batch-credit` だけでは、**すでに試した写真だけを 6 枚選ぶ場合**を捕まえられません。新しい写真は 0 枚なので `batch-credit` に該当しませんが、トライアルの総枚数 5 枚には違反します。この経路を `batch-size` が受けます。

「初回 1 回のみ」とすると、1 枚だけ試した時点で残り 4 枚を失います。クレジット制ならその事故が起きず、部分的な失敗や中止の扱いも規則として自動的に定まります。

#### 6.5.6.1 同一写真の再書き出し

**クレジットの消費判定は、6.2.4 の同一素材判定（`sourceHash`）に従います。** 加工内容が異なっても、同じ元写真であれば追加消費しません。

これがないと、モザイクで書き出して結果を見てから強度を調整して再書き出しするだけで 2 クレジット消費し、通常の無料枠（24 時間以内の再書き出しは追加消費なし）より厳しい扱いになります。試用のための枠がやり直しで目減りする設計は、トライアルの目的に反します。

##### 保存するのは台帳だけ

**残クレジット数は保存しません。消費済み台帳から導出します。**

```kotlin
val remainingCredits =
    if (usageLedger.trialIntegrityLocked) {
        0
    } else {
        maxOf(
            0,
            configuredCreditCount
                - usageLedger.trialEntries.size
                - usageLedger.trialReservations.size,
        )
    }
```

##### クレジットの予約

**認可だけではクレジットを占有できません。** `UsageLedgerStore.transact` は更新を直列化しますが、**認可結果を台帳へ残さなければ、生成完了までクレジットは空いたまま**です。

残り 1 枚の状態で、異なる `sourceHash` の 2 件が並行して認可されると、`sourceHash` ゲートは別素材なので通過し、どちらも `trialEntries.size` が同じ値を見て `BatchTrial(true)` になります。結果としてクレジットを 1 枚超過します。

Free の単体書き出しには月間認可ゲートがありますが（7.4.3）、一括トライアルには対応する仕組みがありませんでした。

台帳へ予約を持たせます。

```kotlin
data class UsageLedger(
    // ...
    val trialReservations: Map<String, String>,   // sourceHash → exportId
)
```

| 契機 | 操作 | 保存先 |
| --- | --- | --- |
| 認可時（`BatchTrial(true)` と判定。手順 −2） | `trialReservations[sourceHash] = exportId` を**同じ `transact` の中で**追加する | ProtectedBlobStore |
| `Prepared` の保存に失敗（手順 0） | **補償トランザクション**で予約を削除する | ProtectedBlobStore |
| 台帳への適用（手順 4） | **同じ台帳トランザクション内で**予約を削除し、`trialEntries[sourceHash]` へ移す | ProtectedBlobStore |
| 最終確定（手順 8） | **台帳には触らない**（Room のみ） | — |
| ロールバック | この `exportId` が所有する**予約または `trialEntries`** を削除する | ProtectedBlobStore |
| 起動時 | コミットの無い予約を孤児として削除する。**その完了後に新規認可を許可する** | ProtectedBlobStore |

**残数計算は `trialEntries` と `trialReservations` の合計で行います。** 予約を数えなければ、予約を作った意味がありません。

**不変条件: 同じ `sourceHash` が `trialEntries` と `trialReservations` の両方に存在してはなりません。** 予約から entry への移動は同一トランザクション内の削除と追加であり、中間状態が観測されません。この条件を台帳の検証時にも確認します。

予約の削除は `ownerExportId` と同じ規則で、**その `exportId` が所有する予約だけ**を対象とします（6.2）。

**予約はコミットより先に作られます。** 認可トランザクション（手順 −2）で予約を作り、その後に手順 0 で `Prepared` を保存します。順序がこの向きである以上、`Prepared` の保存に失敗した場合の補償が必要です。

孤児予約の回収を起動時に行うのは、予約を作った直後にプロセスが落ちた場合に、クレジットが永久に占有されるのを防ぐためです。回収は復旧完了ゲート（7.4.3 の起動順序）の一部として、**新規認可を許可する前に**完了させます。

**`trialIntegrityLocked` を導出に含めます。** 台帳を修復すると `trialEntries` が空になるため、フラグを見なければ表示上 5 枚すべてが復活します。残数 0 のときは、一括トライアル画面への進入・写真選択・認可のすべてを禁止します（6.2.5）。

残数と台帳の両方を保存すると、更新途中の異常終了で不一致が起こりえます。「残 3 枚なのに台帳は 4 件」という状態からは、どちらが正しいか判断できません。導出にすれば正が 1 つになります。

付与数（`configuredCreditCount`）はリモート設定で変更できます（11.1）。導出にしておけば、5 枚から増減しても挙動が自動的に決まります。残数を保存していると、既存利用者の残数を移行する処理が必要になります。

台帳は `Map<sourceHash, TrialEntry>` として `UsageLedger` 内に保持します（6.2）。新しく追加した写真だけが消費対象になります。

この規則により、5 クレジットは「最大 5 回の書き出し」ではなく **「最大 5 枚を試す権利」** として機能します。

**消費済み台帳に期限は設けません。これは意図した仕様です。** 結果として、最初に選んだ 5 枚については、以後も一括処理を何度でも試せます。

期限を設けない理由は 3 つです。

- 6 枚目以降を処理できるようになるわけではなく、**体験できる範囲は最大 5 枚のまま**である
- 端末内処理のため、繰り返しても限界原価が発生しない
- 「24 時間以内」などの期限を設けると、その境界を利用者へ説明する必要が生じ、試用の導線としては複雑になる

「一度きりの体験」に厳密化したい場合は、消費済み台帳へ有効期限を持たせて同一バッチ内または 24 時間以内に限定する変更が可能です。v1 では採りません。

再インストールでクレジットが戻ることは、無料枠と同じ扱いで許容します（仕様 14.5）。

クレジットは一括処理専用です。単体処理には使えません。

**トライアルで解放するのは「一括処理という操作方式」だけです。** エフェクトやスタンプの利用範囲は、そのときのプラン権限をそのまま維持します。

| 能力 | トライアル中に使えるエフェクト |
| --- | --- |
| （常時） | モザイク、ぼかし、黒塗り、基本スタンプ |
| `canUsePremiumStamps` | 追加スタンプ |
| `canUseCustomStamps` | カスタムスタンプ |

**トライアル中もエフェクトの可否は `ResolvedCapabilities` をそのまま参照します。** 一括処理へ入ったことで能力を書き換えません。

追加スタンプやカスタムスタンプまで一時解放すると、Standard の価値が曖昧になります。トライアルの目的は Pro の中核である一括処理を体験させることであり、他プランの権限を先出しすることではありません。

#### 6.5.7 対応しないこと

顔認識を行わない以上、**複数写真を横断した同一人物の判定はできません**（仕様 16.4）。「全写真で家族だけ残し、他人だけ隠す」は実現できません。

Pro の説明文でこれを誤解させないことを、文言作成時の制約とします。

#### 6.5.8 キューと付随機能

キューの進行状態は仕様 16.6 の 8 種（`waiting` / `analyzing` / `review_required` / `exporting` / `completed` / `failed` / `canceled` / `paused`）とし、状態機械を `domain` に置きます。

**キューの進行状態と、6.5.3 の 2 軸は別物です。** 混同しないよう関係を定義します。

| 概念 | 何を表すか | 変化させるもの |
| --- | --- | --- |
| キューの進行状態 | その写真が処理のどの段階にいるか | 処理の進行 |
| 検出ステータス | `triage` が警告を出したか | 検出のやり直し |
| 確認ステータス | 利用者が確認を終えたか | 利用者の操作 |

キューの `review_required` は独立した真実を持たず、**利用者の確認待ちを表す導出値**です。導出条件は 6.5.3 のモードで異なります。

```kotlin
val requiresUserReview = when (mode) {
    BatchMode.Auto ->
        detectionStatus == ReviewRequired && reviewStatus == Unreviewed
    BatchMode.OneByOne ->
        reviewStatus == Unreviewed
}
```

おまかせ一括では警告のある写真だけが `review_required` になります。1 枚ずつ確認では、`Normal` の写真も確認を待っているため `review_required` になります。確認が済んだ写真は `waiting` へ遷移します。

`review_required` を「警告あり」と定義すると、1 枚ずつ確認で未確認の `Normal` 写真が、利用者の操作を待っているのにキュー上はそう見えない状態になります。

Pro の価値を具体化するため、以下を含めます。

| 機能 | 内容 |
| --- | --- |
| 要確認の抽出 | 一覧を要確認の写真だけに絞り込んで表示する（一覧そのものは 6.5.3 のとおり全写真を対象とする） |
| エラーのみ再試行 | 失敗した写真だけを再投入する |
| 一括設定プリセット | よく使う設定（エフェクト、強度、スタンプ、縦横比、背景処理、メタデータ、画質）を保存して再利用する |
| バッチ履歴 | バッチ単位で履歴に 1 件記録する（7.2.6） |
| 完了サマリ | 処理完了後に成功件数と失敗件数を表示する |

**実行開始後のバッチへの写真追加は v1 では実装しません。** 追加分の検出開始時期、進行中の確認作業との関係、要確認件数の増加、一括設定の適用範囲、50 枚超過時の分割といった論点が増える割に、利用者価値が低いためです。実行開始後はバッチを固定し、追加の写真は新しいバッチとして作成します。利用状況を見てから判断します。

その他の規則は仕様 16.5 / 16.7 / 16.8 に従います。

- 1 バッチ最大 50 枚
- 同時並列処理は初期値 1。写真のみのため最大 2 まで許容可能とするが、実機計測後に判断する
- 一枚の失敗でバッチ全体を停止しない
- アプリ再起動後に未完了キューを復元する
- 元素材へのアクセス権限を失った場合は再選択を求める
- バックグラウンド処理は Android が Foreground Service と明示的な通知、iOS は OS の実行制限に従う

#### 6.5.9 一括設定と個別修正の優先順位

一括設定プリセットを適用したあと、警告のある写真を個別に修正し、さらに共通設定を変更する、という操作順が起こります。このとき個別修正が黙って上書きされる事故を防ぎます。

規則は以下とします。

1. **一括設定は各写真の初期値として適用する**
2. 個別に編集された写真には `hasOverride` を記録する
3. **共通設定を変更しても、`hasOverride` が立った写真は変更しない**
4. 全件を上書きしたい場合のみ、確認を経て「個別設定を含めてすべて上書き」を実行する

確認の文言例を示します。

> 4 枚に個別設定があります。これらも新しい設定で上書きしますか？

`hasOverride` は写真単位のフラグとし、`domain` が管理します。上書きの可否判定を `commonTest` で網羅します。

### 6.6 手動領域とキーフレーム

仕様 8.7 および 10 章の手動修正は、すべて `domain` 側で扱います。ネイティブは手動領域を認識しません。

- 写真では、手動指定領域をそのまま加工対象の `FaceTrack`（`createdManually = true`）として扱います
- 誤検出の削除、領域の移動・拡大縮小、エフェクトの個別変更は、`FaceTrack` と `EffectSetting` の編集に還元されます
- 動画（v2）では、手動指定したフレームを `FaceKeyframe` として保持し、キーフレーム間で中心 X / 中心 Y / 幅 / 高さ / 回転角度を補間します（仕様 10.3）

キーフレーム補間は純粋関数であり、v1 の時点で実装とテストを完了させます。

### 6.7 解約・降格後の既存データの扱い

有料時に作成したデータへの操作を、プラン降格後も一貫した規則で扱います。規則がないと、降格した利用者が過去データを人質に取られたと感じます。

**判定軸は「作成時のプラン」ではなく「現在の設定内容が要求するプラン」です。**

```kotlin
/** 表示用。「Standard が必要です」の文言に使う */
fun requiredPlan(project: Project): Plan

/** 実装上の判定。プラン名ではなく能力で決める */
fun canEdit(project: Project, capabilities: ResolvedCapabilities): Boolean
```

**`requiredPlan` の戻り値で可否を決めません。** 必要プラン名と現在のプラン名を比較する実装になると、`status = pending` が素通りします。可否は `canEdit` が `capabilities.canUsePremiumStamps` / `canUseCustomStamps` を見て決めます。`requiredPlan` は Paywall の文言を組み立てるためだけに使います。

作成時のプランで判定すると、不自然な状態が生まれます。Standard 時代にモザイクだけで作ったプロジェクトが Free では編集できないのに、**同じ元写真を選び直せば Free の機能で同じものを作れる**、という説明のつかない差です。内容が Free の範囲なら、編集を禁じる理由はありません。

| 操作 | Free 範囲のプロジェクト | 有料スタンプを含むプロジェクト |
| --- | --- | --- |
| 閲覧 | 可 | 可 |
| 削除 | 可 | 可 |
| 変更せず再書き出し | 可（6.2 のクォータ判定に従う） | 可（6.2 のクォータ判定に従う） |
| **編集して書き出し** | **可（6.2 のクォータ判定に従う）** | Standard 以上 |
| **Free 版として複製** | — | **可** |

Free 範囲のプロジェクトとは、モザイク・ぼかし・黒塗り・基本スタンプ・手動領域・縦横比・メタデータ設定だけを使っているものです。

**「Free 版として複製」** は、有料スタンプを基本の隠し方へ置き換えた複製を作る操作です。元のプロジェクトは変更しません。これにより、有料スタンプを含む作品でも Free で編集を続ける道が残ります。

**置き換え先は利用者に選ばせます。** 自動でモザイクへ決め打ちすると、意図しない見た目の複製ができます。

- 選択肢はモザイク、ぼかし、黒塗り、基本スタンプの 4 つ
- 選んだ方法を、有料スタンプを使っていた領域へ一括で適用する
- **領域の位置と大きさ、およびその他の出力設定はそのまま引き継ぐ**
- 有料スタンプを使っていない領域は変更しない

バッチ**全体**に対する操作は内容によらず能力で決まります。

| 操作 | 必要な能力 |
| --- | --- |
| バッチ履歴の閲覧 | なし |
| バッチ内の個別写真の閲覧 | なし |
| バッチ全体への設定反映 | `canUseProBatch` |
| バッチ全体の再実行 | `canUseProBatch` |
| エラー写真のみの再試行 | `canUseProBatch` |

**バッチ内の 1 枚を開いて単体プロジェクトとして編集する場合は、`canEdit(project, capabilities)` に従います。** 単体の編集であってバッチ操作ではないためです。内容が Free の範囲なら、Free でも編集して書き出せます。書き出し時の消費は 6.2 の `QuotaPolicy` に従うため、24 時間以内であれば `FreeReexport` も適用されます。

Pro を必要とするのは、バッチという単位に対する操作だけです。

スタンプの新規適用は従来どおりです。

| 操作 | Free | Standard | Pro |
| --- | :---: | :---: | :---: |
| カスタムスタンプの閲覧・並べ替え・削除 | 可 | 可 | 可 |
| 追加スタンプの新規適用（新しい写真へ） | 不可 | 可 | 可 |
| カスタムスタンプの新規適用（新しい写真へ） | 不可 | 可 | 可 |

原則は 4 つです。

- **閲覧と削除は常に可能**とします。利用者が自分のデータを取り出せない、消せない状態を作りません
- **既存の作品をそのまま取り出す権利は残します**
- **有料機能の新規利用にのみ契約が必要**です。Free の機能だけで完結する操作は制限しません
- **データそのものは削除しません**（仕様 12.6）。再契約時にカスタムスタンプと一括設定プリセットをそのまま再利用できます

3 つ目が今回の判定軸です。制限すべきなのは「有料機能を使うこと」であって、「過去に有料プランだったこと」ではありません。

**「変更せず再書き出し」は、アプリ提供の追加スタンプとカスタムスタンプを同一に扱います。** カスタムスタンプは利用者自身の画像である以上、それを使って完成させた作品まで取り出せなくするのは成果物を人質に取る形になります。追加スタンプは提供元が異なりますが、既に完成している作品を再度取り出す操作は有料コンテンツの新規消費にあたりません。規則を分けると「どちらのスタンプを使ったか」で挙動が変わり、説明できなくなります。

「変更せず」の判定は、プロジェクトの設定内容のハッシュを保存し、再書き出し時に一致するかで行います。**有料スタンプを含むプロジェクト**において、エフェクト・強度・領域・出力設定のいずれかを変更した時点で Standard 以上が必要になります。Free 範囲のプロジェクトではこの判定を行いません。

**Free で書き出す場合は、内容にかかわらず 6.2 の `QuotaPolicy` に従います。** 新規の書き出しでは月間枠を 1 枚消費し、同じ元写真を初回成功から 24 時間以内に再書き出す場合は追加消費しません（`FreeReexport`）。

降格したという事実は、クォータ判定に影響しません。判定に使うのは `sourceHash` と経過時間だけです。

**「閲覧」と「変更」を分けます。** Free でも編集画面を開いて内容を確認できます。有料スタンプを含むプロジェクトで**変更操作を行おうとした時点**で、2 つの選択肢を提示します。

> このプロジェクトはそのまま書き出せます。編集するには Standard が必要です。
> 有料スタンプを基本のかくし方へ置き換えた複製を作れば、いまのまま編集できます。

なお写真ライブラリへ保存済みの過去の出力は、アプリの契約状態に一切影響されません。

契約期間の終了時に未完了のバッチが残っている場合は、キューを `paused` にし、Pro の契約が終了したため続行できない旨を表示します。完了済みの写真と履歴は保持します。

---

## 7. データモデルと永続化

### 7.1 Room KMP

仕様 19 章のテーブルを採用し、`Batch` を追加します。

| テーブル | 備考 |
| --- | --- |
| `Project` | 仕様 19.1 |
| `FaceTrack` | 仕様 19.2 |
| `FaceKeyframe` | 仕様 19.3。v2 で使用 |
| `EffectSetting` | 仕様 19.4 |
| `ExportSetting` | 仕様 19.5 |
| `CustomStamp` | 仕様 19.6。スタンプ一覧の項目（8.4） |
| `StampAsset` | 新規。プロジェクトが参照する不変の画像実体。内容ハッシュを主キーとし参照カウントを持つ（8.4） |
| `ExportRecord` | 仕様 19.7。`batchId` を追加 |
| `OutputRecord` | 新規。写真ごとの出力状態。`exportId` でコミットと対応づける。実体はパスではなく `outputFileId` で参照し、`outputByteSize` と `outputSha256` を持つ（7.4.3） |
| `ExportCommit` | 新規。書き出しのコミットジャーナル。行に HMAC を付ける（7.4.3） |
| `Batch` | 新規。バッチ単位の履歴（7.2.6） |
| `PendingFileDeletion` | 新規。参照 0 になった実体の削除候補。Room コミット後に削除し、失敗は起動時 GC で再試行（8.4.1） |
| `BatchPreset` | 新規。一括設定プリセット（6.5.8） |

以下は DB ではなく **`ProtectedBlobStore`** へ保存します。改ざんで権限や枠を書き換えられないようにするためです（6.2.5 の HMAC 署名つき）。

**鍵の保管とデータの保管を分けます。** Android Keystore が保持できるのは暗号鍵であり、任意のデータを置くストレージではありません。iOS の Keychain も、台帳のような可変データを繰り返し置き換える用途には向きません。

| 役割 | 契約 | iOS | Android |
| --- | --- | --- | --- |
| 鍵 | `CryptoKeyStore` | Keychain | Android Keystore（エクスポート不可） |
| 署名済みデータ本体 | `ProtectedBlobStore` | アプリ専用ディレクトリ上のファイル（原子的置換） | Proto DataStore |

いずれも原子的な置き換えができることを要件とします。台帳は 1 つのオブジェクトとして丸ごと差し替えるため、部分更新の途中状態が観測されてはいけません（6.2）。

- `SubscriptionState`（6.3 の `Entitlement` キャッシュ）。読み込み失敗時の扱いは 6.3 に定義する
- `UsageLedger`（6.2）。通常クォータ・grant・トライアル台帳・基準時刻を1つの署名済みオブジェクトとして原子的に置き換える。残クレジットは保存せず台帳から導出する

いずれも読み込み結果は `ProtectedLoadResult`（6.2.5）で返し、**未存在・改ざん・一時障害・スキーマ不一致を区別します。** これらを 1 つの失敗にまとめると、初回起動の利用者を封鎖したり、一時障害のたびに正常な状態を上書きしたりします。

### 7.2 履歴とプライバシー

プライバシー保護を目的とするアプリが、アプリ内部に未加工の顔画像を蓄積することは避けます。

#### 7.2.1 サムネイル

**履歴のサムネイルには加工後の画像のみを使用します。** 未加工画像をサムネイルとして保存しません。履歴一覧に隠す前の顔が並ぶことがないようにします。

#### 7.2.2 元画像

**アプリ専用領域へ元画像の完全コピーを永続保存しません。** 保持するのは写真ライブラリへの参照と編集設定のみです。処理用のコピーは書き出し完了後に削除します。

これは仕様 18.3 と整合します。元素材が削除された、またはアクセス権限を失った場合、過去の設定情報は表示できますが再編集はできません。

#### 7.2.3 保存期間と容量

**仕様 18.4 の 100 プロジェクト件数上限は採用しません。** Pro は 1 バッチ 50 枚であり、写真 1 枚につき 1 プロジェクトを作る以上、2 バッチで上限に達します。履歴画面でバッチを 1 件に集約しても、内部的に 50 件のプロジェクトを保持する以上この問題は解消しません。

代わりに、保存期間と使用容量で管理します。7.2.2 のとおり元画像のコピーを保持しないため、件数より容量で制御する方が実態に即します。

| 設定 | 選択肢 | 初期値 |
| --- | --- | --- |
| 保存期間 | 履歴を保存しない / 7 日間 / 30 日間 / **保存期限なし** | **30 日間** |
| 履歴の使用容量上限 | — | **200MB** |

**「制限なし」ではなく「保存期限なし」と表記します。** 容量上限は別に存在するため、「制限なし」では容量も無制限だと誤解されます。設定画面に次を併記します。

> 保存期限なしを選んだ場合も、履歴の使用容量上限を超えると古い履歴から削除されます。

容量上限を超えた場合、古いプロジェクトから順に削除します。サムネイルだけを削除して設定を残す中間状態は設けません。状態が増えるだけで利用者の利益になりません。

**「履歴を保存しない」を選んだ場合、本当に保存しません。** 完了画面を離れた時点で、プロジェクト設定、検出結果、サムネイル、加工用の中間ファイルを削除します。内部的な利便性のために残しておくことはしません。プライバシー保護を掲げるアプリが、保存しないと選んだ利用者のデータを保持している状態は許容できないためです。

例外は 4 つです。

- **未受け渡しの出力ファイル**（6.2.2）。利用者がまだ受け取っていない成果物であり、履歴とは性質が異なります。保存・共有・破棄のいずれかで解消します
- **`UsageLedger` の `sourceHash` と初回成功時刻**（6.2）。無料枠の判定に必要な最小限であり、ProtectedBlobStore 側に保持します。画像の内容を復元できる情報を含みません
- **一括処理トライアルの消費済み素材識別値**（6.5.6.1）。5 枚分のトライアル対象を判定するために、`sourceHash` を ProtectedBlobStore へ **期限なく** 保持します。こちらも画像の内容を復元できる情報を含みません
- **未完了の `ExportCommit` と、それが参照する検証済み出力ファイル**（7.4.3）。書き出しの整合性を回復するための運用データであり、コミット完了またはロールバック後に削除します

3 つ目は保持期間が無期限である点が他と異なります。設定画面での個別説明までは要しませんが、**プライバシーポリシーの記載と整合させる必要があります**（16 節の未決事項）。

4 つ目は履歴ではなく、中断した処理の後始末です。放置すると台帳と出力の不整合が残るため、この設定の対象外とします。

この設定では、やり直し（7.2.4）はできません。再度書き出すには設定を作り直すことになります。24 時間以内であれば `UsageLedger` の grant により無料枠は追加消費されませんが、編集内容は復元されません。これは「保存しない」を選んだ帰結として受け入れます。設定画面にその旨を明記します。

#### 7.2.4 やり直しのための保持保証

**履歴を保存する設定では、保存期間の長短にかかわらず直近の作業を 24 時間保持します。**「履歴を保存しない」を選んだ場合は適用しません（7.2.3）。

| 処理 | 保持対象 |
| --- | --- |
| 単体処理 | 直近 1 プロジェクト |
| 一括処理 | 直近 1 バッチと、そのバッチに属する全プロジェクト（最大 50 件） |

一括処理で「直近 1 プロジェクト」だけを保持すると、バッチ内の残り 49 枚が失われ、再編集が成立しません。

この保持の目的は無料枠の再書き出しだけではなく、**編集のやり直し全般**です。Standard と Pro は書き出し無制限ですが、やり直しの必要性は同じであるため、**プランを問わず同一の扱いとします**。期間は仕様 14.3 の無償再書き出しの窓と一致させます。

#### 7.2.5 削除の対象外

期限切れ、容量超過、利用者による削除のいずれの場合も、削除対象はプロジェクト設定、検出結果、サムネイル、一時ファイル、キャッシュです。

**写真ライブラリへ保存済みの加工済み画像は削除されません。** この点を設定画面と削除確認の両方に明示します。

#### 7.2.6 バッチ履歴

一括処理した写真を履歴へ 50 件並べるのではなく、**バッチ単位で 1 件に集約します**。

```
旅行写真 32枚
30枚完了・2枚エラー
```

開くと個別の写真を確認でき、エラーのみの再試行へ遷移できます。

### 7.3 ファイル管理

仕様 20 章に従います。

- 一時ファイル名は UUID ベースとし、元の写真名を使用しない
- アプリ専用領域へ保存する
- 生成済みの出力ファイルは、未受け渡しなら破棄または 24 時間経過まで、受け渡し済みなら完了画面を離れるまで保持する（6.2.2）
- 上記の条件を満たした後、不要な一時ファイルを削除する
- 起動時に 24 時間以上残存する未使用一時ファイルを掃除する

#### 7.3.1 バックアップ対象の範囲

**「アプリ専用領域をバックアップ対象外」と一括で書きません。** その書き方だと、カスタムスタンプをバックアップしない方針が確定したことになりますが、これは 16 節の未決事項です。ディレクトリ単位で指定します。

| ディレクトリ | バックアップ | 根拠 |
| --- | --- | --- |
| 一時処理ファイル | **対象外** | 復元しても意味がない |
| 未受け渡し出力 | **対象外** | 24 時間で消えるもの。端末移行後に復元しても期限切れ |
| ラスタスタンプ一時ファイル | **対象外** | `render` 呼び出し内でのみ有効（5.1.2） |
| `ProtectedBlobStore` | **対象外** | HMAC 鍵と寿命を揃えるため（6.2.5） |
| カスタムスタンプ / `StampAsset` | **16 節で決定するまで未確定** | 利用者が作った資産であり、失われると再作成が必要 |
| Room DB | **データ種別ごとに決定** | 履歴と設定で判断が異なりうる |

除外の指定は iOS が `isExcludedFromBackup`、Android が `data_extraction_rules.xml` です。

**Room DB を一括で決められないのは、テーブルごとに性質が違うためです。** `ExportCommit` は復元しても対応するファイルが無く、`UsageLedger` との整合も失われます（対象外が妥当）。一方で `BatchPreset` や `CustomStamp` は利用者の設定であり、復元されたほうが自然です。v1 の決定は 16 節で行います。

### 7.4 原子的書き出しと受け渡し

書き出しを **出力の生成** と **利用者への受け渡し** の 2 段階に分けます。

仕様 20.3 は 4 段階を定めていますが、その第 4 段階である写真ライブラリ保存は**受け渡しの一手段であって、生成の完了条件ではありません**。保存せず OS 共有だけで完結する経路が成立するためです。生成の完了条件に保存を含めると、6.2.1 の消費確定点と矛盾します。

#### 7.4.1 第 1 段階: 加工済み出力の生成

1. アプリ専用の一時パスへ書き出す
2. サイズと SHA-256 を計算する
3. デコードできることを簡易確認する
4. **検証済み出力（`VerifiedOutput`）としてコミット処理へ渡す**

**第 4 手順は利用者への公開ではありません。** コミット処理への引き渡しです。

いずれかの手順で失敗した場合、コミット処理へ渡さず、クォータも消費しません。

##### 確定点は 1 つだけ

以前の版では「第 4 手順で消費確定」「コミット手順 8 で最終確定」の 2 つが並存していました。これは 2 つの問題を生みます。

- **どちらが確定点か決まらない。** 手順 7 の検証失敗では会計をロールバックできるため、第 4 手順は確定点ではありません
- **公開済みファイルを抱えたままロールバックする時間差が生じる。** 第 4 手順で利用者へ公開すると、その後の手順 7 失敗で会計を戻す間に、利用者がファイルを取得できてしまいます

境界を 1 本にします。

> **検証済みファイルは、コミット手順 8 が完了するまで UI・`MediaSaver`・`SharePresenter` へ公開しません。**
>
> 手順 3 で台帳へ会計を暫定適用し、**手順 8 のコミット行削除で最終確定します。**
>
> 本書における「利用可能な出力の生成が正常に完了した時点」とは、**コミット手順 8 まで完了した時点**を指します。

| 区間 | 性質 |
| --- | --- |
| 手順 8 より前 | 復旧またはロールバックが可能。成果物は非公開 |
| 手順 8 以降 | 成果物を利用者へ公開する。会計は戻さない |

6.2.1 の「消費は利用可能な加工済み出力の生成が正常に完了した時点で確定する」は、この定義のもとで手順 8 を指します。仕様 14.2 の「保存処理または共有可能な状態になった」とも一致します。手順 8 の完了が、まさに保存・共有が可能になる時点だからです。

##### 非公開を構造で保証する

**「公開しない」と文章で書くだけでは防げません。** `OutputRecord` を手順 5 で作ると、Room の監視クエリはその直後から `Generated` を観測できます。UI の購読先が `OutputRecord` である以上、手順 5〜7 の間に画面へ現れます。

`OutputRecord` の作成を**手順 8 へ移し、コミット行の削除と同一の Room トランザクションで実行します。**

```
手順 5〜7:
  OutputRecord はまだ作らない
  ExportCommit と verifiedOutput だけで健全性を確認する

手順 8（単一 Room トランザクション）:
  OutputRecord(Generated) を insert
  ExportCommit を delete
```

これにより不変条件が観測可能な形になります。

| Room の状態 | 意味 |
| --- | --- |
| コミットあり・`OutputRecord` なし | **非公開**（処理中または復旧対象） |
| コミットなし・`OutputRecord` あり | **公開済み**（会計確定済み） |
| 両方あり | **起こらない**（トランザクションが保証する） |

手順 7 の健全性確認が `OutputRecord` ではなく `verifiedOutput` を参照するのは、この順序変更のためです。確認の時点ではまだ `OutputRecord` が存在しません。

#### 7.4.2 第 2 段階: 利用者への受け渡し

- 写真ライブラリへ保存する（`MediaSaver`）
- OS 共有へ渡す（`SharePresenter`）

いずれも任意であり、何度実行しても追加消費しません（6.2.1）。保存または共有に失敗した場合は、生成済み出力を保持したまま再試行できます（6.2.2）。再書き出しは不要です。

##### 共有結果の扱い

「共有シートを開いた」ことは受け渡しの成功ではありません。**どの結果で `Delivered` へ遷移するかを明示します。**

```kotlin
interface SharePresenter {
    suspend fun share(file: OutputFile): ShareResult
}

enum class ShareResult { Completed, Canceled, Unknown, Failed }
```

| 結果 | 出力状態 | 扱い |
| --- | --- | --- |
| `Completed` | `Generated` → **`Delivered`** | 受け渡し成功 |
| `Canceled` | `Generated` を維持 | 利用者が取りやめた |
| `Failed` | `Generated` を維持 | 再試行できる |
| `Unknown` | **`Generated` を維持** | 安全側へ倒す |

`Unknown` は、共有先アプリが完了を返さない場合に生じます。ここで `Delivered` にすると、実際には渡っていない写真を「保存済み」として一時ファイルを消しかねません。**受け取れていない可能性がある側へ倒します。**

**何を `Completed` とするかは、実装計画で OS ごとに先に定義します。** 契約テストは決定手段ではなく、決めた契約を検証する手段です。テストで挙動を突き合わせてから決めると、そのときの実装が仕様になってしまいます。

実装計画で定義する内容は次のとおりです。

| OS | 定義すべきこと |
| --- | --- |
| iOS | `UIActivityViewController.completionWithItemsHandler` の `completed` / `activityError` / 選択された `activityType` を、4 つの結果へどう写像するか |
| Android | `Intent.ACTION_SEND` の結果（`RESULT_OK` / `RESULT_CANCELED` / 結果を返さない共有先）を、4 つの結果へどう写像するか |

そのうえで契約テストが、定義どおりに写像されることを両 OS で検証します。

#### 7.4.3 コミットジャーナル

書き出しの完了で確定する事柄は、**保存先が 3 つに分かれています。**

| 更新対象 | 保存先 |
| --- | --- |
| 完成済みファイルの公開 | ファイルシステム |
| `OutputRecord` = `Generated` | Room |
| Free 枠の消費、`ExportGrant` の作成 | ProtectedBlobStore |
| 一括トライアル台帳への `sourceHash` 追加 | ProtectedBlobStore |

**単一トランザクションで更新できません。** 異常終了の位置によって次が起こります。

- 出力だけ残り、枠もトライアルも消費されない
- 枠だけ消費され、`OutputRecord` も出力ファイルも残らない
- 通常クォータは更新されたが、トライアル台帳は更新されない

2 つ目は 6.2.2 が守ろうとしている「消費したのに成果物を受け取れない」そのものです。「出力があるなら消費済み」「消費したなら出力を受け取れる」という不変条件が壊れます。

**永続的なコミットジャーナルを置きます。**

```kotlin
data class ExportCommit(
    val exportId: String,
    val projectId: String,
    val batchId: String?,
    val sourceHash: String,
    val outputFileId: String,                 // パスではなく ID。専用ディレクトリ配下で解決する
    val authorization: ExportAuthorization,   // 開始前に固定する
    val verifiedOutput: VerifiedOutput?,      // Prepared では null。FileVerified 以降は必須
    val finalizedAt: Instant?,                // 最終確定処理の effectiveNow
    val finalizedPeriod: YearMonth?,          // 計上先の年月。finalizedAt から導出
    val intent: AccountingIntent?,            // Prepared では null
    val applied: AccountingApplied?,          // 台帳へ適用したあとに埋まる
    val state: ExportCommitState,
    val signature: ByteArray,                 // Keychain / Keystore の鍵による HMAC
)

/** 手順1の検証結果。これ自体も HMAC の対象に含める */
data class VerifiedOutput(
    val byteSize: Long,
    val sha256: ByteArray,
)

/** grant の操作。ensure と preserve を型で分ける */
sealed interface GrantAction {
    /** 有効な grant がなければ firstSuccessAt で新規作成してよい */
    data class Ensure(
        val sourceHash: String,
        val firstSuccessAt: Instant,
    ) : GrantAction

    /** 認可時の grant を維持するだけ。新規作成は禁止 */
    data class PreserveAuthorized(
        val sourceHash: String,
        val firstSuccessAt: Instant,
    ) : GrantAction
}

/** 台帳へ適用しようとする内容。時刻は finalizedAt から導出する */
data class AccountingIntent(
    val consumeExportId: String?,
    val grantAction: GrantAction,
    val trialSourceHashToEnsure: String?,
)

/** 台帳へ実際に適用された結果。AccountingCommitted で確定する */
data class AccountingApplied(
    val consumedInserted: Boolean,
    val grantInsertedByThisExport: Boolean,
    val trialInsertedByThisExport: Boolean,
)

enum class ExportCommitState {
    Prepared,
    FileVerified,          // finalizedAt はまだ null
    Finalizing,            // finalizedAt を確定した。台帳へ適用する直前
    AccountingCommitted,
    ReadyToPublish,        // 手順8の直前。まだ非公開
}
```

**`Completed` から `ReadyToPublish` へ改名します。** この状態では成果物がまだ非公開で、コミット行も残っています。「完了」という名前は実態と合いません。

**「適用しようとする内容」と「実際に適用された結果」を分けます。** 台帳を更新する前に「実際に新規追加した値」を確定することはできません。前者は `FileVerified` で、後者は `AccountingCommitted` で埋まります。

ただし `AccountingApplied` を Room へ書く前に落ちる可能性があるため、**これだけを根拠にロールバックできません。** 台帳側の `ownerExportId`（6.2）が最終的な判断材料です。

###### grant の操作を型で分ける

**`grantToEnsure` という単一フィールドでは preserve を表現できません。** どの勘定でも「新規作成してよい」という指示になり、後段の文章だけで例外を設けることになります。通常処理と起動時復旧が同じ `AccountingIntent` を読む以上、復旧側の実装が ensure してしまう経路が残ります。

`GrantAction` として型で分けます。

| 勘定 | `grantAction` |
| --- | --- |
| `PaidUnlimited` / `FreeMonthlyConsume` / `BatchTrial(true)` / `BatchTrial(false)` | `Ensure(sourceHash, finalizedAt)` |
| `FreeMonthlyReexport` | `PreserveAuthorized(sourceHash, authorization.authorizedGrant.firstSuccessAt)` |

`PreserveAuthorized` の適用規則です。

- 同じ `firstSuccessAt` の grant がまだ存在する → **変更しない**
- 期限切れとして既に削除されている → **再追加しない**
- 別の `firstSuccessAt` へ差し替えない
- `finalizedAt` を使った新規作成を**禁止する**

型で分けたことにより、通常処理と起動時復旧が同じコードパスを通っても 24 時間窓を延長できません。文章上の特例ではなく、`when` の網羅で強制されます。

###### 検証結果をジャーナルへ持つ

**`FileVerified` で落ちた場合、`OutputRecord` はまだ存在しません**（作られるのは会計反映後の手順 5）。検証済みファイルと同じ内容かを起動時に確認する材料が、コミット側になければ復旧できません。

`verifiedOutput` を `ExportCommit` へ持たせます。

| 状態 | `verifiedOutput` |
| --- | --- |
| `Prepared` | `null` |
| `FileVerified` 以降 | 必須 |

- 復旧時は実体のサイズ・SHA-256・デコードを再確認し、`verifiedOutput` と突き合わせる
- 手順 8 の `OutputRecord` 作成時は、`verifiedOutput` から値をコピーする（再計算しない）
- `verifiedOutput` は `ExportCommit` の HMAC 対象に含める

再計算ではなくコピーにするのは、手順 1 と手順 8 の間にファイルが差し替えられた場合に検出するためです。再計算した値を記録すると、差し替え後の内容を「正しい記録値」として固定してしまいます。

###### 時刻はすべて最終確定処理から導出する

**会計時刻を `FileVerified` で確定すると、成功時点と食い違います。**

7 月 31 日に `FileVerified` となり、8 月 1 日に復旧して公開された場合を考えます。

- 利用者が成果物を受け取れるのは 8 月
- 消費は 7 月扱い
- grant の 24 時間は 7 月から開始
- `OutputRecord.generatedAt` の基準が不明

**月をまたぐ場合だけの問題ではありません。** 2 時間後の復旧でも、grant の窓と出力の期限が 2 時間ずれます。「月跨ぎのときだけ再適用する」という規則では不十分です。

そこで **`FileVerified` では `finalizedAt` を確定しません。** 最終確定を試みる直前に `Finalizing` 状態を保存し、そこで初めて時刻を決めます。

```kotlin
data class ExportCommit(
    // ...
    val finalizedAt: Instant?,           // Finalizing 以降で必須。FileVerified では null
    val finalizedPeriod: YearMonth?,     // finalizedAt から導出
    // ...
)
```

| 値 | 導出元 |
| --- | --- |
| `finalizedAt` | **`Finalizing` を保存する時点**の `effectiveNow` |
| `finalizedPeriod` | `finalizedAt` の年月 |
| grant の `firstSuccessAt` | `finalizedAt`（`Ensure` の場合） |
| `OutputRecord.generatedAt` | `finalizedAt` |
| `OutputRecord.expiresAt` | `finalizedAt + 24h` |

最終確定の手順は次のとおりです。

1. 新しい `finalizedAt` を決め、`ExportCommit(Finalizing)` を保存する
2. **以前の暫定会計があれば冪等に取り消し**、新しい `finalizedAt` で再適用する
3. `ExportCommit(AccountingCommitted)` を保存する
4. ファイルを再検証する
5. `ExportCommit(ReadyToPublish)` を保存する
6. Room の最終トランザクションを実行する

**異常終了後は、月をまたいだかどうかにかかわらず、手順 1 からやり直します。** 新しい `finalizedAt` を決め直すため、経過時間の長短で分岐しません。`Finalizing` 以降で中断した場合も同じです。既に適用済みの会計要素は `ownerExportId` で識別して取り消せます（6.2）。

これにより「利用者が受け取った時刻」と「消費を計上した時刻」が必ず一致します。

**以前の版にあった「過去月の `consumeExportId` を現在月へ加算しない」という規則は削除します。** 成功時点が最終確定である以上、過去月の消費という状態自体が発生しません。

`authorization` は開始時に固定したままです（権限の固定と会計時刻の確定は別の話です）。長時間の中断後に復旧しても、**権限は開始時のもの、時刻は確定時のもの**を使います。

##### 書き出し開始前に権限を固定する

**`Blocked` になりうる評価を、生成が終わったあとに行いません。**

```kotlin
data class AuthorizedGrant(
    val sourceHash: String,
    val firstSuccessAt: Instant,        // 認可時に有効だった grant の開始時刻
)

data class ExportAuthorization(
    val entitlementSnapshot: Entitlement,
    val accountingMode: ExportAccountingMode,
    val authorizedAt: Instant,
    val authorizedGrant: AuthorizedGrant?,   // FreeMonthlyReexport のとき必須
)

/** どの勘定を使う書き出しか。Blocked は含めない */
sealed interface ExportAccountingMode {
    data object PaidUnlimited : ExportAccountingMode         // Standard / Pro の通常書き出し
    data object FreeMonthlyConsume : ExportAccountingMode    // Free の単体処理。月間枠を1消費
    data object FreeMonthlyReexport : ExportAccountingMode   // 24時間以内の再書き出し
    data class BatchTrial(val consumesTrialCredit: Boolean) : ExportAccountingMode
}
```

書き出し開始時点で利用権限と勘定を確定し、その書き出しについて固定します。`Blocked` なら `ExportCommit` を作らず、生成も開始しません。型に `Blocked` を含めないことで、検証済みファイルを抱えたまま上限超過で破棄する経路を**表現できなくします**。

**勘定を用途で分けます。** 単一の `QuotaDecision` だと、Free 利用者の一括トライアルが月間枠を消費したり、月間枠を使い切っているだけで `Blocked` になったりします。6.5.6 の「トライアルは月間枠とは別勘定」と矛盾します。

| 勘定 | 月間枠 | トライアル台帳 | grant |
| --- | --- | --- | --- |
| `PaidUnlimited` | 使わない | 使わない | ensure |
| `FreeMonthlyConsume` | **1 消費** | 使わない | ensure |
| `FreeMonthlyReexport` | 使わない | 使わない | **preserve** |
| `BatchTrial(true)` | **使わない** | **1 消費** | ensure |
| `BatchTrial(false)` | 使わない | 使わない | ensure |

**月間クォータを使うのは Free の単体処理だけです。** Free / Standard の一括トライアルは月間枠を参照しません。したがって **Free 利用者が月 5 枚を使い切っていても、クレジットが残っていれば一括トライアルを実行できます。**

###### ensure — 新しい窓を作ってよい勘定

`PaidUnlimited` / `FreeMonthlyConsume` / `BatchTrial(true)` / `BatchTrial(false)` に適用します。

> 正常生成時に有効な grant が存在すれば、既存の `firstSuccessAt` を維持する。存在しなければ、`finalizedAt` を `firstSuccessAt` とする新しい grant を作る。

`BatchTrial(false)` が意味するのは「その写真のトライアルクレジットを**過去に**消費済み」であって、「いま有効な 24 時間 grant が存在する」ではありません。1 週間前にトライアルした写真を再処理する場合、クレジットは消費しませんが、**新しい正常生成として grant は作る必要があります**。両者を混同すると、再処理直後の再書き出しが有料になります。

###### preserve — 窓を延長してはならない勘定

`FreeMonthlyReexport` に適用します。**この勘定に ensure を適用してはいけません。** 認可と会計の間に時間差があるため、次が成立してしまいます。

1. 初回成功から 23 時間 59 分の時点で再書き出しを開始する
2. 認可時点では有効な grant があるので `FreeMonthlyReexport`
3. 生成中に 24 時間を超える
4. 会計時点では旧 grant が期限切れ
5. ensure により `finalizedAt` を起点とする**新しい grant** ができる

これは「再書き出しのたびに窓を延ばさない」という 6.2.0 の規則に反します。無料の再書き出しを繰り返すだけで、窓を無期限に更新できてしまいます。

規則は次のとおりです。

> 認可時に保存した `authorizedGrant.firstSuccessAt` をそのまま維持する。会計時点で新しい `firstSuccessAt` を作らない。

会計時点で認可時の grant が既に期限切れになっていた場合は、**再登録せずそのまま落とします。** 無料で開始したその 1 回は完了させますが、次回の再書き出し権は与えません。認可を握っている以上、生成済みファイルを破棄する必要はありません。

開始後に次が起きても、その書き出しは開始時の権限で完了させます。

- 有料契約が失効した
- 月間上限へ達した
- リモート設定で上限が下がった

**認可の粒度は写真ごとの `exportId` です。** バッチ単位ではありません。この粒度により、6.7 の「契約終了時に未完了バッチを `paused` にする」と両立します。

| Pro 失効時点の状態 | 扱い |
| --- | --- |
| `Prepared` 以降へ進んでいる写真 | 開始時の認可で**完了させる** |
| まだ認可されていない `waiting` の写真 | 開始しない。バッチを `paused` にする |

処理中の 1 枚は最後まで終わり、残りは停止します。

**月間枠の対象となる単体書き出しは同時に 1 件までとします。** 「クォータを消費する書き出し」を条件にできない理由は開始ゲートの項で述べます。消費するかどうかは認可の結果であり、ゲートを取る時点では未確定です。並列に走らせると、開始時の判定が両方 `Consume` になり上限を超えます。

##### 会計内容はファイル検証後に確定する

**`Prepared` では `intent` を `null` にします。** 生成中に月や 24 時間期限をまたぐこと、アプリが長時間バックグラウンドへ入ることがあるためです。

| 状態 | 会計フィールド |
| --- | --- |
| `Prepared` | `finalizedAt` / `finalizedPeriod` / `intent` / `applied` はすべて `null` |
| `FileVerified` | `finalizedAt` / `finalizedPeriod` / `intent` が必須。検証完了時点の `effectiveNow` と最新の `UsageLedger` から確定する |
| `AccountingCommitted` 以降 | `applied` も必須 |

`accountingMode` は `authorization` に固定されているため、ここで再評価するのは**計上先の年月と grant の時刻だけ**です。

**中断して後日復旧した場合は、`finalizedAt` を復旧時点の `effectiveNow` で置き直します。** `FileVerified` で一度確定した値をそのまま使いません。7 月 31 日に検証を終えて 8 月に復旧した場合、成果物を受け取るのは 8 月であり、消費もそこへ計上します。既に暫定適用していた会計要素は冪等に取り消してから再適用します（前掲「時刻はすべて最終確定処理から導出する」）。

##### 台帳更新は直列化する

```kotlin
data class LedgerTransaction<R>(
    val ledger: UsageLedger,
    val result: R,
)

interface UsageLedgerStore {
    suspend fun <R> transact(transform: (UsageLedger) -> LedgerTransaction<R>): R
}
```

オブジェクトの置換が原子的でも、**並列処理が同じ旧台帳を読んで別々に書き戻せば、一方の更新が失われます。** 読み取り・変更・署名・保存を単一の更新口へ通し、Mutex または単一 actor で排他します。

**更新後の台帳だけを返す API では足りません。** 同じ排他区間の中で次も取り出す必要があります。台帳を外側で読んで結果を計算してから `update` すると、競合が再発します。

- 認可時の `ExportAccountingMode`
- 会計時の `AccountingApplied`
- 正規化後の `effectiveNow`
- 月次更新後の `period`

一括処理の同時並列数は将来 2 へ増やす設計です（6.5.8）。書き出し処理は並列でも、**台帳のコミットは直列**とします。

##### 同一 `sourceHash` は直列化する

**同じ `sourceHash` の非終端 `ExportCommit` は同時に 1 件だけとします。**

この不変条件がないと、6.2 の所有者方式が壊れます。

1. Export A が grant を作り、`ownerExportId` が A になる
2. 同じ `sourceHash` の Export B も正常完了する。B は既存 grant を使うので所有者にならない
3. A のファイル異常でロールバックし、A 所有の grant を削除する
4. **B は成功しているのに grant が消える**

トライアル台帳でも同じことが起きます。

- 並列処理は異なる `sourceHash` の間だけ許可する
- 同一 `sourceHash` は直列化する。バッチ内に重複があっても同様
- **コミット行の削除またはロールバック完了まで**、その `sourceHash` をロックする

ロックを `ReadyToPublish` で解放してはいけません。その保存後、コミット行の削除前にも復旧対象となる区間が残っています（7.4.3 の手順 6〜8）。ここで解放すると、同じ `sourceHash` の次の処理とロールバックが競合します。

この制約を設けない場合、grant とトライアル台帳が複数の成功 `exportId` を保持する必要があり、モデルが複雑になります。v1 では直列化を選びます。

##### 開始ゲート

**「同時 1 件」という規則だけでは競合を防げません。** 認可を通ってから `Prepared` を書くまでの間に、別の書き出しが同じ認可を通過できます。認可の**前**にゲートを取ります。

```kotlin
interface ExportStartGate {
    suspend fun <R> withPermit(
        sourceHash: String,
        requiresMeteredSingleExportGate: Boolean,
        block: suspend () -> R,
    ): R
}
```

**ゲートの引数を「月間枠を消費するか」にはできません。** その書き出しが `FreeMonthlyConsume` / `FreeMonthlyReexport` / `Blocked` のどれになるかは、後続の `UsageLedgerStore.transact` で初めて決まります。認可の前にゲートを取る以上、その時点で判明していない値を引数にはできません。

代わりに、**月間枠の対象となる単体書き出しであること**を条件にゲートを取ります。これは解決済み能力と処理種別だけで決まるため、認可前に判定できます。

```kotlin
val requiresMeteredSingleExportGate =
    capabilities.singleExportAccess == SingleExportAccess.Metered && !isBatchExport
```

**`Plan` からは判定しません。** `plan = Standard` かつ `status = pending` の利用者はゲートを取る必要がありますが、プランだけを見ると素通りします（6.2 の `SingleExportAccess`）。

| 条件 | ゲート |
| --- | --- |
| `sourceHash` 単位 | 常に取得する |
| `requiresMeteredSingleExportGate == true` | 月間認可ゲートも取得する |
| 一括トライアル、`singleExportAccess == Unlimited` | 月間認可ゲートは取得しない |

開始の順序は次のとおりです。

1. 復旧完了ゲートを確認する（7.4.3 の起動順序）
2. `sourceHash` 単位のゲートを取得する
3. `requiresMeteredSingleExportGate` なら月間認可ゲートも取得する
4. **その内側で** `UsageLedgerStore.transact` を実行し、`Consume` / `Reexport` / `Blocked` を決める
5. `Blocked` なら生成せずに終える。ゲートは解放する
6. `ExportCommit(Prepared)` を保存する
7. 処理を開始する

**ゲートは認可の完了では解放しません。コミット行の削除またはロールバックの完了まで保持します。** Free の単体書き出しが失敗した場合も、その処理が完全に終わるまで次を開始しません。ロールバックの途中で次の認可が走ると、戻す前の台帳を根拠に判定してしまいます。

これにより、2 件が同じ未更新の台帳を見て両方 `Consume` として認可される経路がなくなります。

`OutputRecord` にも `exportId` を持たせ、どのコミットに対応するかを一意にします。

```kotlin
data class OutputRecord(
    val exportId: String,
    val projectId: String,
    val batchId: String?,
    val outputFileId: String,      // パスではなく ID。専用ディレクトリ配下で解決する
    val outputByteSize: Long,      // verifiedOutput からコピー
    val outputSha256: ByteArray,   // verifiedOutput からコピー
    val state: OutputState,
    val generatedAt: Instant,      // ExportCommit.finalizedAt からコピー
    val expiresAt: Instant,        // finalizedAt + 24.hours
)
```

**時刻も `finalizedAt` から導出します。** `OutputRecord` は手順 8 で作られるため、その時点の `finalizedAt` をコピーすれば、公開時刻・消費計上月・24 時間期限の起点がすべて一致します。

**アルゴリズムを名前で固定します。** `outputDigest` のような抽象名にすると、iOS と Android で別のアルゴリズムを選ぶ余地が残ります。両 OS で同じ値を突き合わせる用途なので、SHA-256 に固定します。

**サイズも記録します。** ダイジェストだけでは、手順 7 の「サイズが記録値と一致する」を判定できません。サイズ比較はダイジェスト計算より安く、途中書き込みを先に弾けます。

**パスを DB へ直接持ちません。** `outputFileId` から専用ディレクトリ配下のパスを解決します。パス文字列を保存すると、DB を書き換えるだけで `../` を含む値を注入でき、期限切れ削除の処理に別のアプリ内部ファイルを消させる経路ができます。ID からの解決なら、削除対象が構造的に専用ディレクトリの外へ出ません。

**期限を `OutputRecord` 自身が持ちます。** 判定は `effectiveNow >= expiresAt` です（6.2.2.5）。`ExportCommit` は完了後に削除するため、**コミットが消えたあとも単独で期限を判定できる**必要があります。

##### 手順と書き込み順

保存先が Room と ProtectedBlobStore にまたがるため、**書き込み順を固定します。**

| 順 | 操作 | 保存先 |
| --- | --- | --- |
| −2 | `transact` 内で時刻正規化・月次更新・期限切れ grant の整理を**永続化**する。`BatchTrial(true)` なら**同じトランザクション内で**トライアル予約を作る | ProtectedBlobStore |
| −1 | `transact` の結果として `ExportAuthorization` を得る。`Blocked` なら以降へ進まない | — |
| 0 | `ExportCommit(Prepared)` を保存（`intent` / `finalizedAt` は `null`）。**保存に失敗したら補償トランザクションで予約を削除する** | Room |
| 1 | 一時ファイルを生成し、サイズ・SHA-256・デコードを検証して `VerifiedOutput` を得る | ファイルシステム |
| 2 | `verifiedOutput` を確定し `ExportCommit(FileVerified)` を保存（`finalizedAt` はまだ `null`） | Room |
| 3 | `finalizedAt` を決め、`intent` を確定して `ExportCommit(Finalizing)` を保存 | Room |
| 4 | `UsageLedger` を冪等に適用する。**予約を削除して `trialEntries` へ移すのも同じ台帳トランザクション内** | ProtectedBlobStore |
| 5 | `applied` を埋めて `ExportCommit(AccountingCommitted)` を保存 | Room |
| 6 | `verifiedOutput` と出力ファイルの**健全性**を確認し、`ExportCommit(ReadyToPublish)` を保存 | ファイルシステム / Room |
| 7 | （欠番。以前の版で `OutputRecord` を作っていた位置） | — |
| 8 | **単一 Room トランザクション**（下記）。**ここが会計の最終確定境界** | Room |

**手順 8 を省くと、書き出しのたびにコミット行が永久に蓄積します。** ジャーナルは中断からの復旧のためだけに存在するので、役目を終えたら消します。

**トライアル台帳の更新は手順 4 です。手順 8 ではありません。** 手順 8 は Room だけのトランザクションであり、`ProtectedBlobStore` を同時に更新できません。予約から `trialEntries` への移動は、台帳トランザクションの中で行います。

###### 手順 8 の内容

**Room に保存する状態は `OutputRecord` だけではありません。** `ExportRecord` と写真ごとのキュー状態も同じ Room にあります。`OutputRecord` の insert とコミットの delete だけでは、次の不整合が残ります。

- 出力は公開済みだが、キューは `exporting` のまま
- キューは `completed` だが、`ExportRecord` が無い
- 履歴上は失敗だが、成果物は存在する

手順 8 の単一 Room トランザクションへ次をすべて含めます。

| 操作 | 対象 |
| --- | --- |
| `OutputRecord(Generated)` を insert | `OutputRecord` |
| 成功記録を insert | `ExportRecord` |
| 対象キュー項目を `completed` へ更新 | キュー状態 |
| プロジェクトの最終更新時刻を更新 | `Project` |
| `ExportCommit` を delete | `ExportCommit` |

バッチの成功件数・失敗件数は、**キュー項目からの導出値**とします。保存値にする場合は同じトランザクションへ含めますが、v1 では導出を採ります。二重管理を避けるためです。

`ExportRecord`（仕様 19.7）は書き出しの履歴として保持します。`OutputRecord` が「いま手元にある未受け渡し出力」を表すのに対し、`ExportRecord` は「いつ何を書き出したか」の記録で、24 時間で消えません。役割が異なるため両方を残します。

###### 手順 7 の確認内容

**存在確認だけでは不足です。** 0 バイトのファイル、途中まで書かれたファイル、デコードできないファイルも「存在する」ため、その状態でコミット行を削除できてしまいます。削除後は会計を戻すためのジャーナルが失われ、消費だけが残ります。

次のすべてを確認してから削除します。**`OutputRecord` はまだ存在しないため、`verifiedOutput` と突き合わせます。**

| 確認項目 | 目的 |
| --- | --- |
| `outputFileId` から解決したファイルが存在する | 実体がある |
| ファイルサイズが 0 でなく、`verifiedOutput.byteSize` と一致する | 途中書き込みでない |
| SHA-256 が `verifiedOutput.sha256` と一致する | 内容が入れ替わっていない |
| 簡易デコードが成功する | 画像として開ける |

いずれかが不成立なら削除せず、そのコミットをロールバック対象として扱います。この時点ではジャーナルが残っているため、会計を正しく戻せます。

###### ロールバックの手順と順序

**「ロールバック対象として扱う」だけでは実装できません。** 何をどの順序で削除するかを固定します。

| 順 | 操作 | 保存先 |
| --- | --- | --- |
| 1 | `UsageLedgerStore.transact` で、この `exportId` が所有する会計要素（消費・grant・トライアル台帳・**トライアル予約**）を**冪等に**取り消す | ProtectedBlobStore |
| 2 | 台帳の保存が成功したことを確認する | ProtectedBlobStore |
| 3 | `OutputRecord` を削除する（存在する場合のみ。手順 8 未到達なら存在しない） | Room |
| 4 | `outputFileId` のファイルを削除する | ファイルシステム |
| 5 | `ExportCommit` を削除する | Room |
| 6 | `sourceHash` ゲートと月間認可ゲートを解放する | メモリ |

規則は次のとおりです。

- **手順 1 が失敗した場合、2 以降を実行しません。** コミットとファイルを残したまま復旧エラーとします。台帳を戻せていないのにジャーナルを消すと、消費だけが残って根拠が失われます
- **手順 1 の完了後に落ちても、再起動時に同じロールバックを冪等に再実行できます。** 取り消しは集合からの削除であり、二重実行は無害です
- **`ExportCommit` の削除後にのみゲートを解放します。** 解放が早いと、ロールバック途中の台帳を次の認可が読みます（開始ゲートの項）
- 取り消してよいのは、台帳の `ownerExportId` がこの `exportId` と一致する要素だけです（6.2）

###### 状態別のロールバック経路

**コミット行が最終的に消えるまでの経路を、状態ごとに定めます。**

| 状態 | 台帳への適用 | ロールバック経路 |
| --- | --- | --- |
| `Prepared` | トライアル予約のみ（認可時に作る） | 手順 1〜6。予約の取り消しは必要。`OutputRecord` は未作成 |
| `FileVerified` | 予約のみ。`finalizedAt` は未確定 | 手順 1〜6 |
| `Finalizing` | 未適用または適用途中 | 手順 1〜6。`intent` の内容を `ownerExportId` と突き合わせて取り消す |
| `AccountingCommitted` | 適用済み | 手順 1〜6。`applied` ではなく台帳の `ownerExportId` を根拠にする |
| `ReadyToPublish` | 適用済み | 手順 6 の健全性確認に合格すれば手順 8 のトランザクションを実行して完了。不合格なら手順 1〜6 |

`FileVerified` で `applied` を根拠にできない理由は、`AccountingApplied` を Room へ書く前に落ちる可能性があるためです（コミットジャーナルの項）。台帳側の `ownerExportId` が唯一の判断材料です。

###### 会計の最終確定境界

**コミット行の削除をもって会計を最終確定とします。ジャーナルが残っている間だけ、会計をロールバックできます。**

この境界を置く理由は 2 つです。

**1. 消費の確定点が再び曖昧になる**

文書では既に次を定めています。

- 生成完了後の異常終了では消費を戻さない（6.2.1）
- 利用者が破棄しても消費を戻さない（6.2.2.4）
- トライアルは初回の正常生成で消費する（6.5.6.1）

コミット削除まで完了した出力は、正常生成が確定済みです。その後のストレージ障害だけを払い戻し対象にすると、「異常終了では戻さないがストレージ障害では戻す」という区別が必要になり、6.2.1 の確定点が崩れます。

**2. 所有者モデルが破綻する**

`ownerExportId` を根拠にコミット削除後のロールバックを許すと、次が成立します。

1. Export A が grant を作り、所有者が A になる
2. A のコミットを正常に削除する
3. 同じ素材を Export B で正常に再書き出しする
4. B は既存 grant を利用するため、所有者は A のまま
5. 後から A の出力ファイルが失われる
6. `ownerExportId` を根拠に grant を削除する
7. **B も正常成功しているのに grant が消える**

トライアル台帳でも同じです。7.4.3 の非終端コミット直列化は、**非終端の間しか効きません。** A のコミットは既に削除済みなので、B の開始を止められません。

###### コミット削除後にファイルが失われた場合

ジャーナルを消したあとで `OutputRecord` と実体が食い違うことは、外部要因（OS によるキャッシュ削除、ストレージ障害）で起こりえます。**この経路では `UsageLedger` を変更しません。**

| 状況 | 扱い |
| --- | --- |
| 元素材と設定から再生成できる | 同じ `exportId` の復旧として、**追加消費なしで再生成する** |
| 再生成できない（元素材が削除された等） | 出力を復元できない旨を利用者へ通知し、壊れた `OutputRecord` を削除する |
| 月間枠 | **戻さない** |
| grant | **戻さない** |
| トライアルクレジット | **戻さない** |

利用者への文言は次とします。

> この加工済み写真のデータが失われました。元の写真が残っていれば、同じ設定でもう一度作成できます（無料枠は消費しません）。

**手順 3 と 4 を逆にしてはいけません。** 先に `AccountingCommitted` を書くと、台帳が未反映のまま「反映済み」として復旧されます。この順なら 3 と 4 の間で落ちても状態は `FileVerified` のままなので、台帳更新を冪等に再適用できます。

手順 0 で `Prepared` を先に書くのは、**生成中に落ちたときに孤児となる一時ファイルを起動時に特定するため**です。ジャーナルに記録のない一時ファイルは掃除対象になります。

冪等性の鍵は 2 種類です。**クォータ消費は `exportId`、トライアル消費は `sourceHash`。** 前者は同じ書き出しの再実行、後者は同じ写真の再書き出しを弾くもので、目的が異なります。台帳が集合を保持しているため（6.2）、再適用は自然に無害です。

##### 署名の対象と再署名

**`ExportCommit` は状態遷移のたびに内容が変わります。** 初回挿入時の署名を残したまま状態だけ更新すると、正規の更新なのに次回起動で検証失敗になります。共通の形式と規則を定めます。

```kotlin
enum class PayloadType { UsageLedger, SubscriptionState, ExportCommit }

data class SignedPayload(
    val payloadType: PayloadType,
    val schemaVersion: Int,
    val canonicalBytes: ByteArray,
    val signature: ByteArray,
)
```

- HMAC の対象は **`signature` 自身を除く全永続フィールド**
- シリアライズ順序を固定する（正準形）
- **スキーマバージョンを署名対象へ含める**
- **`payloadType` を署名対象へ含める**（下記）
- `ExportCommit` の insert / update の**たびに再署名する**
- `UsageLedgerStore.transact` の保存時にも必ず再署名する
- 検証はバイト列の**定数時間比較**で行う
- マイグレーション時は旧形式で検証してから新形式で再署名する

**`payloadType` を含めないと、種別をまたいだ付け替えを検出できません。** 3 種のデータが同じ鍵で署名されているため、署名だけを見れば有効な `SubscriptionState` の blob を `UsageLedger` の保存先へ置いても検証を通ります。復号ではなく検証しかしていないため、内容の構造が偶然パースできれば通過します。`payloadType` を署名対象に含めるか、用途別に鍵を派生させます（`HKDF` で `payloadType` を info とする等）。v1 は前者を採ります。実装が単純で、鍵の数が増えないためです。

##### HMAC の脅威モデル

**HMAC が防げるのは改変であって、リプレイではありません。** 過去の正しい署名済み台帳をファイルごと保存しておき、枠を使い切ったあとで書き戻す攻撃は、署名が正当なため検出できません。

完全に防ぐにはサーバー照合か、端末外の単調増加カウンタが必要です。仕様 14.5 は不正利用防止のためだけの端末識別子収集を禁じており、サーバー照合は導入しません。

v1 の脅威モデルを明記します。

> **対象とする:** DB の直接編集、値の書き換え、`UsageLedger` / `SubscriptionState` / `ExportCommit` の相互の付け替え。
>
> **対象としない:** ルート化 / Jailbreak 済み端末で、過去の正規 blob を丸ごと復元するリプレイ攻撃。

対象外とする根拠は、この攻撃に必要な手間（rootfs へのアクセスと blob の退避）に対して、得られる利益が「月 5 枚の無料枠」であることです。割に合わない攻撃へコストをかけるより、通常の DB 編集を確実に検出する方が費用対効果が高いと判断します。

`lastObservedAt` の単調性（6.2.2.5）は端末時刻の巻き戻しには有効ですが、台帳ごと差し替えられれば一緒に戻るため、リプレイには効きません。

##### コミット行の改ざん対策

`ExportCommit` は Room にありますが、その内容が ProtectedBlobStore の台帳更新を駆動します。**Room を書き換えれば台帳を任意に操作できてしまう**ため、コミット行にも Keychain / Keystore の鍵で HMAC を付けます（6.2.5 と同じ方式）。

**署名検証に失敗した行を自動破棄しません。** 破棄すると、すでに反映済みの `UsageLedger` だけが残る可能性があります。会計済みかどうかを判断できない以上、**復旧エラーとして扱い**、新規書き出しをブロックしたうえで利用者へ提示します。ファイルも自動削除しません。

##### 復旧エラーの解消

**ブロックしたまま解除手段がないと、破損したコミット 1 件でアプリが永久に書き出し不能になります。** 利用者が抜け出せる操作を用意します。

> 処理情報が破損しているため、この書き出しを復元できません。

選択肢は「もう一度試す」と「破損した処理を破棄して続ける」の 2 つです。

「破棄して続ける」の挙動は次のとおりです。

- **現在の署名済み `UsageLedger` は変更しない**
- クォータやトライアルクレジットを払い戻さない
- 該当の `ExportCommit`、出力ファイル、`OutputRecord` を削除する
- 復旧エラーを解除し、新規書き出しを許可する

払い戻さないため利用者に不利になりえますが、**破損した Room の情報を根拠に権利を増やす方が危険**です。改ざんによる枠の水増しに直結します。アプリが永久に使用不能になる状態も同時に避けられます。

##### 起動時の順序

**復旧を終えるまで、新しい書き出しを開始させません。**

1. 未完了 `ExportCommit` をすべて復旧する
2. 不要な一時ファイルを掃除する
3. 未受け渡し出力を復元する（6.2.2.1）
4. 通常画面を表示する
5. 新しい書き出しを許可する

先に新しい書き出しを許可すると、あとから古いコミットをロールバックした際に、**すでに進んだ現在の台帳まで壊しかねません**。

復旧の内容は状態で決まります。

| 中断位置 | 復旧 |
| --- | --- |
| `Prepared` | 一時ファイルを削除し、トライアル予約を取り消してコミットを破棄する。生成未完了なので消費しない（6.2.1） |
| `FileVerified` | ファイルが健在なら**手順 3 からやり直す**（新しい `finalizedAt` を決める）。失われていればロールバック |
| `Finalizing` | 暫定適用があれば冪等に取り消し、**手順 3 からやり直す**。経過時間の長短で分岐しない |
| `AccountingCommitted` | **出力ファイルを再検証**する（下記）。正常なら暫定適用を取り消し、**手順 3 からやり直す** |
| `ReadyToPublish` | 出力ファイルの**サイズ・SHA-256・デコード**を `verifiedOutput` と照合する。正常なら手順 8 のトランザクションを実行する。不一致ならロールバック |
| 署名検証に失敗 | 復旧エラー。自動破棄しない |

**`Finalizing` 以降からの復旧は、必ず手順 3 へ戻ります。** `finalizedAt` を決め直すためです。月をまたいだかどうかで分岐しません。2 時間の中断でも、grant の窓と出力の期限が 2 時間ずれるためです。

**`ReadyToPublish` だけは手順 3 へ戻らず、そのまま公開へ進みます。** この状態はファイル検証まで完了しており、`finalizedAt` と会計が整合しています。ここで時刻を決め直すと、検証済みの会計を無意味に取り消して再適用することになります。

**`ReadyToPublish` を無条件に削除しません。** 手順 6 と 8 の間で落ちた可能性があり、**コミット行だけが復旧の手がかり**だからです。この時点では `OutputRecord` がまだ無いため、コミットを消すと出力が孤児ファイルになります。

##### `AccountingCommitted` からの復旧

台帳は暫定適用済みなので、**ファイルが失われていれば「消費したのに受け取れない出力」になります。** 先へ進む前に、出力ファイルの存在・整合性・デコードを再確認します。

| 再検証の結果 | 対応 |
| --- | --- |
| 正常 | 暫定適用を取り消し、手順 3 からやり直す（`OutputRecord` は手順 8 で作る） |
| 欠損・破損 | **このコミットが実際に追加した会計要素だけ**を取り消す（ロールバック手順） |
| 取り消し不能 | 復旧エラーとして新規書き出しをブロックする。自動削除しない |

**取り消しの判断材料は台帳側の `ownerExportId` です**（6.2）。`AccountingApplied` は Room へ書く前に落ちうるため、単独では根拠になりません。

```
consumedExportIds に対象 exportId があれば削除
grants[sourceHash].ownerExportId == 対象 exportId なら削除
trialEntries[sourceHash].ownerExportId == 対象 exportId なら削除
trialReservations[sourceHash] == 対象 exportId なら削除
別の exportId が作った要素は削除しない
```

これなら手順 3 と 4 の間で落ちても、**所有者から正しく判別できます**。既存の grant を再利用しただけの書き出しは `ownerExportId` が一致しないため、以前から存在した権利を巻き添えで消しません。

### 7.5 削除候補の選定

7.2.3 の容量上限を超えた場合、削除候補は「お気に入りでない」「編集中でない」「処理キューに含まれない」「7.2.4 の保持保証の対象でない」の全条件を満たすもののうち、更新日時が最も古いものとします。

写真ライブラリへ保存済みの出力ファイルは、明示的な確認なしに削除しません。

### 7.6 メタデータ

撮影日時には **ファイル内の EXIF** と **写真ライブラリの登録日時** の 2 層があります。写真アプリの並び順を決めているのは後者です。

EXIF の撮影日時を一律に削除すると、加工後の写真がすべて当日の撮影として並び、運動会や旅行の写真を一括処理した際に元の時系列が失われます。そこで両者を分離して扱います。

| 設定 | 初期値 | 利用者による変更 |
| --- | --- | --- |
| 位置情報を削除 | ON | 可 |
| 撮影機器情報を削除 | ON | 可 |
| コメント・編集ソフト情報を削除 | ON | 可 |
| EXIF の撮影日時を保持 | ON | 可（OFF にすると日時も削除） |
| **写真ライブラリの登録日時を元画像から引き継ぐ** | **常時 ON** | **不可** |

最後の 1 行が要点です。iOS の `PHAssetCreationRequest.creationDate` と Android MediaStore の `DATE_TAKEN` は保存時に明示指定できるため、**EXIF から日時を消しても、ライブラリ側の日時を引き継げば並び順は保たれます**。

これにより、プライバシーを最優先して EXIF 日時を削除した利用者でも、写真アプリ内の並び順は崩れません。外部へファイルを共有した場合のみ日時が失われます。

画像方向とピクセルサイズは常に保持します。

### 7.7 画面スナップショット対策

履歴サムネイルを加工後にしても、**OS のタスクスイッチャには編集中の未加工画面がそのまま残ります**。プライバシー保護アプリとして最も目につく穴であるため、対策を必須とします。

編集画面がフォアグラウンドから外れる際にプライバシーオーバーレイを表示します（iOS は `sceneWillResignActive`、Android は `onPause`）。

Android の `FLAG_SECURE` による全面禁止は採りません。利用者自身のスクリーンショットまで塞ぐためです。

---

## 8. カスタムスタンプ

Standard および Pro で利用可能とします（仕様 12.4）。

### 8.1 登録できるもの

| 項目 | 仕様 |
| --- | --- |
| 取り込み元 | 写真ライブラリ、およびファイルアプリ（`FilePicker`） |
| 対応形式 | PNG、JPEG、HEIF / HEIC、WebP（Android） |
| 透過 PNG | 透過状態を維持する |
| 非透過画像 | 円形または角丸マスクで切り抜く |
| 自動背景除去 | **v1 では行わない** |
| 名前 | 利用者が設定できる |
| 並べ替え | できる |
| 削除 | できる |

ファイルアプリからの取り込みを含める理由は、透過 PNG を確実に扱うためです。写真ライブラリ経由では透過が失われる経路があります。

自動背景除去を v1 で行わない理由は、iOS には Vision の前景マスク生成があるのに対し Android に等価な標準機能がなく、両 OS で品質差が出るためです（仕様 12.5 とも一致）。

### 8.2 登録上限

**Standard・Pro ともに 100 個で統一します。**

仕様 12.7 は Standard 30 / Pro 100 としていますが、これを変更します。理由は 2 点です。

- v1 の Pro の訴求は一括処理に集約すべきであり、スタンプ数で薄く差をつけると焦点がぼやけます
- 30 個で不足する利用者はほとんどおらず、**差別化として機能しません**。機能しない制限を料金表に載せると Standard を見劣りさせるだけです

上限は将来変更可能な設定値とします。

### 8.3 保存

- 端末内のアプリ専用領域へ保存する
- クラウドへアップロードしない
- 解約後もデータを保持し、再契約時に再利用できる（仕様 12.6）
- 解約後は新規適用を制限する
- 利用者は任意に削除できる

### 8.4 アセットの寿命管理

スタンプ一覧の項目と、プロジェクトが参照する画像実体を **別々に管理します。**

一覧の項目を削除したときに実体まで消えると、そのスタンプを使った過去プロジェクトが再書き出しできなくなり、6.7 が定める「既存の作品をそのまま取り出す権利」が成立しません。

| 概念 | テーブル | 役割 |
| --- | --- | --- |
| スタンプ一覧の項目 | `CustomStamp` | 名前、並び順、サムネイル。新規適用の選択肢 |
| 画像実体 | `StampAsset` | 内容ハッシュを主キーとする不変のコピー。参照カウントを持つ |

規則は以下とします。

- プロジェクトがカスタムスタンプを使用した時点で、その画像を `StampAsset` として複製し、`EffectSetting.stampId` は `StampAsset` を指す
- `StampAsset` は**内容ハッシュで重複排除**する。同じ画像を複数プロジェクトで使っても実体は 1 つ
- `CustomStamp` を削除すると、**新規編集では選択できなくなる**。`StampAsset` は削除しない
- プロジェクトを削除したとき、参照カウントを減らす。**0 になった `StampAsset` を削除する**

削除時の表示例を示します。

> スタンプ一覧から削除します。過去の加工履歴では引き続き使用されます。

アプリ提供の基本スタンプと追加スタンプは、5.1 のとおりベクターとしてコードに持つため実体の消失が起きません。`StampAsset` の対象はカスタムスタンプのみです。

#### 8.4.1 Room とファイルの更新順序

**`StampAsset` は Room の参照カウントとファイル実体にまたがります。** 「参照数が 0 なら削除」だけでは、どちらを先に更新するかが決まりません。

- ファイルを先に消すと、Room トランザクションが失敗したときに**参照中のスタンプを失います**（復旧不能）
- Room を先に更新すると、ファイル削除に失敗したときに**孤児ファイルが残ります**（容量を食うだけ）

**失っても復旧できないほうを避けます。Room を先に更新します。**

###### 作成

| 順 | 操作 |
| --- | --- |
| 1 | 一時ファイルへ書く |
| 2 | 完成ファイルへ **atomic rename** する |
| 3 | Room トランザクションで `StampAsset` を upsert し、参照を追加する |
| 4 | Room が失敗した場合、そのファイルを**孤児として削除対象へ入れる** |

###### 削除

| 順 | 操作 |
| --- | --- |
| 1 | Room トランザクションで参照数を減らす |
| 2 | 0 になった `contentHash` を**削除候補として同じトランザクション内で記録する** |
| 3 | Room のコミット後にファイルを削除する |
| 4 | 削除に失敗した場合、**次回起動時の GC で再試行する** |

削除候補は `PendingFileDeletion` テーブルへ記録します。Room のトランザクションに含めることで、「参照は 0 になったが削除候補の記録が無い」という状態を作りません。

###### 孤児ファイルの GC

`PendingFileDeletion` だけでは、作成の手順 3 で失敗したファイルを回収できません（記録する前に落ちるため）。起動時に、**専用ディレクトリの実体と Room 上の参照一覧を突き合わせ**、どちらにも属さないファイルを削除します。

対象は次のディレクトリです。

- `StampAsset` の実体
- ラスタスタンプ一時ファイル（5.1.2）
- 書き出しの一時ファイル（7.4.3 の手順 0 と同じ扱い）

**履歴削除、`CustomStamp` 削除、容量超過削除も、すべてこの経路を通します。** 削除の入口ごとに別の順序を実装すると、片方だけが孤児を残します。

### 8.5 解像度と保存容量

原画像は写真ライブラリ側に残るため、**スタンプ用途で原寸を保存する必要はありません。**

| 項目 | 仕様 |
| --- | --- |
| 登録時の縮小 | 長辺 1,024px を上限とする |
| 透過 | 縮小後も維持する |
| 保存形式 | 透過を維持できる圧縮形式。プラットフォームごとに最適な形式を `ImageEncoder` が選ぶ |
| 極端に大きなファイル | 登録前に縮小する旨を案内する |

PNG で原寸のまま 100 個保存すると数十 MB から 100MB を超えます。圧縮形式と長辺 1,024px の組み合わせにより、これを大きく下回る規模へ抑えます。

長辺 1,024px は、顔領域が画像の大部分を占める自撮りなどで拡大率が高くなる場合に、輪郭の甘さが出る可能性があります。実機での確認結果によって引き上げる余地を残し、設定値として保持します（16 節）。

そのうえで、利用者が容量を把握し解放できる手段を提供します。

#### 8.5.1 使用容量の内訳

8.4 のとおり、一覧から削除しても過去プロジェクトが参照する `StampAsset` は残ります。したがって使用容量を 1 つの数値で示すと、「すべて削除したのに容量がゼロにならない」という説明できない状態が生まれます。

**内訳を分けて表示します。**

| 表示 | 内容 |
| --- | --- |
| 登録中のマイスタンプ | `CustomStamp` が参照する実体 |
| 過去の加工履歴で使用中 | 一覧から削除済みだが `StampAsset` として保持しているもの |
| 合計 | 上記の和 |

#### 8.5.2 一括削除

一括削除は `CustomStamp` の一覧のみを対象とし、参照中の `StampAsset` は削除しません。

> マイスタンプ一覧からすべて削除します。過去の加工履歴で使用中の画像は、履歴を再現するため保持されます。

履歴で使用中のぶんも消したい場合は、**対象の履歴を削除する必要がある**ことを併記します。参照カウントが 0 になった時点で `StampAsset` も削除されます（8.4）。

**参照中の `StampAsset` を強制削除する機能は提供しません。** 過去の作品が再現できなくなり、6.7 が定める「既存の作品をそのまま取り出す権利」を壊すためです。

---

## 9. エラーとログ

### 9.1 エラー型

仕様 26.1 の 20 コードを `sealed interface AppError` として表現します。各要素は再試行可否、利用者向けメッセージ、診断フィールドを持ちます。

仕様 26.2 の再試行可否は型の上で表現し、実行時判断に委ねません。

### 9.2 ログの型による防御

Logger が自由文字列を受け取らない設計とします。

```kotlin
sealed interface LogEvent {
    val code: String
    val fields: Map<String, LogValue>
}

// LogValue は列挙値・区分値・数値のみ。任意の String を受け付けない
fun log(event: LogEvent)   // log(String) は存在しない
```

これにより、仕様 22.5 が禁じるファイル名、パス、顔座標、EXIF、ユーザー入力文字列が **型として渡せなくなります**。レビューでの目視チェックに依存しません。

顔数や解像度は仕様 22.3 の粗い区分値（顔数は 0 / 1 / 2〜5 / 6 以上など）としてのみ `LogValue` になります。動画長の区分は v2 で追加します。

### 9.3 握りつぶしの禁止

すべての `catch` 箇所で `AppError` へ変換したうえで `log` を通すことを規約とします。`runCatching` の裸使用は lint で禁止します。

### 9.4 クラッシュ解析

Sentry へ送信するのは **クラッシュと未分類例外（`UNKNOWN_ERROR`）のみ** とします。

`AD_LOAD_FAILED`、`STORAGE_INSUFFICIENT`、`SAVE_PERMISSION_DENIED` のような想定内のエラーは Sentry へ送らず、分析イベントの区分値として計測します（`VIDEO_TOO_LONG` など動画由来のコードは v1 では発火しません）。Sentry 無料枠（月 5,000 エラーイベント、ユーザー 1 名、保持 30 日）を超過させないためであり、同時にプライバシー面でも正しい方向です。

スパイク保護とサンプリングを有効化し、不良リリース時の突発的な消費を抑えます。

Sentry KMP SDK はメジャーバージョン前のため、`domain` が定義する `CrashReporter` ポートの背後に配置し、将来の差し替えコストを小さく保ちます。

#### 9.4.1 型付き Logger では防げない経路

**`LogValue` による制約が効くのは、アプリ自身が書くログだけです。** Sentry や診断 SDK は `Logger` を通らずに、次を独自に収集します。

- 例外メッセージ（任意文字列。ファイルパスや URL を含みうる）
- スタックトレース中のファイルパス
- breadcrumbs（SDK が自動記録する画面遷移・ネットワーク・タップ）
- HTTP のリクエスト URL とヘッダ
- UI 階層やセッション記録（有効化した場合）
- SDK が自動付与する端末情報

**`LogValue` の制約はこの経路を含みません。** `CrashReporter` の実装契約として制約を明記します。

| 制約 | 内容 |
| --- | --- |
| 送信前フック | `beforeSend` で**許可フィールドだけを残す**。既定は除去 |
| 例外メッセージ | **任意文字列をそのまま送らない。** 例外の型名と `AppError` のコードへ置き換える |
| パスと URL | ファイルパス、写真ライブラリ ID、URL を除去する |
| 利用者入力 | カスタムスタンプ名などの入力値を送らない |
| 添付 | 画像、添付ファイル、画面キャプチャを**送らない** |
| セッション記録 | UI 階層の収集とセッションリプレイを**有効化しない** |
| breadcrumbs | SDK の自動記録を無効化し、**10 章で列挙済みのイベントだけ**を手動で記録する |

**`/v1/diagnostics` も同じ制約を受けます。** 自由形式の JSON を受け付けず、**型付きの許可フィールドだけ**を受けるスキーマとします。サーバー側でも未知フィールドを拒否します（11.2）。

例外メッセージを型名とコードへ置き換えるのは、メッセージが最も混入しやすい経路だからです。ファイル入出力の例外は、既定でパスを本文に含みます。

---

## 10. 分析

仕様 28.2 のイベント名をそのまま sealed class 化します。

仕様 28.3 の禁止項目（元ファイル名、ファイルパス、写真ライブラリ ID、正確な顔座標、画像ハッシュ、SNS アカウント名、カスタムスタンプ画像、写真・動画の内容、音声内容）について、経路ごとに保証の根拠が異なります。

| 送信経路 | 保証 |
| --- | --- |
| **アプリが明示的に送る分析イベント** | 9.2 の `LogValue` 制約により、禁止データを**型として渡せない** |
| **クラッシュ解析（Sentry）** | 9.4.1 の送信前フィルタと許可リストを**別途適用する** |
| **診断送信（`/v1/diagnostics`）** | 9.4.1 の型付きリクエストモデルと、サーバー側の未知フィールド拒否（11.2） |

**`LogValue` 制約だけでは後 2 者を防げません。** SDK は `Logger` を通らずに例外メッセージやファイルパスを収集します（9.4.1）。

---

## 11. バックエンド

### 11.1 役割の縮小

購入検証、ストア通知の受信、権限管理は RevenueCat が担います。自前サーバーは以下 2 本のみとします。

| エンドポイント | 内容 |
| --- | --- |
| `GET /v1/config` | Free 月間書き出し数、一括処理上限、トライアルクレジット数、トリアージ閾値、履歴の容量上限、カスタムスタンプの保存解像度、有効なスタンプパック、広告表示頻度、最低サポートアプリバージョン、障害中の機能停止フラグ |
| `POST /v1/diagnostics` | ユーザーが明示的に同意した場合のみ受信 |

仕様 21.5 の `POST /v1/installations` は実装しません。匿名インストール ID は RevenueCat の App User ID と兼用します。仕様 21.4 の要件（Keychain / Keystore への保存、広告 ID を利用者 ID として使わない、ハードウェア識別子を収集しない）は満たされます。

`POST /v1/entitlements/apple/verify` と `POST /v1/entitlements/google/verify` は RevenueCat が担うため実装しません。

### 11.2 実装

Rust + Axum。`/v1/config` は静的 JSON と ETag による配信とします。

仕様 21.3 の送信禁止データは、送信経路を持たせないことで担保します。**そのためにリクエストモデルを型で固定します。**

```rust
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]      // 未知フィールドを拒否する
pub struct DiagnosticsRequest {
    pub schema_version: u32,
    pub app_version: String,
    pub os: OsKind,                // 列挙。自由文字列ではない
    pub os_version: String,
    pub error_code: AppErrorCode,  // 列挙（9.1）
    pub occurred_at: i64,          // UTC epoch millis
    pub context: DiagnosticsContext,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticsContext {
    pub face_count_bucket: Option<FaceCountBucket>,   // 区分値（9.2）
    pub resolution_bucket: Option<ResolutionBucket>,
    pub plan_kind: Option<PlanKind>,
    pub retry_count: Option<u32>,
}
```

**`serde(deny_unknown_fields)` を必須とします。** 既定の serde は未知フィールドを黙って捨てるため、クライアント側の不具合で自由文字列が送られても気づけません。拒否すれば、送信側の実装ミスが 400 として即座に露見します。

`String` を許すのは `app_version` と `os_version` だけで、いずれも形式を正規表現で検証します。それ以外の自由文字列フィールドを持たせません。

9.4.1 のクライアント側フィルタと、この型定義の**両方**で防ぎます。片方だけでは、もう片方の実装ミスを吸収できません。

### 11.3 障害時

リモート設定の取得に失敗した場合はアプリ内の安全な既定値を使用します。バックエンド障害で編集処理を停止させません（仕様 21.6）。

---

## 12. テスト戦略

### 12.1 テストの層

**以前の版は三層構成とし、`commonTest` に Room・`ProtectedBlobStore`・ファイル破損・プロセス再起動・HMAC・排他・各書き込み位置での異常終了まで含めていました。これは成立しません。** 純粋な状態機械と、偽ストアを使った Saga テストは `commonTest` で書けますが、**実ストレージの原子性や OS のプロセス強制終了は JVM 上で検証できません。**

四層へ分けます。

| 層 | 実行環境 | 対象 |
| --- | --- | --- |
| **domain unit test** | JVM（数秒） | クォータ、トリアージ、座標変換、`compileRenderDraft`、状態機械 |
| **application saga test** | JVM（数十秒） | 偽 Room・偽 `ProtectedBlobStore`・偽ファイルによる**各中断点**の検証 |
| **adapter integration test** | 実機 / エミュレータ | 実 Room、実 DataStore / 保護ファイル、実 HMAC 鍵、契約テスト |
| **process-death fault injection test** | 実機 / エミュレータ | **各手順の直後に強制終了**し、再起動後の状態を検証 |

**コミットジャーナルは、両 OS の実ストレージを使った障害注入テストを必須とします。** 偽ストアの Saga テストは「順序どおりに書けば整合する」ことしか示しません。Room のトランザクションが実際に原子的か、DataStore の書き込みが電源断で切れないか、`fsync` のタイミングはどうか — これらは実装と OS の性質であり、偽物では検証できません。

各項目は、**検証が成立する最も低い層**へ置きます。以下 12.1.1〜12.1.4 で層ごとに列挙します。対象は仕様 30.1 の全項目に加え、本設計で追加した判定を含みます。

#### 12.1.1 domain unit test（JVM、数秒）

純粋関数と状態機械のみ。ストレージもプロセスも関与しません。

- `QuotaPolicy`（月跨ぎ、TZ 変更、時刻巻き戻し、うるう年、月末 23:59:59 → 00:00:00、24 時間境界）
- `EntitlementResolver`（仕様 27.4 の全購入状態）
- `BatchTriagePolicy`（5 つの要確認理由の各単独・複合、空集合）
- `triage` の入力が 5.7.1 の共通モデルだけであること。OS 固有の値に依存しないこと（6.5.2）
- `ReviewIssue` が**発生単位**で列挙され、小さい顔が 3 人なら 3 件になること（6.5.2）
- `issueId` が `detectionRevision` を含み、`OverlappingFaces` では顔 ID が辞書順に並ぶこと（6.5.2）
- 再検出で `detectionRevision` が増え、その写真の `ReviewIssue` / `ReviewDecision` / `Reviewed` が破棄されること（6.5.2）
- `ReviewDecision` が `issueId` ごとに記録され、全 `ReviewIssue` が埋まるまで `Reviewed` にならないこと（6.5.4）
- 1 人分の `issueId` へ判断を記録しただけでは `Reviewed` にならないこと（6.5.4）
- `ManualRegionAdded` が `regionId` を保持し、その領域の削除で判断が破棄されること（6.5.4）
- `ReviewRequired` かつ `Unreviewed` の写真が 1 枚でも残る間は一括書き出しを開始できないこと（6.5.4）
- `Reviewed` がアプリの判断では立たないこと。検出ステータスが利用者操作で変わらないこと（6.5.3）
- `NoFaceDetected` がグループ一括対応の対象外であること（6.5.4）
- `DetectionStatus` と `ReviewIssue` が利用者の判断で変化しないこと（6.5.4）
- 理由別の一括対応で、その理由の `ReviewIssue` が 1 件も取りこぼされないこと（6.5.4）
- トライアルの選択判定が「総枚数 5 枚」と「新規写真 ≤ 残クレジット」の 2 条件であること。残 0 枚でも消費済みの写真は選べること（6.5.6）
- `canEnterBatch` が `canUseProBatch` / `canUseBatchTrial` / `trialIntegrityLocked` / 残数 / entry の有無から導かれること（6.5）
- `canUseProBatch` / `canUseBatchTrial` が能力で判定され、`plan = Pro` かつ `status = pending` が通常一括にならないこと（6.5）
- 消費済みの写真だけで 6 枚選ぼうとしたとき `batch-size` が発火すること（6.5.6）
- 50 枚超過が `batch-limit` であり、アップグレード誘導を伴わないこと（13.5）
- 1 枚ずつ確認で `Normal` の写真が「確認して次へ」により `Reviewed` になること（6.5.4）
- `canEdit` が能力で判定され、`requiredPlan` の戻り値比較で可否を決めないこと（6.7）
- バッチ内の 1 枚を単体編集するとき `canEdit` に従うこと（6.7）
- `requiredPlan` が設定内容から導かれ、作成時のプランに依存しないこと（6.7）
- `QuotaPolicy` と開始ゲートが `Plan` を参照せず `ResolvedCapabilities` のみを受け取ること（6.2）
- `plan = Standard` かつ `status = pending` で `singleExportAccess == Metered` になること（6.2 / 6.3）
- `CapabilityResolution.VerificationRequired` で書き出し認可が開始されず、Free 降格の表示も出ないこと（6.2）
- キャッシュ `Missing` かつオフラインで `VerificationRequired` になること（6.2 / 6.3）
- 降格後の再書き出しでも `FreeReexport` が成立し、24 時間以内なら消費しないこと（6.7）
- 顔 0 件の案内が `QuotaDecision` で分岐すること（6.1.1）
- 月末の初回成功から 24 時間以内なら、月をまたいでも `FreeReexport` になること（6.2.3）
- `rollPeriod` が `consumed` だけをリセットし、`grants` を月境界で捨てないこと（6.2.3）
- 共有結果が `Completed` のときだけ `Delivered` へ遷移すること。`Unknown` では維持されること（7.4.2）
- 確認段階から設定へ戻っても検出結果が保持されること。この経路で写真の選択を変更できないこと（6.5.3）
- `ExportGrant` が能力を問わず作成されること（6.2.0）
- 同一 `sourceHash` の再書き出しで `firstSuccessAt` が更新されないこと（6.2.0）
- 端末時刻を過去へ戻しても 24 時間の窓が延びないこと。`effectiveNow` が後退しないこと（6.2.2.5）
- `domain` の時間判定が `now` ではなく `effectiveNow` だけを受け取ること（6.2.2.5）
- 未受け渡し出力の削除期限が端末時刻の変更で延びないこと（6.2.2.5）
- `monthlyBlockedPeriod == period` のとき、`consumedExportIds` が空でも `Blocked(LedgerIntegrityFailure)` になること（6.2）
- `trialIntegrityLocked` のとき `remainingCredits` が 0 になり、トライアル画面へ進入できないこと（6.5.6.1）
- `trialReservations` が残数計算に含まれること（6.5.6.1）
- `evaluate` が更新後の `UsageLedger` を返し、`Unlimited` でも時刻更新と grant 整理が行われること（6.2）
- `BatchTrial` が月間枠を消費しないこと（6.5.6）
- 月間枠を使い切っていても、クレジットが残っていれば一括トライアルを開始できること（6.5.6）
- 消費済みトライアル台帳に期限がなく、同じ 5 枚を繰り返し処理できること（6.5.6.1）
- トライアル中のエフェクト利用範囲が、そのときの `ResolvedCapabilities` と一致すること（6.5.6）
- `BatchTrial(false)` でも `GrantAction.Ensure` になること（7.4.3）
- `FreeMonthlyReexport` の `grantAction` が `PreserveAuthorized` になること（7.4.3）
- 背景処理の変更で `Reviewed` が解除されること。メタデータ設定の変更では解除されないこと（6.5.3）
- `review_required` の導出がモードで異なること。1 枚ずつ確認では `Normal` の未確認写真も含むこと（6.5.8）
- 確認状態の解除が変更範囲に限定されること。`hasOverride` の写真が共通設定変更で `Unreviewed` にならないこと（6.5.3）
- `overviewConfirmed` が、匿名化結果または構図に影響する変更で必ず false になること（6.5.3）
- 共通設定の変更が `hasOverride` の立った写真へ波及しないこと。全上書きが確認を経ること（6.5.9）
- 完了画面の離脱確認が `Generated` の残数で判定されること。一部保存済みでも出ること（6.2.2）
- 復旧案内の枚数が `Generated` の枚数であり、バッチ総枚数ではないこと（6.2.2.1）
- 書き出しの成立条件がモードごとに異なること。1 枚ずつ確認では末尾到達と確認ボタンを求めないこと（6.5.3）
- 確認後の変更で確認状態が解除されること（6.5.3）
- 未保存バッチが 1 件までに制限されること（6.2.2.2）
- 一括処理の開始が推定必要容量の 1.2 倍の空き容量を要求すること（6.2.2.2）
- 未保存出力がある状態では、単体・一括を問わず新規加工を開始できないこと（6.2.2.3）
- 破棄しても無料枠とトライアルクレジットが戻らないこと（6.2.2.4）
- Free 範囲のプロジェクトが Free で編集・書き出しできること（6.7）
- 降格後の操作可否が 6.7 の表と一致すること
- 追加スタンプとカスタムスタンプで、降格後の再書き出し可否が同一であること（6.7）
- 顔の初期状態が常に加工対象であること（6.1 の不変条件）
- 拡張率適用、`RenderSpec` 生成、`compileRenderDraft`、座標正規化
- `compileRenderDraft` が `RenderPlan` へ絶対ピクセル値のみを入れ、比率を残さないこと（5.2）
- `bindRasterAssets` が `stampRequests` に対応する asset を 1 件でも欠けば失敗すること（5.2）
- `left`/`top` が floor、`right`/`bottom` が ceil で丸められ、領域が外側へ広がること（5.2.1）
- `RenderRegion.bounds` が出力キャンバス基準へ変換されること（5.2）
- `sourceCrop` の不変条件違反が例外になり、クランプで黙って直されないこと（5.2）
- `Manual` の領域が `Auto` より後の `order` になること（5.2.1）
- `domain` が `StampRasterizer` ポートのみを持ち、Compose Canvas を参照しないこと（5.1.1）
- `StampRasterRequest` に位置・回転・不透明度・形状が含まれないこと（5.1.1）
- `sourceHash` が長さ前置き・ビッグエンディアン・UTC epoch ms で計算されること（6.2.4）
- 64KB 未満のファイルで先頭・末尾チャンクが重複しても正しく計算されること（6.2.4）
- 撮影日時が無い場合に長さ 0 のフィールドとして扱われること（6.2.4）
- 撮影日時の優先順位がライブラリ → EXIF → `null` であること。更新日時を使わないこと（6.2.4）
- `representation` が `sourceHash` の入力に含まれないこと（6.2.4）
- 設定ハッシュが `Map` のキー順・`Float` のビット表現・内容ハッシュ参照で正準化され、DB ID に依存しないこと（6.2.4）
- プロジェクト設定ハッシュの一致判定により、Free の「変更せず再書き出し」が許可されること（6.7）
- キーフレーム補間（v2 機能だが仕様確定のため v1 で実装・テスト。5.5）
- ストレージ必要量計算、`ExportQueue` 状態機械、`AdFrequencyPolicy`
- 履歴の保存期間と容量判定。7.2.4 の保持保証が容量超過時にも守られること
- リモート設定のフォールバック

#### 12.1.2 application saga test（JVM、偽ストア）

偽 Room・偽 `ProtectedBlobStore`・偽ファイルを注入し、**各中断点**での挙動を検証します。実ストレージの原子性は検証しません（12.1.3 の役割）。

- `ExportCommit` が各段階で中断しても、起動時に整合が回復すること（7.4.3）
- `Prepared` / `FileVerified` / `Finalizing` / `AccountingCommitted` / `ReadyToPublish` のいずれからもコミット行が最終的に消えること（7.4.3）
- 復旧が終わるまで新しい書き出しを開始できないこと（7.4.3）
- `ExportCommit` の署名検証失敗が復旧エラーになり、自動破棄されないこと（7.4.3）
- 復旧エラーを「破棄して続ける」で解除でき、台帳が変更されないこと（7.4.3）
- 手順 4 と 5 の間で中断しても、台帳更新を冪等に再適用できること（7.4.3）
- `finalizedAt` が `Finalizing` の保存時点で決まり、`FileVerified` では `null` であること（7.4.3）
- 中断して復旧した場合、月跨ぎの有無にかかわらず新しい `finalizedAt` で再適用されること（7.4.3）
- `generatedAt` / `expiresAt` / grant の起点が `finalizedAt` と一致すること（7.4.3）
- `PreserveAuthorized` を起動時復旧から適用しても、`finalizedAt` で grant が作られないこと（7.4.3）
- 認可時の grant が会計時に期限切れでも、その 1 回は完了し、grant は再登録されないこと（7.4.3）
- `AccountingCommitted` からの復旧でファイル欠損時、実際に追加した会計要素だけが取り消されること（7.4.3）
- 既存 grant を再利用しただけのコミットのロールバックで、その grant が削除されないこと（7.4.3）
- 手順 4 の直後（`applied` 未保存）に落ちても、`ownerExportId` から正しくロールバックできること（7.4.3）
- 書き出し開始前に `Blocked` なら `ExportCommit` を作らないこと（7.4.3）
- 開始後に契約が失効しても、その書き出しは開始時の権限で完了すること（7.4.3）
- 失効時、`Prepared` 以降の写真は完了し `waiting` の写真は開始しないこと（7.4.3）
- 月間枠の対象となる単体書き出しが同時に 1 件までに制限されること（7.4.3）
- 開始ゲートが `requiresMeteredSingleExportGate` で取得され、認可前に決定できること（7.4.3）
- 開始ゲートにより、認可から `Prepared` までの間に同一 `sourceHash` の別書き出しが割り込めないこと（7.4.3）
- 同一 `sourceHash` の非終端コミットが同時に 1 件までに制限されること（7.4.3）
- `sourceHash` のロックがコミット行削除まで保持されること（7.4.3）
- 並列書き出し時も `UsageLedgerStore.transact` が直列化され、更新が失われないこと（7.4.3）
- クォータ消費が `exportId`、トライアル消費が `sourceHash` で冪等であること（7.4.3）
- 検証済みファイルが手順 8 の完了まで UI・`MediaSaver`・`SharePresenter` へ公開されないこと（7.4.1）
- `FileVerified` で落ちた場合、`verifiedOutput` と実体を突き合わせて復旧できること（7.4.3）
- 手順 8 のサイズ・SHA-256 が `verifiedOutput` からのコピーであり、再計算でないこと（7.4.3）
- 0 バイト・破損・SHA 不一致の出力ファイルで `ReadyToPublish` のコミット行が削除されないこと（7.4.3）
- 手順 7 の失敗時、ロールバックが台帳 → `OutputRecord` → ファイル → コミット → ゲートの順で実行されること（7.4.3）
- ロールバック手順 1 が失敗した場合、コミットとファイルが残り復旧エラーになること（7.4.3）
- コミット行削除後にファイルを失っても、月間枠・grant・トライアルが戻らないこと（7.4.3）
- コミット削除済みの Export A のファイル欠損で、同一素材を再書き出しした Export B の grant が消えないこと（7.4.3）
- 生成完了後の異常終了では消費が戻らないこと（6.2.1）
- 残 1 枚で異なる `sourceHash` の 2 件が並行認可されても、両方が `BatchTrial(true)` にならないこと（6.5.6.1）
- 予約が手順 −2 で作られ、手順 4 の台帳トランザクション内で `trialEntries` へ移ること（6.5.6.1）
- 手順 0 の `Prepared` 保存失敗で、補償トランザクションが予約を削除すること（6.5.6.1）
- 同じ `sourceHash` が `trialEntries` と `trialReservations` の両方に存在しないこと（6.5.6.1）
- 同じ `sourceHash` の再書き出しでトライアルクレジットが二重に減らないこと（6.5.6.1）
- トライアルクレジットが成功枚数分だけ減り、失敗と中止では減らないこと（6.5.6）
- `UsageLedger` の署名検証失敗時、修復済み台帳が作られ、翌月に月間枠が再開しトライアルは封じられたままであること（6.2.5）
- 修復済み台帳の `trialReservations` が空であること（6.2.5）
- `Missing` で通常台帳が作られ、初回起動の利用者が封鎖されないこと（6.2.5）
- `TemporarilyUnavailable` で台帳が上書きされず、書き出し開始が保留されること（6.2.5）
- `SubscriptionState` の署名不正時、オフラインで有料権限が新規付与されず、カスタムスタンプと履歴が削除されないこと（6.3）
- `OutputRecord` が `ExportCommit` 削除後も単独で期限判定できること（7.4.3）
- 未受け渡しの出力が破棄または 24 時間経過まで保持されること（6.2.2）
- 受け渡し成功後も完了画面を離れるまで出力が保持され、保存と共有を任意の順序で実行できること（6.2.2）
- 消費確定が手順 8 であり、保存や共有の回数に影響されないこと（6.2.1）
- 異常終了後の起動時、`Generated` では復旧案内が出て、`Delivered` では出ないこと（6.2.2.1）
- 「履歴を保存しない」設定で、未受け渡し出力・`UsageLedger`・未完了 `ExportCommit` の 3 つ以外が残らないこと（7.2.3）
- `CustomStamp` を削除しても、それを使用したプロジェクトが再書き出しできること（8.4）
- `StampAsset` が内容ハッシュで重複排除され、参照カウントが 0 になったときのみ削除されること（8.4）
- 一括削除が `CustomStamp` のみを対象とし、参照中の `StampAsset` を消さないこと（8.5.2）
- 削除で Room が先に更新され、`PendingFileDeletion` が同じトランザクションへ記録されること（8.4.1）
- Free が既存プロジェクトの編集画面を開けること。変更操作の時点で案内が出ること（6.7）

#### 12.1.3 adapter integration test（実機 / エミュレータ）

実 Room、実 DataStore / 保護ファイル、実 HMAC 鍵を使います。

- **契約テスト** — `media` / `data` / `billing` / `ads` の各ポートに共通のテストスイートを 1 本書き、Android instrumented test と iOS の XCTest の**両方で同一スイート**を実行します。「片方の OS だけ挙動が違う」を構造的に防ぎます
- 手順 8 の Room トランザクションが原子的であり、`OutputRecord` / `ExportRecord` / キュー状態 / `Project` の更新とコミット削除が同時に成立すること（7.4.3）
- 「コミットあり・`OutputRecord` なし」または「コミットなし・`OutputRecord` あり」以外の状態が観測されないこと（7.4.1）
- `ExportCommit` が状態遷移のたびに再署名され、正規の更新で検証失敗しないこと（7.4.3）
- `SignedPayload` の署名対象に `payloadType` が含まれ、種別間の付け替えが検出されること（7.4.3）
- 実 Keychain / Keystore の鍵で署名・検証が往復すること。鍵の破棄が `IntegrityFailure` になること（6.2.5）
- `ProtectedBlobStore` のデータと HMAC 鍵がともにバックアップ対象外であり、再インストール後が `Missing` になること（6.2.5 / 7.3.1）
- `OutputRecord` の実体解決が `outputFileId` 経由であり、パス文字列の改変で専用ディレクトリ外を削除できないこと（7.4.3）
- `StampAsset` の作成が atomic rename を経ること（8.4.1）
- 写真ライブラリ登録日時の引き継ぎ（7.6）を、両 OS で保存後に読み戻して検証すること
- `NormalizedRect` の `right` / `bottom` が排他的境界として両 OS で一致すること（5.2.1）
- `rotationDegrees` が時計回り正・領域中心基準として両 OS で一致すること（5.2.1）
- `opacity` がレンダラーで 1 回だけ乗算され、ドメイン側で色へ焼き込まれないこと（5.2.1）
- クリップが回転の後に行われ、キャンバス端の回転領域が露出しないこと（5.2.1）
- 背景処理が顔エフェクトより先に適用されること（5.2.1）
- 重なり時に後のエフェクトが加工済み画像へ作用すること（5.2.1）
- Vision と ML Kit の座標系・角度の差がアダプタで吸収され、`DetectedFace` が一致すること（5.2.1）
- `plan` が参照する `bitmapId` が `rasterAssets` に無い場合、描画を開始せずエラーになること（5.1.2）
- 同一 `StampRasterKey` のラスタライズが 1 回で済み、複数領域から再利用されること（5.1.2）
- `RasterizedStampAsset` の `bitmapId` スコープが `render` 呼び出し内に閉じ、並列レンダリングで衝突しないこと（5.1.2）
- ラスタ一時ファイルの解放が冪等であること。二重解放でエラーにならないこと（5.1.2）
- `CrashReporter` が例外メッセージ・パス・URL を除去し、breadcrumbs を列挙済みイベントに限定すること（9.4.1）
- `/v1/diagnostics` が未知フィールドを拒否すること（9.4.1 / 11.2）
- **ゴールデン画像テスト** — 同じ `RenderSpec` から生成したプレビュー用と原寸用の出力が一致すること。`sourceCrop` / `scaleMode` / `background` を適用した結果が設定と一致すること。仕様 30.4 の条件（強度の最小・最大、顔の回転、領域が画面端、領域の重なり、透明度、4 形状）を素材として固定化します

#### 12.1.4 process-death fault injection test（実機 / エミュレータ）

**各手順の直後にプロセスを強制終了し、再起動後の状態を検証します。** 偽ストアでは検証できない、実ストレージと OS の性質を対象とします。

- 手順 −2 / 0 / 1 / 2 / 3 / 4 / 5 / 6 / 8 の**各直後**で強制終了し、再起動後に整合が回復すること（7.4.3）
- ロールバック手順 1 の完了後に落ちても、再起動時の再実行が冪等であること（7.4.3）
- 予約を作った直後に落ちた場合、孤児予約が起動時に回収され、その完了後に新規認可が許可されること（6.5.6.1）
- `StampAsset` の作成で手順 3 の直前に落ちた場合、孤児ファイルが起動時 GC で回収されること（8.4.1）
- `PendingFileDeletion` の削除に失敗した場合、次回起動時の GC で再試行されること（8.4.1）
- 書き出し一時ファイルとラスタ一時ファイルの孤児が、起動時に回収されること（7.3 / 5.1.2）

### 12.2 検出品質

仕様 30.2 の検出条件（正面、横顔、斜め、部分的な遮蔽、マスク、サングラス、暗所、逆光、遠景、集合写真、子ども、高齢者、異なる肌色、イラストの顔、鏡像、写真内の写真）は、**合否判定ではなく検出率の回帰監視** として計測します。

仕様 34.5 が「完全自動を約束しない」と定めている以上、閾値でビルドを落とすのは不適切です。リリース間で検出率が有意に低下した場合のみ調査対象とします。

同じ素材セットで `BatchTriagePolicy` の要確認率も計測します。要確認率が高すぎると Pro の価値が失われ、低すぎると見落としが増えるためです。`ExtremePose` の角度閾値（16 節）はこの計測から決めます。

**両 OS で同じ素材セットを流し、検出率と要確認率の差を監視します。** 5.7.1 の共通モデルにより理論上は同じ判定になるはずですが、検出エンジンが異なる以上、境界付近では差が出ます。差が一定以上に開いた場合は閾値か共通モデルを見直します。

iOS の `VNFaceObservation.confidence` は、この回帰監視でのみ参考値として記録します。トリアージには使いません（6.5.2）。

### 12.3 プライバシーの受入テスト

以下を明示的に検証します。

- 履歴一覧とサムネイルに未加工の顔が現れないこと
- タスクスイッチャのスナップショットに編集中の未加工画面が残らないこと（7.7）
- アプリ専用領域に元画像の永続コピーが残らないこと
- 出力ファイルから位置情報・機器情報・編集ソフト情報が除去されていること
- 写真ライブラリの登録日時が元画像から引き継がれていること

### 12.4 アクセシビリティ

仕様 29 章を受入条件とします。CMP は Canvas 自前描画部分の `semantics` 付与が必須のため、以下を明示的にテストします。

- 顔レビュー画面の各顔領域に読み上げ可能なラベルがある
- 処理進捗が読み上げ可能である
- 色のみで状態を表現していない
- 文字サイズ変更に追従する
- 広告とアプリ機能が明確に区別される

### 12.5 実機マトリクス

仕様 30.8 に従います。

---

## 13. 初回リリース範囲

### 13.1 v1 に含めるもの

- 写真の選択、顔自動検出、隠す顔と残す顔の指定、手動領域追加
- モザイク、ぼかし、黒塗り、スタンプ（ベクター自作）
- カスタムスタンプ登録（8 節）
- 出力比率（元比率 / 1:1 / 4:5 / 9:16）、背景ぼかし、メタデータ設定（7.6）
- 写真ライブラリ保存、OS 共有
- Free / Standard / Pro の 3 プラン、購入復元
- **Pro の一括処理（1 バッチ 50 枚）、トリアージ、2 つの確認モード、処理キュー、一括設定プリセット、バッチ履歴**
- **一括処理トライアル（全プラン共通。月間枠とは別勘定の 5 枚クレジット）**
- 広告（Free のみ）
- ローカル履歴、保存期間設定、エラー復旧

### 13.2 v1 に含めないもの

- **利用者向けの動画選択・編集・書き出し機能**
- 4K 出力（写真は仕様 13.6 で元解像度維持のため、そもそも差別化要因にならない）
- カスタムスタンプの自動背景除去

**「動画に関する一切の機能」とは書きません。** 5.5 のとおり、v1 では動画用のモデル・契約・補間関数を内部実装します（実装するのは定義のみで、OS 実装は v2）。除外するのは利用者から見える機能です。

### 13.3 動画の扱い

**v1 では動画を一切露出させません。** ピッカーは画像限定とします（iOS は `PHPickerFilter.images`、Android Photo Picker は画像のみ）。

理由は 4 点です。

- App Store Review Guideline 2.1（App Completeness）はプレースホルダや未完成コンテンツをリジェクト対象としており、「動画は次回対応」という導線がこれに該当すると判断されうる
- 無料アプリで「選べるのに使えない」は低評価レビューの典型的原因であり、初期レビューは母数が少ないぶん平均点への影響が大きく挽回しにくい
- ピッカーを画像限定にする方が、動画を出して選択後に弾くより分岐とエラー導線が少ない
- 「動画対応しました」を後日の更新告知として温存できる

**この結果、v1 では素材の種類選択が不要になります。** UI モックの `kind-chooser` に相当する画面は v1 に含めません。v1 の単体処理フローは以下とします。

```
ホーム → 写真を選ぶ → 顔検出 → 加工 → 書き出し
```

種類選択は、動画を追加する v2 で初めて導入します。

### 13.4 アップデート予定を告知しない

**設定画面に「今後のアップデート予定」セクションは置きません。**

商品面での逆効果が、需要測定の利得を上回るためです。

- 写真アプリとして満足している利用者に「まだ未完成」と感じさせる
- **動画目的の利用者が、対応するまで課金を控える**。これが最も大きい
- 要望ボタンの押下数は、実際に動画を使うかを表さない

需要はストアレビュー、問い合わせ、動画対応後の告知反応で測ります。

設定には `ご意見・ご要望` のみを置き、その中の一項目として動画への要望を受けます。独立したロードマップとしては提示しません。

Paywall、料金表、編集フロー、ストア掲載文で動画に言及しないことは 13.5 のとおりです。

### 13.5 v1 の Paywall

動画を出さない以上、**Paywall で動画の制限（60 秒 / 5 分 / 30 分）や 4K 出力を訴求してはいけません。** 存在しない機能を根拠にサブスクリプションを販売することになり、App Store Review Guideline 3.1.2（Subscriptions）が求める「契約期間中に実際に提供される価値」の要件に反します。

v1 の各プランの訴求は以下とします。

| プラン | v1 の価値 |
| --- | --- |
| Free | 月 5 枚、広告あり、基本スタンプ |
| Standard 月 300 円 | 書き出し無制限、広告なし、追加スタンプ、カスタムスタンプ |
| Pro 月 980 円 | 上記に加えて一括処理、トリアージ、処理キュー、一括設定プリセット、バッチ履歴 |

Pro の説明は、機能の列挙ではなく体験として記述します。

> 旅行やイベントの写真を最大 50 枚選び、顔をまとめて検出します。一覧で仕上がりを見渡し、注意が必要な写真だけを開いて直せば、そのまま一括で保存できます。

一枚ずつ編集画面を開く必要がないことが価値であり、確認そのものが不要になるとは書きません。6.5.2 のとおり検出漏れはアプリ側で判定できないためです。

6.5.7 のとおり、横断的な人物判定はできません。説明文でこれを誤解させないことを制約とします。

課金訴求の分類（`UpgradeReason`）は v1 では以下に限定します。動画と 4K に由来する訴求は v1 に存在しません。

| 分類 | 発火条件 | 誘導先 |
| --- | --- | --- |
| `export-limit` | Free の月間枠を使い切った（`Blocked(MonthlyLimitReached)`） | Standard |
| `ledger-blocked` | 台帳の整合性検証に失敗し、当月の Free 枠が封じられている（`Blocked(LedgerIntegrityFailure)`） | Standard |
| `premium-stamp` | 追加スタンプを選ぼうとした | Standard |
| `custom-stamp` | カスタムスタンプを使おうとした | Standard |
| `edit-locked` | **有料スタンプを含む**既存作品を編集しようとした（6.7） | Standard |
| `batch-credit` | Free / Standard が残クレジットを超える**新しい写真**を選ぼうとした。または残 0 枚かつ消費済み台帳が空で一括処理へ入ろうとした | Pro |
| `batch-size` | Free / Standard が**総数 5 枚**を超えようとした | Pro |
| `batch-limit` | Pro が**総数 50 枚**を超えようとした | 誘導なし。上限の通知 |

`batch-standard`（Standard が通常の一括処理を開いた）は設けません。その状況は「残クレジット 0 かつ台帳が空」と同じであり、`batch-credit` が受けます。分類を増やしても提示内容が変わらないためです。

動画対応時に `long-video` と `export-4k` を追加します。

価格は据え置きます。後から値上げする方が難しく、動画対応で Pro の価値は仕様どおりに戻るためです。

### 13.6 利用者向け表現

v1 では利用者向けの表現を **「写真」** に統一します。内部モデルは `Media` のままとします。

| 内部表現 | v1 の利用者向け表現 |
| --- | --- |
| 月 5 素材 | 月 5 枚 |
| 最大 50 素材 | 最大 50 枚 |
| 素材を選択 | 写真を選択 |

動画追加時に「写真・動画」または「素材」へ変更します。

### 13.7 v2 以降

動画対応（検出、追跡、プレビュー、書き出し、長尺、4K）。5.5 の 4 契約を実装し、v1 で用意したデータモデルとキーフレーム補間へ接続します。顔トラック関連付け・平滑化・シーン切替判定は、実際の検出結果を見ながら v2 で実装します（5.5）。

---

## 14. UI モックとの関係

`ui-mock/` は Next.js による画面と状態遷移の参照実装です。**本書が正であり、モックは本書に追従します。** コードは実装へ流用しません。

モックは本書の仕様へ追従します。以下はモック側で動作します。

動画の除去、確認モードの 2 分岐、検出／確認の 2 軸、**写真ごとの出力状態と部分的な受け渡し**、トライアルクレジット（台帳からの導出を含む）、メタデータの項目別設定、スタンプの参照用コピー、降格後の閲覧と変更の分離、**`Entitlement`（plan + status）からの権限導出**、履歴の容量超過による自動削除。

### 14.1 モックが再現しないこと

Web モックである以上、以下は本書の記述どおりには再現できません。実装時に本書へ従います。

| 項目 | モック | 実装 |
| --- | --- | --- |
| 顔検出・加工・保存・課金 | ダミーデータと固定の座標 | Vision / ML Kit、Core Image / OpenGL ES、PhotoKit / MediaStore、RevenueCat |
| 時間経過に依存する判定 | 24 時間の窓、月初リセット、保存期限は経過を再現しない | `effectiveNow` による判定（6.2.2.5 / 6.2.3 / 7.2.3） |
| 台帳の永続化と署名 | React の状態として保持。HMAC も改ざん検知もない | `UsageLedger` を `ProtectedBlobStore` へ署名付きで保存（6.2 / 6.2.5） |
| 書き出しの耐久性 | 中断・復旧の概念がない | `ExportCommit` によるコミットジャーナルと起動時の復旧（7.4.3） |
| 排他制御 | なし | `ExportStartGate` と `UsageLedgerStore.transact` による直列化（7.4.3） |
| 共有結果の写像 | デモ用のトグルで切り替える | `SharePresenter` が OS の結果を 4 種へ写像する（7.4.2） |
| `StampAsset` の寿命 | 履歴からの参照有無で判定する簡易版 | 内容ハッシュを主キーとする参照カウント（8.4） |
| 一覧の拡大操作 | タップで全画面プレビューのみ | ピンチ拡大も要件（6.5.3） |
| 支援技術での末尾到達 | スクロール検知のみ | VoiceOver / TalkBack の走査でも成立させる（6.5.3） |

### 14.2 モックから引き継ぐもの

- 画面構成（タブ 4、アップグレード訴求モーダル、単体処理の 5 画面）
- 単体処理フロー `home → ピッカー → detect → effect → export → processing → done`
- 配色、余白、角丸、タイポグラフィなどのビジュアル言語
- 課金訴求の分類（13.5 の `UpgradeReason` 表）

---

## 15. 上位仕様書からの逸脱一覧

| 仕様書 | 仕様書の内容 | 本設計 | 理由 |
| --- | --- | --- | --- |
| 4.2 | フルネイティブ二本立て | KMP + CMP | 3 節。単独実装でのドメイン二重化を避ける |
| 8.1 | 検出結果として「検出信頼度」を保持する | 顔単位の共通モデルに含めない。iOS のみの参考値として検出品質の回帰監視で記録する | 5.7.1 / 6.5.2。ML Kit の `Face` に検出信頼度のアクセサがなく、両 OS で対称に扱えない。代替として頭部回転角（`ExtremePose`）を用いる |
| 12.7 | カスタムスタンプ上限 Standard 30 / Pro 100 | 両プラン 100 | 8.2。差別化として機能せず、Pro の焦点をぼかす |
| 13.8 | 撮影日時を削除対象に含む | EXIF 日時は既定で保持。ライブラリ登録日時は常に元画像から引き継ぐ | 7.6。日時削除は写真アプリの並び順を壊す |
| 14.2 | 消費条件の解釈 | 「利用可能な加工済み出力の生成が完了した時点」で確定。写真ライブラリ保存時点ではない | 6.2.1。保存せず OS 共有だけで無料枠を回避できる経路を塞ぐ。仕様の「共有可能な状態になった」に忠実 |
| 16.3 | 一括処理モードは「全顔を同じ方法で隠す」「素材ごとに確認する」 | 「おまかせ一括」「1 枚ずつ確認」。どちらのモードでも全写真に一度は目を通すことを必須とする | 6.5.3 / 6.5.5。トリアージは検出漏れを判定できない |
| 18.4 | 保存上限は 100 プロジェクト | 件数上限を撤廃し、保存期間（既定 30 日）と使用容量上限（既定 200MB）で管理 | 7.2.3。Pro の 1 バッチ 50 枚に対して 100 件では 2 バッチで枯渇する |
| 20.3 | 原子的書き出しの第 4 段階を「写真ライブラリへ保存する」とする | 生成と受け渡しの 2 段階に分離。生成の完了は「保存または共有が可能な完成済み出力として公開した時点」 | 7.4。保存せず共有だけで完結する経路があり、保存を完了条件にすると 6.2.1 と矛盾する |
| 21.5 | `/v1/installations` と購入検証 API | 実装しない | 11.1。RevenueCat が担う |
| 32.1 | 初回リリース必須機能に動画を含む | v1 では動画を含めない | 13.3。段階リリース |

---

## 16. 未決事項

| 項目 | 内容 | 決定時期 |
| --- | --- | --- |
| 商品 ID | 仕様 27.1 の商品 ID は暫定。ストア登録時に確定 | ストア登録時 |
| カスタムスタンプのバックアップ方針 | 仕様 20.4 が初期リリース前の決定としている | v1 実装中 |
| プライバシーポリシーの記載 | トライアル台帳（`sourceHash`）を期限なく端末内へ保持することを記載し、7.2.3 の例外と整合させる | ストア申請前 |
| 共有結果 `Unknown` 後の利用者操作 | `Generated` を維持するため、共有後に画面を離れると「保存していない写真があります」が出る。「共有できましたか？」と明示確認して `Delivered` にするか、`Generated` のまま保存・再共有・破棄を選ばせるか。OS 結果の写像だけでなく、その後の操作まで定義が必要（7.4.2） | 実装計画で確定 |
| 基本スタンプの意匠 | ベクターで自作する 12〜20 種の具体的な図案 | v1 実装中 |
| `ExtremePose` の角度閾値 | yaw / pitch の絶対値が何度を超えたら警告するか。検出品質テストの結果から決定（6.5.2） | v1 実装中 |
| 履歴の使用容量上限 | 初期値 200MB は暫定。加工後サムネイルの実サイズを計測して確定 | v1 実装中 |
| カスタムスタンプの保存解像度 | 長辺 1,024px は暫定。顔が大きく写る素材での見え方を実機で確認して確定（8.5） | v1 実機検証時 |
| トライアルのクレジット数 | 5 枚は暫定。転換率を見て調整可能な設定値とする | リリース後 |
| 一括処理の同時並列数 | 写真のみのため 2 まで許容可能だが、初期値は 1。両 OS の実機計測後に判断 | v1 実機検証時 |

---

## 17. 次の手順

本設計の承認後、`superpowers:writing-plans` により実装計画を作成します。サブプロジェクトへの分解単位は以下を想定します。

1. プロジェクト基盤（KMP + CMP の骨格、CI、lint、テスト実行基盤）
2. ドメイン層（`QuotaPolicy`、`EntitlementResolver`、`BatchTriagePolicy`、`RenderPlan` 生成、キーフレーム補間、`ExportQueue`）
3. プラットフォーム契約（12 契約の両 OS 実装と契約テスト）。**モジュールは責務ごとに分ける**（下表）。`SharePresenter` は OS ごとの結果写像を先に定義してから実装する（7.4.2）
4. 編集フロー UI（detect / effect / export / processing / done）
5. 課金と権限（RevenueCat、Paywall、復元、`SubscriptionState` の読み込み失敗経路）
6. 広告
7. 一括処理とトリアージ
8. 履歴・カスタムスタンプ・設定
9. バックエンド（Rust + Axum）
10. リリース準備（アクセシビリティ、プライバシー受入テスト、実機マトリクス、ストア申請物）

サブプロジェクト 3 の内訳は次のとおりです。**12 契約をすべて `shared/media` へ実装しません**（5.4）。

| モジュール | 契約 |
| --- | --- |
| `shared/media` | `PhotoPicker` / `FilePicker` / `ImageLoader` / `FaceDetector` / `ImageEffectRenderer` / `ImageEncoder` / `MediaSaver` / `SharePresenter` |
| `shared/data` | `ProtectedBlobStore`、Room、ファイル管理 |
| `shared/data/security` | `CryptoKeyStore` |
| `shared/ads` | `AdPresenter` |
| `composeApp`（アプリシェル） | `PrivacyShield` |

各サブプロジェクトは個別に spec → plan → 実装のサイクルを回します。
