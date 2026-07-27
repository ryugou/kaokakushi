# かおかくし 技術スタックおよびアーキテクチャ設計

| 項目 | 内容 |
| --- | --- |
| 文書名 | かおかくし 技術スタックおよびアーキテクチャ設計 |
| バージョン | 1.0 |
| 作成日 | 2026-07-27 |
| 対象 | 写真・動画向け顔匿名化アプリ（iOS / Android） |
| 上位文書 | 写真・動画向け顔匿名化アプリ 仕様書 v0.1 |
| 本書の範囲 | 技術選定、モジュール構成、境界設計、データフロー、エラー設計、テスト戦略、リリース段階 |
| 本書の対象外 | 画面ごとの UI 仕様（`ui-mock/` を正とする）、スタンプの意匠 |

---

## 1. 前提

### 1.1 実装体制

本プロジェクトの実装者は Claude Code 単独です。この制約が技術選定を支配します。

同一のドメインロジックを二度実装すると、実装コストが倍になるだけでなく、両者が徐々に乖離して仕様差異バグを生みます。したがって **共有できる層を最大化する構成** を最優先とします。

### 1.2 上位仕様からの変更点

仕様書 4.2 は iOS / Android のフルネイティブ二本立て（Swift + SwiftUI / Kotlin + Jetpack Compose）を指定していますが、本設計ではこれを変更します。変更理由は 3 節に記述します。

仕様書のドメイン要件（プラン、課金、プライバシー、エラー、性能、テスト条件）は変更しません。

---

## 2. 確定した技術スタック

### 2.1 全体

| 領域 | 採用技術 |
| --- | --- |
| 共有基盤 | Kotlin Multiplatform (KMP) |
| 共有 UI | Compose Multiplatform (CMP) |
| iOS ネイティブ | Swift（メディア層のみ） |
| Android ネイティブ | Kotlin（メディア層のみ） |
| ローカル DB | Room KMP |
| DI | Koin |
| 課金 | RevenueCat KMP SDK (`purchases-kmp`) |
| 広告 | Google Mobile Ads（`expect`/`actual` で自前ラップ） |
| クラッシュ解析 | Sentry KMP SDK |
| バックエンド | Rust + Axum（リモート設定と診断のみ） |
| 対応 OS | iOS 17 以降 / Android 10 (API 29) 以降 |

### 2.2 iOS メディア層

| 用途 | 採用 API |
| --- | --- |
| 顔検出 | Vision |
| 写真選択 | PhotosPicker |
| 画像読み込み・向き正規化 | Image I/O |
| エフェクト描画 | Core Image（`CIPixellate` / `CIGaussianBlur`） |
| エンコード・メタデータ除去 | Image I/O |
| 写真ライブラリ保存 | PhotoKit |
| セキュア保存 | Keychain |
| 動画（次リリース） | AVFoundation / AVAssetWriter |

### 2.3 Android メディア層

| 用途 | 採用 API |
| --- | --- |
| 顔検出 | ML Kit Face Detection |
| 写真選択 | Android Photo Picker |
| 画像読み込み・向き正規化 | ImageDecoder |
| エフェクト描画 | OpenGL ES 2.0（フラグメントシェーダ） |
| エンコード・メタデータ除去 | `Bitmap.compress` + ExifInterface |
| 写真ライブラリ保存 | MediaStore |
| セキュア保存 | Keystore |
| 動画（次リリース） | Jetpack Media3 Transformer |

Android の最低対応が API 29 のため、`RenderEffect`（API 31 以降）は使用できません。ぼかしとモザイクは OpenGL ES 2.0 のフラグメントシェーダで実装します。

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
| iOS のアクセシビリティ | Canvas 自前描画部分は `semantics` の明示的な付与が必須 | 仕様 29 章を受入条件とし、後述のテスト戦略で担保 |
| CMP は JetBrains 単独支援 | 将来の開発継続性が Google 支援の KMP ほど堅くない | ドメイン層を CMP に依存させない。UI 差し替え経路を確保しておく |
| 広告 SDK の自前ラップ | 公式 KMP SDK が存在しない | `expect`/`actual` の薄いポートに閉じ込め、契約テストで両 OS の挙動を揃える |

---

## 4. モジュール構成

```
kaokakushi/
├── composeApp/              CMP アプリ本体（共有 UI とエントリポイント）
│   ├── commonMain/          全画面の Compose UI、ナビゲーション
│   ├── androidMain/         Activity、AndroidView（広告バナー）
│   └── iosMain/             ComposeUIViewController、UIKitViewController 埋め込み
│
├── shared/
│   ├── domain/              純粋 Kotlin。プラットフォーム依存ゼロ
│   ├── data/                Room KMP、ファイル管理、設定永続化
│   ├── media/               メディア境界の expect/actual
│   ├── billing/             RevenueCat ラッパと権限解決
│   ├── ads/                 広告の expect/actual
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

`domain` は他のいかなるモジュールにも依存しません。Kotlin 標準ライブラリと `kotlinx-datetime` 以外の依存を持ちません。

この制約により、仕様書 30.1 が要求する単体テスト項目がすべて `commonTest` に収まり、JVM 上でエミュレータなしに実行できます。

### 4.2 ナビゲーションと iOS 差し替え経路

ナビゲーションは Compose 側が所有します。画面は `Route` の sealed class で表現し、`Route` から Composable への解決を 1 箇所の `when` に集約します。

v1 では全画面を Compose で実装します。iOS の特定画面を SwiftUI へ差し替える必要が生じた時点で、その `when` に分岐を追加し、`UIKitViewController` 経由で SwiftUI をホストする `UIViewController` を描画します。差し替え機構を先回りして実装することはしません（YAGNI）。設計上の要件は「`Route` を sealed class にすること」「画面解決を 1 箇所に集約すること」の 2 点のみです。

---

## 5. ネイティブ境界の設計

### 5.1 基本方針

**エフェクトの数学をすべてドメイン側に置き、ネイティブには描画プリミティブのみを残します。**

```
ネイティブ  顔検出 → 正規化座標の矩形群 + 信頼度 + 向き
    ↓
ドメイン    拡張率適用（上 25% / 下 15% / 左右 15%）
            形状決定（楕円 / 円 / 矩形 / 角丸）
            強度の相対値 → 絶対値換算
            スタンプのベクター描画とラスタライズ
            → RenderPlan
    ↓
ネイティブ  RenderPlan を受け取り、4 プリミティブのみ実行
            ①マスク内モザイク ②マスク内ぼかし ③単色塗り ④画像貼り付け
```

座標はすべて 0〜1 の正規化値で扱います（仕様 19.3 と一致）。ドメインはピクセル解像度を知りません。これにより拡張率やマージンの計算がプラットフォーム間でずれません。

スタンプをベクターで自作する方針により、ドメイン側が Compose Canvas でベクターを描いてビットマップ化できます。ネイティブ側は「画像を貼る」1 プリミティブで全スタンプを処理でき、スタンプの種類が増えてもネイティブコードは増えません。

### 5.2 RenderPlan

```kotlin
data class RenderPlan(
    val canvasSize: IntSize,            // 出力先の実ピクセルサイズ
    val regions: List<RenderRegion>,
)

data class RenderRegion(
    val bounds: NormalizedRect,         // 拡張率適用済み。0..1
    val rotationDegrees: Float,
    val shape: MaskShape,               // Ellipse / Circle / Rectangle / Rounded(cornerRatio)
    val featherRatio: Float,            // 境界ぼかし。領域短辺に対する比
    val op: RenderOp,
)

sealed interface RenderOp {
    data class Mosaic(val cellRatio: Float) : RenderOp    // 領域短辺に対するセル比
    data class Blur(val sigmaRatio: Float) : RenderOp     // 領域短辺に対する σ 比
    data class Solid(val color: Long, val opacity: Float) : RenderOp
    data class Stamp(val bitmapId: String, val opacity: Float) : RenderOp
}
```

エフェクト強度をすべて **領域サイズに対する相対値** で保持します（仕様 11.1）。これにより低解像度プレビューと原寸書き出しで見た目が一致し、ゴールデン画像テストが成立します。

### 5.3 拡張率の適用

```kotlin
fun expand(face: NormalizedRect, effect: EffectSetting): NormalizedRect
```

既定値は上 25% / 下 15% / 左右 15%（仕様 8.4）。スタンプはモザイクより大きめの拡張率を用います。

**画像外へはみ出す場合もクランプしません。** クランプすると顔が露出する方向へ倒れるためです。はみ出しはマスク描画側で処理します。これは仕様 9.5 の「平滑化によって顔が露出する場合は、領域を小さくするのではなく拡張する」と同じ思想です。

### 5.4 ネイティブ契約（v1 = 写真のみ）

| 契約 | 責務 | iOS | Android |
| --- | --- | --- | --- |
| `PhotoPicker` | OS 標準ピッカー。画像のみ | PhotosPicker | Photo Picker |
| `ImageLoader` | 読み込み、向き正規化、検出用縮小、HEIC 対応 | Image I/O | ImageDecoder |
| `FaceDetector` | 顔検出。正規化座標で返す | Vision | ML Kit |
| `ImageEffectRenderer` | RenderPlan の 4 プリミティブ実行 | Core Image | OpenGL ES 2.0 |
| `ImageEncoder` | JPEG / PNG エンコード、メタデータ除去 | Image I/O | Bitmap.compress + ExifInterface |
| `MediaSaver` | 写真ライブラリ保存 | PhotoKit | MediaStore |
| `SecureStore` | 匿名 ID、権限キャッシュ、HMAC 鍵 | Keychain | Keystore |
| `AdPresenter` | バナー・全画面広告 | GADBannerView | AdView |

### 5.5 動画対応で追加する契約（v2）

以下 4 契約を **v1 の設計時点で定義**し、実装のみ v2 に回します。

| 契約 | 責務 | iOS | Android |
| --- | --- | --- | --- |
| `VideoProbe` | 長さ、解像度、コーデック、回転、HDR 判定 | AVAsset | MediaExtractor |
| `VideoFrameSource` | 時刻指定のフレーム取得 | AVAssetReader | MediaCodec |
| `PreviewRenderer` | エフェクト適用済みテクスチャ出力 | MTKView | GLSurfaceView |
| `VideoExporter` | 書き出し | AVAssetWriter | Media3 Transformer |

`domain` 側の顔トラック関連付け、キーフレーム補間、平滑化、シーン切替判定は **v1 の時点で実装とテストまで完了させます**。いずれも純粋関数であり、動画の実物なしにテストできます。これにより v2 での手戻りを防ぎます。

### 5.6 プレビューと書き出しの一致

インタラクティブなプレビューは低解像度で `composeApp` の Compose Canvas により両 OS 共通で描画し、書き出しのみ原寸でネイティブが処理します。これは仕様 8.3 の「検出用縮小画像を使い、書き出し時は元解像度へ適用する」と整合します。

両者の乖離を防ぐため、同一の `RenderPlan` に対するゴールデン画像テストで差分を許容誤差内に抑えます。

### 5.7 顔検出の座標処理

仕様 8.3 の手順に従います。

1. 元画像の向き情報を正規化する
2. 検出用に長辺 1,920 ピクセル程度へ縮小する
3. 顔検出を実行する
4. **ネイティブ側で正規化座標へ変換して返す**
5. 以降、ドメインはピクセル座標を扱わない

検出用画像上で顔の短辺が 24 ピクセル未満の検出結果には `requiresReview` を立てます（仕様 8.5）。

---

## 6. ドメイン設計

### 6.1 無料枠の消費判定（QuotaPolicy）

仕様 14 章に対応します。UI モックは書き出しのたびに無条件で残数を 1 減らしていますが、実装ではこれを純粋関数の判定に置き換えます。

```kotlin
data class QuotaLedger(
    val period: YearMonth,              // 消費を計上している年月
    val consumed: Int,
    val grants: List<ExportGrant>,      // 24 時間の無償再書き出し権
)

data class ExportGrant(
    val sourceHash: String,
    val firstSuccessAt: Instant,
)

sealed interface QuotaDecision {
    object Unlimited : QuotaDecision        // Standard / Pro
    object FreeReexport : QuotaDecision     // 24 時間以内の再書き出し。消費しない
    object Consume : QuotaDecision          // 1 消費する
    data class Blocked(val limit: Int) : QuotaDecision
}

fun evaluate(
    ledger: QuotaLedger,
    plan: Plan,
    sourceHash: String,
    now: Instant,
    zone: TimeZone,
): QuotaDecision
```

判定順序は以下とします。

1. `plan != Free` なら `Unlimited`
2. 期間更新を適用する（6.1.2 の巻き戻し防止つき）
3. `grants` に同一 `sourceHash` があり `now - firstSuccessAt < 24h` なら `FreeReexport`
4. `consumed >= limit` なら `Blocked`
5. それ以外は `Consume`

#### 6.1.1 消費の確定タイミング

仕様 14.2 に厳密に従い、書き出しパイプラインの最終ステップで確定します。出力ファイルが生成され、整合性確認とデコード確認を通り、写真ライブラリへ保存されたトランザクション内でのみ `commit` します。

以下では消費しません。検出のみ、プレビューのみ、キャンセル、失敗、空き容量不足、異常終了、対応外形式。

#### 6.1.2 月初リセットと時刻巻き戻し

仕様 14.4 の「端末時刻が過去へ戻された場合、最後に確認した年月より前へ戻さない」を、期間の単調増加を強制することで実現します。

```kotlin
fun rollPeriod(ledger: QuotaLedger, now: Instant, zone: TimeZone): QuotaLedger {
    val current = now.toLocalDateTime(zone).yearMonth
    return if (current > ledger.period) {
        QuotaLedger(current, consumed = 0, grants = emptyList())
    } else {
        ledger   // 同一または過去 → リセットしない
    }
}
```

タイムゾーンを西へ移動して月をまたぎ戻しても、端末時計を手動で戻しても、`period` は後退しません。

#### 6.1.3 同一素材の判定

仕様 14.3 は「新しいプロジェクトとして作り直しても、元素材識別子とローカルハッシュが一致すれば同一素材として扱う」と定めます。`PHAsset.localIdentifier` や MediaStore の URI は再インストールや再選択で変わりうるため、**ハッシュを主、識別子を従**とします。

ハッシュは `ファイルサイズ + 先頭 64KB + 末尾 64KB + 撮影日時` の複合とします。48 メガピクセルの HEIC を全読みする負荷を避けるためです。

理論上の衝突時は「別素材なのに無料で再書き出しできる」方向へ倒れます。これはユーザーに有利な安全側であり許容します。逆方向（同一素材なのに二重消費）へ倒れる設計は採りません。

#### 6.1.4 改ざん耐性

`QuotaLedger` を平文で DB に保存すると、DB を書き換えるだけで無料枠が無制限になります。一方で仕様 14.5 は、不正利用防止のためだけに端末固有識別子や過剰な個人情報を収集することを禁じています。

折衷案として、Keychain / Keystore の鍵で `QuotaLedger` に HMAC 署名を付与し、検証失敗時は「消費済み」側へ倒します。サーバー照合も端末識別子の収集も行いません。

再インストールで枠が戻ることは仕様 14.5 が明示的に許容しているため、追跡しません。

### 6.2 権限解決（EntitlementResolver）

RevenueCat の `CustomerInfo` をアプリ全体に流さず、純粋関数で畳み込みます。

```kotlin
fun resolve(snapshot: CustomerInfoSnapshot, now: Instant): Entitlement

data class Entitlement(
    val plan: Plan,                     // free / standard / pro
    val status: PlanStatus,             // active / grace / pending / expired / revoked
    val expiresAt: Instant?,
    val lastVerifiedAt: Instant,
)
```

要件は 3 点です。

- **`pending`（支払い保留）では有料機能を付与しません**（仕様 5.4）。UI モックの `canBatch` 等の権限フラグはすべて `Entitlement` から導出します
- **オフライン耐性**（仕様 25.3 / 27.3）。最後に検証成功した `Entitlement` を `lastVerifiedAt` とともに SecureStore へ保存します。ネットワーク不通時はこのキャッシュで有料機能を維持し、復元失敗を理由に Free へ強制降格させません。失効が明示的に確認された場合のみ剥奪します
- **バックエンド障害で編集を止めません**（仕様 21.6）。リモート設定が取得できない場合はアプリ内の安全な既定値を使用します

### 6.3 広告表示頻度（AdFrequencyPolicy）

仕様 15.3 / 15.4 を純粋関数として実装します。

- 検出中、顔選択中、編集中、書き出し中、書き出しエラー対応中、課金処理中は表示しない
- 初回書き出し完了時には全画面広告を表示しない
- 全画面広告は最大でも 2〜3 回の書き出しにつき 1 回
- 同一セッションで連続表示しない
- 広告取得失敗でアプリ処理を止めない

判定を純粋関数に閉じることで `commonTest` で網羅できます。

### 6.4 一括処理（ExportQueue）

Pro のみ利用可能。v1 では写真のみを対象とします。

状態は仕様 16.6 の 8 種（`waiting` / `analyzing` / `review_required` / `exporting` / `completed` / `failed` / `canceled` / `paused`）とし、状態機械を `domain` に置きます。

- 1 バッチ最大 50 素材
- 同時並列処理は初期状態で 1 素材。写真のみのため最大 2 まで許容可能とするが、初期値は 1
- 一素材の失敗でバッチ全体を停止しない
- アプリ再起動後に未完了キューを復元する（仕様 16.7）
- 元素材へのアクセス権限を失った場合は再選択を求める
- バックグラウンド処理は仕様 16.8 に従う。Android は Foreground Service と明示的な通知、iOS は OS の実行制限に従う

### 6.5 手動領域とキーフレーム

仕様 8.7 および 10 章の手動修正は、すべて `domain` 側で扱います。ネイティブは手動領域を認識しません。

- 写真では、手動指定領域をそのまま加工対象の `FaceTrack`（`createdManually = true`）として扱います
- 誤検出の削除、領域の移動・拡大縮小、エフェクトの個別変更は、`FaceTrack` と `EffectSetting` の編集に還元されます
- 動画（v2）では、手動指定したフレームを `FaceKeyframe` として保持し、キーフレーム間で中心 X / 中心 Y / 幅 / 高さ / 回転角度を補間します（仕様 10.3）

キーフレーム補間は純粋関数であり、v1 の時点で実装とテストを完了させます。

---

## 7. データモデルと永続化

### 7.1 Room KMP

仕様 19 章のテーブルをほぼそのまま採用します。`Project` / `FaceTrack` / `FaceKeyframe` / `EffectSetting` / `ExportSetting` / `CustomStamp` / `ExportRecord`。

`SubscriptionState` と `QuotaLedger` は DB ではなく SecureStore へ保存します（6.1.4 の HMAC 署名つき）。

### 7.2 ファイル管理

仕様 20 章に従います。

- 一時ファイル名は UUID ベースとし、元の写真名を使用しない
- アプリ専用領域へ保存する
- 書き出し完了後に不要な一時ファイルを削除する
- 起動時に 24 時間以上残存する未使用一時ファイルを掃除する
- OS のクラウドバックアップ対象外とする（iOS は `isExcludedFromBackup`、Android は `data_extraction_rules.xml`）

### 7.3 原子的書き出し

仕様 20.3 の 4 段階を厳守します。

1. アプリ専用の一時パスへ書き出す
2. ファイル整合性を確認する
3. デコードできることを簡易確認する
4. 正常な場合のみ写真ライブラリへ保存する

失敗時に不完全な出力を公開しません。この 4 段階を通過した時点が、6.1.1 のクォータ確定点と一致します。

### 7.4 保存上限

全プラン共通で最大 100 プロジェクト。上限超過時の削除候補は「お気に入りでない」「未編集中でない」「処理キューに含まれない」「更新日時が最も古い」の全条件を満たすものとします（仕様 18.4）。

写真ライブラリへ保存済みの出力ファイルは、明示的な確認なしに削除しません。

### 7.5 メタデータ除去

仕様 13.8 に従い、GPS 位置情報、撮影機器情報、撮影日時、編集ソフト情報、ユーザーコメントを除去します。画像方向とピクセルサイズは保持します。

---

## 8. エラーとログ

### 8.1 エラー型

仕様 26.1 の 20 コードを `sealed interface AppError` として表現します。各要素は再試行可否、利用者向けメッセージ、診断フィールドを持ちます。

仕様 26.2 の再試行可否は型の上で表現し、実行時判断に委ねません。

### 8.2 ログの型による防御

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

顔数や動画長は仕様 22.3 の粗い区分値（顔数は 0 / 1 / 2〜5 / 6 以上など）としてのみ `LogValue` になります。

### 8.3 握りつぶしの禁止

すべての `catch` 箇所で `AppError` へ変換したうえで `log` を通すことを規約とします。`runCatching` の裸使用は lint で禁止します。

### 8.4 クラッシュ解析

Sentry へ送信するのは **クラッシュと未分類例外（`UNKNOWN_ERROR`）のみ** とします。

`AD_LOAD_FAILED`、`STORAGE_INSUFFICIENT`、`VIDEO_TOO_LONG` のような想定内のエラーは Sentry へ送らず、分析イベントの区分値として計測します。Sentry 無料枠（月 5,000 エラーイベント、ユーザー 1 名、保持 30 日）を超過させないためであり、同時にプライバシー面でも正しい方向です。

スパイク保護とサンプリングを有効化し、不良リリース時の突発的な消費を抑えます。

Sentry KMP SDK はメジャーバージョン前のため、`domain` が定義する `CrashReporter` ポートの背後に配置し、将来の差し替えコストを小さく保ちます。

---

## 9. 分析

仕様 28.2 のイベント名をそのまま sealed class 化します。

仕様 28.3 の禁止項目（元ファイル名、ファイルパス、写真ライブラリ ID、正確な顔座標、画像ハッシュ、SNS アカウント名、カスタムスタンプ画像、写真・動画の内容、音声内容）は、8.2 の `LogValue` 制約により構造的に混入しません。

---

## 10. バックエンド

### 10.1 役割の縮小

購入検証、ストア通知の受信、権限管理は RevenueCat が担います。自前サーバーは以下 2 本のみとします。

| エンドポイント | 内容 |
| --- | --- |
| `GET /v1/config` | Free 月間書き出し数、プラン別動画上限、一括処理上限、有効なスタンプパック、広告表示頻度、最低サポートアプリバージョン、障害中の機能停止フラグ |
| `POST /v1/diagnostics` | ユーザーが明示的に同意した場合のみ受信 |

仕様 21.5 の `POST /v1/installations` は実装しません。匿名インストール ID は RevenueCat の App User ID と兼用します。仕様 21.4 の要件（Keychain / Keystore への保存、広告 ID を利用者 ID として使わない、ハードウェア識別子を収集しない）は満たされます。

`POST /v1/entitlements/apple/verify` と `POST /v1/entitlements/google/verify` は RevenueCat が担うため実装しません。

### 10.2 実装

Rust + Axum。`/v1/config` は静的 JSON と ETag による配信とします。

仕様 21.3 の送信禁止データは、そもそも送信経路を持たないことで担保します。

### 10.3 障害時

リモート設定の取得に失敗した場合はアプリ内の安全な既定値を使用します。バックエンド障害で編集処理を停止させません（仕様 21.6）。

---

## 11. テスト戦略

### 11.1 三層構成

**`commonTest`（JVM、数秒）** — `domain` を全網羅します。対象は仕様 30.1 の全項目です。

- `QuotaPolicy`（月跨ぎ、TZ 変更、時刻巻き戻し、うるう年、月末 23:59:59 → 00:00:00、24 時間境界）
- `EntitlementResolver`（仕様 27.4 の全購入状態）
- 拡張率適用、`RenderPlan` 生成、座標正規化
- 顔トラック関連付け、キーフレーム補間（v2 機能だが v1 で実装・テスト）
- ストレージ必要量計算、`ExportQueue` 状態機械、`AdFrequencyPolicy`
- リモート設定のフォールバック

**契約テスト** — `media` / `data` / `billing` / `ads` の各ポートに共通のテストスイートを 1 本書き、Android instrumented test と iOS の XCTest の両方で同一スイートを実行します。「片方の OS だけ挙動が違う」を構造的に防ぎます。

**ゴールデン画像テスト** — 低解像度プレビューと原寸書き出しの一致、およびエフェクトの回帰を検証します。仕様 30.4 の条件（強度の最小・最大、顔の回転、領域が画面端、領域の重なり、透明度、4 形状）を素材として固定化します。

### 11.2 検出品質

仕様 30.2 の検出条件（正面、横顔、斜め、部分的な遮蔽、マスク、サングラス、暗所、逆光、遠景、集合写真、子ども、高齢者、異なる肌色、イラストの顔、鏡像、写真内の写真）は、**合否判定ではなく検出率の回帰監視** として計測します。

仕様 34.5 が「完全自動を約束しない」と定めている以上、閾値でビルドを落とすのは不適切です。リリース間で検出率が有意に低下した場合のみ調査対象とします。

### 11.3 アクセシビリティ

仕様 29 章を受入条件とします。CMP は Canvas 自前描画部分の `semantics` 付与が必須のため、以下を明示的にテストします。

- 顔レビュー画面の各顔領域に読み上げ可能なラベルがある
- 処理進捗が読み上げ可能である
- 色のみで状態を表現していない
- 文字サイズ変更に追従する
- 広告とアプリ機能が明確に区別される

### 11.4 実機マトリクス

仕様 30.8 に従います。

---

## 12. 初回リリース範囲

### 12.1 v1 に含めるもの

- 写真の選択、顔自動検出、隠す顔と残す顔の指定、手動領域追加
- モザイク、ぼかし、黒塗り、スタンプ（ベクター自作）
- カスタムスタンプ登録
- 出力比率（元比率 / 1:1 / 4:5 / 9:16）、背景ぼかし、メタデータ除去
- 写真ライブラリ保存、OS 共有
- Free / Standard / Pro の 3 プラン、購入復元
- **Pro の一括処理（1 バッチ 50 素材）、処理キュー、一括設定適用**
- 広告（Free のみ）
- ローカル履歴、エラー復旧

### 12.2 v1 に含めないもの

- 動画に関する一切の機能
- 4K 出力（写真は仕様 13.6 で元解像度維持のため、そもそも差別化要因にならない）

### 12.3 動画の扱い

**v1 では動画を一切露出させません。** ピッカーは画像限定とします（iOS は `PHPickerFilter.images`、Android Photo Picker は画像のみ）。

理由は 4 点です。

- App Store Review Guideline 2.1（App Completeness）はプレースホルダや未完成コンテンツをリジェクト対象としており、「動画は次回対応」という導線がこれに該当すると判断されうる
- 無料アプリで「選べるのに使えない」は低評価レビューの典型的原因であり、初期レビューは母数が少ないぶん平均点への影響が大きく挽回しにくい
- ピッカーを画像限定にする方が、動画を出して選択後に弾くより分岐とエラー導線が少ない
- 「動画対応しました」を後日の更新告知として温存できる

### 12.4 v1 の Paywall

動画を出さない以上、**Paywall で動画の制限（60 秒 / 5 分 / 30 分）や 4K 出力を訴求してはいけません。** 存在しない機能を根拠にサブスクリプションを販売することになり、App Store Review Guideline 3.1.2（Subscriptions）が求める「契約期間中に実際に提供される価値」の要件に反します。

v1 の各プランの訴求は以下とします。

| プラン | v1 の価値 |
| --- | --- |
| Free | 月 5 素材、広告あり、基本スタンプ |
| Standard 月 300 円 | 書き出し無制限、広告なし、追加スタンプ、カスタムスタンプ |
| Pro 月 980 円 | 上記に加えて一括処理（1 バッチ 50 素材）、処理キュー、一括設定適用 |

`UpgradeReason` の `long-video` と `export-4k` は v1 では発火しない状態とし、動画リリース時に有効化します。

価格は据え置きます。後から値上げする方が難しく、動画対応で Pro の価値は仕様どおりに戻るためです。

### 12.5 アップデート予定の告知

設定タブに「今後のアップデート予定」という静的なセクションを置き、動画対応を予告します。

**条件:**

- 時期を約束しない。「対応を予定しています」と記述し、「予定は変更される場合があります」を添える
- 操作可能な機能として見せない。テキストとして提示する
- 併せて「動画対応を希望する」を配置し、タップで受付表示のうえ分析イベントを 1 件送る。個人情報は含まない

**この告知を置いてはいけない場所:**

- Paywall と料金表（Guideline 3.1.2）
- ピッカーと編集フローの中（Guideline 2.1）
- App Store / Google Play の掲載文とスクリーンショット（Guideline 2.3 および Google Play の誤解を招く主張ポリシー）

### 12.6 v2 以降

動画対応（検出、追跡、プレビュー、書き出し、長尺、4K）。5.5 の 4 契約を実装し、v1 の時点で実装・テスト済みのドメインロジック（顔トラック関連付け、キーフレーム補間、平滑化、シーン切替判定）と接続します。

---

## 13. UI モックとの差分

`ui-mock/` は完成形の UI を示す参照資料であり、コードは実装へ流用しません。以下は意図的な差分です。

| 項目 | モックの挙動 | 実装の挙動 |
| --- | --- | --- |
| 無料枠の消費 | 書き出しのたびに無条件で残数 −1 | `QuotaPolicy.evaluate` が `Consume` を返したときのみ減算。24 時間以内の同一素材再書き出しでは減らさない（6.1） |
| 月初リセット | 未実装 | `rollPeriod` により実装。時刻巻き戻し防止つき（6.1.2） |
| 動画 | ピッカーに動画素材あり（`m3` / `m4` / `m5`） | v1 では露出させない（12.3） |
| 料金表の動画・4K 訴求 | あり | v1 では削除（12.4） |
| 権限フラグ | `plan` から直接導出 | `Entitlement`（plan + status）から導出。`pending` では付与しない（6.2） |

モックの画面構成（12 画面、タブ 4、モーダル 3）とフロー（`home →(種類選択→ピッカー)→ detect → effect → export → processing → done`）は実装でも維持します。`UpgradeReason` の分類もそのまま採用します。

---

## 14. 未決事項

| 項目 | 内容 | 決定時期 |
| --- | --- | --- |
| 商品 ID | 仕様 27.1 の商品 ID は暫定。ストア登録時に確定 | ストア登録時 |
| カスタムスタンプのバックアップ方針 | 仕様 20.4 が初期リリース前の決定としている | v1 実装中 |
| 基本スタンプの意匠 | ベクターで自作する 12〜20 種の具体的な図案 | v1 実装中 |
| 一括処理の同時並列数 | 写真のみのため 2 まで許容可能だが、初期値は 1。両 OS の実機計測後に判断 | v1 実機検証時 |

---

## 15. 次の手順

本設計の承認後、`superpowers:writing-plans` により実装計画を作成します。サブプロジェクトへの分解単位は以下を想定します。

1. プロジェクト基盤（KMP + CMP の骨格、CI、lint、テスト実行基盤）
2. ドメイン層（`QuotaPolicy`、`EntitlementResolver`、`RenderPlan` 生成、トラック関連付け、キーフレーム補間、`ExportQueue`）
3. メディア境界（8 契約の両 OS 実装と契約テスト）
4. 編集フロー UI（detect / effect / export / processing / done）
5. 課金と権限（RevenueCat、Paywall、復元）
6. 広告
7. 一括処理
8. 履歴・スタンプ・設定
9. バックエンド（Rust + Axum）
10. リリース準備（アクセシビリティ、実機マトリクス、ストア申請物）

各サブプロジェクトは個別に spec → plan → 実装のサイクルを回します。
