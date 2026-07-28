# 顔かくし 技術スタックおよびアーキテクチャ設計

| 項目 | 内容 |
| --- | --- |
| 文書名 | 顔かくし 技術スタックおよびアーキテクチャ設計 |
| バージョン | 2.5 |
| 作成日 | 2026-07-27 |
| 対象 | 写真向け顔匿名化アプリ（**iOS 単独**） |
| 上位文書 | 写真・動画向け顔匿名化アプリ 仕様書 v0.1 |
| 本書の範囲 | 技術選定、モジュール構成、境界設計、データフロー、エラー設計、テスト戦略、リリース段階 |
| 本書の対象外 | 画面ごとの視覚デザイン（配色・余白・タイポグラフィは `ui-mock/` を参照）、スタンプの意匠 |

本書は上位仕様書からいくつかの点で逸脱します。逸脱の一覧と理由は 15 節に集約しています。

挙動の定義については **本書が正であり、`ui-mock/` は本書に追従します**（14 節）。

**v2.0 での方針転換。** v1.x は Kotlin Multiplatform + Compose Multiplatform による iOS / Android 同時リリースを前提としていましたが、**iOS 単独リリース**へ変更しました。技術スタックは Swift + SwiftUI の単一ネイティブ構成です。ドメイン設計（クォータ、トリアージ、コミットジャーナル、ハッシュ正準化）は言語を移すだけで、判断の内容は v1.29 から変えていません。

---

## 1. 前提

### 1.1 実装体制

本プロジェクトの実装者は Claude Code 単独です。

v1.x では「同一のドメインロジックを二度実装しない」ことが技術選定を支配していましたが、**リリース対象が iOS のみになったため、この制約は消えました。** 二重実装する相手が存在しません。

代わりに支配的となるのは次です。

- **プラットフォームの機能をそのまま使えること。** 抽象化層を挟まない分、Vision や Core Image の新機能を即座に利用できます
- **単一言語で完結すること。** Swift 以外の言語を持ち込みません。ビルド構成、テスト実行、デバッグ経路がすべて Xcode に閉じます

### 1.2 上位仕様からの変更点

仕様書 4.2 は iOS / Android のフルネイティブ二本立て（Swift + SwiftUI / Kotlin + Jetpack Compose）を指定しています。本設計は **iOS 側のみを実装**し、Android は v1 のリリース対象から外します（15 節の逸脱一覧）。

**Android を後から追加する場合、ドメイン層の再実装が必要になります。** Swift で書いたクォータ判定・トリアージ・コミットジャーナルは Android へ持ち込めません。これは iOS 単独リリースを選んだことの帰結として記録しておきます。移植時に参照できるよう、**ドメイン層の設計判断は本書に文章として残します**（6 節・7 節）。コードだけが仕様になる状態を避けます。

仕様書のドメイン要件（プラン、課金、プライバシー、エラー、性能、テスト条件）は、15 節に列挙する逸脱を除いて変更しません。

---

## 2. 確定した技術スタック

### 2.1 全体

| 領域 | 採用技術 |
| --- | --- |
| 言語 | Swift 6（strict concurrency） |
| UI | SwiftUI |
| 状態管理 | Observation（`@Observable`） |
| 非同期・排他 | Swift Concurrency（`actor`） |
| ローカル DB | **GRDB**（SQLite） |
| DI | イニシャライザ注入（フレームワーク不使用） |
| 課金 | RevenueCat iOS SDK |
| 広告 | Google Mobile Ads iOS SDK |
| クラッシュ解析 | Sentry Cocoa SDK |
| バックエンド | Rust + Axum（リモート設定と診断のみ） |
| 対応 OS | **iOS 26 以降** |

### 2.2 プラットフォーム API

| 用途 | 採用 API |
| --- | --- |
| 顔検出 | Vision（`DetectFaceRectanglesRequest`） |
| 写真選択 | PhotosPicker |
| カスタムスタンプの取り込み | `fileImporter`（UIDocumentPicker） |
| 画像読み込み・向き正規化 | Image I/O |
| エフェクト描画 | Core Image（`CIPixellate` / `CIGaussianBlur`） |
| スタンプのラスタライズ | Core Graphics（`ImageRenderer` ではなく `CGContext`。5.1.1） |
| エンコード・メタデータ除去 | Image I/O |
| 写真ライブラリ保存 | PhotoKit（`PHAssetCreationRequest`） |
| 署名鍵の保管 | Keychain（**鍵のみ**。データ本体は置かない） |
| 署名付きデータの保管 | アプリ専用ディレクトリ上のファイル（HMAC 付き、原子的置換） |
| 動画（次リリース） | AVFoundation / AVAssetWriter |

**鍵とデータ本体を分けます。** Keychain は台帳のような可変データを繰り返し置き換える用途に向きません。`UsageLedger` や `SubscriptionState` の本体はファイルへ置き、Keychain の鍵で HMAC を付けます。`CryptoKeyStore`（鍵）と `ProtectedBlobStore`（署名付きデータ）の 2 つのプロトコルに分けます（4 章）。

---

## 3. 技術選定の根拠

### 3.1 iOS 単独リリースが決めたこと

リリース対象が iOS のみである以上、**クロスプラットフォーム構成を採る理由がありません。**

v1.x で KMP + CMP を選んだ根拠は「ドメイン層とUI を二重実装しない」ことでした。実装対象が 1 プラットフォームなら、共有すべき相手が存在せず、抽象化のコストだけが残ります。

| 構成 | iOS 単独での評価 |
| --- | --- |
| **Swift + SwiftUI** | **採用。** 追加の抽象化層がなく、プラットフォーム機能を直接使える |
| KMP + CMP | 不採用。共有相手がいないのに Kotlin ツールチェーンと Swift 相互運用の複雑さを負う |
| Flutter | 不採用。同上。加えて Vision / Core Image / PhotoKit をすべてブリッジ経由にする必要がある |

### 3.2 SwiftUI を採る理由

**UIKit ではなく SwiftUI を採ります。**

- **iOS 26 を最低対応にできるため、SwiftUI の機能不足を回避策で埋める必要がありません。** 過去に SwiftUI 採用を妨げていた要因（リスト性能、ナビゲーション制御、テキスト編集）はいずれも解消済みです
- 本アプリの主画面（顔レビュー、エフェクト調整）は `Canvas` による自前描画が主体です。この部分は UIKit でも SwiftUI でも実装量が変わりません
- 設定・履歴・Paywall は宣言的に書けるほうが短く、状態の取り違えが起きにくくなります

**`Canvas` と `UIViewRepresentable` の使い分け**を先に決めます。

| 用途 | 実装 |
| --- | --- |
| 顔の枠、ハンドル、選択状態の描画 | SwiftUI `Canvas` |
| プレビュー画像の表示 | SwiftUI `Image`（低解像度 `CGImage`） |
| ピンチ・ドラッグによる領域編集 | SwiftUI ジェスチャ |
| 原寸書き出しの描画 | Core Image（UI を経由しない。5.1） |

**`UIViewRepresentable` / `UIViewControllerRepresentable` を使うのは広告バナーと共有シートだけ**とします。Google Mobile Ads の `BannerView` に SwiftUI 版が無いこと、`ShareLink` が共有結果を返せないこと（7.4.2）が理由です。

### 3.3 GRDB を採る理由

**SwiftData ではなく GRDB を採ります。**

本設計の中核はコミットジャーナル（7.4.3）であり、次を要求します。

- **明示的なトランザクション境界。** 手順 7 は「`OutputRecord` の insert」「`ExportRecord` の insert」「キュー状態の更新」「`Project` の更新」「`ExportCommit` の delete」を**単一トランザクション**で実行します
- **原子性の検証可能性。** プロセス強制終了テスト（12.1.4）で、トランザクションが途中適用されないことを確認します
- **ヘッドレス実行。** ドメインに近い層のテストを、シミュレータ起動なしで走らせます

SwiftData の `ModelContext` は保存タイミングが暗黙的で、上記の 3 点をいずれも保証しにくい構造です。GRDB は `try dbQueue.write { db in ... }` が SQLite のトランザクションそのものであり、境界が明確です。

| 観点 | GRDB | SwiftData |
| --- | --- | --- |
| トランザクション境界 | **明示的** | 暗黙的（`ModelContext` の保存に依存） |
| 原子性の保証 | SQLite に一致 | 実装依存 |
| テストの実行環境 | インメモリ DB で完結 | シミュレータが必要になりやすい |
| マイグレーション | `DatabaseMigrator` で明示 | スキーマ推論に依存 |
| 型安全なクエリ | あり | あり |

**SwiftData を採らないのは、機能不足ではなく制御の粒度の問題です。** 通常の CRUD アプリなら SwiftData で十分ですが、本設計は「どの順序で何が永続化されたか」に挙動が依存します。

### 3.4 選定時に確認した外部事実

- iOS 26 は 2025 年秋のメジャーリリース
- **iOS 26 は技術的な必須条件ではありません。** Swift 専用の Vision API（`DetectFaceRectanglesRequest`）は iOS 18 から、`Observation` は iOS 17 から利用できます。したがって「新 API を使うために 26 が必要」という説明は誤りです
- 26 を下限とするのは、**古い OS への対応コストを負わず、最新の UI と API だけを対象にするという商品・開発上の判断**です。分岐と回避策を書かない分、実装量とテスト対象が減ります
- Vision の `DetectFaceRectanglesRequest` は Swift Concurrency に対応した新 API。`VNDetectFaceRectanglesRequest`（旧 API）と併存する
- RevenueCat iOS SDK は StoreKit 2 に対応済み
- Sentry Cocoa SDK はメジャーバージョン到達済み。v1.x で懸念していた「KMP SDK がメジャー前」という問題は消える
- GRDB は SQLite の薄いラッパーであり、SQLite 自体の原子性保証をそのまま利用できる

### 3.5 iOS 単独リリースに伴い受け入れるリスク

| リスク | 内容 | 緩和策 |
| --- | --- | --- |
| Android 展開時の再実装 | ドメイン層を Swift で書くため、移植は書き直しになる | ドメインの判断を本書に文章として残す（1.2）。コードのみが仕様になる状態を避ける |
| 市場の半分を取り逃す | Android 利用者へ届かない | v1 の検証を優先する経営判断として受け入れる。15 節に逸脱として記録 |
| iOS 26 未満の端末を切る | 対応 OS が新しく、初期の到達範囲が狭い | 2026 年時点で iOS 26 の普及率は十分に高い。古い OS のための回避策コストを負わない |

**逆に、iOS 単独にしたことで解消した制約があります。**

| v1.x の制約 | v2.0 での扱い |
| --- | --- |
| 検出信頼度を使えない（ML Kit に API が無い） | **`FaceObservation.confidence` を使える。** 仕様 8.1 どおり `lowConfidence` をトリアージ理由へ戻す（5.7.1 / 6.5.2） |
| ぼかしを OpenGL ES 2.0 のシェーダで自作 | Core Image の `CIGaussianBlur` を使う |
| 両 OS の座標系・角度の差を吸収する契約テスト | 不要。Vision の座標系のみを扱う |
| 広告 SDK の自前ラップ | 不要。iOS SDK を直接使う |

---

## 4. モジュール構成

Swift Package Manager のローカルパッケージとして層を分け、**モジュール境界をコンパイラに強制させます。** 1 つのターゲットへ全部を入れると、依存の向きが規約でしか守られません。

```
kaokakushi/
├── Kaokakushi.xcodeproj
├── App/                     アプリ本体
│   ├── KaokakushiApp.swift  エントリポイント、DI の組み立て
│   ├── Navigation/          Route と画面解決
│   ├── Screens/             SwiftUI の各画面
│   └── PrivacyShield/       スクリーンショット対策（7.7）
│
├── Packages/
│   ├── Domain/              純粋 Swift。Foundation 以外に依存しない
│   ├── Application/         書き出し Saga、起動時復旧、ロールバック（4.4）
│   ├── Rendering/           StampRasterizer 実装（Core Graphics）
│   ├── Persistence/         GRDB、ファイル管理、ProtectedBlobStore
│   │   └── Security/        CryptoKeyStore（Keychain。HMAC 鍵のみ）
│   ├── MediaKit/            Vision / Image I/O / Core Image / PhotoKit
│   ├── Billing/             RevenueCat ラッパと権限解決
│   ├── Ads/                 AdPresenter（Google Mobile Ads）
│   └── Analytics/           イベント定義と送信
│
├── server/                  Rust + Axum（リモート設定と診断のみ）
│
└── ui-mock/                 Next.js による UI モック（参照専用。実装には流用しない）
```

### 4.1 依存の向き

依存は次の一方向とします。

```
実行時の依存:

  App ──→ Application ──→ Domain
                            ↑
  Persistence / MediaKit / Rendering / Billing / Ads / Analytics
  （Domain のプロトコルを実装する）

Composition Root（DI の組み立て）:

  App ──→ Application
   └────→ Persistence / MediaKit / Rendering / Billing / Ads / Analytics
```

`Domain` がプロトコルを定義し、各アダプタがそれを実装します。`Application` は `Domain` のプロトコルだけを通してアダプタを操作します。

**`App` は具象アダプタへ依存します。** DI を組み立てる Composition Root が具象を生成して `Application` へ注入する以上、`App` からアダプタへの依存は避けられません。「`App → Application → Domain` の一直線」だけを書くと、Composition Root が具象へ到達できない図になります。

この依存は**組み立て時に限ります。** `App` の `View` や状態オブジェクトがアダプタを直接呼ぶことは禁止します。呼び先は `Application` の Coordinator だけです。

**例外は 2 つの境界サービスだけです。** `PhotoSelectionBridge` と `FileSelectionBridge` は、ピッカーの結果を境界を越えられる型へ変換するために `ManagedFileStore` を直接使います（5.4）。ピッカーは SwiftUI の modifier であり `Domain` のプロトコルにできないため、この変換をどこかで行う必要があります。

| 規則 | 内容 |
| --- | --- |
| 例外の範囲 | **この 2 つの型のみ。** `View` は bridge を呼び、`ManagedFileStore` には触れない |
| 使ってよいアダプタ | `ManagedFileStore` のみ。ほかのアダプタは呼べない |
| CI のチェック | `App/Sources` 配下で `ManagedFileStore` を参照するファイルを、この 2 つに限定する |

**「例外なし」と書いて実装で破るより、範囲を型名で固定します。** 検査対象が 2 ファイルなら、レビューでも CI でも確認できます。

**`Domain` は `Foundation` 以外に依存しません。**

| 使ってよい | 使わない |
| --- | --- |
| `Foundation`（`Date`、`Data`、`UUID`、`Calendar`、`TimeZone`） | `SwiftUI`（`CGSize`、`Color`、`Angle` 等を含む） |
| Swift 標準ライブラリ | `UIKit` / `CoreGraphics` / `CoreImage` |
| | `GRDB` |

**`CGSize` や `CGRect` も使いません。** 必要な値型は `PixelSize` / `PixelRect` / `NormalizedRect` としてドメイン側で定義します（5.2）。`CoreGraphics` の型を持ち込むと、暗黙に「原点は左下か左上か」といった描画系の前提が混入します。ドメインは 5.2.1 の規約だけに従います。

**`Package.swift` の依存関係では強制できません。** Apple SDK のシステムモジュール（`SwiftUI`、`UIKit`、`CoreGraphics`、`CoreImage`）は、ターゲットの `dependencies` に列挙しなくても `import` できます。`dependencies` が空でもコンパイルは通ります。

**CI で禁止します。**

| 手段 | 内容 |
| --- | --- |
| SwiftLint の `forbidden_imports` | `Domain/Sources/**` に対し `SwiftUI` / `UIKit` / `CoreGraphics` / `CoreImage` / `GRDB` / `Vision` / `Photos` を禁止 |
| CI のチェック | `Domain/Sources` 配下の `import` 行を走査し、許可リスト（`Foundation` のみ）以外を検出したら失敗させる |

補助として SwiftSyntax ベースの Build Tool Plugin も選べますが、v1 では lint と CI の 2 段で足ります。**「規約なので守る」ではなく、機械的に落ちる形にすることが要件です。**

`Application` にも同じ制約を課します。**`Application` は `SwiftUI` / `GRDB` / `Vision` / `CoreImage` / `Security`（Keychain）を直接 `import` しません**（4.4）。

この制約により、仕様書 30.1 が要求する単体テスト項目がすべてシミュレータなしで実行できます（12.1.1）。

### 4.2 ナビゲーション

画面は `Route` の enum で表現し、`Route` から `View` への解決を 1 箇所の `switch` に集約します。`NavigationStack` の `path` を `[Route]` として `@Observable` な状態オブジェクトが所有します。

**画面遷移をドメインの状態から導出しません。** 「未保存出力があるときは新規加工を開始できない」（6.2.2.3）のような規則はドメインが判定し、UI はその結果を表示するだけです。遷移可否の判断を `View` の中へ書きません。

### 4.3 並行性の方針

Swift 6 の strict concurrency を有効にします。

| 対象 | 隔離 |
| --- | --- |
| `Domain` の値型 | `Sendable`。判定関数はすべて純粋関数 |
| `UsageLedgerStore` | `Domain` は**プロトコル**。実装は待機キューを持つ `actor`（7.4.3） |
| `ExportStartGate` | 同上 |
| `Application` の Coordinator | `actor` |
| `SharePresenter` / `AdPresenter` | **`@MainActor`**（UIKit を操作する。5.4） |
| UI の状態オブジェクト | `@MainActor` |
| `MediaKit` の重い処理 | `nonisolated` な `async` 関数。呼び出し側が並行度を制御する |

**`actor` にするだけでは排他区間を保持できません。** Swift の actor は再入可能で、`await` の中断点で別の呼び出しが入れます。本設計が要求するのは「読み取りから保存完了まで他を進めない」ことなので、実装 actor の内部に**明示的な待機キュー**を持たせます。詳細と規則は 7.4.3 に定義します。

### 4.4 Application 層

**書き出し Saga を所有する層を独立させます。**

次の処理は `Domain`（純粋 Swift）にも `App`（SwiftUI）にも置けません。

- 書き出しの手順 −2〜7（7.4.3）
- 補償トランザクション
- 起動時復旧
- ロールバック
- DB・台帳・ファイルの協調
- ゲートの取得と解放
- 出力の受け渡し（保存・共有）

`App` の `View` や状態オブジェクトへ置くと、**UI 状態と永続化 Saga が結合します。** 画面を離れたら復旧処理が止まる、といった経路ができます。`Domain` へ置くと、副作用と `await` が入って純粋 Swift の制約が壊れます。

```swift
// Application — Domain のプロトコルだけを使う
actor ExportCoordinator { }           // 手順 −2〜7、ロールバック
actor StartupRecoveryCoordinator { }  // 起動時復旧（7.4.3 の起動順序）
actor OutputDeliveryCoordinator { }   // MediaSaver / SharePresenter の呼び出しと状態遷移
```

**`Application` が直接 `import` してはいけないもの**を明示します。

| 禁止 | 代わりに使う |
| --- | --- |
| `SwiftUI` / `UIKit` | UI は知らない。保護データの利用可否は `Domain` の `ProtectedDataAvailability`（7.3.3） |
| `GRDB` | `Domain` の永続化プロトコル |
| `Vision` / `CoreImage` / `Photos` | `Domain` の `FaceDetector` / `ImageEffectRenderer` / `MediaSaver` |
| `Security`（Keychain） | `Domain` の `CryptoKeyStore` |

この制約により、**12.1.2 の saga テストが偽実装だけで完結します。** `Application` が具象を知らないため、各中断点の検証にシミュレータが不要になります。

---

## 5. プラットフォーム境界の設計

### 5.1 基本方針

**エフェクトの数学をすべて `Domain` に置き、`MediaKit` には描画プリミティブのみを残します。**

iOS 単独になっても、この分離は維持します。理由は OS 間の差を吸収するためではなく、**エフェクトの計算をシミュレータなしでテストできる状態に保つため**です（12.1.1）。Core Image を呼び出す層に強度計算が混ざると、そのテストには実機が要ります。

```
MediaKit   Vision で顔検出 → 正規化座標の矩形群 + 頭部回転角 + 信頼度 + 小顔フラグ（5.7.1）
    ↓
Domain     拡張率適用（上 25% / 下 15% / 左右 15%）
           形状決定（楕円 / 円 / 矩形 / 角丸）
           切り抜きと背景処理の決定
           → RenderSpec（正規化座標・相対強度のまま）
    ↓
Domain     compileRenderDraft(spec, sourceSize, targetSize)
           相対強度 → 絶対ピクセル値へ換算
           正規化座標 → 元画像ピクセル / 出力キャンバス基準へ変換
           → RenderDraft（stampKeys の rasterSize 算出済み）
    ↓
Rendering  StampRasterizer でスタンプ画像をビットマップ化
           → RasterizedStampAsset（実体つき）を得る
    ↓
Domain     bindRasterAssets(draft, assets) → RenderPlan
    ↓
MediaKit   RenderPlan を受け取り、4 プリミティブのみ実行
           ①マスク内モザイク ②マスク内ぼかし ③単色塗り ④画像貼り付け
```

顔領域の位置と大きさは、`RenderSpec` の段階では 0〜1 の正規化座標で保持します（仕様 19.3 と一致）。**永続化するのは `RenderSpec` 側の値だけ**で、ピクセル座標は保存しません。これにより、同じ設定を解像度の異なる出力（プレビューと原寸）へ一貫して適用できます。

#### 5.1.1 スタンプのラスタライズをドメインへ置かない

**ラスタライズは Core Graphics を使うため、`Domain` の責務にできません。** 4.1 の「`Domain` は `CoreGraphics` に依存しない」と直接矛盾します。

**`ImageRenderer`（SwiftUI）ではなく `CGContext` を使います。** `ImageRenderer` は `@MainActor` に隔離されており、一括処理 50 枚のラスタライズを直列化してしまいます。`CGContext` はバックグラウンドで実行でき、ピクセル形式とストライドも明示的に指定できます（5.1.2 の規約に必要）。

**幾何情報は `RenderRegion` だけに持たせます。** ラスタライズ側にも `bounds` / `rotationDegrees` / `opacity` を持たせると、ラスタライズ時と描画時に**二重適用**されます。`StampRasterizer` は「スタンプ画像そのものを、指定ピクセルサイズで作る」ことだけを行います。

```swift
// Domain — Foundation のみ
// 要求の同一性は StampRasterKey（source と rasterSize の組、5.2）で表す

// Domain がプロトコルを定義し、Rendering が実装する
protocol StampRasterizer: Sendable {
    /// 1 回の render セッションに必要なラスタを一括で作る
    func rasterize(
        _ keys: Set<StampRasterKey>
    ) async throws -> [StampRasterKey: RasterizedStampAsset]
}
```

**1 件ずつ受け取る形にしません。** 「同じ `StampRasterKey` は 1 回だけラスタライズする」「同じ `bitmapID` を再利用する」「`bitmapID` は 1 回の `render` 内で一意」（5.1.2）という 3 つの規約は、**誰が重複排除し、誰が `bitmapID` を採番するのか**が決まって初めて実装できます。1 件ずつの API では、呼び出し元が自前でキャッシュを持つか、実装側がグローバルなキャッシュを持つかのどちらかになり、後者は並列レンダリング時に他方の解放と競合します。

`Set<StampRasterKey>` を 1 回渡す形にすると、次がすべて型で決まります。

| 責務 | 担当 |
| --- | --- |
| 重複排除 | `Set` の型そのもの（`compileRenderDraft` が構築する） |
| `bitmapID` の採番 | `StampRasterizer` の実装。1 回の呼び出し内で一意な値を振る |
| 実体の寿命 | 1 回の `render` セッション。**グローバルキャッシュを持たない** |
| 戻り値の完全性 | 与えた `keys` の全要素に対応する値を返す。1 件でも欠ければ `throw` |

戻り値が `keys` を覆っているかは `bindRasterAssets` が再度検証します（5.2）。ラスタライザ側の実装ミスで欠けた場合も、`RenderPlan` は生成されません。

`StampRasterizer` が**行わないこと**を明示します。

| 項目 | 適用場所 |
| --- | --- |
| 画面上の位置 | `RenderRegion.bounds` |
| 回転 | `RenderRegion.rotationDegrees` |
| 不透明度 | `RenderOp.stamp.opacity` |
| 顔領域の形状 | `RenderRegion.shape` |

いずれも `RenderPlan` 側で**1 回だけ**適用します。

`RenderOp.stamp(bitmapID:)` を組み立てる順序は次のとおりです（5.2 の二段階コンパイル）。

1. `Domain` が `compileRenderDraft` で寸法を確定し、`Set<StampRasterKey>` を得る
2. `Rendering` が `StampRasterizer` で一括ラスタライズし、`[StampRasterKey: RasterizedStampAsset]` を得る
3. `Domain` が `bindRasterAssets` で `RenderPlan` を生成する

`Domain` はプロトコルを定義するだけで、実装を持ちません。4.1 の依存の向きと一致します。

スタンプをベクターで自作する方針の利点は変わりません。`MediaKit` は「画像を貼る」1 プリミティブで全スタンプを処理でき、スタンプの種類が増えても描画コードは増えません。

#### 5.1.2 ラスタ画像の受け渡し契約

**ID とサイズだけでは、モジュール境界を越えて実体へ到達できません。** `CGImage` を `Domain` の型へ入れることはできないため、**実体を指す形式**を定めます。

```swift
struct RasterizedStampAsset: Sendable {
    let bitmapID: String
    let rasterFile: ManagedFileRef   // kind は .rasterTemporary（7.3.4）
    let pixelSize: PixelSize
    let rowBytes: Int
}

protocol ImageEffectRenderer: Sendable {
    func render(
        source: ImageSource,
        plan: RenderPlan,
        rasterAssets: [String: RasterizedStampAsset]   // bitmapID → 実体
    ) async throws -> RenderedImage
}
```

**実体はファイル経由で渡します。** `Data` を直接持たせる方式も成立しますが、Pro の 1 バッチ 50 枚では、原寸スタンプのビットマップを複数枚同時にメモリへ載せることになります。専用ディレクトリの一時ファイルにすれば、`CGDataProvider(url:)` でメモリマップして読めます。`ManagedFileRef` と同じく ID からパスを解決し、パス文字列は渡しません（7.3.4）。`kind` は `.rasterTemporary` です。

##### ラスタファイルの形式

**「RGBA8888」だけでは実装が一意に定まりません。** 次まで固定します。

| 項目 | 規約 |
| --- | --- |
| 構造 | **ヘッダなしの raw bytes** |
| 行の順序 | **上から下** |
| 各行の順序 | **左から右** |
| チャネル順 | **R, G, B, A** |
| ファイルサイズ | **`rowBytes * height` に厳密に一致する** |
| `rowBytes` | **`>= width * 4`**（アライメントのため大きくてよい） |
| 行末パディング | **ゼロ初期化する** |
| アルファ | **straight alpha**。Core Graphics は premultiplied で描画するため、**保存前に straight へ変換する** |
| 色空間 | sRGB（5.2.1） |

**パディングをゼロ初期化しないと、未初期化メモリの内容がファイルへ書かれます。** `CGContext` が確保するバッファは、行末のアライメント領域を初期化する保証がありません。ここに残ったバイト列が、一時ファイルとしてディスクへ落ちます。プライバシー保護を目的とするアプリで、由来不明のメモリ内容を永続化することは許容できません。`CGBitmapContextGetData` の全域を明示的にゼロ埋めしてから描画します。

**premultiplied → straight の変換を明示するのは、Core Graphics の既定が premultiplied だからです。** `CGImageAlphaInfo.premultipliedLast` のまま保存し、描画側で straight として扱うと、半透明のスタンプが暗くなります。

##### 寿命とスコープ

| 項目 | 規約 |
| --- | --- |
| ID スコープ | `bitmapID` は**1 回の `render` 呼び出し内でのみ**一意。呼び出しをまたいで同じ ID が別実体を指してよい |
| 寿命 | `render` の呼び出し開始から復帰までの間、`rasterAssets` の全要素が有効であること |
| 解放 | `render` の成功・失敗にかかわらず、復帰後に**呼び出し元が**一時ファイルを削除する。**解放は冪等**とし、二重解放と未解放の再解放をエラーにしない |
| 再利用 | 同じ `StampRasterKey`（`source` と `rasterSize` の組）に対しては同一の `bitmapID` を返し、1 回の `render` 内で複数の `RenderRegion` から参照してよい。重複排除は `Set<StampRasterKey>` が担い、採番は `StampRasterizer` が行う（5.1.1） |
| 未解決 ID | `plan` が参照する `bitmapID` が `rasterAssets` に無い場合は描画を開始せず、エラーを投げる（無視して描き飛ばさない）。`bindRasterAssets` が通っていれば起こりませんが、契約として残します |

**ID スコープを呼び出し内に閉じるのは、同時レンダリングのためです。** 一括処理は将来 2 並列になります（6.5.8）。グローバルなレジストリを共有すると、片方の完了時の解放がもう片方の参照中実体を消します。呼び出しごとに集合が閉じていれば、この競合が起きません。

**未解決 ID を無視しません。** スタンプが 1 つ欠けたまま書き出すと、顔が隠れていない出力が完成扱いになります。これは 6.1 の安全側の既定と同じ思想です。

再利用の単位を `StampRasterKey`（`source` と `rasterSize` の組）にするのは、同じスタンプでも顔の大きさが異なれば必要な解像度が変わるためです。1 枚に同じスタンプを 10 個置く場合、サイズが揃っていればラスタライズは 1 回で済みます。

異常終了で一時ファイルが残った場合は、起動時の孤児ファイル掃除で回収します（8.4.1）。

### 5.2 RenderSpec と RenderPlan

**記述（`RenderSpec`）とコンパイル済み命令（`RenderPlan`）を分けます。**

`RenderPlan` に `cellRatio` / `sigmaRatio` / `featherRatio` という**相対値**を残すと、Core Image を呼ぶ層が比率計算を持つことになります。エフェクトの数学を `Domain` に閉じる方針（5.1）と矛盾し、その計算のテストに実機が必要になります。

同時に、「低解像度プレビューと原寸書き出しで**同じ `RenderPlan`**を使う」という表現も成立しません。`canvasSize` が異なる以上、別物です。

```swift
struct PixelSize: Sendable, Hashable {   // ドメイン独自型。CGSize を使わない
    let width: Int
    let height: Int
}

/// 永続化・編集の対象。解像度に依存しない
struct RenderSpec: Sendable, Equatable {
    let sourceCrop: NormalizedRect       // 元画像のどこを切り出すか（出力比率の適用結果）
    let scaleMode: SourceScaleMode       // fit / fill
    let background: BackgroundSpec
    let regions: [RenderRegionSpec]
}

struct RenderRegionSpec: Sendable, Equatable {
    let bounds: NormalizedRect           // 拡張率適用済み。出力キャンバス基準（5.2.1）
    let rotationDegrees: RotationDegrees
    let shape: MaskShape                 // ellipse / circle / rectangle / rounded(cornerRatio)
    let featherRatio: FeatherRatio       // 領域短辺に対する比。0 を許す
    let origin: RegionOrigin             // auto / manual（描画順に使う）
    let op: RenderOpSpec
}

/// 組み込みスタンプとカスタムスタンプを文字列で混ぜない
enum StampSource: Sendable, Hashable {
    case builtIn(code: String)
    case custom(contentHash: String)
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

**一段階では依存が循環します。** `StampRasterKey.rasterSize` は、対象解像度における `RenderRegion` のピクセル寸法から決まります。その寸法を計算するのはコンパイル処理です。しかし `RenderPlan` の構築には `bitmapID` が要ります。

コンパイルを 2 つに分けます。

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
    let stampKeys: Set<StampRasterKey>        // rasterSize は算出済み。重複排除済み
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
    case stamp(key: StampRasterKey, opacity: EffectOpacity)   // ← ここが RenderOp との差
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

**`RenderRegionDraft` と `RenderOpDraft` を明示的に定義します。** これが無いと、`bindRasterAssets` が「どの領域のどの `StampRasterKey` へ、どの `bitmapID` を差し込むのか」を表現できません。`bindRasterAssets` は `RenderOpDraft.stamp(key:opacity:)` の `key` で `assets` を引き、`RenderOp.stamp(bitmapID:opacity:)` へ置換します。それ以外の `case` は値をそのまま移します。

処理の順序は次のとおりです。

1. `compileRenderDraft(spec:sourceSize:targetSize:)` で寸法を確定し、`stampKeys` を得る
2. `Rendering` が `stampKeys` を一括ラスタライズする
3. `bindRasterAssets(draft:assets:)` で `RenderPlan` を得る

`bindRasterAssets` は、`draft.stampKeys` に対応する `assets` が 1 件でも欠けていれば `throw` します。未解決のまま `RenderPlan` を作れません（5.1.2 の「未解決 ID を無視しない」を型で保証します）。

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

enum SourceScaleMode: Sendable { case fit, fill }

struct RenderRegion: Sendable {
    let bounds: PixelRect                // 出力キャンバス基準の絶対ピクセル
    let rotationDegrees: RotationDegrees
    let shape: MaskShape
    let featherPx: FeatherPx
    let order: Int                       // 描画順（5.2.1）
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

**プレビュー用と書き出し用は、同じ `RenderSpec` から別々の `RenderPlan` を生成します。** 相対値は `RenderSpec` にあるため、両者の見た目は一致します。ゴールデン画像テストが成立する根拠もここです。

##### 合成の契約

**`sourceCrop` と `sigma` だけでは合成が決まりません。** 元画像をキャンバスのどこへ、どの拡縮方式で置くか、背景ぼかしが**何をぼかすのか**が未定義だと、レンダラーが独自に決めることになります。

| 概念 | 保持する型 |
| --- | --- |
| 出力キャンバスの実サイズ | `RenderPlan.canvasSize` |
| 元画像のどこを使うか | `SourcePlacement.sourceRect`（**元画像基準の絶対ピクセル**） |
| キャンバス上のどこへ置くか | `SourcePlacement.destinationRect` |
| Fit か Fill か | `SourcePlacement.scaleMode` |
| 余白の埋め方 | `RenderPlan.background` |
| 背景ぼかしの**元範囲** | `BackgroundOp.blurFromSource` の `sourceRect`（**元画像基準の絶対ピクセル**） |
| 顔領域の位置 | `RenderRegion.bounds`（**出力キャンバス基準の絶対ピクセル**） |

##### `RenderPlan` に正規化座標を残さない

**`RenderPlan` は「コンパイル済み」を名乗る以上、正規化座標を 1 つも持ちません。**

`SourcePlacement.sourceRect` と `BackgroundOp.blurFromSource.sourceRect` を `NormalizedRect` のまま残すと、`MediaKit` が元画像のピクセル寸法を掛けて実座標を求めることになります。これは比率計算であり、「エフェクトの数学は `Domain` に閉じる」（5.1）に反します。丸め規則（本節「ピクセルへの丸め」）も `MediaKit` 側に重複します。

そのため `compileRenderDraft` は **`sourceSize` を受け取ります。** これが無ければ、元画像基準の正規化値をピクセルへ変換できません。`RenderSpec.sourceCrop` は解像度に依存しない記述として正規化のまま保持し、変換はコンパイル時に一度だけ行います。

| 型 | 座標 |
| --- | --- |
| `RenderSpec` の全フィールド | 正規化（解像度非依存） |
| `RenderDraft` / `RenderPlan` の全フィールド | **絶対ピクセル** |

`sourceSize` は `PickedPhotoLoader` が向きを正規化したあとの寸法です（5.2.1「`NormalizedRect`」）。EXIF 回転を適用する前の寸法を渡すと、縦横が入れ替わります。

`BackgroundOp.blur(sigmaPx:)` ではなく `blurFromSource` にしたのは、`sigma` だけでは「元画像全体をぼかすのか、切り抜き範囲をぼかすのか、どの倍率で敷くのか」が決まらないためです。一般的な用途では `sourceRect` に元画像全体を指定し、`Fill` でキャンバス全面へ拡大します。

`RenderRegion.bounds` の基準を**出力キャンバス**に確定します。元画像基準にすると、`MediaKit` が切り抜き変換を再実装することになり、「数学はドメイン」の方針に反します。`compileRenderDraft` が `sourcePlacement` を適用したあとの座標へ変換します。

##### `sourceCrop` の不変条件

顔の拡張領域（5.3）と違い、**`sourceCrop` が元画像の外へ出る理由はありません。**

- `width > 0` かつ `height > 0`
- `0.0 <= left`、`right <= 1.0`、`0.0 <= top`、`bottom <= 1.0`
- 違反は `compileRenderDraft` が `throw` する（クランプで黙って直さない）

黙ってクランプすると、比率計算の誤りが出力の見た目としてしか現れず、原因の特定が遅れます。

`PixelRect` の `rightExclusive` / `bottomExclusive` は名前で排他性を示します。`right` / `bottom` という名前だと、包含のつもりで実装される余地が残ります。

##### 何も隠さない `RenderOp` を作れないようにする

**生の `Double` / `Int` を受け取ると、安全上の no-op を表現できます。**

`isMasked == true` の顔に対して、次はいずれも「加工したことになっているが、実際には何も隠れていない」出力を作ります。

| 値 | 結果 |
| --- | --- |
| `opacity = 0` | 完全に透明な塗り・スタンプ |
| `sigmaRatio = 0` | ぼかしゼロ |
| `cellRatio = 0`（または `cellSizePx < 2`） | モザイクのセルが 1 ピクセル＝原画のまま |
| 幅または高さ 0 の `bounds` | 描画対象が無い |
| `NaN` / 無限大の座標 | 描画が未定義（レンダラーが黙って無視しうる） |
| 完全に透明なカスタムスタンプ画像 | 貼っても何も隠れない |

**検証済みの値型としてしか作れないようにし、モデルの側でも生の `Double` を持ちません。**

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

**`0.0...1.0` では 0 を通してしまいます。** 禁止すると書いた値を型が許すことになるため、下限を開区間にします。

##### 生の `Double` を残さない

型を用意しても、モデルが `Double` を持っていれば迂回できます。**`RenderOpSpec` と `RenderOp` の全フィールドを検証済み型へ置き換えます。**

```swift
enum RenderOpSpec: Sendable, Equatable {
    case mosaic(cellRatio: MosaicRatio)
    case blur(sigmaRatio: BlurRatio)
    case solid(color: VisibleColor, opacity: EffectOpacity)
    case stamp(source: StampSource, opacity: EffectOpacity)
}
```

検証する対象は次のとおりです。

| 型 | 条件 |
| --- | --- |
| `EffectOpacity` | 有限かつ **`0 < v <= 1`** |
| `MosaicRatio` / `BlurRatio` | 有限かつ **`0 < v <= 上限`** |
| `PixelSize` | `width > 0` かつ `height > 0` |
| `PixelRect` / `NormalizedRect` | すべて有限。`left < rightExclusive`、`top < bottomExclusive` |
| `CellSizePx` | **`>= 2`**（下記） |
| `SigmaPx` | **`> 0`** |
| `FeatherPx` | `>= 0`（0 は許容。境界をぼかさない指定） |
| `RotationDegrees` | 有限 |
| **`VisibleColor`** | **アルファが 0 より大きい** |
| カスタムスタンプ画像 | **最大アルファ値が 0 なら取り込み時に拒否する**（8.1） |

**`cellSizePx >= 1` では不足です。** セルが 1 ピクセルのモザイクは元画像と同じです。**最終セルサイズを最低 2px** とします。

**`VisibleColor` を分けるのは、`SrgbArgb8888` のアルファが 0 でも `solid` が成立してしまうためです。** 色のアルファと `EffectOpacity` の積が 0 より大きいことを、`compileRenderDraft` が併せて検証します。

`FeatherPx` だけ 0 を許すのは、境界のぼかしが匿名化の強度に影響しないためです。他は 0 が「隠していない」を意味します。

##### 検証を迂回できないようにする

**Swift は `struct` へ memberwise initializer を自動生成します。** `init(_:) throws` を書いても、同一モジュール内からは `EffectOpacity(value: 0)` で検証を飛ばせます。

- **検証前の initializer をモジュール外へ公開しない**（`internal` に留め、`public` は `throws` 版だけ）
- 同一モジュール内でも直接生成しない規約とし、lint で検出する
- **永続データのデコード時にも同じ検証を通す**（`Decodable` の `init(from:)` で `throws` 版を呼ぶ）

最後の項目が重要です。**DB を改変された場合、旧バージョンのデータを読む場合、バグで不正値が保存された場合のいずれからも no-op を作れない**必要があります。「UI で 0 を選べない」だけでは、これらを防げません。

##### 意図的に隠さない場合

**利用者が「この顔は隠さない」と選ぶ経路は別に存在します。**

`isMasked = false` にするか、`ReviewResolution.unmaskedExportConfirmed` を記録するか（6.5.4）のいずれかです。**no-op の `RenderOp` を作って迂回させません。**

`isMasked == true` の顔に no-op 相当の値が渡された場合、`compileRenderDraft` が `throw` します。UI 側でスライダーの下限を 0 にしない、といった表示上の対処だけに頼りません。

#### 5.2.1 座標・回転・色の共通規約

**数値の解釈を規約として固定します。** 未定義のままだと、`MediaKit` の実装者（将来の自分を含む）が独自に解釈し、ゴールデン画像テストの期待値が「たまたま今の実装が出す値」になります。規約を先に決め、テストはそれを検証する手段に留めます。

##### `NormalizedRect`

| 項目 | 規約 |
| --- | --- |
| 原点 | **向き正規化後**の画像の左上 |
| +X | 右方向 |
| +Y | **下方向** |
| `left` / `top` | 含む（inclusive） |
| `right` / `bottom` | **含まない（exclusive）** |

原点を「向き正規化後」と明記するのは、EXIF の回転を適用する前後で左上の位置が変わるためです。`PickedPhotoLoader` が向きを正規化したあとの画像が、すべての座標の基準です。

値域は**段階によって異なります。** 「0.0〜1.0」と「はみ出しを許容」を同じ型の規約として並べることはできません。

| 段階 | 値域 |
| --- | --- |
| `DetectedFace.bounds`（検出直後） | **0.0〜1.0 に収まる。** アダプタが保証する |
| `expand()` 適用後（5.3） | **負数および 1.0 超過を許容する。** クランプしない |
| `RenderPlan.regions[].bounds` | 出力キャンバス基準のピクセル。キャンバス外の値を含みうる |
| 最終的なクリップ | **レンダラーがキャンバス境界で行う** |

はみ出しをドメインで潰さない理由は 5.3 のとおりです。クランプすると顔が露出する方向へ倒れます。

##### ピクセルへの丸め

`compileRenderDraft` が正規化値をピクセルへ変換する規則を固定します。丸めが未定義だと、プレビューと原寸で 1 ピクセルずれ、ゴールデン画像テストが不安定になります。

| 値 | 丸め |
| --- | --- |
| `left` / `top` | **floor** |
| `right` / `bottom` | **ceil** |
| `featherPx` / `cellSizePx` / `sigmaPx` | 丸めない（`Double` のまま渡す） |

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
| 1（先） | `RegionOrigin.auto`（自動検出された顔） |
| 2（後） | `RegionOrigin.manual`（利用者が追加した手動領域） |

同一区分内は `RenderSpec.regions` の並び順を保ちます。

**手動領域を後に置くのは、利用者の明示的な指示を最終結果にするためです。** 自動検出の結果に不足があって手動で足した領域が、自動領域に上書きされては意味がありません。

`overlappingFaces` を正式なトリアージ理由として扱い、ゴールデンテストにも含める以上（6.5.2）、重なり順をテスト実装任せにはできません。

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

```swift
struct SrgbArgb8888: Sendable, Hashable {
    let value: UInt32    // 0xAARRGGBB
}
```

| 項目 | 規約 |
| --- | --- |
| 色空間 | sRGB |
| ビット配置 | `0xAARRGGBB` |
| アルファ | **straight alpha**（premultiplied ではない） |
| `opacity` の乗算 | **レンダラーが 1 回だけ**乗算する。ドメインは色へ焼き込まない |
| premultiplied への変換 | Core Image と Core Graphics が premultiplied を要求するため、**`MediaKit` / `Rendering` 側で**変換する |

`UInt32` を裸で使わず専用型にするのは、ビット配置の解釈を呼び出し側任せにしないためです。

`opacity` を「1 回だけ」と定めるのは、`SrgbArgb8888` のアルファと `RenderOp.solid` の `opacity` の両方があるためです。前者は色そのものの不透明度、後者はエフェクト全体の適用強度で、レンダラーが両方を掛け合わせます。ドメイン側で事前に畳み込みません。

##### `FaceDetector` の変換責務

**`MediaKit` は Vision の座標系と角度をこの規約へ変換してから `DetectedFace` を返します。**

**Vision は左下原点の正規化座標を返します。** 本設計は左上原点なので、Y 軸の反転が必要です。`VNImageRectForNormalizedRect` は `CGImage` の座標系（左下原点）を前提とするため、そのまま使うと上下が反転します。変換は `MediaKit` の責務であり、`Domain` へ持ち込みません。

同様に、`FaceObservation` の `yaw` / `pitch` / `roll` は `Measurement<UnitAngle>` です。度への変換と符号の向きを 5.7.1 の共通モデルへ揃えます。

##### `Domain` から Core Image への変換責務

**Vision → `Domain` の変換だけでは足りません。逆向きも必要です。**

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

あわせて次を定めます。

| 項目 | 規約 |
| --- | --- |
| 回転方向 | `Domain` は時計回り正。**Core Image は反時計回り正**なので符号を反転する |
| `extent` の原点 | 向き正規化後の `CIImage.extent` を **`(0, 0)` へ移す**（`transformed(by:)`）。原点が 0 でない `CIImage` は存在しうる |
| ぼかしの端 | `CIGaussianBlur` の**前に `CIAffineClamp` で端を伸ばし**、処理後にキャンバスの `extent` で `cropped(to:)` する |
| マスク | **同じ `makeCIRect` を通す。** マスクだけ別の変換を書かない |
| 出力 | エンコード時に**再度上下反転しない**（Image I/O は `CGImage` を受けるため、ここで整合する） |

**`CIAffineClamp` を省くと、画像端の顔のぼかしが薄くなります。** Core Image はキャンバス外を透明として扱うため、端の領域では透明とブレンドされて隠蔽が弱まります。仕様 9.5 の「平滑化によって顔が露出する場合は領域を拡張する」と同じ問題です。

**`extent` の原点を明示的に 0 へ移すのは、`cropped(to:)` の結果が原点を保つためです。** 途中で切り抜きを行うと以降の座標がずれます。

ゴールデン画像テストの素材へ次を追加します（12.1.3）。

- 画像**上端**だけに顔がある
- 画像**下端**だけに顔がある
- `extent` の原点が `(0, 0)` でない `CIImage`

上下の非対称性は、Y 軸反転の誤りが最も現れやすい形です。中央に顔がある素材では反転しても差が出ません。

エフェクト強度は **`RenderSpec` の段階で領域サイズに対する相対値** として保持します（仕様 11.1）。`compileRenderDraft` が対象解像度で絶対ピクセルへ換算するため、低解像度プレビューと原寸書き出しで見た目が一致し、ゴールデン画像テストが成立します。**`MediaKit` は比率計算を一切行いません。**

### 5.3 拡張率の適用

```swift
func expand(face: NormalizedRect, effect: EffectSetting) -> NormalizedRect
```

既定値は上 25% / 下 15% / 左右 15%（仕様 8.4）。スタンプはモザイクより大きめの拡張率を用います。

**画像外へはみ出す場合もクランプしません。** クランプすると顔が露出する方向へ倒れるためです。はみ出しはマスク描画側で処理します。これは仕様 9.5 の「平滑化によって顔が露出する場合は、領域を小さくするのではなく拡張する」と同じ思想です。

### 5.4 プラットフォームプロトコル（v1 = 写真のみ）

プロトコルとして切る理由は、**テストダブルを差し込む点**であり、12.1.2 の saga テストが成立する境界だからです。

##### `Domain` のプロトコル

`Application` から `async` 関数として呼べるものだけを置きます。

| プロトコル | 責務 | 実装モジュール | 使用 API |
| --- | --- | --- | --- |
| `PickedPhotoLoader` | **物質化済みファイル**の読み込み、向き正規化、検出用縮小、HEIC 対応 | `MediaKit` | Image I/O |
| `FaceDetector` | 顔検出。正規化座標で返す | `MediaKit` | Vision |
| `ImageEffectRenderer` | `RenderPlan` の 4 プリミティブ実行 | `MediaKit` | Core Image |
| `ImageEncoder` | JPEG / HEIC エンコード、メタデータ除去 | `MediaKit` | Image I/O |
| `MediaSaver` | 写真ライブラリ保存、登録日時の指定 | `MediaKit` | PhotoKit |
| `StampRasterizer` | スタンプのラスタライズ（5.1.1） | `Rendering` | Core Graphics |
| `CryptoKeyStore` | HMAC 鍵の生成と保持。**鍵のみ扱う** | `Persistence/Security` | Keychain |
| `ProtectedBlobStore` | 署名済み状態の原子的な読み書き | `Persistence` | 保護ファイル（原子的置換） |
| `ManagedFileStore` | 全ファイル生成の共通口（7.3.4） | `Persistence` | Foundation |
| `ProtectedDataAvailability` | 保護データの利用可否と復帰待ち（7.3.3） | `App` | `UIApplication` と 2 つの通知 |

##### `@MainActor` のプロトコル

UIKit のビューやコントローラを操作するため、**メインアクタへ隔離します。**

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

| プロトコル | 責務 | 実装モジュール | 使用 API |
| --- | --- | --- | --- |
| `SharePresenter` | 共有シートの提示と結果の返却 | `MediaKit` | `UIActivityViewController`（7.4.2） |
| `AdPresenter` | バナー・全画面広告 | `Ads` | Google Mobile Ads |

`OutputDeliveryCoordinator`（`actor`）から `await` して呼びます。`@MainActor` の型はアクタによって状態が保護されるため、`Sendable` として扱えます。

##### `App` が所有するもの

**ピッカーは `Domain` のプロトコルにできません。**

`PhotosPicker` は SwiftUI の `View`／modifier であり、`fileImporter` も modifier です。いずれも**画面上の `Binding` と提示状態**を必要とします。`Application` から呼ぶ非 UI サービスとして表現できません。

| 対象 | 所有者 | 備考 |
| --- | --- | --- |
| `PhotosPicker` の提示 | **`App`** | `PhotosPickerItem` は `App` の外へ出さない |
| `fileImporter` の提示 | **`App`** | 外部 `URL` は `App` の外へ出さない |
| `PrivacyShield` | `App` | `scenePhase` に紐づく（7.7） |

##### 選択の境界サービスは 2 つだけ

**`App` の `View` や状態オブジェクトが具象アダプタを直接呼ぶことは禁じています**（4.1）。しかし選択結果の物質化は、`App` から `Persistence` の `ManagedFileStore` を呼ぶ必要があります。この 2 つを両立させるには、例外を**サービス単位で**限定します。

```swift
// App — 境界サービス。View から呼べるのはこの 2 つだけ
@MainActor final class PhotoSelectionBridge { }   // PhotosPickerItem → PickedPhotoInput
@MainActor final class FileSelectionBridge { }    // security-scoped URL → ManagedFileRef
```

| 規則 | 内容 |
| --- | --- |
| `View` が呼べるもの | **この 2 サービスのみ。** `ManagedFileStore` を直接触らない |
| この 2 サービスの特権 | **`ManagedFileStore` を直接使ってよい**（4.1 の唯一の例外） |
| 出力する型 | `PickedPhotoInput` / `ManagedFileRef` のみ。`PhotosPickerItem` と外部 `URL` は外へ出さない |
| 置き場所 | `App`。`Application` からは見えない |

**`PickedFileImporter` を `Domain` のプロトコルから削除します。** 以前の版は「外部 `URL` は `App` の外へ出さない」と「`PickedFileImporter`（`MediaKit` 実装）がコピーする」を同時に書いており、両立しません。`MediaKit` が外部 `URL` を受け取る時点で、`URL` が `App` の外へ出ています。コピーは `FileSelectionBridge` が security-scoped access の区間内で行います。

**`PickedPhotoLoader` の責務も縮小します。** 選択結果の取得は行わず、**物質化済みファイルのデコード・向き正規化・検出用縮小**だけを担当します。入力は `ManagedFileRef` です。

##### `PhotoSelectionBridge`

**「`App` が選択し、`MediaKit` が読み込む」だけでは、その間を何が通るのかが決まりません。** `PhotosPickerItem` は PhotosUI の型なので `Domain` にも `Application` にも渡せません。

`App` 内に **`PhotoSelectionBridge`** を置き、そこで境界を越える型へ変換します。

```swift
// Domain — プラットフォーム非依存
struct PickedPhotoInput: Sendable {
    let importedFile: ManagedFileRef          // 7.3.4 で物質化済み
    let providerAssetIdentifier: String?      // 一時的にのみ保持。保存・ログ禁止
    let libraryCreationDate: Date?
    let representation: SourceRepresentation  // 6.2.4
}

protocol PickedPhotoLoader: Sendable {
    /// 物質化済みファイルを読み、向きを正規化して返す。選択そのものは扱わない
    func load(_ file: ManagedFileRef) async throws -> LoadedPhoto
}
```

処理順を固定します。

| 順 | 操作 | 実行場所 |
| --- | --- | --- |
| 1 | `PhotosPickerItem` を受け取る | `App` |
| 2 | `loadTransferable` を実行する | `App`（bridge） |
| 3 | **`Data` のまま保持せず、`ManagedFileStore` で処理用ファイルへ物質化する** | `App` → `Persistence` |
| 4 | `PhotosPickerItem` を破棄する | `App` |
| 5 | `PickedPhotoInput` だけを `Application` へ渡す | `App` → `Application` |
| 6 | `providerAssetIdentifier` を HMAC 化して `SourceIdentity` を作る | `Application` / `Persistence` |

**手順 3 が要点です。** 48 メガピクセルの画像を `Data` のまま抱えると、50 枚の一括処理でメモリが尽きます。物質化してから ID で参照します。

**`providerAssetIdentifier` は `PickedPhotoInput` の寿命の中でのみ使います。** ログへ出さず、永続化しません。ハッシュ化した値だけが台帳へ入ります（6.2.4）。

##### 処理用ファイルの寿命を DB で管理する

**`PickedPhotoInput` は一時値です。再起動後には残りません。** 一方 6.5.8 は「アプリ再起動後に未完了キューを復元する」と定めています。復元したキュー項目が参照する処理用ファイルを表す永続モデルが無ければ、**復元しても加工を再開できません。**

`runtime.db` に持たせます。

```swift
struct WorkingSourceRecord: Sendable {
    let projectID: ProjectID          // 6.9
    let sourceFile: ManagedFileRef    // kind は .processingTemporary
    let createdAt: Date
}
```

| 項目 | 規約 |
| --- | --- |
| 保存先 | `runtime.db`（バックアップ対象外。7.1） |
| 作成 | 手順 3 の物質化と**同一トランザクション**。ファイルを作って行を作らない経路を残さない |
| 参照 | キュー項目・編集中プロジェクトの元素材 |
| 削除 | プロジェクトの書き出し完了時、またはプロジェクト破棄時に `PendingFileDeletion` へ（7.5.1） |
| 起動時 | どのプロジェクトからも参照されない行を回収し、実体も削除する |
| 実体が欠けている | そのキュー項目を **`reselectionRequired`** へ遷移させる。エラーで止めない |

**保存先は `Library/Application Support/runtime/processing/` です**（7.3.1）。`tmp/` に置くと OS がいつでも削除でき、再起動のたびにキューの復元が失敗します。

`reselectionRequired` は、実体が失われた場合の逃げ道として残します。ディスク不足で OS がアプリ領域を削減した場合など、どこへ置いても消える可能性はゼロになりません。**その場合は該当項目だけを再選択対象とし、バッチ全体を失いません。**

`fileImporter` も同じ構造です。security-scoped access を開いている間に `ManagedFileStore` でアプリ領域へコピーし、`Application` へは**外部 `URL` ではなく `ManagedFileRef`** を渡します。

`CryptoKeyStore` と `ProtectedBlobStore` を `MediaKit` へ置きません。`MediaKit` は画像の入出力に閉じた責務であり、ここへ鍵と台帳の保管を混ぜると、写真処理のテストダブルが鍵ストアまで抱えることになります。

#### 5.4.1 ピッカー結果の取り扱い

##### `PhotosPicker`

**`itemIdentifier` は `Optional` です。** `photoLibrary` を指定せずに作成した `PhotosPicker` では `nil` になります。`providerAssetKeyHash`（6.2.4）を得るため、次の指定を必須とします。

```swift
.photosPicker(
    isPresented: $isPresented,
    selection: $selection,
    matching: .images,
    preferredItemEncoding: .current,   // 可能ならトランスコードを避ける
    photoLibrary: .shared()            // これが無いと itemIdentifier が nil になる
)
```

**それでも `itemIdentifier` は `Optional` として扱います。** 取得できない場合は `SourceIdentity.providerAssetKeyHash` を `nil` とし、`contentFingerprint` だけで判定します（6.2.4）。

`preferredItemEncoding: .current` は、**可能ならトランスコードを避ける**指定です。HEIC が JPEG へ変換される頻度が下がり、6.2.4 の `.transcoded` 経路が減ります。ただし保証ではないため、`SourceRepresentation` の記録は継続します。

##### `fileImporter`

**返される `URL` は security-scoped です。** 利用前にアクセスを開始し、処理後に必ず解放します。start と stop を均衡させないとカーネル資源をリークします。

```swift
let accessed = url.startAccessingSecurityScopedResource()
defer {
    if accessed {
        url.stopAccessingSecurityScopedResource()
    }
}
// この区間内でアプリ領域へコピーする
```

**外部の `URL` を永続保存しません。** `FileSelectionBridge` がこの区間内でアプリ専用領域へコピーし、以後は自前の `ManagedFileRef` で参照します（7.3.4）。ブックマークを保存して後から再アクセスする方式は採りません。カスタムスタンプは取り込み時点で複製すれば足りるためです（8.4）。

#### 5.4.2 写真ライブラリの読み取り権限

**`PhotosPicker` そのものは写真ライブラリの権限を必要としません。** 利用者が選んだ項目へのアクセスだけが許され、アプリはライブラリ全体を見られません。

一方、**`PHAsset.fetchAssets` で `creationDate` や永続的な素材参照を取得する処理には、明示的な PhotoKit 権限が必要です。** 以前の版は「`PhotosPicker` は権限なしで使う」「`PHAsset.creationDate` を取得する」「写真ライブラリへの参照を履歴へ保持する」を同時に前提としており、これは成立しません。

##### v1 の構成

**新規加工は権限を要求せずに開始できることを優先します。**

| 場面 | 権限 |
| --- | --- |
| 新規加工の開始 | **要求しない。** `PhotosPicker` だけで完結する |
| `providerAssetIdentifier` | `itemIdentifier` が得られる場合だけ使う。得られなければ `nil`（6.2.4） |
| 撮影日時 | **まず EXIF の `DateTimeOriginal` を使う**（7.6 の優先順位を変更） |
| 写真ライブラリへの保存 | `PHAssetCreationRequest`。**追加のみの権限**で足りる |
| **履歴から元素材を直接読み込む** | **この時点で PhotoKit の読み取り権限を要求する** |

**撮影日時の取得元は用途ごとに分けます。** 権限の有無で変わってよいのは、写真ライブラリへ保存する際の `creationDate` だけです。

| 用途 | 取得元 |
| --- | --- |
| クォータ用 `contentFingerprint`（6.2.4） | **EXIF の `DateTimeOriginal` のみ。** 無ければ `null` |
| 写真ライブラリ保存時の `creationDate`（7.6） | `PHAsset.creationDate`（権限がある場合のみ）→ EXIF → 設定しない |

前者を権限に依存させると、権限を得る前後で同じ写真の fingerprint が変わり、無料枠を二重に消費します（6.2.4）。

##### 履歴からの再編集

**権限が無い、または対象 asset が限定選択の範囲外なら、再選択を求めます。**

> この写真をもう一度編集するには、写真へのアクセスを許可するか、同じ写真を選び直してください。

7.2.2 の「元画像の完全コピーを永続保存しない」を維持する以上、再編集には元素材への再アクセスが要ります。ここで初めて権限を要求するのは、**権限を求めるタイミングと理由が利用者に伝わる**ためです。起動直後に理由なく求めると拒否されやすくなります。

**「常に直接再編集できること」を要件にする場合は、初回選択の後に読み取り権限を明示要求する構成へ変更します。** v1 では採りません。再編集の頻度が高くないと見込むためです。この判断は 16 節の未決事項とせず、リリース後の利用状況で見直します。

##### 再編集にはハッシュではなく平文の参照が要る

**`providerAssetKeyHash` から `PHAsset` は取得できません。** クォータ用の alias（6.2.4）は復元不能なハッシュであり、意図どおり `PHAsset.localIdentifier` へ戻せません。これしか保存していなければ、**履歴からの再編集は権限があっても実行できません。**

用途を分けて、機能用の参照を別に持ちます。

```swift
/// 再編集のための参照。クォータ用の SourceAlias とは別物
struct ProjectSourceLocator: Sendable, Equatable {
    /// PHAsset.localIdentifier。ファイル取り込み等で取得できない場合は nil
    let photoLibraryLocalIdentifier: String?
}
```

| 項目 | 規約 |
| --- | --- |
| 保存先 | **`user-data.db` の `Project` のみ** |
| バックアップ | 対象外（`user-data/` 配下。7.3.1） |
| ログ・分析・診断 | **一切出さない。** 分析イベントのフィールド型にしない（9.2） |
| `UsageLedger` への保存 | **しない。** クォータ側は `providerAssetKeyHash` のまま |
| `nil` の場合 | 再編集で再選択を求める（上記） |
| `Project` の削除 | 同じ行なので同時に消える |

**クォータ側を平文に戻しません。** 仕様 14.5 が制限しているのは「不正利用防止のための識別子収集」です。再編集は利用者自身が要求する機能であり、その実現に必要な最小の参照を、利用者のデータと同じ寿命・同じ保護で持つことは目的が異なります。**2 つを 1 つのフィールドへまとめないことが要点です。**

### 5.5 動画対応で追加するプロトコル（v2）

以下 4 つを **v1 の設計時点で定義**し、実装のみ v2 に回します。

| プロトコル | 責務 | 使用 API |
| --- | --- | --- |
| `VideoProbe` | 長さ、解像度、コーデック、回転、HDR 判定 | AVAsset |
| `VideoFrameSource` | 時刻指定のフレーム取得 | AVAssetReader |
| `PreviewRenderer` | エフェクト適用済みテクスチャ出力 | MTKView |
| `VideoExporter` | 書き出し | AVAssetWriter |

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

インタラクティブなプレビューも書き出しも、**同じ `ImageEffectRenderer`（Core Image）が処理します。** 違うのは `targetSize` だけです。

v1.x では「プレビューは Compose Canvas、書き出しはネイティブ」という二系統でしたが、iOS 単独ではその必要がありません。**描画経路を 1 本にできるため、プレビューと書き出しの乖離という問題自体が消えます。**

- プレビュー: `compileRenderDraft(spec:targetSize: 長辺 1,280 程度)` → `render` → `Image` で表示
- 書き出し: `compileRenderDraft(spec:targetSize: 原寸)` → `render` → `ImageEncoder`

これは仕様 8.3 の「検出用縮小画像を使い、書き出し時は元解像度へ適用する」と整合します。

**顔の枠・ハンドル・選択状態だけは SwiftUI `Canvas` が描きます。** これらは加工結果ではなく操作用のオーバーレイであり、書き出しには含まれません。

ゴールデン画像テストは、**同一の `RenderSpec` から生成したプレビュー用と原寸用の出力**を比較し、差分を許容誤差内に抑えます。解像度が異なる以上、`RenderPlan` そのものは別物です（5.2）。一致の根拠は `RenderSpec` の共通性と `compileRenderDraft` の決定性にあります。

### 5.7 顔検出の座標処理

仕様 8.3 の手順に従います。

1. 元画像の向き情報を正規化する
2. 検出用に長辺 1,920 ピクセル程度へ縮小する
3. `DetectFaceRectanglesRequest` を実行する
4. **`MediaKit` で正規化座標へ変換して返す**（Y 軸の反転を含む。5.2.1）
5. 以降、`Domain` は顔領域をピクセル座標として保持しない（出力サイズは `compileRenderDraft` 呼び出し時にのみ受け取る。5.1）

検出用画像上で顔の短辺が 24 ピクセル未満の検出結果には、顔単位のフラグ `isSmallFace` を立てます（仕様 8.5）。

#### 5.7.1 顔単位の共通モデル

`FaceDetector` が返す顔を、`Domain` 側の値型へ変換して渡します。Vision の型（`FaceObservation`）を `Domain` へ流しません。

```swift
struct DetectedFace: Sendable, Equatable {
    let faceTrackID: FaceTrackID  // 6.9
    let bounds: NormalizedRect    // 左上原点へ変換済み（5.2.1）
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
    faceTrackID: FaceTrackID(rawValue: observation.uuid.uuidString),
    bounds: convertBounds(observation.boundingBox),   // Y 軸反転（5.2.1）
    confidence: Double(observation.confidence),
    yawDegrees: observation.yaw.converted(to: .degrees).value,
    pitchDegrees: observation.pitch.converted(to: .degrees).value,
    rollDegrees: observation.roll.converted(to: .degrees).value,
    isSmallFace: isSmallFace
)
```

##### 新旧 Vision API を混在させない

**角度は非 Optional です。** 新しい `FaceObservation` の `yaw` / `pitch` / `roll` は `Measurement<UnitAngle>` であり、旧 `VNFaceObservation` の `NSNumber?` とは別物です。

以前の版は `DetectFaceRectanglesRequest` / `FaceObservation` を採用しながら、角度だけ旧 API の `NSNumber?` を前提に「`nil` の場合の扱い」を定義していました。**これは実装できません。** 新 API へ統一し、`nil` に関する規則をすべて削除します。

**Optional な角度が必要になった場合は、全体を旧 API（`VNDetectFaceRectanglesRequest` / `VNFaceObservation`）へ戻します。** 片方の API から片方の型だけを借りることはしません。

##### `confidence` を含める（v1.x からの変更）

**v1.x では `confidence` を除外していました。** Android の ML Kit に検出信頼度のアクセサが無く、片方の OS だけで判定すると警告の量が非対称になるためです。その代替として頭部回転角（`extremePose`）をトリアージ理由に据えていました。

**iOS 単独になったため、この制約は消えます。** `FaceObservation.confidence` を使えるので、仕様 8.1 が求める「検出信頼度を保持する」をそのまま実装します。逸脱 1 件が解消します（15 節）。

`extremePose` は削除しません。信頼度と頭部回転角は別の失敗を捉えます。

| 理由 | 捉える状況 |
| --- | --- |
| `lowConfidence` | 検出器自身が確信を持てていない。誤検出または見落としの近傍 |
| `extremePose` | 検出はできているが、横向き・上向きで**拡張率の既定値では隠しきれない**可能性がある |

##### `confidence` の意味を実素材で確認する

**Vision の `confidence` は、常に意味のある値とは限りません。** Apple は、`1.0` が「最高信頼度」を表す場合と、**その観測が `confidence` に意味を割り当てていない**場合の両方がありうると説明しています。常に `1.0` が返るリビジョンでは、閾値判定が無意味になります。

`lowConfidence` を有効にする前に、採用する `DetectFaceRectanglesRequest.Revision` について実素材で分布を確認します。**次を受入条件とします。**

- 値が実際に変動する（常に同一値ではない）
- 検出品質と一定の相関がある（目視で怪しい検出が低い値に偏る）
- 常に `1.0` ではない

**この条件を満たさない場合、`lowConfidence` をトリアージから外します。** 意味のない値で警告を出すと、警告の総量だけが増えて利用者が読まなくなり、本当に見るべき `smallFace` や `extremePose` まで流し読みされます。

確認は 12.2 の検出品質テストで行い、閾値は 16 節の未決事項として実素材の分布から決めます。

これらの顔単位の値と、`Domain` 側で計算する端接触・重なりが、6.5.2 の `triage` の入力になります。写真単位の `reviewRequired` と名前が重ならないよう、顔単位では `requiresReview` という名称を使いません。

---

## 6. ドメイン設計

### 6.1 顔の初期状態と安全側の既定

**検出された顔は、すべて加工対象の状態で初期化します。** これはドメインの不変条件とし、UI の慣習に委ねません。

```swift
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

```swift
struct YearMonth: Sendable, Hashable, Comparable {
    let year: Int
    let month: Int          // 1...12
}

struct UsageLedger: Sendable, Equatable {
    let period: YearMonth                        // 消費を計上している年月
    let consumedExportIDs: Set<ExportID>         // 計上済みの書き出し（6.9）
    let sourceRecords: [SourceRecord]            // 素材の正規 ID と alias（6.2.4）
    let grants: [GrantEntry]                     // 権利（6.2.4）
    let trialEntries: [TrialEntry]               // トライアル消費
    let trialReservations: [TrialReservation]    // 認可時の予約（6.5.6.1）
    let sourceLeases: [SourceLease]              // 認可中の書き出しによる参照（6.2.4）
    let lastObservedAt: Date                     // 後退させない基準時刻（6.2.2.5）
    let monthlyIntegrityLock: MonthlyIntegrityLock  // 破損修復による月間枠の封鎖（6.2.2.5）
    let lastTrustedMonth: YearMonth?             // 信頼できる時刻から導出した最新の年月
    let trialIntegrityLocked: Bool               // 破損修復によりトライアルを封じたか
}

extension UsageLedger {
    var consumed: Int { consumedExportIDs.count }

    func grant(forSourceID id: SourceID) -> GrantEntry? {
        grants.first { $0.sourceID == id }
    }
}
```

**`monthlyBlockedPeriod: YearMonth?` を `MonthlyIntegrityLock` へ置き換えます。** 端末年月との比較で解除する構造は、年月を作れる側が解除条件を作れることを意味します（6.2.2.5）。`lastTrustedMonth` は解除の根拠となる「信頼できる時刻から導出した年月」で、サーバーまたは RevenueCat から時刻を得たときにのみ前進します。

`SourceRecord` / `GrantEntry` / `TrialEntry` / `TrialReservation` の定義と、素材を `sourceID` で管理する理由は 6.2.4 に示します。

**各要素に `ownerExportID` を持たせます。** 7.4.3 のロールバックで「この書き出しが追加したもの」と「以前から存在したもの」を、**台帳そのものから**判別するためです。DB 側の記録だけに頼ると、台帳を書いた直後に落ちた場合に判別できません。

**消費を件数ではなく書き出し ID の集合で持ちます。** 単なる `Int` では、7.4.3 が要求する「同じ `exportID` の再適用を弾く」も「特定の書き出しの消費だけ取り消す」も実装できません。集合にすれば、再適用は自然に冪等になり、ロールバックは該当 ID の削除で済みます。

`grants` も同じ理由で、同一素材への追記が上書きにならないようにします。既存要素があれば `firstSuccessAt` を維持します（6.2.0）。

3 つを別々の `ProtectedBlobStore` 値として更新すると、片方だけ書けた状態が生じます。1 つの署名済みオブジェクトなら、置き換えは全部か無かです。

##### 判定

```swift
enum QuotaBlockReason: Sendable {
    case monthlyLimitReached      // 通常の月間上限
    case ledgerIntegrityFailure   // 台帳破損による当月封鎖（6.2.5）
}

enum QuotaDecision: Sendable, Equatable {
    case unlimited                                        // Standard / Pro
    case freeReexport                                     // 24 時間以内の再書き出し。消費しない
    case consume                                          // 1 消費する
    case blocked(reason: QuotaBlockReason, limit: Int?)
}

struct QuotaEvaluation: Sendable {
    let decision: QuotaDecision
    let updatedLedger: UsageLedger   // 時刻更新・月次更新・期限切れ grant の整理を含む
}

func evaluate(
    ledger: UsageLedger,
    access: SingleExportAccess,      // Plan ではない。6.3 が解決した能力を受け取る
    sourceID: SourceID,              // 6.2.4 で解決済み（6.9）
    usageNow: Date,                  // 6.2.2.5 で正規化済み。端末時刻を直接渡さない
    timeZone: TimeZone
) -> QuotaEvaluation
```

**判定結果だけでなく更新後の台帳も返します。** `QuotaDecision` しか返さないと、`lastObservedAt` の前進、月次更新、期限切れ `grant` の削除を永続化できません。

##### `Plan` を直接受け取らない

6.3 は「権限は `plan` と `status` から導出し、`plan` から直接導出しない」と定めています。特に `pending`（支払い保留）では有料機能を付与しません。

**`QuotaPolicy` が `Plan` を受け取ると、この規則を迂回します。** `plan = Standard` かつ `status = pending` でも `plan != Free` が成立し、`Unlimited` になります。

`EntitlementResolver` が確定した能力を渡します。

```swift
enum SingleExportAccess: Sendable {
    case metered      // 月間枠の対象
    case unlimited    // 月間枠の対象外
}

struct ResolvedCapabilities: Sendable, Equatable {
    let singleExportAccess: SingleExportAccess
    let canUsePremiumStamps: Bool
    let canUseCustomStamps: Bool
    let canUseProBatch: Bool      // 制限なしの一括処理
    let canUseBatchTrial: Bool    // クレジット消費による一括トライアル
    let shouldShowAds: Bool
}
```

`Plan` を参照してよいのは能力解決の内側だけです。`QuotaPolicy`、`AdFrequencyPolicy`、開始ゲート、一括処理の可否判定、既存作品の編集可否、UI の活性制御は、すべて `ResolvedCapabilities` を見ます。

##### 「確認できない」を型で表す

`ResolvedCapabilities` を必ず返す関数では、「購入状態を確認できない」を表現できません。`Metered` を返せば暗黙降格になり、`Unlimited` を返せば未検証で有料機能を付与します。

解決そのものを状態型にします。

```swift
enum CapabilityResolution: Sendable {
    case resolved(ResolvedCapabilities)
    case verificationRequired
}

func resolveCapabilities(_ state: SubscriptionCacheState) -> CapabilityResolution
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

1. `lastObservedAt` を `usageNow` へ前進させる
2. 期間更新と期限切れ `grant` の整理を適用する（6.2.3）
3. `access == Unlimited` なら `Unlimited`
4. **`monthlyIntegrityLock` が解除条件を満たしていなければ `Blocked(LedgerIntegrityFailure)`**（6.2.5）
5. `ledger.grant(forSourceID: sourceID)` があり `usageNow - it.firstSuccessAt < 24h` なら `FreeReexport`
6. `consumed >= limit` なら `Blocked(MonthlyLimitReached, limit)`
7. それ以外は `Consume`

**判定手順 4 を月間上限の判定より前に置きます。** 破損修復後は `consumedExportIDs` が空なので、上限判定だけでは通過してしまいます。（この番号は 7.4.3 のコミット手順とは無関係です）

**理由を型で分けるのは、文言が異なるためです。** 破損時に「今月の無料保存を使い切りました」と表示するのは事実に反します。

**有料プランで `Unlimited` を返す場合も、手順 1 と 2 は必ず実施してから返します。** 有料期間中に時刻更新と grant 整理を止めると、降格した瞬間に古い状態から判定が始まります。

#### 6.2.0 ExportGrant の作成規則

**`ExportGrant` は、書き出し時のプランにかかわらず作成します。**

| 動作 | 条件 |
| --- | --- |
| `grants` へ素材を追加する | 利用可能な出力の生成が正常に完了した時点＝コミット手順 7 の完了（7.4.3）。プランを問わない |
| `consumedExportIds` へ `exportID` を追加する | `QuotaDecision` が `Consume` のときだけ |
| `firstSuccessAt` を更新する | しない。同一素材の有効な grant があれば、そのまま維持する |

有料プランでの書き出し時に grant を作らないと、次の経路が破綻します。

1. Standard で写真 A を書き出す
2. 1 時間後に Free へ降格する
3. 写真 A を再書き出しする

grant がなければ `FreeReexport` にならず枠を 1 枚消費します。これは 6.7 の「降格した事実はクォータ判定に影響しない。判定に使うのは素材の同一性と経過時間だけ」と矛盾します。

`firstSuccessAt` を更新しないのは、再書き出しのたびに窓が延びると 24 時間の上限が意味を失うためです。

**この規則は「認可時に有効な grant があったか」ではなく「会計時に有効な grant があるか」で判断すると破れます。** 認可から会計までの間に窓が切れると、grant が存在しない状態として新規作成されるためです。`FreeMonthlyReexport` は認可時の `firstSuccessAt` を保存して維持します（7.4.3 の preserve）。

#### 6.2.1 消費の確定タイミング

**消費は「利用可能な加工済み出力の生成が正常に完了した時点」で確定します。** 写真ライブラリへの保存時点ではありません。

仕様 14.2 は消費条件を「書き出し処理が正常終了した」「出力ファイルが生成された」「**保存処理または共有可能な状態になった**」と定めています。写真ライブラリ保存を確定条件にすると、加工済み画像を生成して保存せずに OS 共有から他アプリへ渡す経路で無料枠を回避できてしまい、仕様の文言にも反します。

確定点は **7.4.3 のコミット手順 7 が完了した時点**とします。一時パスへの生成・サイズと SHA-256 の確認・デコード確認（7.4.1）を通過し、会計を台帳へ適用し、コミット行を削除して成果物を公開できる状態になった時点です。**写真ライブラリへの保存は含みません**（7.4.2）。その後の操作は追加消費しません。

手順 7 より前は成果物を公開せず、ロールバックが可能です（7.4.1 の「確定点は 1 つだけ」）。

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

```swift
enum OutputState: Sendable { case generated, delivered, discarded }
```

| 状態 | 意味 | 保持する期間 |
| --- | --- | --- |
| `Generated` | 生成済み。受け渡しは未成功 | 利用者が明示的に破棄するまで、または 24 時間経過するまで |
| `Delivered` | 保存または共有が 1 回以上成功した | **完了画面を離れるまで** |
| `Discarded` | 利用者が明示的に破棄した | 直ちに削除する |

**状態は写真ごとの出力レコードに保持します。バッチ単位では持ちません。**

一括処理では部分的な成功が起こるためです。32 枚のうち 20 枚を写真ライブラリへ保存し、12 枚が空き容量不足で保存できなかった状態でアプリが終了する、という場面が現実に生じます。バッチ全体に 1 つだけ状態を持つと、この状況を表現できません。

バッチの状態は、各 `OutputRecord`（型定義は 7.4.3）の状態から集計して導出します。

```swift
// バッチの未受け渡し枚数 = records.count { $0.batchID == id && $0.state == .generated }
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

```swift
struct TimeAnchor: Sendable { let lastObservedAt: Date }

struct ObservedTime: Sendable {
    let usageNow: Date        // 単調。クォータ・grant 用
    let retentionNow: Date?   // 非単調。削除・保持期間用。異常ジャンプ中は nil（下記）
    let updatedAnchor: TimeAnchor
}

func observeTime(now: Date, anchor: TimeAnchor, trusted: Date?) -> ObservedTime
```

`usageNow` は `max(now, anchor.lastObservedAt)` です。`retentionNow` の決め方は後述します（「単調時刻を削除判定へ使えない」）。**用途によって使い分けるため、以降は `effectiveNow` という総称を使わず、どちらかを名指しします。**

`now - firstSuccessAt < 24h` に端末時刻を直接使うと、**書き出し後に時計を 1 週間戻せば差が負になり、常に 24 時間未満と判定されます。** 時計が元の日時へ追いつくまで `FreeReexport` が残り続けます。

**アンカーは `UsageLedger.lastObservedAt` として保持します**（6.2）。型を分けているのは責務を示すためで、保存先は台帳と同一です。

6.2.3 では月次期間の後退を防いでいますが、24 時間の窓には同じ防御がありませんでした。基準時刻を 1 つに集約して両方へ適用します。

適用対象は以下です。

| 判定 | 使う時刻 |
| --- | --- |
| `ExportGrant` の 24 時間判定（6.2） | `usageNow` |
| 未受け渡し出力の 24 時間保持（6.2.2） | `retentionNow` |
| やり直しのための 24 時間保持保証（7.2.4） | `retentionNow` |
| 履歴の保存期間判定（7.2.3） | `retentionNow` |
| 月次期間の更新（6.2.3） | `usageNow` |
| `finalizedAt` の確定（7.4.3） | `usageNow` |

これをしないと、クォータだけでなく**未保存出力の削除期限まで端末時刻の変更で延長されます**。

**`Domain` の時間判定は `now` を引数に取りません。`usageNow` または `retentionNow` だけを受け取ります。** 端末時刻に触れてよいのは `observeTime` の呼び出し口 1 か所だけとし、それ以外へ `Date()` を渡さないことを規約とします。SwiftLint のカスタムルールで `Domain` ターゲット内の `Date()` を禁止します。

##### 未来への時計変更は防げない

**`max(now, lastObservedAt)` が防ぐのは、時計を過去へ戻して期限を延長する操作だけです。** 未来へ進める操作には無力です。

時計を進めると次が起こります。

| 影響 | 内容 |
| --- | --- |
| 月間枠 | 先の月へリセットされ、**枠を前倒しで取得できる** |
| 履歴・未受け渡し出力 | **即座に期限切れになる** |
| リモート設定 | 即座に失効する（11.3） |
| `lastObservedAt` | 未来の値で固定され、時計を戻しても元へ戻らない |

**枠の前倒し取得は脅威モデルの対象外とします。** 端末時計を進める操作を検出する手段が、サーバー照合なしには存在しません。得られる利益（月 5 枚の無料枠）に対して、対策のコストが見合いません（7.4.3 の HMAC 脅威モデルと同じ判断）。

**ただし、破壊的削除は保留します。** 大幅な未来ジャンプだけを根拠に、履歴や未受け渡し出力を削除しません。

| 状況 | 削除の扱い |
| --- | --- |
| 信頼できる時刻がある（サーバーまたは RevenueCat から最近取得した値） | **その値を上限として使う** |
| 信頼できる時刻が無く、`lastObservedAt` からの跳躍が大きい | **削除を保留する。** 次に信頼できる時刻を得るまで待つ |
| 通常の経過 | そのまま判定する |

「大幅な跳躍」の閾値は、**保持期間の最長（30 日）を超える前進**とします。

枠の前倒しは利用者に有利な方向であり、放置しても成果物は失われません。逆に削除は取り返しがつきません。**取り返しのつかない方向にだけ保守的に倒します。**

##### 単調時刻を削除判定へ使えない

**「利用者が時計を直せば通常の経過に戻る」は、単一の基準時刻では成立しません。**

`effectiveNow = max(now, lastObservedAt)` は単調です。一度 `lastObservedAt` が未来へ進めば、時計を正しい値へ戻しても `effectiveNow` は未来の値のままです。**削除は保留されず、そのまま実行されます。** 上の表が意図した「次に信頼できる時刻を得るまで待つ」が機能しません。

用途が相反するため、**基準時刻を 2 つに分けます。**

```swift
struct ObservedTime: Sendable {
    /// クォータ・grant 用。単調増加する。巻き戻し防止が目的
    let usageNow: Date

    /// 削除・保持期間用。信頼できる時刻を得られない異常ジャンプ中は nil
    let retentionNow: Date?

    let updatedAnchor: TimeAnchor
}
```

| 用途 | 使う時刻 | `nil` のときの挙動 |
| --- | --- | --- |
| `ExportGrant` の 24 時間判定 | `usageNow` | — |
| 月次期間の更新（6.2.3） | `usageNow` | — |
| `finalizedAt` の確定（7.4.3） | `usageNow` | — |
| 履歴の保存期間判定（7.2.3） | `retentionNow` | **削除しない** |
| 未受け渡し出力の 24 時間削除（6.2.2） | `retentionNow` | **削除しない**（表示は「期限を確認できません」） |
| やり直しの 24 時間保持保証（7.2.4） | `retentionNow` | **保持を続ける**（安全側） |

`retentionNow` の決め方です。

| 条件 | 値 |
| --- | --- |
| 信頼できる時刻がある（サーバーまたは RevenueCat から最近取得した値） | その値 |
| 端末時刻が `lastObservedAt` から 30 日を超えて前進している | **`nil`** |
| それ以外 | 端末時刻 |

**`retentionNow` に `max` を掛けません。** 単調にしないからこそ、時計を正しい値へ戻したときに通常の判定へ復帰します。巻き戻しによる保持期間の延長は、利用者に不利な方向ではないため許容します。

##### 整合性封鎖を端末時計で解除させない

**`monthlyBlockedPeriod` を「その時点の端末年月」として保存すると、時計操作で即座に解除できます。**

1. 時計を過去の月へ変更する
2. 台帳を破損させる
3. 過去月として修復され、`monthlyBlockedPeriod` にその月が入る
4. 時計を現在へ戻す
5. `monthlyBlockedPeriod != period` が成立し、**Free 枠がその場で再開する**

封鎖の解除条件を「年月が違うこと」にしている限り、年月を作れる側が解除条件を作れます。

**封鎖を型にします。**

```swift
enum MonthlyIntegrityLock: Sendable, Equatable {
    case none

    /// 指定した年月より後の「信頼できる年月」を観測するまで封鎖
    case lockedUntilTrustedMonthAfter(YearMonth)

    /// 端末時刻だけでは解除できない。再インストールを要する
    case lockedUntilReinstall
}
```

| 規則 | 内容 |
| --- | --- |
| 解除に使える年月 | **信頼できる時刻から導出した年月のみ**（サーバーまたは RevenueCat 由来） |
| 端末時刻由来の年月 | **解除に使わない。** 何度変更しても封鎖は解けない |
| 信頼できる時刻を一度も得られない | 封鎖は維持される。Free 枠は使えないが、有料利用者は影響を受けない |
| 破損が繰り返される | 2 回目以降は `lockedUntilReinstall` へ引き上げる |

**信頼できる時刻を得られないまま Free 枠が使えない状態は、意図した結果です。** 台帳の破損は通常の利用では起こりません。改ざんの疑いがある状態で、端末側の申告だけを根拠に枠を再開する経路を残しません。

有料利用者は `paidUnlimited` であり月間枠を参照しないため、この封鎖の影響を受けません（7.4.3 の勘定表）。**課金済みの利用者が締め出される経路は作りません。**

#### 6.2.3 月初リセットと時刻巻き戻し

仕様 14.4 の「端末時刻が過去へ戻された場合、最後に確認した年月より前へ戻さない」を、期間の単調増加を強制することで実現します。

**月初にリセットするのは `consumed` だけです。`grants` は月をまたいで保持します。**

```swift
func rollPeriod(
    _ ledger: UsageLedger,
    usageNow: Date,
    timeZone: TimeZone
) -> UsageLedger {
    let current = YearMonth(from: usageNow, in: timeZone)
    // 24時間を過ぎた権利だけを落とす。月の境界とは無関係
    let activeGrants = ledger.grants.filter {
        usageNow.timeIntervalSince($0.firstSuccessAt) < 24 * 3600
    }

    if current > ledger.period {
        // 期間が進んだ → consumed だけをリセット
        return ledger.with(period: current, consumedExportIDs: [], grants: activeGrants)
    } else {
        // 同一または過去 → 期間はリセットしない
        return ledger.with(grants: activeGrants)
    }
}
```

引数は `usageNow` です。`now` を直接受け取ると 6.2.2.5 の防御が抜けます。

`grants` を月初に空にすると、**7 月 31 日 23:59 に書き出して 8 月 1 日 00:01 に再書き出しした場合、2 分しか経っていないのに `FreeReexport` になりません。** 24 時間の窓は月の境界と無関係であり、両者を連動させる理由はありません。

タイムゾーンを西へ移動して月をまたぎ戻しても、端末時計を手動で戻しても、`period` は後退しません。

#### 6.2.4 同一素材の判定

仕様 14.3 は「新しいプロジェクトとして作り直しても、元素材識別子とローカルハッシュが一致すれば同一素材として扱う」と定めます。

##### 単一ハッシュでは足りない

`contentFingerprint` 1 本にすると、**OS が画像を変換した場合に同一素材と判定できません。**

PhotosPicker は、要求形式や iCloud の状態によって HEIC を JPEG へ変換して返します。変換後は先頭・末尾のバイト列が別物になるため、**同じ写真が別ハッシュになり、無料枠を二重に消費します。** これは 6.2.4 が掲げる「同一素材なのに二重消費する方向へ倒さない」に正面から反します。

`representation` をハッシュ入力へ含めない（後述）だけでは解決しません。含めなくても、バイト列そのものが異なるためです。

##### 複合 ID にする

素材の識別を、**2 つの独立した手掛かりの OR** とします。

```swift
struct SourceIdentity: Sendable, Hashable {
    /// 写真ライブラリの asset 識別値を端末内でハッシュ化したもの。
    /// 取得できない場合（ファイル取り込み等）は nil
    let providerAssetKeyHash: String?

    /// サイズ・先頭 64KB・末尾 64KB・撮影日時から算出（後述の正準化規則）
    let contentFingerprint: String
}

func isSameSource(_ a: SourceIdentity, _ b: SourceIdentity) -> Bool {
    if let ka = a.providerAssetKeyHash, let kb = b.providerAssetKeyHash, ka == kb {
        return true
    }
    return a.contentFingerprint == b.contentFingerprint
}
```

##### この OR 判定は同値関係ではない

**上の `isSameSource` を直接使ってはいけません。推移律が成立しません。**

```
A = (provider: P1, fingerprint: F1)
B = (provider: P1, fingerprint: F2)
C = (provider: nil, fingerprint: F2)

isSameSource(A, B) == true    // provider が一致
isSameSource(B, C) == true    // fingerprint が一致
isSameSource(A, C) == false   // どちらも一致しない
```

同値関係でない述語を同一性判定に使うと、次が起こります。

- 同じ素材の grant が複数作られる
- トライアルを二重消費する
- 配列内に「実質同じ素材」が複数残る
- `SourceIdentity: Hashable` の等価性と `isSameSource` が食い違う
- **`ExportStartGate` が同じ素材を別キーとして扱い、同時実行を許す**

最後の項目が最も深刻です。ゲートが `SourceIdentity` を直接キーにしている限り、7.4.3 の「同一素材は直列化する」を保証できません。

##### 正規 ID と alias で解決する

**素材へ正規 ID（`sourceID`）を割り当て、識別情報を alias として管理します。**

```swift
enum SourceAlias: Sendable, Hashable {
    case provider(String)   // providerAssetKeyHash
    case content(String)    // contentFingerprint
}

struct SourceID: Sendable, Hashable { let rawValue: UUID }   // 6.9

struct SourceRecord: Sendable, Equatable {
    let sourceID: SourceID
    var aliases: Set<SourceAlias>   // 空にしない（下記の不変条件 7）
}
```

素材を解決する手順です。

1. `provider` alias に一致する `SourceRecord` を探す
2. `content` alias に一致する `SourceRecord` を探す
3. 両方が見つかり、**別レコードを指していたら 1 件へ統合する**
4. 片方だけ見つかれば、そのレコードへ不足している alias を追加する
5. どちらも見つからなければ新しい `sourceID` を発行する

**以後、grant・トライアル台帳・予約・ゲートはすべて `sourceID` で管理します。** `sourceID` は `UUID` であり、等価性は通常の `==` です。推移律は自明に成立します。

##### 統合時の規則

**統合は安全側へ固定します。** 遭遇する頻度は低いものの、規則が無いと実装のたびに判断が変わります。

| 対象 | 統合結果 |
| --- | --- |
| `aliases` | 両者の和集合 |
| grant | **最も古い `firstSuccessAt` を維持する**（窓を延長しない。6.2.0） |
| トライアル台帳 | **どちらかが消費済みなら消費済み**（払い戻さない。6.5.6.1） |
| 予約 | 両方を統合する。**実行中の export が競合するなら、新規開始を止める** |
| **`sourceLeases`** | **`sourceID` を勝者へ書き換える。** 削除も統合もしない |
| `ownerExportID` | 維持したほうの値を残す |

**`sourceLeases` の規則を落とせません。** 統合は敗者側の `sourceID` を廃止しますが、lease はそれを参照したままになりえます。すると次が起こります。

- 起動時の孤児 lease 回収が「対応する `SourceRecord` が無い」lease を見つける
- 認可中の書き出しの lease が回収され、その `SourceRecord` が GC される
- 処理中の素材が消える

統合時に **`sourceID` を持つ全集合**を勝者へ書き換えます。**書き換え漏れを型で防げないため、一覧を規則として固定します。**

```
grants            の sourceID → 勝者
trialEntries      の sourceID → 勝者
trialReservations の sourceID → 勝者
sourceLeases      の sourceID → 勝者
```

書き換えの結果、同じ `sourceID` の要素が同じ集合に 2 件できる場合は、上の統合規則（grant は最古、トライアルは消費済み優先）で 1 件へ畳みます。`sourceLeases` は `exportID` が異なる限り併存して構いません（同時実行数の上限までしか存在しません）。

**v1 では、書き出し開始ゲートを素材単位ではなく全体で 1 件にしても構いません。** 同時並列数の初期値が 1 である以上（16 節）、素材ごとの粒度は実質使われません。統合が競合と重なる経路そのものを消せます。並列数を 2 へ上げる時点で `sourceID` 単位のゲートへ移行します。

##### `PHAsset.localIdentifier` の扱い

**平文で保存しません。** 仕様 14.5 は不正利用防止のための識別子収集を制限しています。端末内でソルト付きハッシュへ変換し、元の値を復元できない形で持ちます。**ソルトは台帳署名とは別の鍵から派生させます**（7.4.3 の鍵の用途分離）。

##### 台帳の保持形式

各集合は `sourceID` をキーにします。

```swift
struct GrantEntry: Sendable, Equatable {
    let sourceID: SourceID          // 6.9
    let firstSuccessAt: Date
    let ownerExportID: ExportID
}

struct TrialEntry: Sendable, Equatable {
    let sourceID: SourceID
    let ownerExportID: ExportID
}

struct TrialReservation: Sendable, Equatable {
    let sourceID: SourceID
    let exportID: ExportID
}

/// 認可中の書き出しが素材を参照していることを示す。SourceRecord の GC を防ぐ
struct SourceLease: Sendable, Equatable {
    let sourceID: SourceID
    let exportID: ExportID
}
```

`SourceRecord` の集合も `UsageLedger` に持ちます。alias の追加と統合が台帳更新と同一トランザクションで行われる必要があるためです。別の場所に置くと、統合の途中で落ちたときに alias と grant が食い違います。

##### `SourceRecord` の寿命

**削除規則が無いと alias が永久に蓄積します。** 有料利用者は grant の 24 時間が切れても書き出しを続けるため、処理した写真の数だけ `SourceRecord` が増え続けます。

一方、**単純に「未参照なら削除」もできません。** `paidUnlimited` の通常の単体書き出しには grant も予約もありません。認可から正常生成までの間、その素材を参照するものが台帳に存在しないため、**処理中の素材が GC されます。**

`SourceLease` で埋めます。

| 契機 | 操作 |
| --- | --- |
| 認可時（手順 −2） | `SourceLease(sourceID:exportID:)` を追加する。**勘定の種類を問わない** |
| 台帳への適用（手順 4）またはロールバック | 該当 `exportID` の lease を**台帳トランザクション内で**削除する |
| 起動時 | 対応するコミットが無い lease を回収する（起動順序の手順 3） |

**`SourceRecord` を削除してよいのは、次のすべてから参照されなくなったときだけです。**

- `grants`
- `trialEntries`
- `trialReservations`
- `sourceLeases`

削除は `rollPeriod`（6.2.3）で期限切れ grant を落とすのと同じタイミングで行います。grant の整理直後が、参照が最も減っている時点だからです。

**保守的台帳（6.2.5）では `sourceRecords` と `sourceLeases` も空にします。** 破損修復の表へ追加します。

**線形探索で構いません。** 各集合の要素数には上限があります。

| 集合 | 上限 |
| --- | --- |
| `sourceRecords` | 参照元がある素材のみ。上記の削除規則により有界 |
| `sourceLeases` | 同時実行数。v1 は 1 |
| `grants` | 24 時間以内に成功した書き出しの素材数。実用上は数件〜数十件 |
| `trialEntries` | `configuredCreditCount`（既定 5） |
| `trialReservations` | 同時実行数。v1 は 1、将来 2（6.5.8） |
| `consumedExportIDs` | 月間上限（既定 5） |

**不変条件です。** 台帳を保存する前と、読み込んで署名を検証した直後の両方で検査します。

| # | 条件 | 破れたときに起こること |
| --- | --- | --- |
| 1 | 同じ `SourceAlias` を 2 つの `SourceRecord` が持たない | 素材解決が 2 レコードを返し、統合が毎回走る |
| 2 | 同じ `sourceID` の要素を、同じ集合内に 2 件持たない | grant の窓が二重になる |
| 3 | `grants` / `trialEntries` / `trialReservations` の `sourceID` が `sourceRecords` に存在する | 参照先の無い権利が残る |
| 4 | **`sourceLeases` の `sourceID` が `sourceRecords` に存在する** | 認可中の素材が GC される（上記） |
| 5 | **`trialReservations` の各要素に、同じ `exportID` かつ同じ `sourceID` の `SourceLease` が存在する** | 予約だけが残り、素材が GC される |
| 6 | **同じ `sourceID` が `trialEntries` と `trialReservations` の両方に存在しない** | 確定済みの素材を二重に予約し、クレジットを余分に数える |
| 7 | **`SourceRecord.aliases` が空でなく、全レコードを通じて一意** | alias を持たないレコードは二度と解決されず、永久に残る |

条件 5 は、予約と lease が手順 −2 の同一トランザクションで作られ、手順 4 またはロールバックで同時に消えることの帰結です（下記「`SourceRecord` の寿命」）。片方だけが残る状態は、どこかで補償が漏れたことを意味します。

条件 6 は、6.5.6.1 の「確定した素材は再予約しない」を台帳の形で表したものです。予約から確定への遷移は削除と追加の組であり、両方に存在する中間状態はトランザクション内にしか存在しません。

条件 7 の後半は条件 1 と重なりますが、**空集合の禁止**を別に立てます。統合で敗者の alias をすべて勝者へ移したあと、敗者のレコードを消し忘れると alias が空のレコードが残ります。これは条件 1 に違反しないため、別条件が要ります。

追加時は既存要素を `sourceID` で検索し、見つかれば置き換えではなく既存を維持します（`grants` の `firstSuccessAt` を延長しないため。6.2.0）。

##### `contentFingerprint` の構成

`ファイルサイズ + 先頭 64KB + 末尾 64KB + 撮影日時` の複合とします。48 メガピクセルの HEIC を全読みする負荷を避けるためです。

理論上の衝突時は「別素材なのに無料で再書き出しできる」方向へ倒れます。これはユーザーに有利な安全側であり許容します。逆方向（同一素材なのに二重消費）へ倒れる設計は採りません。

##### 正準化規則

**「複合」だけでは実装が一意に定まりません。** バイト順やフィールド境界が違えば、同じ写真から別のハッシュが出ます。`contentFingerprint` は無料枠の判定に直結するため、規則を固定します。

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

```swift
struct SourceFingerprintInput: Sendable {
    let fileSize: Int64
    let headBytes: Data
    let tailBytes: Data
    let capturedAtUTCMillis: Int64?
    let representation: SourceRepresentation
}

enum SourceRepresentation: Sendable {
    case original      // プロバイダーが返した原データ
    case transcoded    // OS が変換した派生データしか取得できなかった
}
```

**撮影日時の取得元を `EXIF` に限定します。**

1. **EXIF の撮影日時**（`DateTimeOriginal`）
2. 無ければ **`null`**（長さ 0 のフィールド）

**`PHAsset.creationDate` を fingerprint の入力にしません。** 写真ライブラリの読み取り権限は、v1 では新規加工に必要としません（5.4.2）。権限の有無で取得元が変われば、**同じ写真が別の `contentFingerprint` になります。**

```
初回:   権限なし → EXIF の日時 → fingerprint F1
再編集: 権限あり → PHAsset の日時 → fingerprint F2   ← 同じ写真なのに別素材
```

`F1 != F2` になれば、同じ写真に対して無料枠を二重に消費します。**fingerprint を権限状態に依存させません。**

| 用途 | 撮影日時の取得元 |
| --- | --- |
| **クォータ用 `contentFingerprint`** | **EXIF のみ。** 無ければ `null` |
| 写真ライブラリ保存時の `creationDate`（7.6） | 権限があり取得できれば `PHAsset.creationDate`、無ければ EXIF、どちらも無ければ未設定 |

前者は同一性の判定に使うため、常に同じ入力から計算できる必要があります。後者は保存する写真の属性であり、より正確な値が得られるならそれを使って構いません。**2 つを同じ優先順位表で扱わないことが要点です。**

**ファイル更新日時はどちらにも使いません。** コピーや同期で容易に変わり、同一素材の判定を壊します。

**原データを取得できない場合の扱い**も定めます。iOS の PhotosPicker は要求形式によっては HEIC を JPEG へ変換して返し、iCloud 上の原本を取得できない場合もあります。

| 状況 | 扱い |
| --- | --- |
| 原データを取得できる | `Original` としてハッシュを計算する |
| 原データを取得できない | **`Transcoded` として、取得できた表現からハッシュを計算する。処理は拒否しない** |

**処理自体を拒否しません。** 利用者にとって「この写真は加工できません」は理解不能な失敗です。`Transcoded` では同一素材の保証が弱まり、同じ写真を別素材と判定して**無料枠を余分に消費する**ことがありえますが、これは 6.2.4 が既に許容している「別素材なのに無料で再書き出しできる」の逆方向ではなく、利用者に不利な方向です。

そのため `representation` を `contentFingerprint` の**入力には含めません**。含めると、同じ写真が取得経路によって別ハッシュになります。`Transcoded` は診断のための区分値としてのみ記録し（9.2 の分析イベントのフィールド）、変換が発生する頻度を計測します。頻度が高ければ、v1.x で原データ取得の再試行を強化します。

##### プロジェクト設定ハッシュ

6.7 の「変更せず再書き出し」の判定にも正準化が必要です。**同じ設定なのに別ハッシュになる要因**が複数あります。

| 要因 | 規則 |
| --- | --- |
| `Map` の反復順 | **キーの辞書順**でソートしてから書く |
| 浮動小数の表現 | **IEEE 754 の 64 ビット `Double.bitPattern` をビッグエンディアンで**書く（文字列化しない） |
| DB の自動採番 ID | **含めない。** アプリ更新やデータ移行で変わる |
| スタンプの参照 | DB ID ではなく **`StampAsset` の内容ハッシュ**（8.4） |
| 欠損値 | 長さ 0 のフィールドとして明示する |
| フィールド順 | スキーマで固定する。追加は末尾のみ |

アルゴリズムと形式は `contentFingerprint` と同じ（SHA-256、長さ前置き、スキーマバージョン付き）です。

文字列化しない理由は、`description` の桁数が実装依存だからです。同じ値が `0.15` と `0.15000001` になれば別ハッシュになります。ビット表現なら一意です。

**`Float`（32 ビット）へ丸めません。** 実際のモデルはすべて `Double` です（`EffectOpacity` / `MosaicRatio` / `BlurRatio` / `RotationDegrees` など、5.2）。32 ビットへ丸めると、**異なる `Double` が同じハッシュになります。**

```
0.1500000000000000  → Float: 0.15
0.1500000059604645  → Float: 0.15   ← 別の設定が「変更なし」と判定される
```

6.7 の「変更せず再書き出し」は、これが成立すると**設定を変えたのに無料の再書き出しとして通します。** 精度を落とす理由がないため、`Double.bitPattern` の 64 ビットをそのまま書きます。

`-0.0` と `+0.0` は `bitPattern` が異なりますが、値としては等しいため、**符号化の前に `+0.0` へ正規化します。** `NaN` は検証済み値型が拒否するため（5.2）、ここへ到達しません。

#### 6.2.5 改ざん耐性

`UsageLedger` を平文で DB に保存すると、DB を書き換えるだけで無料枠が無制限になります。一方で仕様 14.5 は、不正利用防止のためだけに端末固有識別子や過剰な個人情報を収集することを禁じています。

折衷案として、Keychain の鍵で `UsageLedger` に HMAC 署名を付与します。サーバー照合も端末識別子の収集も行いません。

##### 読み込み結果の分類

読み込みが失敗する理由は 1 つではありません。初回起動・改ざん・ストレージの一時障害・スキーマ更新を同じ結果にまとめると、**初回起動の利用者が最初から Free 枠とトライアルを封じられ**、逆に**一時障害のたびに正常な台帳を保守状態で上書きします**。

`ProtectedBlobStore` の読み込み結果を、原因ごとに分けた型で返します。

```swift
enum ProtectedLoadResult<T: Sendable>: Sendable {
    case valid(T)
    case missing                        // まだ存在しない
    case integrityFailure               // HMAC 不一致
    case temporarilyUnavailable         // Keychain・ファイルの一時障害
    case unsupportedSchema(version: Int)
}
```

| 結果 | 扱い |
| --- | --- |
| `Valid` | そのまま使う |
| `Missing` | **新規利用者用の通常台帳を作る**（`monthlyIntegrityLock = .none`、`trialIntegrityLocked = false`） |
| `IntegrityFailure` | 後述の保守的台帳へ修復する |
| `TemporarilyUnavailable` | **上書きしない。** 再試行し、書き出しの開始を一時停止する（`ExportStartGate` を通さない）。利用者には再試行可能なエラーを提示する |
| `UnsupportedSchema` | 定義済みの移行処理を実行する。移行後に再検証する |
| 移行不能 | 復旧エラー（7.4.3）として扱う。**自動初期化しない** |

**`TemporarilyUnavailable` と `IntegrityFailure` を混同しないことが要点です。** 鍵ストアが一時的に利用できないだけの状態を改ざんとして修復すると、正常な利用者の枠を消します。両者は「署名検証まで到達したか」で区別できます。データを読めて HMAC が一致しない場合のみ `IntegrityFailure` です。読み込み自体が失敗した場合、鍵を取得できなかった場合は `TemporarilyUnavailable` です。

HMAC 鍵そのものが失われた、または無効化された場合（Keychain の項目が失われた場合を含む）は、データを検証できないため `IntegrityFailure` として扱います。鍵の喪失と改ざんは端末側から区別できないためです。

##### 検証失敗時の扱い

以下は `IntegrityFailure` に対する規則です。

**空の `UsageLedger` を作り直しません。** 台帳は消費件数だけでなく、どの素材が grant を持ちトライアルを消費したかを保持しています。空にすると**無料枠もトライアルも全回復**し、改ざんの動機になります。

**`IntegrityFailure` を一時的な読み取り結果のままにしません。保守的に修復した永続状態へ変換します。**

読み取り失敗のたびに判断すると、正しい `lastObservedAt` を失っているため `usageNow` を算出できず、「当月だけ `Blocked`」を翌月に解除する手立てもなく、Standard / Pro が成功しても grant を書き込む先がありません。

検出した時点で、次の内容の**新しい署名済み台帳**を作ります。

| フィールド | 値 |
| --- | --- |
| `lastObservedAt` | **署名失敗を検出した時点の端末時刻**。正しいアンカーを失っているため、ここを新しい基準時刻とする |
| `monthlyIntegrityLock` | `.lockedUntilTrustedMonthAfter(現在月)`。**端末年月では解除できない**（6.2.2.5） |
| `trialIntegrityLocked` | `true` |
| `grants` | 空 |
| `consumedExportIDs` | 空 |
| `trialEntries` | 空 |
| **`trialReservations`** | **空** |
| **`sourceRecords`** | **空** |
| **`sourceLeases`** | **空** |
| `period` | 現在月 |

`trialReservations` を空にすることを明記します。書き漏らすと、修復後も過去の予約が残っているものとして残クレジットが減り、`trialIntegrityLocked` と合わせて二重に封鎖されます。

`sourceRecords` と `sourceLeases` も空にします。参照先の grant / trial / reservation がすべて空である以上、残す意味がありません。alias だけが残ると、次の解決で「既知の素材」として扱われ、修復前の同一性判定が部分的に生き残ります。

結果として次のようになります。

- **Free 単体書き出しは不可。信頼できる時刻から導出した年月が封鎖時の月より後になった時点で再開する**（端末時計を進めても解除されない。6.2.2.5）
- **一括処理トライアルは再インストールまで不可**（`trialIntegrityLocked` は解除しない）
- Standard / Pro の通常書き出しは許可。月間枠に依存しない
- 成功した書き出しの grant は、この修復済み台帳へ通常どおり追加できる
- `FreeReexport` は grant が空なので当面成立しない

**改ざんされた値を根拠に枠やクレジットを付与しません。** 空の台帳をそのまま作ると無料枠もトライアルも全回復するため、封じるフラグを同時に立てます。

##### 封鎖フラグを実際に効かせる箇所

フラグを立てるだけでは効果がありません。次の 2 箇所で参照します。

| フラグ | 参照箇所 | 効果 |
| --- | --- | --- |
| `monthlyIntegrityLock` | `QuotaPolicy.evaluate` の判定手順 4（6.2） | 月間上限の判定より前に `Blocked(LedgerIntegrityFailure)` を返す |
| `trialIntegrityLocked` | `remainingCredits` の導出（6.5.6.1） | 残数を 0 とし、一括トライアル画面への進入・写真選択・認可をすべて禁止する |

`monthlyIntegrityLock` を上限判定より前に置く理由は、修復後の `consumedExportIDs` が空だからです。上限判定だけでは `consumed(0) >= limit` が成立せず、そのまま通過します。

再インストールで枠が戻ることは仕様 14.5 が明示的に許容しているため、追跡しません。

##### バックアップ対象からの除外

**署名済みデータと HMAC 鍵のライフサイクルを一致させます。** データだけがクラウドバックアップや端末移行で復元され、鍵が復元されないと、**通常の再インストールでも `IntegrityFailure` になり、当月枠とトライアルが封鎖されます。** これは直前の「再インストールで枠が戻る」方針と正反対の結果です。

v1 では次を規則とします。

| 対象 | 規則 |
| --- | --- |
| `ProtectedBlobStore` のファイル | **クラウドバックアップ対象外**（`isExcludedFromBackup`。7.3.1） |
| HMAC 鍵 | **端末外へ移行しない**（Keychain へ `ThisDeviceOnly` 系のアクセシビリティを指定。7.3.1） |
| 再インストール・端末移行後 | データが消えるため `Missing` となり、**新規台帳を作る** |

**「鍵とデータの両方が消える」とは仮定しません。** `ThisDeviceOnly` が保証するのは別端末へ移行しないことであり、アンインストール時の削除ではありません。**鍵だけが残る状態は正常な状態として扱います**（7.3.2 に規則を定義）。

いずれの場合も、データが `Missing` なら新規台帳を作ります。鍵の有無で分岐しません。

### 6.3 権限解決（EntitlementResolver）

RevenueCat の `CustomerInfo` をアプリ全体に流さず、純粋関数で畳み込みます。

```swift
func resolve(snapshot: CustomerInfoSnapshot, usageNow: Date) -> Entitlement

struct Entitlement: Sendable, Equatable {
    let plan: Plan               // free / standard / pro
    let status: PlanStatus       // active / grace / pending / expired / revoked
    let expiresAt: Date?
    let lastVerifiedAt: Date
}
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

判定を純粋関数に閉じることで domain unit test で網羅できます（12.1.1）。

### 6.5 一括処理とトリアージ

**一括処理の制限なし利用は `canUseProBatch` が必要です。** `canUseBatchTrial` だけを持つ利用者は、次のいずれかを満たす場合にトライアルとして利用できます。

- 未使用クレジットの範囲で、新しい写真を処理する
- **消費済み台帳に登録されている写真を、再度処理する**（6.5.6.1）

したがって **残クレジットが 0 でも、消費済み台帳に写真があれば一括処理画面を閉じません。** 「クレジットを使い切ったら一切使えない」とすると、6.5.6.1 が定める「同じ 5 枚は期限なく何度でも試せる」が成立しません。

進入条件を式で示します。

```swift
let canEnterBatch =
    capabilities.canUseProBatch ||
    (
        capabilities.canUseBatchTrial &&
        !usageLedger.trialIntegrityLocked &&
        (
            remainingCredits > 0 ||
            !usageLedger.trialEntries.isEmpty
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

```swift
enum ReviewReason: Sendable, Hashable {
    case noFaceDetected      // 顔を 1 つも検出できなかった
    case lowConfidence       // 検出信頼度が閾値未満（5.7.1）
    case smallFace           // 検出用画像上で短辺 24px 未満の顔がある
    case extremePose         // 横や上下を大きく向いた顔がある
    case faceAtEdge          // 拡張後の領域が画像境界に接する顔がある
    case overlappingFaces    // 領域同士が重なる顔がある
}

/// 警告 1 件の同一性。理由ではなく「発生」を識別する
struct ReviewIssueID: Sendable, Hashable {
    let projectID: ProjectID             // 写真を識別する。noFaceDetected に必須（6.9）
    let detectionRevision: Int64
    let reason: ReviewReason
    let affectedFaceTrackIDs: [FaceTrackID]   // 辞書順にソート済み
}

struct ReviewIssue: Sendable, Equatable {
    let id: ReviewIssueID
}

extension ReviewIssue {
    /// ID から導出する。二重に持たない
    var affectedFaceTrackIDs: [FaceTrackID] { id.affectedFaceTrackIDs }
}

func triage(
    _ result: DetectionResult,
    projectID: ProjectID,
    detectionRevision: Int64
) -> [ReviewIssue]
```

##### 警告は発生単位で持つ

**`Set<ReviewReason>` では、同じ理由を持つ複数の顔を区別できません。** これは匿名化確認の安全性に直接影響します。

小さい顔が 3 人写っている写真を考えます。`Set` では `smallFace` が 1 件に集約されるため、**1 人に手動領域を追加しただけで** `.manualRegionAdded` を記録でき、3 人すべてに対応したものとして `Reviewed` へ進めます。残り 2 人は隠れていません。

`ReviewIssue` を発生単位で列挙します。

| 理由 | 発生単位 |
| --- | --- |
| `lowConfidence` | **顔ごと**に 1 件 |
| `smallFace` | **顔ごと**に 1 件 |
| `extremePose` | **顔ごと**に 1 件 |
| `faceAtEdge` | **顔ごと**に 1 件 |
| `overlappingFaces` | **重なる顔の組み合わせごと**に 1 件 |
| `noFaceDetected` | **写真ごと**に 1 件（対象の顔が存在しないため `affectedFaceTrackIDs` は空。`projectID` で識別する） |

##### 再検出時は対応づけを試みない

**「再検出しても同じ顔へ同じ ID が付く」とは保証できません。** 新旧の顔を対応づけるアルゴリズムが必要になりますが、検出順が変わっただけでも別の `faceTrackID` になりえます。誤った対応づけは「別人の顔に対する判断を、この顔の判断として扱う」ことを意味し、匿名化確認としては最悪の失敗です。

v1 では対応づけを試みません。

- `issueID` に **`detectionRevision`** を含める
- **再検出のたびに `detectionRevision` を増やす**
- 再検出時は、その写真の **`ReviewIssue` / `ReviewDecision` / `Reviewed` をすべて破棄する**

利用者はやり直しになりますが、対応づけを誤って安全側を崩すよりも確実です。再検出は利用者が明示的に行う操作であり、頻度も高くありません。

`affectedFaceTrackIDs` の生成規則を固定します。

| 理由 | `affectedFaceTrackIds` |
| --- | --- |
| `lowConfidence` / `smallFace` / `extremePose` / `faceAtEdge` | 対象の `faceTrackID` 1 件 |
| `overlappingFaces` | 重なる 2 件を**辞書順に並べる**（順序で別 ID にならないように） |
| `noFaceDetected` | 空。`projectID` と `detectionRevision` が識別を担う |

##### 判定に使う値（v1.x からの変更）

**v1.x では `confidence` をトリアージから外していました。** ML Kit に対応する API が無く、Android だけ警告が出ない非対称が生じるためです。**iOS 単独になったため、この制約は消えます。**

仕様 8.1 が求めるとおり `lowConfidence` をトリアージ理由へ戻し、`extremePose` と併用します。

| 理由 | 判定 | 捉える失敗 |
| --- | --- | --- |
| `lowConfidence` | `confidence` が閾値未満 | 検出器自身が確信を持てていない。誤検出または見落としの近傍 |
| `extremePose` | `yawDegrees` または `pitchDegrees` の絶対値が閾値超過 | 検出はできているが、**拡張率の既定値では隠しきれない**可能性がある |

**両方を残すのは、捉える失敗が違うからです。** 正面を向いた顔を低い信頼度で検出することもあれば、高い信頼度で真横の顔を検出することもあります。片方だけでは、もう一方の状況を見逃します。

閾値（`confidence` の下限、yaw / pitch の上限）はリモート設定で調整可能とします（11.1）。実素材での分布を見てから決めるため、初期値は 16 節の未決事項です。

`triage` の結果が写真の **検出ステータス**（6.5.3）を決めます。空なら `Normal`、空でなければ `ReviewRequired` です。

**このトリアージは、検出された顔の品質しか評価できません。** 検出されなかった顔の存在は、いかなる警告条件にも現れません。

たとえば 3 人が写る写真で 2 人を十分な大きさ・正面向き・画像中央で検出し、残る 1 人を完全に見落とした場合、`triage` は空集合を返します。顔は検出されており、小さくもなく、大きく向いてもおらず、端でもなく、重なってもいないためです。この写真は `Normal` に分類されますが、実際には 1 人の顔が露出したまま書き出されます。

したがって `Normal` は安全の保証ではなく、**検出結果の上で警告すべき点がないこと**を意味するに過ぎません。この限界があるため、6.5.3 の確認を必須とします（モードごとの満たし方は 6.5.3 に定義）。

**アプリ側が `Reviewed` を立てることはありません。** 検出漏れを判定できない以上、アプリが確認済みと宣言することはできません。`Reviewed` は利用者の操作によってのみ成立します。

#### 6.5.3 写真の状態と確認の成立条件

**写真の状態を 2 つの軸で持ちます。** 「アプリが何を検出したか」と「利用者が何を確認したか」は別の情報であり、1 つの状態へ混ぜると「通常なのに確認済み」「要確認を確認済みへ変更する」といった意味の混線が生じます。

```swift
enum DetectionStatus: Sendable { case normal, reviewRequired }   // triage の結果
enum ReviewStatus: Sendable { case unreviewed, reviewed }        // 利用者の操作
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

```swift
struct BatchReviewState: Sendable { let overviewConfirmed: Bool }
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

おまかせ一括の末尾到達判定は、スクロールだけでなく VoiceOver による走査でも成立させます。支援技術の利用者が確認操作へ到達できない実装は、仕様 29 章に反します。

なお **末尾までの到達も `Reviewed` も、安全の保証ではありません。** 見落としを減らすための手順として扱い、6.5.2 のとおり「確認済みだから安全」とは表現しません。いかなる場合も「安全」という語を状態表示に用いません（仕様 34.5）。

#### 6.5.4 要確認への対応

**`ReviewRequired` かつ `Unreviewed` の写真が 1 枚でも残っている間は、一括書き出しを開始できません。**

**警告を消すのではなく、警告に対する利用者の判断を記録します。** 検出結果は事実であり、利用者が確認したからといって事実が変わるわけではないためです。

```swift
enum ReviewResolution: Sendable, Equatable {
    /// 内容を見て、このままでよいと判断した
    case acceptedAsIs

    /// 手動で隠す範囲を追加した。どの領域かを保持する
    case manualRegionAdded(regionID: RegionID)   // 6.9

    /// 顔を隠さずそのまま保存すると選んだ
    case unmaskedExportConfirmed
}

struct ReviewDecision: Sendable, Equatable {
    let resolutions: [ReviewIssueID: ReviewResolution]
}
```

**`ManualRegionAdded` は `regionID` を持ちます。** 単なる列挙値だと、どの手動領域を追加したのかが分かりません。あとから利用者がその領域を削除した場合に、判断だけが残って「対応済み」と表示されます。

領域の作成と判断の記録は、**1 つのドメインコマンドで原子的に**行います。片方だけが成立する状態を作りません。

- 手動領域の作成が失敗すれば、判断も記録しない
- `regionID` の領域が削除されたら、対応する `ReviewResolution` も破棄して `Unreviewed` へ戻す

**判断は `ReviewIssue` ごとに記録します（理由ごとではありません）。** 1 枚の写真には複数の警告が同時に付き、同じ理由が複数件つくこともあります（6.5.2）。

```swift
ReviewDecision(resolutions: [
    // 1 人目の小さい顔に範囲を足した
    ReviewIssueID(projectID: pid, detectionRevision: rev, reason: .smallFace,
                  affectedFaceTrackIDs: [face1])
        : .manualRegionAdded(regionID: region9),
    // 2 人目はそのままでよいと判断した
    ReviewIssueID(projectID: pid, detectionRevision: rev, reason: .smallFace,
                  affectedFaceTrackIDs: [face2])
        : .acceptedAsIs,
    // 端の顔はそのままでよいと判断した
    ReviewIssueID(projectID: pid, detectionRevision: rev, reason: .faceAtEdge,
                  affectedFaceTrackIDs: [face5])
        : .acceptedAsIs,
])
```

`ReviewRequired` の写真が `Reviewed` になる条件は、**その写真の `[ReviewIssue]` すべてに対して `ReviewResolution` が記録されていること**です。1 件でも未記録なら `Unreviewed` のままです。

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

##### 「新しい写真」を数えるには正規 ID が要る

**選択画面で `SourceIdentity` を素朴に比較できません。** 正規 `sourceID` の解決と alias の統合は、書き出し開始時の `UsageLedgerStore.transact` の中でしか行われません（6.2.4）。その外で生の `SourceIdentity` を OR 述語で比べると、推移律が成立しないため次が起こります。

| 誤り | 起こること |
| --- | --- |
| 同じ写真を 2 枚と数える | 新規枚数が過大になり、選べるはずの組み合わせを拒否する |
| OS がトランスコードした写真を新規扱いする | 消費済みのはずの写真でクレジットを要求する |
| 選択中の重複を見逃す | 同じ写真を 2 枚選んだまま通過する |

`BatchSelectionClassifier` を設けます。

```swift
struct BatchSelectionClassification: Sendable {
    let canonicalCount: Int      // 正規素材としての枚数（選択中の重複を畳んだ数）
    let newSourceCount: Int      // 消費済み台帳に無い正規素材の数
}

protocol BatchSelectionClassifier: Sendable {
    func classify(
        selection: [SourceIdentity],
        ledger: UsageLedger
    ) -> BatchSelectionClassification
}
```

判定は**連結成分**として行います。

1. 台帳の `SourceRecord` が持つ alias 集合と、選択中の各写真の alias 集合を、同じグラフの頂点として扱う
2. 同じ alias を共有する頂点を辺で結ぶ
3. 連結成分ごとに 1 つの正規素材とみなす
4. 台帳の `SourceRecord` を含む成分は「消費済み」、含まない成分は「新規」

OR 述語をそのまま使うのではなく、**alias の共有関係を推移的に閉じる**ことで、6.2.4 の `sourceID` 解決と同じ結果になります。

##### 選択画面の判定を認可の根拠にしない

**上の分類は表示と入力制限のためのものです。** 選択から実行開始までの間に、別の書き出しが台帳を更新する可能性があります。

実行開始の直前に、**最新の台帳で全件を原子的に再検証します。** 再検証は書き出し開始ゲート（7.4.3）の内側で行い、分類結果が変わっていれば実行を開始せず、選択画面へ戻して差分を提示します。

> 選択した写真の一部が、ほかの処理ですでに使われました。もう一度確認してください。

**選択時の判定だけで消費を認可しません。** 6.2.4 が「認可は台帳トランザクション内で確定する」と定めているのと同じ理由です。

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

**クレジットの消費判定は、6.2.4 で解決した `sourceID` に従います。** 加工内容が異なっても、同じ元写真であれば追加消費しません。

これがないと、モザイクで書き出して結果を見てから強度を調整して再書き出しするだけで 2 クレジット消費し、通常の無料枠（24 時間以内の再書き出しは追加消費なし）より厳しい扱いになります。試用のための枠がやり直しで目減りする設計は、トライアルの目的に反します。

##### 保存するのは台帳だけ

**残クレジット数は保存しません。消費済み台帳から導出します。**

```swift
let remainingCredits =
    usageLedger.trialIntegrityLocked
        ? 0
        : max(
            0,
            configuredCreditCount
                - usageLedger.trialEntries.count
                - usageLedger.trialReservations.count
        )
```

##### クレジットの予約

**認可だけではクレジットを占有できません。** `UsageLedgerStore.transact` は更新を直列化しますが、**認可結果を台帳へ残さなければ、生成完了までクレジットは空いたまま**です。

残り 1 枚の状態で、異なる素材の 2 件が並行して認可されると、どちらも `trialEntries` の同じ件数を見て `batchTrial(true)` になります。結果としてクレジットを 1 枚超過します。

v1 は全体排他ゲート（7.4.3）により同時 1 件なのでこの経路は塞がれていますが、**予約は並列化後も必要です。** ゲートの粒度を素材単位へ下げた時点で、別素材どうしの並行認可が復活します。

台帳へ予約を持たせます。

```swift
struct UsageLedger {
    // ...
    let trialReservations: [TrialReservation]   // source と exportID の組（6.2.4）
}
```

| 契機 | 操作 | 保存先 |
| --- | --- | --- |
| 認可時（`BatchTrial(true)` と判定。手順 −2） | 該当素材の `TrialReservation` を**同じ `transact` の中で**追加する | ProtectedBlobStore |
| `Prepared` の保存に失敗（手順 0） | **補償トランザクション**で予約・`SourceLease` を削除し、参照元を失った `SourceRecord` を GC する | ProtectedBlobStore |
| 台帳への適用（手順 4） | **同じ台帳トランザクション内で**予約を削除し、`trialEntries` の該当要素 へ移す | ProtectedBlobStore |
| 台帳への適用（手順 4） | **同じ台帳トランザクション内で** `SourceLease` を削除する | ProtectedBlobStore |
| 最終確定（手順 7） | **台帳には触らない**（DB のみ） | — |
| ロールバック | この `exportID` が所有する**予約または `trialEntries`** を削除する | ProtectedBlobStore |
| 起動時 | コミットの無い予約を孤児として削除する。**その完了後に新規認可を許可する** | ProtectedBlobStore |

**残数計算は `trialEntries` と `trialReservations` の合計で行います。** 予約を数えなければ、予約を作った意味がありません。

**不変条件: 同じ素材が `trialEntries` と `trialReservations` の両方に存在してはなりません。** 予約から entry への移動は同一トランザクション内の削除と追加であり、中間状態が観測されません。この条件を台帳の検証時にも確認します。

予約の削除は `ownerExportID` と同じ規則で、**その `exportID` が所有する予約だけ**を対象とします（6.2）。

**予約はコミットより先に作られます。** 認可トランザクション（手順 −2）で予約を作り、その後に手順 0 で `Prepared` を保存します。順序がこの向きである以上、`Prepared` の保存に失敗した場合の補償が必要です。

孤児予約の回収を起動時に行うのは、予約を作った直後にプロセスが落ちた場合に、クレジットが永久に占有されるのを防ぐためです。回収は復旧完了ゲート（7.4.3 の起動順序）の一部として、**新規認可を許可する前に**完了させます。

**`trialIntegrityLocked` を導出に含めます。** 台帳を修復すると `trialEntries` が空になるため、フラグを見なければ表示上 5 枚すべてが復活します。残数 0 のときは、一括トライアル画面への進入・写真選択・認可のすべてを禁止します（6.2.5）。

残数と台帳の両方を保存すると、更新途中の異常終了で不一致が起こりえます。「残 3 枚なのに台帳は 4 件」という状態からは、どちらが正しいか判断できません。導出にすれば正が 1 つになります。

付与数（`configuredCreditCount`）はリモート設定で変更できます（11.1）。導出にしておけば、5 枚から増減しても挙動が自動的に決まります。残数を保存していると、既存利用者の残数を移行する処理が必要になります。

台帳は `[TrialEntry]` として `UsageLedger` 内に保持します（6.2）。新しく追加した写真だけが消費対象になります。

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

キューの進行状態は仕様 16.6 の 8 種（`waiting` / `analyzing` / `review_required` / `exporting` / `completed` / `failed` / `canceled` / `paused`）とし、状態機械を `Domain` に置きます。

**キューの進行状態と、6.5.3 の 2 軸は別物です。** 混同しないよう関係を定義します。

| 概念 | 何を表すか | 変化させるもの |
| --- | --- | --- |
| キューの進行状態 | その写真が処理のどの段階にいるか | 処理の進行 |
| 検出ステータス | `triage` が警告を出したか | 検出のやり直し |
| 確認ステータス | 利用者が確認を終えたか | 利用者の操作 |

キューの `review_required` は独立した真実を持たず、**利用者の確認待ちを表す導出値**です。導出条件は 6.5.3 のモードで異なります。

```swift
let requiresUserReview = switch mode {
case .auto:
    detectionStatus == .reviewRequired && reviewStatus == .unreviewed
case .oneByOne:
    reviewStatus == .unreviewed
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
- バックグラウンド処理は OS の実行制限に従う。`BGProcessingTask` は使わず、フォアグラウンド継続を前提とする

#### 6.5.9 一括設定と個別修正の優先順位

一括設定プリセットを適用したあと、警告のある写真を個別に修正し、さらに共通設定を変更する、という操作順が起こります。このとき個別修正が黙って上書きされる事故を防ぎます。

規則は以下とします。

1. **一括設定は各写真の初期値として適用する**
2. 個別に編集された写真には `hasOverride` を記録する
3. **共通設定を変更しても、`hasOverride` が立った写真は変更しない**
4. 全件を上書きしたい場合のみ、確認を経て「個別設定を含めてすべて上書き」を実行する

確認の文言例を示します。

> 4 枚に個別設定があります。これらも新しい設定で上書きしますか？

`hasOverride` は写真単位のフラグとし、`Domain` が管理します。上書きの可否判定を domain unit test で網羅します（12.1.1）。

### 6.6 手動領域とキーフレーム

仕様 8.7 および 10 章の手動修正は、すべて `Domain` 側で扱います。`MediaKit` は手動領域を認識せず、`RenderPlan` の `RenderRegion` として渡されたものを描画するだけです。

- 写真では、手動指定領域をそのまま加工対象の `FaceTrack`（`createdManually = true`）として扱います
- 誤検出の削除、領域の移動・拡大縮小、エフェクトの個別変更は、`FaceTrack` と `EffectSetting` の編集に還元されます
- 動画（v2）では、手動指定したフレームを `FaceKeyframe` として保持し、キーフレーム間で中心 X / 中心 Y / 幅 / 高さ / 回転角度を補間します（仕様 10.3）

キーフレーム補間は純粋関数であり、v1 の時点で実装とテストを完了させます。

### 6.7 解約・降格後の既存データの扱い

有料時に作成したデータへの操作を、プラン降格後も一貫した規則で扱います。規則がないと、降格した利用者が過去データを人質に取られたと感じます。

**判定軸は「作成時のプラン」ではなく「現在の設定内容が要求するプラン」です。**

```swift
/// 表示用。「Standard が必要です」の文言に使う
func requiredPlan(_ project: Project) -> Plan

/// 実装上の判定。プラン名ではなく能力で決める
func canEdit(_ project: Project, capabilities: ResolvedCapabilities) -> Bool
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

降格したという事実は、クォータ判定に影響しません。判定に使うのは素材の同一性と経過時間だけです。

**「閲覧」と「変更」を分けます。** Free でも編集画面を開いて内容を確認できます。有料スタンプを含むプロジェクトで**変更操作を行おうとした時点**で、2 つの選択肢を提示します。

> このプロジェクトはそのまま書き出せます。編集するには Standard が必要です。
> 有料スタンプを基本のかくし方へ置き換えた複製を作れば、いまのまま編集できます。

なお写真ライブラリへ保存済みの過去の出力は、アプリの契約状態に一切影響されません。

契約期間の終了時に未完了のバッチが残っている場合は、キューを `paused` にし、Pro の契約が終了したため続行できない旨を表示します。完了済みの写真と履歴は保持します。

### 6.8 アプリ更新の誘導（UpdatePolicy）

起動時に新しいバージョンがあれば App Store へ誘導します。判定は純粋関数に閉じます。

#### 6.8.1 バージョン情報の取得元

**App Store の Lookup API（`itunes.apple.com/lookup`）を使いません。**

| 理由 | 内容 |
| --- | --- |
| 反映が遅い | CDN のキャッシュにより、公開直後は古いバージョンを返すことがある |
| 公開仕様ではない | レスポンス形式の変更が予告なく起こりうる |
| 段階的な提示ができない | 「公開済みだが、まだ誘導は始めない」を表現できない |

**`GET /v1/config` へ含めます**（11.1）。自前で配信すれば、公開とロールアウトを分けられます。審査通過直後に全利用者へ誘導が飛ぶ事故も防げます。

```swift
struct UpdateConfig: Sendable, Decodable {
    let minimumSupportedVersion: AppVersion   // これ未満は使用不可
    let recommendedVersion: AppVersion        // これ未満は任意更新を提示
    let appStoreID: String
}
```

#### 6.8.2 バージョン比較

**文字列比較を使いません。** `"1.10.0" < "1.9.0"` が文字列としては真になり、**新しいバージョンを古いと判定します。**

```swift
struct AppVersion: Sendable, Comparable, Decodable {
    let major: Int
    let minor: Int
    let patch: Int
}
```

`CFBundleShortVersionString` を数値の組へパースします。**パースに失敗した場合は更新なしと判定します。** ここで強制更新へ倒すと、バージョン表記の書式ミスで全利用者がブロックされます。

`CFBundleVersion`（ビルド番号）は比較に使いません。TestFlight のビルドごとに増える値であり、App Store 上のバージョンと対応しません。

#### 6.8.3 判定

```swift
enum UpdateDecision: Sendable, Equatable {
    case none
    case recommended(AppVersion)   // 任意。スキップできる
    case required(AppVersion)      // 強制。アプリを使用できない
}

func evaluateUpdate(
    current: AppVersion,
    config: UpdateConfig?,          // 取得できていなければ nil
    skippedVersion: AppVersion?,    // 利用者が「後で」を選んだバージョン
    lastPromptedAt: Date?,
    usageNow: Date
) -> UpdateDecision
```

判定順序は次のとおりです。

1. `config == nil` なら **`.none`**（リモート設定を取得できない場合は誘導しない）
2. `current < config.minimumSupportedVersion` なら **`.required`**
3. `current >= config.recommendedVersion` なら `.none`
4. `skippedVersion == config.recommendedVersion` なら `.none`（同じバージョンを再提示しない）
5. `usageNow - lastPromptedAt < 24h` なら `.none`（1 日 1 回まで）
6. それ以外は **`.recommended`**

時刻には `usageNow` を使います（6.2.2.5）。端末時計を戻して再提示を回避されても実害はありませんが、**時間判定を 1 か所に集約する規約**を例外なく適用します。

**手順 1 が最も重要です。** サーバー障害や通信不良で設定を取得できないときに強制更新へ倒すと、**バックエンドの障害が全利用者のアプリ停止に直結します。** 11.3 の「バックエンド障害で編集処理を停止させない」と同じ原則です。

`configVersion` の後退拒否（11.3）により、古い設定が再配信されて誤って強制更新が出る事故も防げます。

#### 6.8.4 未受け渡し出力を失わせない

**強制更新は、6.2.2 の「消費したのに成果物を受け取れない」を作りかねません。**

利用者が書き出しを完了し（消費が確定し）、保存する前にアプリを再起動した場面を考えます。ここで強制更新の全画面ブロックを最優先で表示すると、`Generated` 状態の出力を受け取る手段が消えます。24 時間後には出力も消えます。**無料枠だけが減ります。**

規則を定めます。

| 状態 | 強制更新の扱い |
| --- | --- |
| `Generated` の出力が 1 件もない | **即座に強制更新画面を表示する** |
| `Generated` の出力がある | **受け渡しの導線を先に提示する**（下記） |

`Generated` がある場合の画面は次とします。

> アプリの更新が必要です。
> 保存していない加工済み写真が N 枚あります。先に保存してから更新してください。
>
> ［写真を保存する］［App Store を開く］

**この画面から到達できるのは保存・共有・破棄だけ**とします。新規の加工、履歴の閲覧、設定へは進めません。強制更新の目的（古いバージョンを動かさない）を保ちつつ、成果物の損失だけを防ぎます。

保存または破棄によって `Generated` が 0 件になった時点で、通常の強制更新画面へ切り替えます。

#### 6.8.5 復旧処理との順序

**更新判定は、7.4.3 の起動時復旧より後に行います。**

復旧を止めると、未完了の `ExportCommit` が残ったまま次回起動を迎えます。更新後も同じ状態から始まるだけで、何も解決しません。むしろ、復旧前に強制更新画面を出すと 6.8.4 の `Generated` 件数を正しく数えられません。

起動順（7.4.3）へ組み込みます。

| 順 | 操作 |
| --- | --- |
| 0〜7 | 7.4.3 の復旧手順（journal_mode 検証、台帳検証、コミット復旧、参照整合、孤児回収、未受け渡し出力の復元） |
| **8** | **`evaluateUpdate` を実行する** |
| 9 | `.required` なら更新画面（6.8.4 の分岐を含む）、それ以外は通常画面 |

#### 6.8.6 任意更新の提示条件

`.recommended` のダイアログは、**割り込んでよい場面でのみ表示します。** 判定条件は 6.4 の広告表示禁止条件と同じ思想です。

- 検出中、顔選択中、編集中、書き出し中、書き出しエラー対応中、課金処理中は**表示しない**
- `Generated` の未受け渡し出力があるときは**表示しない**
- ホーム画面または履歴画面を表示している時点でのみ提示する

選択肢は「App Store を開く」と「後で」の 2 つです。「後で」を選んだ場合、そのバージョンを `skippedVersion` として記録します。`recommendedVersion` が上がれば再び提示されます。

チェックの契機は**起動時とフォアグラウンド復帰時**とします。フォアグラウンド復帰を含めるのは、長時間起動しっぱなしの利用者へ届かなくなるためです。

#### 6.8.7 App Store を開く

```swift
URL(string: "https://apps.apple.com/app/id\(config.appStoreID)")
```

SwiftUI の `openURL` 環境値で開きます。`itms-apps://` スキームは使いません。App Store アプリが無い環境（企業端末等）でリンクが失敗するためです。`https://` なら Safari 経由で App Store へ解決されます。

**`SKOverlay` は使いません。** 自アプリの更新誘導ではなく他アプリの推薦を意図した API であり、用途が異なります。

#### 6.8.8 審査への配慮

**強制更新の閾値は、審査中のビルドをブロックしない値に保ちます。**

審査担当者は App Store 公開前のビルドを実行します。`minimumSupportedVersion` を「これから公開するバージョン」に設定してしまうと、審査中のビルド自身がブロックされ、リジェクトされます。

運用規則とします。

- `minimumSupportedVersion` を上げるのは、**そのバージョンが公開され、十分に普及したあと**
- 新バージョンの審査提出時は、`minimumSupportedVersion` を変更しない
- 強制更新は、**セキュリティ上の問題や、サーバー側の互換性が切れた場合に限る**

保存されるのは `skippedVersion` と `lastPromptedAt` のみで、いずれも `UserDefaults` に置きます。改ざんされても更新の再提示が遅れるだけであり、`ProtectedBlobStore` を使う必要はありません。

### 6.9 ドメイン識別子の型

**識別子を `String` と `UUID` で混在させません。**

これまでの記述では、`ReviewIssueID.projectID` が `UUID`、`ExportCommit.projectID` と `OutputRecord.projectID` が `String`、`regionID` と `exportID` が `String` でした。**同じ概念が 2 つの型で表現されている状態では、DB の結合も HMAC の正準化も一意に決まりません。**

概念ごとに専用型を定めます。

```swift
// Domain — すべて Foundation のみ
struct ProjectID:    Sendable, Hashable { let rawValue: UUID }
struct BatchID:      Sendable, Hashable { let rawValue: UUID }
struct ExportID:     Sendable, Hashable { let rawValue: UUID }
struct RegionID:     Sendable, Hashable { let rawValue: UUID }
struct FaceTrackID:  Sendable, Hashable { let rawValue: String }   // Vision の observation UUID 文字列（5.7.1）
```

`FaceTrackID` だけ内部表現が `String` なのは、値の出所が Vision の `observation.uuid.uuidString` であり、アプリが採番しないためです。ほかは `ManagedFileID`（7.3.4）と同じく `UUID` を採ります。

型を分ける理由は 4 つです。

| 理由 | 内容 |
| --- | --- |
| 誤った受け渡しの防止 | `exportID` を期待する引数へ `projectID` を渡せない。**コンパイルで止まる** |
| DB 結合の一意性 | `runtime.db` と `user-data.db` を跨ぐ整合検査（7.1）の対象が型で決まる |
| 正準化の一意性 | HMAC 対象の各 ID を「`UUID` の 16 バイト」として符号化できる（7.4.3） |
| ログ禁止の強制 | 分析イベントのフィールド型にしないことで、送信経路へ入れられない（9.2） |

**いずれの型も `CustomStringConvertible` に適合させません。** 文字列補間で自動的にログや診断へ流れる経路を作らないためです。表示が必要な場面は存在しません。

該当箇所の型を次へ揃えます。

| 箇所 | 変更後 |
| --- | --- |
| `ReviewIssueID.projectID`（6.5.2） | `ProjectID` |
| `ExportCommit.projectID` / `.exportID` / `.batchID`（7.4.3） | `ProjectID` / `ExportID` / `BatchID?` |
| `OutputRecord.projectID` / `.exportID` / `.batchID`（7.4.3） | `ProjectID` / `ExportID` / `BatchID?` |
| `ExportReservation.exportID` / `SourceLease.exportID`（6.2.4） | `ExportID` |
| `ReviewResolution.manualRegionAdded(regionID:)`（6.5.4） | `RegionID` |
| `DetectedFace.faceTrackID`（5.7.1） | `FaceTrackID` |

`sourceID` はすでに `UUID` を直接持っていますが、同じ理由で `SourceID { let rawValue: UUID }` とします（6.2.4）。

---

## 7. データモデルと永続化

### 7.1 データベース構成

GRDB（SQLite）を使います。採用理由は 3.3 に示します。

##### データベースを 2 つに分ける

**バックアップの単位はファイルであり、テーブルではありません。** OS のバックアップ規則が扱えるのはパスなので、1 つの SQLite ファイルの中で「このテーブルは対象外」と指定することはできません（7.3.1）。

保存するデータの性質でファイルを分けます。

**`runtime.db`（バックアップ対象外）**

| テーブル | 備考 |
| --- | --- |
| `ExportCommit` | 書き出しのコミットジャーナル。行に HMAC を付ける（7.4.3） |
| `OutputRecord` | 写真ごとの出力状態。`exportID` でコミットと対応づける。実体はパスではなく `ManagedFileRef` で参照し、`outputByteSize` と `outputSha256` を持つ（7.4.3 / 7.3.4） |
| `ExportQueueItem` | 一括処理のキュー状態（6.5.8） |
| `WorkingSourceRecord` | 処理用にアプリ領域へ複製した元素材。キューの再起動復元に必須（5.4） |
| `PendingFileDeletion` | 参照 0 になった実体の削除候補。DB のコミット後に削除し、失敗は起動時 GC で再試行（8.4.1） |

**`user-data.db`（バックアップ対象外。7.3.1）**

| テーブル | 備考 |
| --- | --- |
| `Project` | 仕様 19.1。再編集用の `ProjectSourceLocator` を持つ（5.4.2）。**ここにのみ平文の `localIdentifier` が存在する** |
| `FaceTrack` | 仕様 19.2 |
| `FaceKeyframe` | 仕様 19.3。v2 で使用 |
| `EffectSetting` | 仕様 19.4 |
| `ExportSetting` | 仕様 19.5 |
| `CustomStamp` | 仕様 19.6。スタンプ一覧の項目（8.4） |
| `StampAsset` | プロジェクトが参照する不変の画像実体のメタデータ。内容ハッシュを主キーとし参照カウントを持つ（8.4） |
| `ExportRecord` | 仕様 19.7。`batchID` を追加 |
| `Batch` | バッチ単位の履歴（7.2.6） |
| `BatchPreset` | 一括設定プリセット（6.5.8） |

**`runtime.db` を復元してはいけない理由は明確です。** `ExportCommit` を別端末へ復元しても、対応する一時ファイルは存在せず、`UsageLedger`（バックアップ対象外）との整合も失われます。復元された途端に全件が復旧エラーになります。

##### 2 つの接続に分けない

**この分割は制約を生みます。** 手順 7 の単一トランザクション（7.4.3）は `OutputRecord`・`ExportRecord`・キュー状態・`Project` を同時に更新しますが、このうち `ExportRecord` と `Project` は `user-data.db` 側です。

**SQLite の `ATTACH DATABASE` を使い、1 つの接続から両ファイルを扱います。** SQLite は複数 DB にまたがるトランザクションで 2 相コミットを行います。

`ATTACH` を使わず 2 つの接続に分けると、手順 7 が 2 つのトランザクションに割れ、その間で落ちた場合に「出力は公開済みだがキューは `exporting`」という状態が残ります。7.4.3 が排除しようとした不整合そのものです。

##### 原子性が成立する条件

**「`ATTACH` すれば原子的」ではありません。** SQLite の複数 DB トランザクションがクラッシュをまたいで原子的になるのは、条件を満たす場合だけです。**特に WAL では、DB ごとの原子性は保たれても、複数 DB の一部だけがコミットされることがあります。**

次を必須の構成とします。

| 項目 | 規約 |
| --- | --- |
| 接続 | **`DatabaseQueue` を 1 つだけ**使う |
| main database | **`runtime.db`**（`:memory:` にしない） |
| attach | 接続確立のたびに `user-data.db` を `ATTACH` する |
| `journal_mode` | **`DELETE` / `TRUNCATE` / `PERSIST` のいずれか** |
| WAL | **使用しない** |
| `DatabasePool` | **使用しない**（複数接続になり、`ATTACH` の前提が崩れる） |
| 配置 | 両ファイルを**同一ファイルシステム・同一 VFS 上**に置く |
| `synchronous` | **`EXTRA`**（下記） |
| 起動時検査 | **両スキーマの `journal_mode` と `synchronous` を検証する**（下記） |

**WAL を捨てる代償は受け入れます。** WAL は並行読み書きの性能で有利ですが、本アプリの DB アクセスは書き出しの前後に集中し、同時読み書きの負荷が高くありません。**手順 7 の原子性のほうが優先度が高い**と判断します。

##### 検証はスキーマごとに行う

**`PRAGMA journal_mode` はスキーマ単位です。** 片方だけ確認しても意味がありません。

```sql
PRAGMA main.journal_mode;
PRAGMA user_data.journal_mode;
PRAGMA main.synchronous;
PRAGMA user_data.synchronous;
```

いずれかが WAL なら復旧エラーとし、書き出しを開始しません。マイグレーションツールや将来の GRDB が既定で WAL へ切り替える可能性があるため、**設定したつもりが変わっていた**を検出できる形にします。

##### 耐久性の水準を決める

**`synchronous` を `EXTRA` にします。** rollback journal 方式では、`EXTRA` がディレクトリの同期を追加します。既定は `EXTRA` とし、実機計測の結果で `FULL` へ下げる余地を残します。

**保証の強さを段階で書き分けます。** 以前の版は「OS クラッシュ・電源断も保証」としていましたが、これは言い過ぎでした。SQLite の `EXTRA` は rollback journal に対する追加の同期であって、ハードウェアを含むあらゆる条件での絶対的な電源断保証ではありません。Apple の強制同期 API（`F_FULLFSYNC`）にも同じことが言えます。デバイス側の書き込みキャッシュの挙動まではアプリから制御できません。

| 障害 | 保証の水準 | 根拠 |
| --- | --- | --- |
| **プロセス強制終了**（`_exit` / SIGKILL / jetsam） | **保証する** | コミット Saga と単一トランザクション（7.4.3）。12.1.4 が検証する |
| **OS クラッシュ・電源断** | **best effort の耐久性** | `synchronous = EXTRA`、ファイルと親ディレクトリの同期 |
| 復帰後の整合 | **回復する** | コミットジャーナルと起動時復旧（7.4.3）。中断位置がどこでも、いずれかの `ExportCommitState` から再開する |

**要点は「書き込みが必ず届く」ことではなく、「どこで切れても整合を回復できる」ことです。** 電源断で最後の書き込みが失われた場合、その書き出しは 1 つ前の状態から再開されます。会計と成果物の不変条件（6.2.2）は、この再開によって守られます。

| 対象 | プロセス終了 | OS クラッシュ・電源断 |
| --- | --- | --- |
| DB | `synchronous = EXTRA` | 同左（best effort） |
| 出力ファイル | atomic rename で十分 | ファイルと親ディレクトリの同期（best effort） |
| `ProtectedBlobStore` | `replaceItemAt` で十分 | 同上 |

v1 では、**出力ファイルと保護ブロブについてもファイルと親ディレクトリを同期します。** 台帳と出力の整合が崩れると 6.2.2 の不変条件が壊れるため、DB と同じ水準に揃えます。

**同期方式は実機計測後に決めます。** 「1 枚あたり数ミリ秒で無視できる」という以前の記述は、計測前の推測でした。削除します。`F_FULLFSYNC` は端末とストレージの状態によっては数十ミリ秒以上かかることがあり、50 枚のバッチでは体感に現れる可能性があります。計測して、通常の `fsync` との差と、耐久性の差を見比べてから決めます。

`ATTACH DATABASE` の原子性については、**main DB がファイルであり WAL を使わないという条件そのものは正しく**（7.1）、この節で緩めません。

##### 外部キーはスキーマ境界をまたげない

**SQLite の外部キー制約は `ATTACH` した別 DB を参照できません。** `runtime.db` の `OutputRecord.projectID` から `user-data.db` の `Project` への外部キーは作れません。

したがって、この整合性は**アプリ側が保証します。**

| 保証する場所 | 内容 |
| --- | --- |
| 手順 7（7.4.3） | 同一トランザクション内で両 DB を更新し、参照先が存在する状態でのみコミットする |
| 起動時検査（7.4.3 の起動順序） | 下記の不一致を検出する |

起動時に次を検査します。

- `OutputRecord.projectID` に対応する `Project` が存在する
- `ExportQueueItem.batchID` に対応する `Batch` が存在する
- `ExportCommit.projectID` に対応する `Project` が存在する

**不一致の扱いを分けます。**

| 状況 | 扱い |
| --- | --- |
| `OutputRecord` の参照先が無い | **孤児として削除する**（7.5.1 の経路。ファイルも削除） |
| `ExportCommit` の参照先が無い | **復旧エラー**。会計済みか判断できないため自動削除しない |
| `ExportQueueItem` の参照先が無い | 孤児として削除する |

`ExportCommit` だけ扱いが違うのは、それが会計の根拠だからです（7.4.3 の「コミット行の改ざん対策」と同じ理由）。

##### 保護ストア

以下は DB ではなく **`ProtectedBlobStore`** へ保存します。改ざんで権限や枠を書き換えられないようにするためです（6.2.5 の HMAC 署名つき）。

**鍵の保管とデータの保管を分けます。** Keychain は、台帳のような可変データを繰り返し置き換える用途に向きません。

| 役割 | プロトコル | 実装 |
| --- | --- | --- |
| 鍵 | `CryptoKeyStore` | Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`） |
| 署名済みデータ本体 | `ProtectedBlobStore` | アプリ専用ディレクトリ上のファイル（原子的置換） |

原子的な置き換えができることを要件とします。台帳は 1 つのオブジェクトとして丸ごと差し替えるため、部分更新の途中状態が観測されてはいけません（6.2）。実装は一時ファイルへ書いてから `FileManager.replaceItemAt` です。

**`ThisDeviceOnly` を指定するのは、鍵を別端末へ移行させないためです。** ただしこれは**アンインストール時の削除を保証しません**（7.3.1）。

- `SubscriptionState`（6.3 の `Entitlement` キャッシュ）。読み込み失敗時の扱いは 6.3 に定義する
- `RemoteConfigState`（11.3）。last-known-good と `highestAcceptedVersion`。HMAC 不一致ならバンドル既定値へ戻す
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

**「履歴を保存しない」を選んだ場合、本当に保存しません。** 完了画面を離れた時点で、次をすべて削除します。

- プロジェクト設定、検出結果、サムネイル、加工用の中間ファイル
- **`ProjectSourceLocator`**（5.4.2。`Project` と同じ行にあるため同時に消えます）
- **`WorkingSourceRecord` と処理用ファイル**（5.4）
- **`ExportRecord`**（7.5.2）
- **完了済みの `ExportQueueItem`**（7.5.2）

内部的な利便性のために残しておくことはしません。プライバシー保護を掲げるアプリが、保存しないと選んだ利用者のデータを保持している状態は許容できないためです。

例外は 4 つです。

- **未受け渡しの出力ファイル**（6.2.2）。利用者がまだ受け取っていない成果物であり、履歴とは性質が異なります。保存・共有・破棄のいずれかで解消します
- **`UsageLedger` の `SourceRecord` と初回成功時刻**（6.2）。無料枠の判定に必要な最小限であり、ProtectedBlobStore 側に保持します。画像の内容を復元できる情報を含みません
- **一括処理トライアルの消費済み素材識別値**（6.5.6.1）。5 枚分のトライアル対象を判定するために、`SourceRecord`（alias のハッシュ）を ProtectedBlobStore へ **期限なく** 保持します。こちらも画像の内容を復元できる情報を含みません
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

**v1 では、アプリが保存するすべてをバックアップ対象外とします。** 以前の版は `user-data.db` / `stamps/` / `thumbnails/` を未決としていましたが、実装計画の前に確定させます。

##### 配置

**SQLite の journal と super-journal を確実に除外するため、DB をディレクトリで分けます。** これらは DB と同じディレクトリに作られるため、DB ファイルだけを指定しても覆えません。

```
Library/Application Support/runtime/runtime.db
Library/Application Support/user-data/user-data.db
Library/Application Support/user-data/stamps/
Library/Application Support/user-data/thumbnails/
Library/Application Support/runtime/processing/
Library/Application Support/protected/
Library/Caches/stamp-thumbnails/
tmp/raster/
```

同一ファイルシステム上にあるため、`ATTACH` の条件（7.1）は維持されます。

**処理中ファイルを `tmp/` に置きません。** `tmp/` は OS がいつでも削除できます。6.5.8 は「アプリ再起動後に未完了キューを復元する」と定めており、復元したキューが参照する元素材のコピーが消えていれば、その項目は再選択を求めるしかありません。50 枚のバッチで途中終了するたびに全件の再選択を求める体験は成立しないため、**`runtime/processing/` へ置いて OS による削除の対象から外します。** 掃除はアプリ自身が行います（7.3 の起動時清掃、`WorkingSourceRecord` の寿命は 5.4）。

`raster/` は `tmp/` のままです。1 回の `render` 呼び出し内でのみ有効であり（5.1.2）、消えて困る状況が存在しません。

##### 方針

| パス | バックアップ | 根拠 |
| --- | --- | --- |
| `.../runtime/processing/` | 対象外 | `runtime/` 全体と同じ。復元しても整合しない |
| `tmp/raster/` | 対象外 | `render` 呼び出し内でのみ有効（5.1.2） |
| `Library/Caches/stamp-thumbnails/` | 対象外 | 実体から再生成できるキャッシュ（7.3.5） |
| `Library/Application Support/outputs/` | 対象外 | 24 時間で消えるもの。復元しても期限切れ |
| `.../protected/` | 対象外 | HMAC 鍵と寿命を揃えるため（6.2.5） |
| `.../runtime/` | 対象外 | 復元しても整合しない（7.1） |
| **`.../user-data/`（DB・スタンプ・サムネイルを含む）** | **対象外** | 下記 |

##### `user-data/` を対象外にする理由

| 理由 | 内容 |
| --- | --- |
| 商品説明との整合 | 「選択した写真は端末内で処理されます」と述べている以上、顔領域と加工済みサムネイルを OS のクラウドへ移すのは一貫しません |
| 復元の同時点性 | DB と画像ファイルが同じ時点で復元される保証がありません。参照はあるが実体が無い状態が起こりえます |
| 参照の失効 | 別端末では写真ライブラリ参照（`providerAssetKeyHash`）が意味を持ちません。履歴を復元しても再編集できません |
| 復旧 Saga の増加 | 「復元されたが実体が欠けている」経路を v1 で増やしません |

##### 利用者への明示

設定画面と初回起動時に記載します。**黙って失われる状態を作りません。**

> 履歴とマイスタンプはこの端末内にのみ保存されます。アプリの削除や端末の変更では引き継がれません。

##### 将来バックアップする場合

**OS による生ファイルのバックアップではなく、別設計とします。** DB・スタンプ・サムネイルを 1 つの検証可能なアーカイブとして書き出し、復元時に整合を検査する形です。生ファイルの部分復元は、上記の同時点性の問題を解決できません。

##### 実装上の注意

除外の指定は各パスへ `URL.setResourceValues` で `isExcludedFromBackup = true` を設定します。

**ディレクトリへ一度設定すれば足りる、とは考えません。** Apple は `isExcludedFromBackup` について、一般的なファイル操作で値が `false` へ戻りうるため、**ファイルを保存するたびに設定する**よう明記しています。`ProtectedBlobStore` は `replaceItemAt` で置換するため、特にこれに該当します。

**すべてのファイル生成を `ManagedFileStore` へ通します**（7.3.4）。ディレクトリ単位の設定は保険であり、保証ではありません。

#### 7.3.2 再インストール後に鍵だけが残る場合

**「再インストールすれば Keychain の鍵とデータの両方が消える」と仮定できません。**

`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` が保証するのは「別端末へ移行しないこと」であり、**アンインストール時に削除されることではありません。** Apple もこの挙動を文書上の保証としていません。実際、アプリを削除して再インストールしたときに Keychain の項目が残る事例が知られています。

したがって次を**正式な状態**として扱います。

| `ProtectedBlobStore` | `CryptoKeyStore` | 扱い |
| --- | --- | --- |
| `Missing` | `Missing` | 通常の新規台帳を作る（6.2.5） |
| `Missing` | **`Existing`** | **同じく通常の新規台帳を作る。** 鍵はそのまま再利用してよい |
| `Valid` | `Existing` | 通常経路 |
| `IntegrityFailure` | `Existing` | 保守的台帳へ修復（6.2.5） |

**「データが無いのに鍵がある」を異常として扱いません。** 再インストール直後の正常な状態でありえます。ここで復旧エラーにすると、再インストールした利用者がアプリを使えません。

鍵を再利用するか新しく生成するかは、どちらでも安全性が変わりません。**再利用します。** 古い鍵を削除して新規生成する処理は、その削除自体が失敗しうる余計な経路を増やします。

なお、**再インストールで無料枠が戻ることは仕様 14.5 が許容しています**（6.2.5）。鍵が残っていても台帳が無ければ新規台帳になるため、この挙動は変わりません。

#### 7.3.3 データ保護クラス

**バックアップ除外とは別に、端末ロック時の保護レベルを指定します。** バックアップ対象外にしても、端末が盗まれてロック画面の状態で解析されれば、保護クラスが低いファイルは読めます。

本アプリが端末へ置くものには、**未加工の顔画像、未受け渡しの加工済み出力、顔領域を含む履歴**が含まれます。プライバシー保護を目的とする以上、ここを既定任せにしません。

| 対象 | 保護クラス |
| --- | --- |
| 処理中の元画像コピー（`runtime/processing/`） | **`.complete`** |
| 未受け渡し出力（`outputs/`） | **`.complete`** |
| ラスタ一時ファイル（`tmp/raster/`） | **`.complete`** |
| カスタムスタンプ実体（`user-data/stamps/`） | **`.complete`** |
| 履歴サムネイル（`user-data/thumbnails/`） | **`.complete`** |
| `runtime/` / `user-data/` の DB | `.completeUntilFirstUserAuthentication` |
| `ProtectedBlobStore` | `.completeUntilFirstUserAuthentication` |

指定は `FileProtectionType` を `FileManager` の属性として設定します。**バックアップ除外と同じく、ファイル生成のたびに設定します**（7.3.4）。

**アプリ全体の既定を `.completeUntilFirstUserAuthentication` にし、画像系ファイルだけ `.complete` へ上書きします。** 既定を低いままにして個別に引き上げる構成だと、設定漏れが「保護が弱い」方向へ倒れます。既定を上げておけば、漏れても最低限の保護が残ります。

**SQLite は DB 本体だけでは足りません。** rollback journal、super-journal、一時 DB ファイルにも同じ保護が必要です。これらは SQLite が自動生成するため、**ディレクトリの既定保護クラス**で覆う必要があります。ここでも既定を `.completeUntilFirstUserAuthentication` にしておくことが効きます。

##### なぜ DB を `.complete` にしないか

`.complete` はロック中に読み書きできません。**DB をこのクラスにすると、ロック中に起動時復旧を実行できません。**

起動時復旧（7.4.3）は、`UsageLedger` の検証とコミットジャーナルの読み取りを行います。これがロック解除まで待たされると、復旧の完了が不定になり、その間の新規書き出しをブロックし続けることになります。

`.completeUntilFirstUserAuthentication` なら、再起動後に一度ロックを解除すればアクセスできます。**画像そのものを含まない**（履歴のサムネイルは別ファイル）ため、この差を許容します。

##### `.complete` へロック中にアクセスした場合

**破損や欠損として扱いません。** ファイルは存在しており、読めないだけです。

| 誤った扱い | 正しい扱い |
| --- | --- |
| ファイル欠損としてロールバック | **「保護データ利用不可」として処理を一時停止する** |
| 復旧エラーにする | ロック解除後に再試行する |
| `verifiedOutput` との不一致として扱う | 照合を行わず、判断を保留する |

`.complete` のファイルを欠損と誤認すると、**7.4.3 のロールバックが走って会計を戻します。** 実際には出力は無事なので、消費だけが取り消されて出力が残る、あるいは無事な出力が削除されます。

##### 保護データの利用可否は状態で判定する

**エラーコードだけで判断しません。** `NSFileReadNoPermissionError` / `EPERM` は他の原因でも返りえます。

| 手段 | 用途 |
| --- | --- |
| `UIApplication.isProtectedDataAvailable` | **アクセス前に**利用可否を確認する |
| `protectedDataDidBecomeAvailableNotification` | ロック解除後に**処理を再開する** |
| `protectedDataWillBecomeUnavailableNotification` | 進行中の処理を安全な位置で止める |
| `NSFileReadNoPermissionError` / `EPERM` | 上記で捕捉できなかった場合の**補助的な**判定 |

`isProtectedDataAvailable` が `false` の間は `.complete` のファイルへアクセスせず、通知を待ちます。**エラーを受けてから判断する経路を主にしません。** 一度でも誤って欠損と判定すればロールバックが走るためです。

`AppError` に保護データ利用不可の専用コードを設けます（9.1）。このエラーは**再試行可能**として分類し、利用者には「端末のロックを解除してください」と提示します。

##### 利用可否を取得する契約

**上の 3 つはいずれも `UIKit` の API です。** `Application` は `UIKit` を `import` できません（4.4）。契約が無いままだと、`StartupRecoveryCoordinator` は起動順序の手順 −4（保護データの待機、7.4.3）を実装できません。

`Domain` にプロトコルを置きます。

```swift
// Domain — Foundation のみ
enum ProtectedDataState: Sendable, Equatable {
    case available
    case unavailable        // 端末がロックされている
}

protocol ProtectedDataAvailability: Sendable {
    func currentState() async -> ProtectedDataState

    /// available になるまで待つ。すでに available なら即座に戻る
    func waitUntilAvailable() async

    /// unavailable へ遷移したことを購読する。進行中処理を安全な位置で止めるために使う
    var willBecomeUnavailable: AsyncStream<Void> { get }
}
```

| 層 | 役割 |
| --- | --- |
| `Domain` | プロトコルの定義のみ |
| `App`（または専用アダプタ） | `UIApplication.isProtectedDataAvailable` と 2 つの通知で実装する |
| `Application` | このプロトコルだけを呼ぶ。`UIKit` を知らない |

`waitUntilAvailable()` は**キャンセルに応答します。** 起動直後にアプリが終了させられた場合、待機のまま残りません（実装は 7.4.3 の待機キューと同じく `withTaskCancellationHandler` を使います）。

`willBecomeUnavailable` を購読するのは、`.complete` のファイルを読み書きしている最中にロックへ入る場合があるためです。書き出しの手順 3〜7 の途中でこれを受けた場合は、次のジャーナル保存点まで進めてから停止し、`waitUntilAvailable()` で再開します。**処理の途中でエラーにしてロールバックしません。**

12.1.2 の saga テストでは偽実装を差し替え、`unavailable` のまま復旧を開始した場合に待機へ入ることを検証します。

#### 7.3.4 ManagedFileStore

**ファイル生成を 1 か所へ集約します。** バックアップ除外と保護クラスを、生成のたびに確実に設定するためです。

`Domain` がプロトコルを定義し、`Persistence` が実装します。

##### ファイル参照は種別を含む

**ID だけでは削除先を識別できません。** `PendingFileDeletion` は出力・履歴サムネイル・`StampAsset` のすべてに使われますが、以前の版は `outputFileID` という 1 つの文字列しか持っていませんでした。**同じ文字列が別のディレクトリに存在すれば、誤ったファイルを削除します。**

```swift
enum ManagedFileKind: UInt32, Sendable {
    case output = 1
    case stampAsset = 2
    case historyThumbnail = 3
    case stampThumbnail = 4
    case processingTemporary = 5
    case rasterTemporary = 6
    case protectedBlob = 7
}

/// 文字列にしない。任意の値を作れる型では専用ディレクトリ外へ出られる
struct ManagedFileID: Sendable, Hashable {
    let rawValue: UUID
}

struct ManagedFileRef: Sendable, Hashable {
    let kind: ManagedFileKind
    let fileID: ManagedFileID
}

struct PendingFileDeletion: Sendable {
    let file: ManagedFileRef
}
```

**`ManagedFileStore` は `ManagedFileRef` だけを受け取り、呼び出し元へパスを返しません。** パスの解決は `kind` からディレクトリを決め、`fileID` を連結する形に閉じます。これにより、削除・属性設定・孤児 GC・バックアップ判定のすべてが同じ型で処理できます。

##### `fileID` を `String` にしない

**`let fileID: String` である限り、「ID だから専用ディレクトリの外へは出ない」は成立しません。** `"../protected/…"` も `"a/b"` も型として作れます。DB を書き換えられた場合、旧バージョンのデータを読む場合、実装ミスで外部由来の文字列が流れ込んだ場合のいずれからも、パス連結の結果が専用ディレクトリを脱出します。7.4.3 で「パス文字列を保存すると `../` を注入できる」と述べた問題が、`fileID` の側に残っていました。

`UUID` を内部表現にすると、`/` も `.` も含まない値しか存在しません。**構造的に脱出できません。**

永続化とデコードでも同じ保証が要ります。

| 経路 | 規約 |
| --- | --- |
| 生成 | `ManagedFileStore` が採番する。呼び出し元は値を作らない |
| DB への保存 | `UUID` として保存する（文字列カラムでも `UUID` としてデコードする） |
| デコード失敗 | **その行を不正として扱う。** 文字列へフォールバックしない |
| HMAC 正準化 | `UUID` の 16 バイトをそのまま符号化する（7.4.3） |

##### 解決側の二重防御

型だけに頼りません。`ManagedFileStore` の解決処理でも次を行います。

1. `kind` から基準ディレクトリの `URL` を得る
2. `fileID` を連結し、`standardizedFileURL` で正規化する
3. **正規化後のパスが基準ディレクトリ配下であることを確認する**
4. 配下でなければ `open` も `delete` も行わず、エラーとして記録する

`UUID` を通した時点で 3 が失敗することは起こりませんが、将来 `ManagedFileID` の内部表現を変えた場合に、この検査だけが残ります。型と実行時検査の両方を置きます。

| 保存先 | `kind` |
| --- | --- |
| `OutputRecord.outputFile` | `.output` |
| `Project.thumbnailFile` | `.historyThumbnail` |
| `StampAsset` の実体 | `.stampAsset` |
| `ExportCommit.outputFile` | `.output` |

`kind` に `UInt32` の生値を固定するのは、HMAC の正準化（7.4.3）で `enum` の宣言順に依存させないためです。

| 順 | 操作 |
| --- | --- |
| 1 | 一時ファイルへ書く |
| 2 | atomic rename / `replaceItemAt` で最終 URL へ移す |
| 3 | **最終 URL へ `isExcludedFromBackup` を設定する**（該当する場合） |
| 4 | **最終 URL へ `FileProtectionType` を設定する** |
| 5 | 属性を**読み返して検証する** |
| 6 | 検証に失敗したら**完成扱いにしない**（一時ファイルとして残し、GC 対象とする） |

**手順 3 と 4 を rename の後に行います。** `replaceItemAt` は置換先の属性を引き継ぐとは限らないため、置換前に設定しても意味がありません。

**手順 5 の読み返しを省きません。** 設定が反映されなかった場合、次回起動まで気づけません。1 ファイルあたりの属性読み取りは軽く、書き出しの所要時間に影響しません。

対象は次のすべてです。**個別に `FileManager` を呼ぶ実装を許しません。**

- 処理中の一時ファイル
- 未受け渡し出力
- ラスタスタンプ一時ファイル
- カスタムスタンプ実体
- 履歴サムネイル（7.3.5）
- `ProtectedBlobStore` の blob

SQLite のファイル群は GRDB が生成するため `ManagedFileStore` を通せません。ディレクトリの既定保護クラスで覆い、起動時に DB ファイルの属性を検証します。

#### 7.3.5 履歴サムネイル

**7.2.3 の容量上限 200MB は加工後サムネイルを対象としていますが、その保存先が定義されていませんでした。**

| 項目 | 規約 |
| --- | --- |
| ディレクトリ | `Library/Application Support/user-data/thumbnails/` |
| 参照 | ファイル名ではなく **`ManagedFileRef(.historyThumbnail, ...)`**（`Project` が保持） |
| 保護クラス | **`.complete`**（加工後とはいえ顔を含む画像） |
| バックアップ | **対象外**（`user-data/` 配下。7.3.1） |
| 生成 | `ManagedFileStore` を通す（7.3.4） |
| 削除 | `Project` 削除と**同じ DB トランザクション**で `PendingFileDeletion` へ追加（7.5.1） |
| 孤児 GC | 起動時に `Project` から参照されない実体を回収（8.4.1） |
| 復元時に実体が無い | サムネイルなしのプレースホルダを表示する。**履歴自体は消さない** |

**`user-data/` 配下にまとめて置き、一括で対象外にします**（7.3.1）。DB だけ復元されてサムネイルが無ければ履歴一覧が空の画像で埋まり、逆も参照先がありません。分けて判断できる対象ではありません。

`CustomStamp` の一覧サムネイルは、**`StampAsset` の実体から再生成できるキャッシュ**として扱います。バックアップ対象外とし、欠損時は実体から作り直します。履歴サムネイルと違い、元データが手元にあるためです。

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

以前の版では「第 4 手順で消費確定」「コミット手順 7 で最終確定」の 2 つが並存していました。これは 2 つの問題を生みます。

- **どちらが確定点か決まらない。** 手順 6 の検証失敗では会計をロールバックできるため、第 4 手順は確定点ではありません
- **公開済みファイルを抱えたままロールバックする時間差が生じる。** 第 4 手順で利用者へ公開すると、その後の手順 6 失敗で会計を戻す間に、利用者がファイルを取得できてしまいます

境界を 1 本にします。

> **検証済みファイルは、コミット手順 7 が完了するまで UI・`MediaSaver`・`SharePresenter` へ公開しません。**
>
> 手順 4 で台帳へ会計を暫定適用し、**手順 7 のコミット行削除で最終確定します。**
>
> 本書における「利用可能な出力の生成が正常に完了した時点」とは、**コミット手順 7 まで完了した時点**を指します。

| 区間 | 性質 |
| --- | --- |
| 手順 7 より前 | 復旧またはロールバックが可能。成果物は非公開 |
| 手順 7 以降 | 成果物を利用者へ公開する。会計は戻さない |

6.2.1 の「消費は利用可能な加工済み出力の生成が正常に完了した時点で確定する」は、この定義のもとで手順 7 を指します。仕様 14.2 の「保存処理または共有可能な状態になった」とも一致します。手順 7 の完了が、まさに保存・共有が可能になる時点だからです。

##### 非公開を構造で保証する

**「公開しない」と文章で書くだけでは防げません。** `OutputRecord` を会計直後に作ると、GRDB の `ValueObservation` はその時点から `Generated` を観測できます。UI の購読先が `OutputRecord` である以上、最終確定より前に画面へ現れます。

`OutputRecord` の作成を**手順 7 へ移し、コミット行の削除と同一の DB トランザクションで実行します。**

```
手順 5〜6:
  OutputRecord はまだ作らない
  ExportCommit と verifiedOutput だけで健全性を確認する

手順 7（単一トランザクション）:
  OutputRecord(Generated) を insert
  ExportCommit を delete
```

これにより不変条件が観測可能な形になります。

| DB の状態 | 意味 |
| --- | --- |
| コミットあり・`OutputRecord` なし | **非公開**（処理中または復旧対象） |
| コミットなし・`OutputRecord` あり | **公開済み**（会計確定済み） |
| 両方あり | **起こらない**（トランザクションが保証する） |

手順 6 の健全性確認が `OutputRecord` ではなく `verifiedOutput` を参照するのは、この順序変更のためです。確認の時点ではまだ `OutputRecord` が存在しません。

#### 7.4.2 第 2 段階: 利用者への受け渡し

- 写真ライブラリへ保存する（`MediaSaver`）
- OS 共有へ渡す（`SharePresenter`）

いずれも任意であり、何度実行しても追加消費しません（6.2.1）。保存または共有に失敗した場合は、生成済み出力を保持したまま再試行できます（6.2.2）。再書き出しは不要です。

##### 共有結果の扱い

「共有シートを開いた」ことは受け渡しの成功ではありません。**どの結果で `Delivered` へ遷移するかを明示します。**

`SharePresenter` の定義は 5.4 にあります（`@MainActor`）。ここでは結果の型と写像だけを定めます。

```swift
enum ShareResult: Sendable { case completed, canceled, unknown, failed }
```

| 結果 | 出力状態 | 扱い |
| --- | --- | --- |
| `.completed` | `Generated` → **`Delivered`** | 受け渡し成功 |
| `.canceled` | `Generated` を維持 | 利用者が取りやめた |
| `.failed` | `Generated` を維持 | 再試行できる |
| `.unknown` | **`Generated` を維持** | 安全側へ倒す |

`.unknown` は、共有先アプリが完了を返さない場合に生じます。ここで `Delivered` にすると、実際には渡っていない写真を「保存済み」として一時ファイルを消しかねません。**受け取れていない可能性がある側へ倒します。**

##### `ShareLink` では実装できない

**`SharePresenter` は `UIActivityViewController` だけで実装します。**

`ShareLink` は共有 UI を提示する `View` であり、**完了結果を返す API を持ちません。** 上の 4 値を返せない以上、`ShareLink` では `Delivered` への遷移条件を判定できません。SwiftUI 標準であることより、結果を取得できることを優先します。

`UIActivityViewController` の `completionWithItemsHandler` は、選択された `activityType`、完了フラグ、エラーを返します。写像は次とします。

| 条件 | 結果 |
| --- | --- |
| `activityError != nil` | **`.failed`** |
| `completed == true` | **`.completed`** |
| `completed == false` かつ `activityType == nil` | **`.canceled`**（シートを閉じた） |
| それ以外 | **`.unknown`** |

最後の行が要点です。`completed == false` でも `activityType` が入っている場合は、**共有先アプリが結果を返さなかった**ことを意味します。取りやめとは区別できないため `.unknown` とし、`Generated` を維持します。

`UIViewControllerRepresentable` で包み、`CheckedContinuation` で `async` 関数として公開します。3.2 で「`UIViewRepresentable` を使うのは広告バナーだけ」としましたが、**`SharePresenter` も例外に加えます**（`View` ではなくコントローラの提示であり、UI 階層への埋め込みではありません）。

適合テストが、この写像どおりに動くことを検証します（12.1.3）。

#### 7.4.3 コミットジャーナル

書き出しの完了で確定する事柄は、**保存先が 3 つに分かれています。**

| 更新対象 | 保存先 |
| --- | --- |
| 完成済みファイルの公開 | ファイルシステム |
| `OutputRecord` = `Generated` | DB |
| Free 枠の消費、`ExportGrant` の作成 | ProtectedBlobStore |
| 一括トライアル台帳への素材追加 | ProtectedBlobStore |

**単一トランザクションで更新できません。** 異常終了の位置によって次が起こります。

- 出力だけ残り、枠もトライアルも消費されない
- 枠だけ消費され、`OutputRecord` も出力ファイルも残らない
- 通常クォータは更新されたが、トライアル台帳は更新されない

2 つ目は 6.2.2 が守ろうとしている「消費したのに成果物を受け取れない」そのものです。「出力があるなら消費済み」「消費したなら出力を受け取れる」という不変条件が壊れます。

**永続的なコミットジャーナルを置きます。**

```swift
struct ExportCommit: Sendable {
    let exportID: ExportID                  // 6.9
    let projectID: ProjectID
    let batchID: BatchID?
    let sourceID: SourceID                  // 6.2.4 で解決済み
    let outputFile: ManagedFileRef          // 種別つきの参照（7.3.4）
    let authorization: ExportAuthorization  // 開始前に固定する
    let verifiedOutput: VerifiedOutput?     // Prepared では nil。FileVerified 以降は必須
    let finalizedAt: Date?                  // Finalizing で確定する usageNow
    let finalizedPeriod: YearMonth?         // 計上先の年月。finalizedAt から導出
    let intent: AccountingIntent?           // Finalizing で確定する
    let applied: AccountingApplied?         // 台帳へ適用したあとに埋まる
    let state: ExportCommitState
    let signature: Data                     // Keychain の鍵による HMAC
}

/// 手順1の検証結果。これ自体も HMAC の対象に含める
struct VerifiedOutput: Sendable {
    let byteSize: Int64
    let sha256: Data
}

/// grant の操作。ensure と preserve を型で分ける
enum GrantAction: Sendable {
    /// 有効な grant がなければ firstSuccessAt で新規作成してよい
    case ensure(sourceID: SourceID, firstSuccessAt: Date)

    /// 認可時の grant を維持するだけ。新規作成は禁止
    case preserveAuthorized(sourceID: SourceID, firstSuccessAt: Date)
}

/// 台帳へ適用しようとする内容。時刻は finalizedAt から導出する
struct AccountingIntent: Sendable {
    let consumeExportID: ExportID?
    let grantAction: GrantAction
    let trialSourceIDToEnsure: SourceID?
}

/// 台帳へ実際に適用された結果。AccountingCommitted で確定する
struct AccountingApplied: Sendable {
    let consumedInserted: Bool
    let grantInsertedByThisExport: Bool
    let trialInsertedByThisExport: Bool
}

enum ExportCommitState: Sendable {
    case prepared
    case fileVerified          // finalizedAt はまだ nil
    case finalizing            // finalizedAt を確定した。台帳へ適用する直前
    case accountingCommitted
    case readyToPublish        // 手順7の直前。まだ非公開
}
```

**`Completed` から `ReadyToPublish` へ改名します。** この状態では成果物がまだ非公開で、コミット行も残っています。「完了」という名前は実態と合いません。

**「適用しようとする内容」と「実際に適用された結果」を分けます。** 台帳を更新する前に「実際に新規追加した値」を確定することはできません。前者は **`Finalizing`** で、後者は `AccountingCommitted` で埋まります。`FileVerified` の時点では会計時刻が未確定なため、`intent` を作れません（「時刻はすべて最終確定処理から導出する」）。

ただし `AccountingApplied` を DB へ書く前に落ちる可能性があるため、**これだけを根拠にロールバックできません。** 台帳側の `ownerExportID`（6.2）が最終的な判断材料です。

###### grant の操作を型で分ける

**`grantToEnsure` という単一フィールドでは preserve を表現できません。** どの勘定でも「新規作成してよい」という指示になり、後段の文章だけで例外を設けることになります。通常処理と起動時復旧が同じ `AccountingIntent` を読む以上、復旧側の実装が ensure してしまう経路が残ります。

`GrantAction` として型で分けます。

| 勘定 | `grantAction` |
| --- | --- |
| `paidUnlimited` / `freeMonthlyConsume` / `batchTrial(true)` / `batchTrial(false)` | `.ensure(sourceID:firstSuccessAt: finalizedAt)` |
| `freeMonthlyReexport` | `.preserveAuthorized(sourceID:firstSuccessAt: ...)` |

`PreserveAuthorized` の適用規則です。

- 同じ `firstSuccessAt` の grant がまだ存在する → **変更しない**
- 期限切れとして既に削除されている → **再追加しない**
- 別の `firstSuccessAt` へ差し替えない
- `finalizedAt` を使った新規作成を**禁止する**

型で分けたことにより、通常処理と起動時復旧が同じコードパスを通っても 24 時間窓を延長できません。文章上の特例ではなく、`switch` の網羅で強制されます。

###### 検証結果をジャーナルへ持つ

**`FileVerified` で落ちた場合、`OutputRecord` はまだ存在しません**（作られるのは最終トランザクションの手順 7）。検証済みファイルと同じ内容かを起動時に確認する材料が、コミット側になければ復旧できません。

`verifiedOutput` を `ExportCommit` へ持たせます。

| 状態 | `verifiedOutput` |
| --- | --- |
| `Prepared` | `null` |
| `FileVerified` 以降 | 必須 |

- 復旧時は実体のサイズ・SHA-256・デコードを再確認し、`verifiedOutput` と突き合わせる
- 手順 7 の `OutputRecord` 作成時は、`verifiedOutput` から値をコピーする（再計算しない）
- `verifiedOutput` は `ExportCommit` の HMAC 対象に含める

再計算ではなくコピーにするのは、手順 1 と手順 7 の間にファイルが差し替えられた場合に検出するためです。再計算した値を記録すると、差し替え後の内容を「正しい記録値」として固定してしまいます。

###### 時刻はすべて最終確定処理から導出する

**会計時刻を `FileVerified` で確定すると、成功時点と食い違います。**

7 月 31 日に `FileVerified` となり、8 月 1 日に復旧して公開された場合を考えます。

- 利用者が成果物を受け取れるのは 8 月
- 消費は 7 月扱い
- grant の 24 時間は 7 月から開始
- `OutputRecord.generatedAt` の基準が不明

**月をまたぐ場合だけの問題ではありません。** 2 時間後の復旧でも、grant の窓と出力の期限が 2 時間ずれます。「月跨ぎのときだけ再適用する」という規則では不十分です。

そこで **`FileVerified` では `finalizedAt` を確定しません。** 最終確定を試みる直前に `Finalizing` 状態を保存し、そこで初めて時刻を決めます。

```swift
struct ExportCommit {
    // ...
    let finalizedAt: Date?             // Finalizing 以降で必須。FileVerified では nil
    let finalizedPeriod: YearMonth?    // finalizedAt から導出
    // ...
}
```

| 値 | 導出元 |
| --- | --- |
| `finalizedAt` | **`Finalizing` を保存する時点**の `usageNow` |
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
6. 最終トランザクションを実行する

**異常終了後は、月をまたいだかどうかにかかわらず、手順 1 からやり直します。** 新しい `finalizedAt` を決め直すため、経過時間の長短で分岐しません。`Finalizing` 以降で中断した場合も同じです。既に適用済みの会計要素は `ownerExportID` で識別して取り消せます（6.2）。

これにより「利用者が受け取った時刻」と「消費を計上した時刻」が必ず一致します。

**以前の版にあった「過去月の `consumeExportID` を現在月へ加算しない」という規則は削除します。** 成功時点が最終確定である以上、過去月の消費という状態自体が発生しません。

`authorization` は開始時に固定したままです（権限の固定と会計時刻の確定は別の話です）。長時間の中断後に復旧しても、**権限は開始時のもの、時刻は確定時のもの**を使います。

##### 書き出し開始前に権限を固定する

**`Blocked` になりうる評価を、生成が終わったあとに行いません。**

```swift
struct AuthorizedGrant: Sendable {
    let sourceID: SourceID
    let firstSuccessAt: Date       // 認可時に有効だった grant の開始時刻
}

struct ExportAuthorization: Sendable {
    let entitlementSnapshot: Entitlement
    let accountingMode: ExportAccountingMode
    let authorizedAt: Date
    let authorizedGrant: AuthorizedGrant?   // freeMonthlyReexport のとき必須
}

/// 開始を止める理由だけを列挙する。通過を表す値を含めない
enum ExportStartBlockReason: Sendable, Equatable {
    case monthlyLimitReached            // 通常の月間上限
    case ledgerIntegrityFailure         // 台帳破損による当月封鎖（6.2.5）
    case trialCreditsUnavailable        // トライアルのクレジットが残っていない（6.5.6）
    case trialIntegrityLocked           // トライアル台帳の破損による封鎖（6.2.5）
    case capabilityVerificationRequired // 権限の再検証が必要（6.3）
}

struct ExportStartBlock: Sendable, Equatable {
    let reason: ExportStartBlockReason
    let limit: Int?                 // 上限値。提示に使う。該当しなければ nil
}

/// 開始トランザクションの結果。blocked と authorized を型で分ける
enum ExportStartDecision: Sendable {
    case blocked(ExportStartBlock)
    case authorized(AuthorizedExportStart)
}

struct AuthorizedExportStart: Sendable {
    let sourceID: SourceID          // このトランザクションで確定した（6.2.4 / 6.9）
    let authorization: ExportAuthorization
}

/// どの勘定を使う書き出しか。blocked は含めない
enum ExportAccountingMode: Sendable {
    case paidUnlimited                          // 月間枠の対象外（singleExportAccess == .unlimited）
    case freeMonthlyConsume                     // 月間枠を1消費
    case freeMonthlyReexport                    // 24時間以内の再書き出し
    case batchTrial(consumesTrialCredit: Bool)
}
```

書き出し開始時点で利用権限と勘定を確定し、その書き出しについて固定します。`Blocked` なら `ExportCommit` を作らず、生成も開始しません。型に `Blocked` を含めないことで、検証済みファイルを抱えたまま上限超過で破棄する経路を**表現できなくします**。

###### `blocked` に `QuotaDecision` を入れない

**`case blocked(QuotaDecision)` では、型で分けた意味がありません。**

`QuotaDecision` は `unlimited` / `freeReexport` / `consume` / `blocked` を含む列挙です。これを `blocked` の連想値にすると、次がすべて型として構築できます。

```swift
.blocked(.unlimited)      // 無制限なのに開始できない
.blocked(.consume)        // 消費できるのに開始できない
.blocked(.freeReexport)   // 無料で再書き出しできるのに開始できない
```

いずれも意味を成しませんが、コンパイラは止めません。`switch` の網羅も助けになりません。**「`blocked` と `authorized` を型で分ける」という目的は、`blocked` 側が通過を表す値を持てないことまで含みます。**

`ExportStartBlock` は**開始を止める理由だけ**を持ちます。`QuotaDecision` の `blocked` に加えて、トライアル側の 2 つと権限再検証を含めるのは、開始を止める理由が月間枠だけではないためです（6.5.6 / 6.3）。以前の版はこれらを `QuotaDecision` で表現できないまま `blocked` に押し込んでいました。

逆向きの対応は `QuotaPolicy` 側で行います。`evaluate` が `.blocked(reason:limit:)` を返した場合、開始トランザクションが `ExportStartBlockReason` へ写します。`unlimited` / `freeReexport` / `consume` はいずれも `ExportAccountingMode` へ写り、`blocked` にはなりません。

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

**認可の粒度は写真ごとの `exportID` です。** バッチ単位ではありません。この粒度により、6.7 の「契約終了時に未完了バッチを `paused` にする」と両立します。

| Pro 失効時点の状態 | 扱い |
| --- | --- |
| `Prepared` 以降へ進んでいる写真 | 開始時の認可で**完了させる** |
| まだ認可されていない `waiting` の写真 | 開始しない。バッチを `paused` にする |

処理中の 1 枚は最後まで終わり、残りは停止します。

**月間枠の対象となる単体書き出しは同時に 1 件までとします。** 「クォータを消費する書き出し」を条件にできない理由は開始ゲートの項で述べます。消費するかどうかは認可の結果であり、ゲートを取る時点では未確定です。並列に走らせると、開始時の判定が両方 `Consume` になり上限を超えます。

##### 状態ごとの必須フィールド

**会計フィールドは `Finalizing` で確定します。`FileVerified` ではありません。**

| 状態 | 必須フィールド |
| --- | --- |
| `Prepared` | `authorization` のみ |
| `FileVerified` | 上記 ＋ `verifiedOutput` |
| `Finalizing` | 上記 ＋ `finalizedAt` / `finalizedPeriod` / `intent` |
| `AccountingCommitted` | 上記 ＋ `applied` |
| `ReadyToPublish` | 上記 ＋ ファイル再検証済み |

`accountingMode` は `authorization` に固定されているため、`Finalizing` で決めるのは**計上先の年月と grant の時刻だけ**です。

生成中に月や 24 時間期限をまたぐこと、アプリが長時間バックグラウンドへ入ることがあるため、`Prepared` や `FileVerified` の時点で会計内容を確定できません。

##### 台帳更新は直列化する

```swift
struct LedgerTransaction<R: Sendable>: Sendable {
    let ledger: UsageLedger
    let result: R
}

// Domain はプロトコルだけを定義する（4.1）
protocol UsageLedgerStore: Sendable {
    func transact<R: Sendable>(
        _ transform: @Sendable (UsageLedger) throws -> LedgerTransaction<R>
    ) async throws -> R
}
```

オブジェクトの置換が原子的でも、**並列処理が同じ旧台帳を読んで別々に書き戻せば、一方の更新が失われます。** 読み取り・変更・署名・保存を単一の更新口へ通します。

##### `actor` にするだけでは排他区間を保持できない

**Swift の `actor` は再入可能です。** `await` で中断すると、その隙に別の呼び出しが同じ actor のメソッドへ入れます。Swift は actor reentrancy を明示しており、厳密な FIFO も保証しません。

したがって、次はいずれも成立しません。

- `actor UsageLedgerStore` にすれば `transact` 全体が直列化される
- `actor ExportStartGate` にすれば `withExclusivePermit` の `operation` 全体がロックされる

`transact` は「台帳を読む → 変換する → **署名してファイルへ保存する**」であり、保存が `await` を含みます。その中断点で次の `transact` が入れば、更新が失われます。**`actor` は本設計が要求する排他をそのままでは満たしません。**

##### 実装規則

`Domain` はプロトコルだけを定義し、実装は `Persistence` へ置きます（4.1 の依存の向き）。実装 actor には**明示的な待機キュー**を持たせます。

```swift
// Persistence — 実装
actor FileUsageLedgerStore: UsageLedgerStore {
    private var isBusy = false
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var waiters: [Waiter] = []   // FIFO
}
```

| 規則 | 内容 |
| --- | --- |
| 待機キュー | actor 内部に保持する（`isBusy` と `[Waiter]`） |
| 取得 | `isBusy` なら **`withCheckedThrowingContinuation`** で待機する。`CheckedContinuation<Void, Never>` ではキャンセルを伝えられない |
| 保持 | **`await` を含む処理の全体で保持し続ける**（ファイル保存中も解放しない） |
| 解放 | `defer` で必ず行う。`throw` しても解放される |
| 順序 | 待機キューを**明示的に FIFO** とする。actor の暗黙の順序に依存しない |

**`transact` は、読み込みから書き込み完了まで、別の `transact` を進めません。** ファイル保存中の `await` をまたいでも次の台帳処理を開始しません。

`ExportStartGate` も同じ構造です。permit を保持したまま **`await operation()` を実行します。** `withExclusivePermit` から復帰するまで、次の要求は待機します。

**「`actor` にしたから安全」という記述は、本設計では誤りです。** actor が保証するのは actor 内部の可変状態への同時アクセスが無いことだけであり、複数の `await` をまたぐ論理的なクリティカルセクションではありません。

##### キャンセルを扱う

**`CheckedContinuation` だけではキャンセルを解除できません。**

利用者が待機中の写真をキャンセルしても、continuation はキューに残ります。前の処理が終わると resume され、**キャンセル済みのタスクが permit を取得して書き出しを開始します。** 結果としてキャンセル後にクォータやトライアルを消費します。

| 規則 | 内容 |
| --- | --- |
| waiter の識別 | 各 waiter へ **`UUID`** を割り当てる |
| キャンセル時 | **`withTaskCancellationHandler`** でキューから該当 waiter を除去し、`CancellationError` で resume する |
| permit 取得直後 | **`try Task.checkCancellation()`** |
| 認可の直前 | **もう一度 `try Task.checkCancellation()`**（待機中に取り消された場合を捕捉） |
| 解放 | `defer` で必ず行う。キャンセル経路でも解放される |

**チェックを 2 回入れます。** permit 取得直後だけだと、その後の `transact` 開始までの間にキャンセルされた場合を拾えません。認可の直前が最後の安全な中断点です。

##### 二重 resume を防ぐ

**キャンセルと permit 解放が競合すると、同じ continuation を 2 回 resume してクラッシュします。** actor 内部で次の順に行います。

1. **waiter ID をキューから原子的に除去する**
2. **除去できた場合だけ** `CancellationError` で resume する
3. permit 解放側は、**既に除去済みの waiter を resume しない**（キューの先頭から取り出す時点で存在を確認する）

「除去できたか」を resume の条件にすることで、どちらの経路が先に走っても resume は 1 回に収まります。

**`CancellationError` は業務エラーとして扱いません。** Sentry へ送らず（9.4）、キュー項目を `canceled` へ遷移させる制御フローとします。利用者が取りやめた操作は障害ではありません。

##### キャンセルの境界

**どこまでならキャンセルで消費が発生しないかを定めます。**

| 時点 | 扱い |
| --- | --- |
| 手順 4 より前 | **ロールバック。消費なし** |
| 手順 4 以降・最終確定（手順 7）より前 | **暫定会計を取り消してロールバック**（7.4.3 のロールバック手順） |
| 手順 7 の完了後 | **キャンセルではなく破棄として扱う。** 枠は戻さない（6.2.2.4） |

3 行目が要点です。手順 7 が完了した時点で成果物は公開されており、正常生成が確定しています。ここから先の「キャンセル」は、利用者から見れば**出力の破棄**です。6.2.2.4 の「破棄しても消費は戻らない」と同じ扱いにします。

UI 上も、手順 7 の完了後は「キャンセル」ではなく「破棄」と表示します。取り消せるかのような文言にしません。

**更新後の台帳だけを返す API では足りません。** 同じ排他区間の中で次も取り出す必要があります。台帳を外側で読んで結果を計算してから `update` すると、競合が再発します。

- 認可時の `ExportAccountingMode`
- 会計時の `AccountingApplied`
- 正規化後の `usageNow`
- 月次更新後の `period`

一括処理の同時並列数は将来 2 へ増やす設計です（6.5.8）。書き出し処理は並列でも、**台帳のコミットは直列**とします。

##### 同一素材は直列化する

**同じ素材の非終端 `ExportCommit` は同時に 1 件だけとします。**

この不変条件がないと、6.2 の所有者方式が壊れます。

1. Export A が grant を作り、`ownerExportID` が A になる
2. 同じ素材の Export B も正常完了する。B は既存 grant を使うので所有者にならない
3. A のファイル異常でロールバックし、A 所有の grant を削除する
4. **B は成功しているのに grant が消える**

トライアル台帳でも同じことが起きます。

- 並列処理は異なる素材の間だけ許可する
- 同一素材は直列化する。バッチ内に重複があっても同様
- **コミット行の削除またはロールバック完了まで**、その素材をロックする

ロックを `ReadyToPublish` で解放してはいけません。その保存後、コミット行の削除前にも復旧対象となる区間が残っています（7.4.3 の手順 6〜7）。ここで解放すると、同じ素材の次の処理とロールバックが競合します。

この制約を設けない場合、grant とトライアル台帳が複数の成功 `exportID` を保持する必要があり、モデルが複雑になります。v1 では直列化を選びます。

##### 開始ゲート

**「同時 1 件」という規則だけでは競合を防げません。** 認可を通ってから `Prepared` を書くまでの間に、別の書き出しが同じ認可を通過できます。認可の**前**にゲートを取ります。

##### `sourceID` をゲートのキーにできない

**`sourceID` は、ゲートの内側で初めて決まります。**

素材の正規 `sourceID` は、`UsageLedger` 内の alias を検索・統合して確定します（6.2.4）。つまり `sourceID` を得るには `transact` が必要で、`transact` はゲートの内側にあります。**ゲート取得に必要な値が、ゲート取得後にしか分かりません。**

台帳をゲートの外で先読みして `sourceID` を解決すると、**同時処理が同じ alias から別々の `sourceID` を作る競合**が再発します。統合処理そのものが競合対象なので、外で解決しても意味がありません。

##### v1 は全体で 1 件のゲートにする

同時並列数の初期値が 1 である以上（16 節）、素材単位の粒度は実質使われません。**ゲートを全体で 1 件にします。**

```swift
// Domain — プロトコル。実装は Application 側の actor（6.2 の実装規則に従う）
protocol ExportStartGate: Sendable {
    func withExclusivePermit<R: Sendable>(
        operation: @Sendable () async throws -> R
    ) async throws -> R
}
```

**その内側の 1 回の `UsageLedgerStore.transact` で、次をすべて行います。**

1. alias を解決・統合し、**`sourceID` を確定する**（6.2.4）
2. 時刻を正規化し、月次更新と期限切れ grant の整理を行う
3. クォータまたはトライアルを認可する
4. 必要な予約と `SourceLease` を追加する（6.2.4）
5. 更新済み台帳と `ExportStartDecision` を返す

**1 回の `transact` にまとめるのが要点です。** 解決と認可を別々のトランザクションに分けると、その間に別の処理が同じ alias を解決できます。

##### 並列数を 2 へ上げるときの移行

**現在の `sourceID` ゲートをそのまま使えません。** 並列化する場合は 2 段構えにします。

| 段 | ゲート | 内容 |
| --- | --- | --- |
| 1 | **alias 単位の解決ゲート** | alias から `sourceID` を確定するまでを排他する |
| 2 | `sourceID` 単位のゲート | 確定した `sourceID` で以降を排他する |

第 1 段が短時間で終わるため、実質的な並列度は保たれます。この設計は並列数を上げる時点で行い、v1 では実装しません（YAGNI）。

##### 月間枠のゲートは不要になる

以前の版は `requiresMeteredSingleExportGate` で月間枠のゲートを別に取っていましたが、**全体で 1 件のゲートにすれば不要です。** 同時に走る書き出しが 1 件しかない以上、月間枠の二重消費は起こりません。

`requiresMeteredSingleExportGate` の判定と、それを `Plan` からではなく `ResolvedCapabilities` から導く規則（6.2）は、**並列化時に第 2 段のゲートで復活させます。** v1 では判定自体を行いません。

##### ゲートの解放時点

**ゲートは認可の完了では解放しません。コミット行の削除またはロールバックの完了まで保持します。** 書き出しが失敗した場合も、その処理が完全に終わるまで次を開始しません。ロールバックの途中で次の認可が走ると、戻す前の台帳を根拠に判定してしまいます。

開始の順序は次のとおりです。

1. 復旧完了ゲートを確認する（7.4.3 の起動順序）
2. **`withExclusivePermit` を取得する**
3. **その内側で** `UsageLedgerStore.transact` を 1 回実行し、`ExportStartDecision` を得る
4. `.blocked` なら生成せずに終える。ゲートは解放する
5. `ExportCommit(Prepared)` を保存する
6. 処理を開始する
7. 手順 7 の完了またはロールバック完了で**ゲートを解放する**

`OutputRecord` にも `exportID` を持たせ、どのコミットに対応するかを一意にします。

```swift
struct OutputRecord: Sendable {
    let exportID: ExportID                  // 6.9
    let projectID: ProjectID
    let batchID: BatchID?
    let outputFile: ManagedFileRef   // 種別つきの参照（7.3.4）
    let outputByteSize: Int64    // verifiedOutput からコピー
    let outputSHA256: Data       // verifiedOutput からコピー
    let state: OutputState
    let generatedAt: Date        // ExportCommit.finalizedAt からコピー
    let expiresAt: Date          // finalizedAt + 24h
}
```

**時刻も `finalizedAt` から導出します。** `OutputRecord` は手順 7 で作られるため、その時点の `finalizedAt` をコピーすれば、公開時刻・消費計上月・24 時間期限の起点がすべて一致します。

**アルゴリズムを名前で固定します。** `outputDigest` のような抽象名にすると、実装ごとに別のアルゴリズムを選ぶ余地が残ります。記録時と照合時で同じ値を突き合わせる用途なので、SHA-256 に固定します。

**サイズも記録します。** ダイジェストだけでは、手順 6 の「サイズが記録値と一致する」を判定できません。サイズ比較はダイジェスト計算より安く、途中書き込みを先に弾けます。

**パスを DB へ直接持ちません。** `ManagedFileRef` から専用ディレクトリ配下のパスを解決します（7.3.4）。パス文字列を保存すると、DB を書き換えるだけで `../` を含む値を注入でき、期限切れ削除の処理に別のアプリ内部ファイルを消させる経路ができます。ID からの解決なら、削除対象が構造的に専用ディレクトリの外へ出ません。

**期限を `OutputRecord` 自身が持ちます。** 判定は `retentionNow >= expiresAt` です（6.2.2.5）。`retentionNow` が `nil` の間は削除しません。`ExportCommit` は完了後に削除するため、**コミットが消えたあとも単独で期限を判定できる**必要があります。

##### 手順と書き込み順

保存先が DB と ProtectedBlobStore にまたがるため、**書き込み順を固定します。**

**この表が唯一の正です。** 他の節が手順番号や状態遷移に言及する場合は、必ずこの表を参照します。以前の版では複数の節が別々に順序を述べ、互いに食い違っていました。

| 順 | 操作 | 保存先 | 遷移後の状態 |
| --- | --- | --- | --- |
| −2 | `transact` 内で時刻正規化・月次更新・期限切れ grant の整理を**永続化**する。`batchTrial(true)` なら**同じトランザクション内で**トライアル予約を作る | ProtectedBlobStore | — |
| −1 | `transact` の結果として `ExportStartDecision` を得る。`.blocked` なら以降へ進まない | — | — |
| 0 | `ExportCommit` を保存（`verifiedOutput` / `intent` / `finalizedAt` はすべて `nil`）。**保存に失敗したら補償トランザクションで予約・lease・未参照 `SourceRecord` を削除し、ゲートを解放する** | DB | **`Prepared`** |
| 1 | 一時ファイルを生成し、サイズ・SHA-256・デコードを検証して `VerifiedOutput` を得る | ファイルシステム | — |
| 2 | `verifiedOutput` を確定して保存（`finalizedAt` はまだ `nil`） | DB | **`FileVerified`** |
| 3 | **`finalizedAt` を決め、`intent` を確定して**保存 | DB | **`Finalizing`** |
| 4 | `UsageLedger` を冪等に**暫定適用**する。**予約の `trialEntries` への移動と `SourceLease` の削除も同じ台帳トランザクション内** | ProtectedBlobStore | — |
| 5 | `applied` を埋めて保存 | DB | **`AccountingCommitted`** |
| 6 | `verifiedOutput` と出力ファイルの**健全性**を確認して保存 | ファイルシステム / DB | **`ReadyToPublish`** |
| 7 | **単一トランザクション**（下記）。`OutputRecord` を作り、コミット行を削除する。**ここが会計の最終確定境界** | DB | （行が消える） |

状態遷移をまとめると次の 1 本です。

```
Prepared → FileVerified → Finalizing → AccountingCommitted → ReadyToPublish
                                                                   ↓
                                              手順 7 の単一トランザクションで削除
```

**復旧はすべて次へ統一します。**

> `Finalizing` 以降で中断した場合、**暫定会計を取り消し、新しい `finalizedAt` で手順 3 から再開する。**

例外はありません。`ReadyToPublish` も同様です（理由は「復旧の内容は状態で決まります」の項）。

###### 中断はプロセス終了だけではない

**「異常終了したら手順 3 へ戻る」だけでは `finalizedAt` の陳腐化を防げません。** 同じプロセスが生き続けたまま、次の経路をたどれます。

```
手順 3 で Finalizing を保存
  → バックグラウンドへ移行
  → 数時間または数日、実行が停止する
  → 同じ Task が再開する
  → 手順 7 をそのまま実行する
```

プロセスは落ちていないため、起動時復旧を通りません。結果は復旧規則が防ごうとしたものと同じです。

- 公開時刻と `finalizedAt` がずれる
- 月をまたげば計上月がずれる
- `expiresAt = finalizedAt + 24h` が公開直後に切れている

**手順 7 の直前に時刻を再確認します。**

| 順 | 操作 |
| --- | --- |
| 7-a | 新しい `usageNow` を取得する |
| 7-b | `finalizedAt` との差、および `finalizedPeriod` との一致を確認する |
| 7-c | いずれかが規定を外れていれば、**暫定会計を取り消して手順 3 から再確定する** |
| 7-d | 規定内なら、そのまま手順 7 の単一トランザクションを実行する |

判定の規定です。

| 条件 | 扱い |
| --- | --- |
| `usageNow` の年月 ≠ `finalizedPeriod` | **再確定する**（計上月がずれる） |
| `usageNow - finalizedAt` > **5 分** | **再確定する** |
| 上記以外 | そのまま進む |

5 分は、正常な処理で手順 3 から 7 までに要する時間（1 枚あたり数秒、50 枚で数分）を十分に上回り、かつ 24 時間の期限に対して無視できる大きさとして選びます。実機計測後に調整します。

あわせて、**バックグラウンド移行時に手順 3〜7 を進めません。** `willBecomeUnavailable`（7.3.3）と同様に、シーンの非活性化を受けたら次の保存点で停止し、復帰時に上記の再確認から再開します。停止位置は必ずいずれかの `ExportCommitState` であり、中間状態で止まりません。

**「プロセスが落ちた場合だけ再確定する」という以前の規則は、この節で置き換えます。**

**手順 7 を省くと、書き出しのたびにコミット行が永久に蓄積します。** ジャーナルは中断からの復旧のためだけに存在するので、役目を終えたら消します。

**台帳の更新は手順 4 です。手順 7 ではありません。** 手順 7 は DB だけのトランザクションであり、`ProtectedBlobStore` を同時に更新できません。予約から `trialEntries` への移動と `SourceLease` の削除は、台帳トランザクションの中で行います。

###### 手順 7 の内容

**DB に保存する状態は `OutputRecord` だけではありません。** `ExportRecord` と写真ごとのキュー状態も同じ DB にあります。`OutputRecord` の insert とコミットの delete だけでは、次の不整合が残ります。

- 出力は公開済みだが、キューは `exporting` のまま
- キューは `completed` だが、`ExportRecord` が無い
- 履歴上は失敗だが、成果物は存在する

手順 7 の単一トランザクションへ次をすべて含めます。

| 操作 | 対象 |
| --- | --- |
| `OutputRecord(Generated)` を insert | `OutputRecord` |
| 成功記録を insert | `ExportRecord` |
| 対象キュー項目を `completed` へ更新 | キュー状態 |
| プロジェクトの最終更新時刻を更新 | `Project` |
| `ExportCommit` を delete | `ExportCommit` |

バッチの成功件数・失敗件数は、**キュー項目からの導出値**とします。保存値にする場合は同じトランザクションへ含めますが、v1 では導出を採ります。二重管理を避けるためです。

`ExportRecord`（仕様 19.7）は書き出しの履歴として保持します。`OutputRecord` が「いま手元にある未受け渡し出力」を表すのに対し、`ExportRecord` は「いつ何を書き出したか」の記録で、24 時間で消えません。役割が異なるため両方を残します。

###### 手順 6 の確認内容

**存在確認だけでは不足です。** 0 バイトのファイル、途中まで書かれたファイル、デコードできないファイルも「存在する」ため、その状態でコミット行を削除できてしまいます。削除後は会計を戻すためのジャーナルが失われ、消費だけが残ります。

次のすべてを確認してから削除します。**`OutputRecord` はまだ存在しないため、`verifiedOutput` と突き合わせます。**

| 確認項目 | 目的 |
| --- | --- |
| `outputFile` から解決したファイルが存在する | 実体がある |
| ファイルサイズが 0 でなく、`verifiedOutput.byteSize` と一致する | 途中書き込みでない |
| SHA-256 が `verifiedOutput.sha256` と一致する | 内容が入れ替わっていない |
| 簡易デコードが成功する | 画像として開ける |

いずれかが不成立なら削除せず、そのコミットをロールバック対象として扱います。この時点ではジャーナルが残っているため、会計を正しく戻せます。

###### ロールバックの手順と順序

**「ロールバック対象として扱う」だけでは実装できません。** 何をどの順序で削除するかを固定します。

| 順 | 操作 | 保存先 |
| --- | --- | --- |
| 1 | `UsageLedgerStore.transact` で、この `exportID` が所有する会計要素（消費・grant・トライアル台帳・トライアル予約・**`SourceLease`**）を**冪等に**取り消す | ProtectedBlobStore |
| 2 | 台帳の保存が成功したことを確認する | ProtectedBlobStore |
| 3 | `OutputRecord` を削除する（存在する場合のみ。手順 7 未到達なら存在しない） | DB |
| 4 | `outputFile` のファイルを削除する | ファイルシステム |
| 5 | `ExportCommit` を削除する | DB |
| 6 | 全体排他ゲートを解放する（7.4.3 の開始ゲート） | メモリ |

規則は次のとおりです。

- **手順 1 が失敗した場合、2 以降を実行しません。** コミットとファイルを残したまま復旧エラーとします。台帳を戻せていないのにジャーナルを消すと、消費だけが残って根拠が失われます
- **手順 1 の完了後に落ちても、再起動時に同じロールバックを冪等に再実行できます。** 取り消しは集合からの削除であり、二重実行は無害です
- **`ExportCommit` の削除後にのみゲートを解放します。** 解放が早いと、ロールバック途中の台帳を次の認可が読みます（開始ゲートの項）
- 取り消してよいのは、台帳の `ownerExportID` がこの `exportID` と一致する要素だけです（6.2）

###### 状態別のロールバック経路

**コミット行が最終的に消えるまでの経路を、状態ごとに定めます。**

| 状態 | 台帳への適用 | ロールバック経路 |
| --- | --- | --- |
| `Prepared` | **`SourceLease`**、トライアル時のみ予約 | 手順 1〜6。lease・予約・未参照 `SourceRecord` の取り消しは必要。`OutputRecord` は未作成 |
| `FileVerified` | 同上。`finalizedAt` は未確定 | 手順 1〜6 |
| `Finalizing` | 上記 ＋ **暫定会計が存在しうる** | 手順 1〜6。`intent` の内容を `ownerExportID` と突き合わせて取り消す |
| `AccountingCommitted` | 適用済み | 手順 1〜6。`applied` ではなく台帳の `ownerExportID` を根拠にする |
| `ReadyToPublish` | 適用済み | **同一プロセス内なら**手順 7 を実行して完了。**起動時に発見した場合は**暫定会計を取り消して手順 3 から再開（下記） |

`FileVerified` で `applied` を根拠にできない理由は、`AccountingApplied` を DB へ書く前に落ちる可能性があるためです（コミットジャーナルの項）。台帳側の `ownerExportID` が唯一の判断材料です。

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

`ownerExportID` を根拠にコミット削除後のロールバックを許すと、次が成立します。

1. Export A が grant を作り、所有者が A になる
2. A のコミットを正常に削除する
3. 同じ素材を Export B で正常に再書き出しする
4. B は既存 grant を利用するため、所有者は A のまま
5. 後から A の出力ファイルが失われる
6. `ownerExportID` を根拠に grant を削除する
7. **B も正常成功しているのに grant が消える**

トライアル台帳でも同じです。7.4.3 の非終端コミット直列化は、**非終端の間しか効きません。** A のコミットは既に削除済みなので、B の開始を止められません。

###### コミット削除後にファイルが失われた場合

ジャーナルを消したあとで `OutputRecord` と実体が食い違うことは、外部要因（OS によるキャッシュ削除、ストレージ障害）で起こりえます。**この経路では `UsageLedger` を変更しません。**

| 状況 | 扱い |
| --- | --- |
| 元素材と設定から再生成できる | 同じ `exportID` の復旧として、**追加消費なしで再生成する** |
| 再生成できない（元素材が削除された等） | 出力を復元できない旨を利用者へ通知し、壊れた `OutputRecord` を削除する |
| 月間枠 | **戻さない** |
| grant | **戻さない** |
| トライアルクレジット | **戻さない** |

利用者への文言は次とします。

> この加工済み写真のデータが失われました。元の写真が残っていれば、同じ設定でもう一度作成できます（無料枠は消費しません）。

###### 再生成を通常の書き出し Saga で表現しない

**「追加消費なしで再生成する」を既存の `ExportAccountingMode` で実行できません。** どの勘定を選んでも、Saga は台帳と履歴を更新します。

| 起こること | 影響 |
| --- | --- |
| grant を新規作成または延長する | 24 時間の窓が伸び、無料の再書き出し期間が実質延長される |
| `OutputRecord` を insert する | 既存行と主キーが衝突する。あるいは重複行ができる |
| `ExportRecord` を追加する | 履歴に同じ書き出しが 2 回現れる |
| `generatedAt` / `expiresAt` を更新する | 期限が延び、6.2.2 の 24 時間保持が二重に適用される |
| キューの成功件数が増える | バッチの集計が実際の枚数を超える |

**別の操作として型で分けます。**

```swift
enum ExportOperation: Sendable {
    /// 通常の書き出し。手順 −2〜7 をすべて実行する
    case newExport(ExportAuthorization)

    /// 失われた出力の再生成。会計を一切変更しない
    case restoreOutput(
        originalGeneratedAt: Date,
        originalExpiresAt: Date
    )
}
```

`restoreOutput` の規則です。

| 項目 | 規則 |
| --- | --- |
| `UsageLedger` | **変更しない。** 手順 −2 と手順 4 を実行しない |
| `ExportCommit` | 作らない（会計を戻す必要がないため、ジャーナルが不要） |
| `OutputRecord` | **update する。** insert しない |
| `generatedAt` / `expiresAt` | **元の値を維持する。** 延長しない |
| `ExportRecord` | **追加しない** |
| キューの成功件数 | **増やさない** |
| `originalExpiresAt` が既に過去 | **再生成しない。** 期限切れとして `OutputRecord` を削除する |
| 開始ゲート | 通常の書き出しと同じゲートを取得する（同じ素材への同時操作を避ける） |

**期限切れなら再生成しない**のが要点です。再生成しても即座に削除されるだけであり、利用者に「作り直せた」と見せてから消えるほうが体験として悪くなります。この場合の文言は次とします。

> この加工済み写真は保存期限を過ぎています。もう一度加工してください（新しい書き出しとして扱われます）。

12.1.2 の saga テストに、`restoreOutput` が台帳を 1 バイトも変更しないことを検証する項目を置きます。

**手順 4 と 5 を逆にしてはいけません。** 先に `AccountingCommitted` を書くと、台帳が未反映のまま「反映済み」として復旧されます。この順なら 4 と 5 の間で落ちても状態は `Finalizing` のままなので、台帳更新を冪等に再適用できます。

手順 0 で `Prepared` を先に書くのは、**生成中に落ちたときに孤児となる一時ファイルを起動時に特定するため**です。ジャーナルに記録のない一時ファイルは掃除対象になります。

冪等性の鍵は 2 種類です。**クォータ消費は `exportID`、トライアル消費は素材の同一性。** 前者は同じ書き出しの再実行、後者は同じ写真の再書き出しを弾くもので、目的が異なります。台帳が集合を保持しているため（6.2）、再適用は自然に無害です。

##### 署名の対象と再署名

**`ExportCommit` は状態遷移のたびに内容が変わります。** 初回挿入時の署名を残したまま状態だけ更新すると、正規の更新なのに次回起動で検証失敗になります。共通の形式と規則を定めます。

```swift
enum PayloadType: UInt32, Sendable {
    case usageLedger = 1
    case subscriptionState = 2
    case exportCommit = 3
    case remoteConfigState = 4    // 11.3
}

struct SignedPayload: Sendable {
    let payloadType: PayloadType
    let schemaVersion: UInt32
    let canonicalBytes: Data
    let signature: Data
}
```

- HMAC の対象は **`signature` 自身を除く全永続フィールド**
- **専用のバイナリエンコーダで正準形を作る**（下記）
- **スキーマバージョンを署名対象へ含める**
- **`payloadType` を署名対象へ含める**（下記）
- `ExportCommit` の insert / update の**たびに再署名する**
- `UsageLedgerStore.transact` の保存時にも必ず再署名する
- 検証はバイト列の**定数時間比較**で行う
- マイグレーション時は旧形式で検証してから新形式で再署名する

**`payloadType` を含めないと、種別をまたいだ付け替えを検出できません。** 4 種のデータが同じ鍵で署名されているため、署名だけを見れば有効な `SubscriptionState` の blob を `UsageLedger` の保存先へ置いても検証を通ります。復号ではなく検証しかしていないため、内容の構造が偶然パースできれば通過します。

##### 正準形は専用エンコーダで作る

**「シリアライズ順序を固定する」だけでは実装が定まりません。** `UsageLedger` には次が含まれます。

- `Set<String>`（`consumedExportIDs`）
- `[SourceRecord]` / `[GrantEntry]` / `[TrialEntry]` / `[TrialReservation]`
- `Set<SourceAlias>`
- `Date`
- `UUID`

**`JSONEncoder` や binary plist を正準形として使いません。** 集合と配列の順序、`Date` の表現（秒か ミリ秒か、浮動小数の丸め）、辞書のキー順が実装とバージョンに依存します。**同じ意味の台帳から別の署名が出れば、正規の起動が `IntegrityFailure` になります。**

HMAC 専用のバイナリエンコーダを定義します。

| 型 | 符号化 |
| --- | --- |
| 先頭 | `payloadType`（`UInt32`）＋ `schemaVersion`（`UInt32`） |
| 整数 | **ビッグエンディアン**の固定長 |
| `enum` | 固定の `UInt32`（`case` の宣言順に依存させない） |
| 可変長データ | `UInt32` の長さ前置き |
| `Date` | **UTC epoch milliseconds の `Int64`** |
| `Double` | **IEEE 754 の `bitPattern`**（文字列化しない） |
| `UUID` | 16 バイトのビッグエンディアン |
| `Optional` | **`0` / `1` のタグ** ＋ 値（`nil` は タグのみ） |
| `String` | **UTF-8** バイト列 |
| コレクション | **先頭に `UInt32` の要素数**、各要素は長さ前置き |
| **unordered collection** | 各要素を符号化し、**バイト列の辞書順にソート**してから連結 |
| **ordered array** | **元の順序を保持する。ソートしない** |

##### 「配列はすべてソートする」は誤り

**順序に意味を持つ配列が存在します。** 以前の版は一律にソートすると定めていましたが、これは `RenderSpec.regions` のような配列に適用すると**描画順を変えます**（5.2.1 の `order`）。署名のための正準化が、意味を持つデータを壊します。

型ごとに分類を固定します。

| 分類 | 対象 | 符号化 |
| --- | --- | --- |
| unordered | `consumedExportIDs`、`sourceRecords`、`grants`、`trialEntries`、`trialReservations`、`sourceLeases`、`SourceRecord.aliases` | **ソートする** |
| ordered | `RenderSpec.regions`、`ReviewIssueID.affectedFaceTrackIDs`、リモート設定内の順序付きリスト | **保持する** |

`affectedFaceTrackIDs` は既に「辞書順にソート済み」として構築されますが（6.5.2）、それは**構築時の規則**であり、正準化がソートするのではありません。順序は値の一部です。

**分類は型に付けます。** 「この配列はソートする / しない」を呼び出し側の判断に委ねると、新しいフィールドを追加したときに取り違えます。unordered な集合は Swift の `Set` として宣言し、`Array` はすべて ordered として扱うのが原則です。`grants` などが `Array` なのは要素が `Hashable` でないためであり、この場合は**エンコーダ側に unordered として明示的に登録します。**

##### トップレベル payload のフィールド順

**型ごとの符号化順を決めても、payload そのもののフィールド順が無ければ正準形は一意になりません。**

各 `schemaVersion` について、次を固定します。

| payload | `schemaVersion` 1 のフィールド順 |
| --- | --- |
| `UsageLedger` | `period` → `consumedExportIDs` → `sourceRecords` → `grants` → `trialEntries` → `trialReservations` → `sourceLeases` → `lastObservedAt` → `monthlyIntegrityLock` → `lastTrustedMonth` → `trialIntegrityLocked` |
| `SubscriptionState` | `plan` → `status` → `expiresAt` → `willRenew` → `fetchedAt` |
| `ExportCommit` | `exportID` → `projectID` → `batchID` → `sourceID` → `outputFile` → `authorization` → `verifiedOutput` → `finalizedAt` → `finalizedPeriod` → `intent` → `applied` → `state` |
| `RemoteConfigState` | `highestAcceptedVersion` → envelope の固定フィールド順 → payload の固定フィールド順 |

**追加は末尾のみ**とし、既存フィールドの順序を変えません。順序を変える必要が生じた場合は `schemaVersion` を上げ、旧バージョンのデコーダを残します（「署名の対象と再署名」のマイグレーション規則）。

##### ゴールデンテスト

**各 `schemaVersion` について、固定の canonical bytes と HMAC 値をテストに埋め込みます。**

| 検証 | 目的 |
| --- | --- |
| 既知の値から生成した canonical bytes が、期待するバイト列と一致する | 符号化の変更を検出する |
| 固定鍵で計算した HMAC が、期待する値と一致する | 署名の互換性を検出する |
| 集合の構築順を変えても同じバイト列になる | unordered の分類が正しい |
| ordered 配列の順序を変えると別のバイト列になる | ordered の分類が正しい |

**リファクタリングで正準形が変わると、既存利用者の台帳がすべて `IntegrityFailure` になります。** 単体テストで気づけなければ、リリース後に発覚します。

##### 型ごとの符号化順

**「`sourceID` → `firstSuccessAt` → `ownerExportID` で一律」では足りません。** そのキーを持たない型があります。

| 型 | フィールドの符号化順 |
| --- | --- |
| `consumedExportIDs` | 要素（`ExportID` の 16 バイト）を昇順にソート |
| `SourceRecord` | `sourceID` → `aliases`（各 alias を正準バイト順にソート） |
| `ProjectID` / `BatchID` / `ExportID` / `RegionID` / `SourceID` / `ManagedFileID` | **`UUID` の 16 バイト**（6.9 / 7.3.4） |
| `ManagedFileRef` | `kind`（固定 `UInt32`）→ `fileID`（16 バイト） |
| `MonthlyIntegrityLock` | case 番号（固定 `UInt32`）→ 連想値（`.lockedUntilTrustedMonthAfter` のみ `YearMonth`） |
| `SourceAlias` | **case 番号（固定 `UInt32`）** → 値（`String`） |
| `GrantEntry` | `sourceID` → `firstSuccessAt` → `ownerExportID` |
| `TrialEntry` | `sourceID` → `ownerExportID` |
| `TrialReservation` | `sourceID` → `exportID` |
| **`SourceLease`** | `sourceID` → `exportID` |
| `RemoteConfigState` | `highestAcceptedVersion` → envelope の固定フィールド順 → payload の固定フィールド順 |

**`SourceAlias` の case 番号を固定します。** `enum` の宣言順に依存させると、`case` を追加した時点で全台帳の署名が変わります。

**`RemoteConfig` の内部にも配列や集合があります**（有効なスタンプパック等）。それぞれに個別の順序規則を定め、payload の固定フィールド順に含めます。

##### `RemoteConfig` の値域検証

署名の検証とは別に、**内容の整合も確認します**（11.3 の「設定全体を拒否する」の判定材料）。

- `minimumSupportedVersion <= recommendedVersion`
- `issuedAt <= expiresAt`
- 各閾値が有限（`isFinite`）かつアプリ内の許容範囲内

`contentFingerprint` の正準化（6.2.4）と同じ方式ですが、**エンコーダは共用しません。** 用途が違えばスキーマ変更のタイミングも違い、片方の変更がもう片方の署名を壊すためです。

##### 鍵の用途を分離する

**同じマスター鍵を複数の用途で直接使いません。**

| 用途 | 派生ラベル |
| --- | --- |
| 台帳・購入状態・コミットの署名 | `payload-signing-v1` |
| `providerAssetKeyHash` のソルト（6.2.4） | `source-provider-key-v1` |

`CryptoKeyStore` が保持するマスター鍵から **HKDF** で派生させます。`payloadType` を info に含めて用途ごとに鍵を分ける方式も採れますが、v1 では `payloadType` を署名対象へ含める方式とします。実装が単純で、鍵の数が増えないためです。

**署名とソルトを分けるのは、性質が違うからです。** ソルトは値の秘匿が目的で、署名鍵は完全性の保証が目的です。同じ鍵を使うと、片方の運用（ローテーション等）がもう片方へ波及します。

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

`ExportCommit` は DB にありますが、その内容が ProtectedBlobStore の台帳更新を駆動します。**DB を書き換えれば台帳を任意に操作できてしまう**ため、コミット行にも Keychain の鍵で HMAC を付けます（6.2.5 と同じ方式）。

**署名検証に失敗した行を自動破棄しません。** 破棄すると、すでに反映済みの `UsageLedger` だけが残る可能性があります。会計済みかどうかを判断できない以上、**復旧エラーとして扱い**、新規書き出しをブロックしたうえで利用者へ提示します。ファイルも自動削除しません。

##### 復旧エラーの解消

**ブロックしたまま解除手段がないと、破損したコミット 1 件でアプリが永久に書き出し不能になります。** 利用者が抜け出せる操作を用意します。

> 処理情報が破損しているため、この書き出しを復元できません。

選択肢は「もう一度試す」と「破損した処理を破棄して続ける」の 2 つです。

「破棄して続ける」の挙動は次のとおりです。

- クォータやトライアルクレジットを払い戻さない
- **台帳側の予約を先に確定させる**（下記）
- 該当の `ExportCommit` を**行 ID で**削除する。**出力ファイルと `OutputRecord` には触れない**（下記）
- 復旧エラーを解除し、新規書き出しを許可する

払い戻さないため利用者に不利になりえますが、**破損した DB の情報を根拠に権利を増やす方が危険**です。改ざんによる枠の水増しに直結します。アプリが永久に使用不能になる状態も同時に避けられます。

###### 予約を放置するとクレジットが払い戻される

**「台帳を変更しない」では不十分でした。** 次の経路でトライアルクレジットが戻ります。

1. 署名不正のコミットに対応する `trialReservations` が台帳にある
2. 「破棄して続ける」で `ExportCommit` だけを削除する
3. 次回起動時、**その予約は有効なコミットに対応しない**（起動順序の手順 3）
4. 孤児予約として削除される
5. **クレジットが 1 枚戻る**

「払い戻さない」という方針と矛盾します。

###### 署名不正行のフィールドを一切使わない

**HMAC 検証に失敗した時点で、その行の全フィールドが信用できません。**

`exportID` / `sourceID` / `outputFile` / `projectID` / `authorization` / `state` のいずれも改ざんされている可能性があります。以前の版は「その行の `exportID` で予約を探す」「その行の `outputFile` を削除する」としていましたが、これは攻撃経路です。

| 改ざん先 | 起こること |
| --- | --- |
| `exportID` を別の正規予約のものへ | **無関係なクレジットを消費させられる** |
| `outputFile` を別の正常な出力へ | 専用ディレクトリ外へは出られないが、**他の正常な出力を削除できる** |
| `projectID` を別の履歴へ | 無関係な履歴を巻き込む |

**復旧の根拠は署名済み `UsageLedger` 側だけとします。**

まず、有効な署名済みコミットに対応しない `SourceLease`（孤立 lease）を抽出します。v1 は全体ゲートにより同時 1 件なので（開始ゲートの項）、孤立 lease は 0 件か 1 件のはずです。

**件数で分岐します。**

| 孤立 lease | 処理 |
| --- | --- |
| **0 件** | **台帳を一切変更せず**、署名不正行を DB 内部の行 ID だけで削除する |
| **1 件** | その `exportID` の `TrialReservation` を同じ `sourceID` の `TrialEntry` へ変換し、`SourceLease` を削除する。台帳の保存成功を確認してから、署名不正行を行 ID で削除する |
| **2 件以上** | 対応を一意に決められない。**復旧エラーを維持し、台帳へ触れない** |

**0 件を「復旧不能」にしません。以前の版はここで永久ブロックしていました。**

`SourceLease` は手順 4 の台帳トランザクションで削除されます（手順と書き込み順）。したがって次の状態でコミット行だけが壊れた場合、**孤立 lease が 0 件なのは正常です。**

- `AccountingCommitted`
- `ReadyToPublish`
- 手順 4 の完了後、手順 5 の保存前

これらを「孤立 lease がちょうど 1 件」の条件で要求すると、どの経路でも復旧エラーから抜けられません。0 件は「台帳側にこの書き出しの痕跡が残っていない」ことを意味し、**台帳へ何もしないことが正しい対応**です。会計は既に確定しており、払い戻しは行いません。

2 件以上は、全体ゲートが 1 件しか許さないはずの状態と矛盾します。自動で「たぶんこれだろう」と決めず、復旧エラーを維持します。

**1 件の場合に台帳の保存が失敗したら、コミットを削除せず復旧エラーを維持します。** 台帳を確定できていないのにコミットを消すと、次回起動で孤児予約として払い戻されます。

**署名不正行が存在する間は、孤児 `TrialReservation` と孤児 `SourceLease` の自動回収を全件保留します。** どの孤児が破損行に対応するかを識別できないためです（起動順序の手順 3）。回収を再開するのは、復旧エラーが解消されたあとです。

###### ファイルには触れない

**「該当の出力ファイルと `OutputRecord` を削除する」という以前の記述を削除します。**

署名不正行の `outputFile` と `projectID` は信用できません。`ManagedFileRef` により専用ディレクトリの外へは出られませんが（7.3.4）、**同じディレクトリ内の別の正常な出力を指すことは可能です。** それを削除すれば、無関係な書き出しの成果物が失われます。

行を削除したあと、その出力ファイルはどこからも参照されなくなります。**起動時の孤児ファイル GC が回収します**（8.4.1）。参照の有無だけを根拠にするため、改ざんされたフィールドの影響を受けません。

**孤児回収から除外するのは予約だけではありません。** 署名不正行に対応する `SourceLease` も、復旧エラーが解消されるまで自動回収の対象外とします（起動順序の手順 3）。

`TrialEntry` の `ownerExportID` には対象の `exportID` をそのまま入れます。**その書き出しは成功していませんが、クレジットは消費されたものとして扱います。** これが「払い戻さない」の意味です。

同じ素材を再度処理する場合、`trialEntries` に該当があるため `batchTrial(false)` となり、追加のクレジットは消費しません（6.5.6.1）。**利用者から見れば「1 枚分の試用機会を使ったが、その素材はまた試せる」**という状態になります。

##### 起動時の順序

**復旧を終えるまで、新しい書き出しを開始させません。**

順序を固定します。**各手順が前の手順の結果に依存します。**

| 順 | 操作 | 依存 |
| --- | --- | --- |
| −4 | **保護データが利用可能になるまで待つ**（7.3.3） | — |
| −3 | `runtime.db` を開き、`user-data.db` を `ATTACH` する | −4 の完了 |
| −2 | 両スキーマの `journal_mode` と `synchronous` を設定・検証する（7.1） | −3 の完了 |
| −1 | **両 DB のスキーマ移行を実行する**（下記） | −2 の完了 |
| 0 | **`ProtectedBlobStore` のスキーマ移行を実行する** | −1 の完了 |
| 1 | `UsageLedger` を読み込み、検証し、必要なら修復する（6.2.5） | 0 の完了 |
| 2 | `ExportCommit` を読み込み、行ごとの署名を検証する | 0 の完了 |
| 3 | **有効なコミットに対応しない `trialReservations` と `sourceLeases` を削除する**（孤児予約・孤児 lease） | 1・2 の完了 |
| 4 | 有効な未完了コミットを復旧する（下表） | 1・2・3 の完了 |
| 5 | **DB 間参照の整合を検査する**（7.1 の「外部キーはスキーマ境界をまたげない」） | 4 の完了 |
| 6 | `PendingFileDeletion` と孤児ファイルを回収する（8.4.1） | 5 の完了 |
| 7 | 未受け渡し出力を復元する（6.2.2.1） | 5 の完了 |
| 8 | **`evaluateUpdate` を実行する**（6.8.5） | 7 の完了。`Generated` の件数が必要 |
| 9 | `.required` なら更新画面、それ以外は通常画面を表示し、**新しい書き出しを許可する** | 全手順の完了 |

**手順 3 を手順 4 より前に置きます。** 孤児予約はクレジットを占有したままなので、これを回収する前に新しい認可を許可すると、実際には空いているクレジットを「使用中」と判定します。

**手順 5 を手順 4 の後に置きます。** ロールバックが `OutputRecord` を削除するため、先に検査すると存在しない不一致を検出します。

**署名検証に失敗したコミットに対応する予約は、自動削除しません。** そのコミットが会計済みかどうかを判断できない以上（7.4.3 の「コミット行の改ざん対策」）、予約だけを消すと台帳と食い違います。**復旧エラーが解消されるまで予約を保持します。**

手順 6 を手順 5 の後に置くのは、ロールバックと孤児削除が `PendingFileDeletion` へ行を追加しうるためです。先に GC を走らせると、その回で回収できません。

**手順 −4 を最初に置くのは、`.complete` のファイルがロック中に読めないためです**（7.3.3）。DB を開く前に待ちます。

##### 2 つの DB の移行は 1 トランザクションで行う

**個別の `DatabaseMigrator` を順に commit しません。** 片方だけ移行が済んだ状態で落ちると、2 つの DB のスキーマバージョンが食い違い、次回起動でどちらを正とするか決められません。

両 DB を変更する移行は、**`ATTACH` 済みの単一トランザクション**で実行します。SQLite の 2 相コミットが、両方適用か両方未適用かを保証します（7.1）。

片方の DB だけを変更する移行は、その DB に閉じたトランザクションで構いません。ただし**移行の版番号は 1 系列で管理し**、どちらの DB を変更したかを記録します。

先に新しい書き出しを許可すると、あとから古いコミットをロールバックした際に、**すでに進んだ現在の台帳まで壊しかねません**。

復旧の内容は状態で決まります。

| 中断位置 | 復旧 |
| --- | --- |
| `Prepared` | 一時ファイルを削除し、**トライアル予約・`SourceLease`・未参照になった `SourceRecord`** を取り消してコミットを破棄する。生成未完了なので消費しない（6.2.1） |
| `FileVerified` | ファイルが健在なら**手順 3 からやり直す**（新しい `finalizedAt` を決める）。失われていればロールバック |
| `Finalizing` | 暫定適用があれば冪等に取り消し、**手順 3 からやり直す**。経過時間の長短で分岐しない |
| `AccountingCommitted` | **出力ファイルを再検証**する（下記）。正常なら暫定適用を取り消し、**手順 3 からやり直す** |
| `ReadyToPublish` | 出力ファイルを `verifiedOutput` と照合する。正常なら暫定適用を取り消し、**手順 3 からやり直す**。不一致ならロールバック |
| 署名検証に失敗 | 復旧エラー。自動破棄しない |

**`Finalizing` 以降からの復旧は、`ReadyToPublish` を含めて必ず手順 3 へ戻ります。** `finalizedAt` を決め直すためです。月をまたいだかどうかで分岐しません。2 時間の中断でも、grant の窓と出力の期限が 2 時間ずれます。

**`ReadyToPublish` を例外にできません。** この状態で異常終了し、数日後に再起動した場合を考えます。

- `finalizedAt` は数日前
- 実際に公開されるのは再起動時
- `expiresAt = finalizedAt + 24h` は**すでに過ぎている**

つまり、公開した瞬間に期限切れの出力ができます。利用者は成果物を受け取れないまま消費だけを負います。ファイル検証が済んでいることと、時刻が妥当であることは別の話です。

再確定のコストは、暫定適用の取り消しと再適用だけです。どちらも `ownerExportID` を根拠とする冪等な操作であり（6.2）、失うものはありません。

**`ReadyToPublish` を無条件に削除しません。** 手順 6 と 7 の間で落ちた可能性があり、**コミット行だけが復旧の手がかり**だからです。この時点では `OutputRecord` がまだ無いため、コミットを消すと出力が孤児ファイルになります。

##### `AccountingCommitted` からの復旧

台帳は暫定適用済みなので、**ファイルが失われていれば「消費したのに受け取れない出力」になります。** 先へ進む前に、出力ファイルの存在・整合性・デコードを再確認します。

| 再検証の結果 | 対応 |
| --- | --- |
| 正常 | 暫定適用を取り消し、手順 3 からやり直す（`OutputRecord` は手順 7 で作る） |
| 欠損・破損 | **このコミットが実際に追加した会計要素だけ**を取り消す（ロールバック手順） |
| 取り消し不能 | 復旧エラーとして新規書き出しをブロックする。自動削除しない |

**取り消しの判断材料は台帳側の `ownerExportID` です**（6.2）。`AccountingApplied` は DB へ書く前に落ちうるため、単独では根拠になりません。

```
consumedExportIds に対象 exportID があれば削除
grants のうち ownerExportID == 対象 exportID の要素を削除
trialEntries のうち ownerExportID == 対象 exportID の要素を削除
trialReservations のうち exportID == 対象 exportID の要素を削除
sourceLeases のうち exportID == 対象 exportID の要素を削除
別の exportID が作った要素は削除しない
```

これなら手順 3 と 4 の間で落ちても、**所有者から正しく判別できます**。既存の grant を再利用しただけの書き出しは `ownerExportID` が一致しないため、以前から存在した権利を巻き添えで消しません。

### 7.5 削除の経路

7.2.3 の容量上限を超えた場合、削除候補は更新日時が最も古いもののうち、**下記の削除可否判定を通ったもの**とします。

写真ライブラリへ保存済みの出力ファイルは、明示的な確認なしに削除しません。

#### 7.5.0 履歴の削除可否判定

**除外条件を文章で列挙すると、参照元が増えるたびに書き漏らします。** 以前の版は「お気に入り」「編集中」「キュー中」「24 時間保持対象」の 4 つしか挙げておらず、**実行中・復旧中のデータを巻き込めました。**

判定を 1 か所へ集約します。

```swift
func canDeleteHistoryUnit(
    _ unit: HistoryUnit,          // Project または Batch
    context: DeletionContext
) -> Bool
```

**次のいずれかから参照されていれば削除できません。**

| 参照元 | 巻き込んだ場合に起こること |
| --- | --- |
| お気に入り | 利用者が明示的に保護した履歴が消える |
| 編集中のプロジェクト | 編集画面が参照先を失う |
| **非終端のキュー項目**（`waiting` / `exporting` / `paused`） | 処理中のバッチが消える |
| **`OutputRecord`** | 未受け渡し出力の実体だけが残り、レコードが孤児になる |
| **非終端の `ExportCommit`** | 復旧の手がかりを失い、会計を戻せなくなる |
| **`WorkingSourceRecord`**（5.4） | 処理用の元素材が消え、キューを復元できない |
| **出力再生成 Saga の対象**（`restoreOutput`、7.4.3） | 再生成中の対象が消える |
| 7.2.4 の 24 時間やり直し保証 | やり直しができなくなる |

**判定と削除は `ATTACH` した同一トランザクション内で行います**（7.1）。`runtime.db` の `OutputRecord` / `ExportCommit` / `ExportQueueItem` / `WorkingSourceRecord` と、`user-data.db` の `Project` / `Batch` を跨いで見る必要があるためです。別トランザクションに分けると、判定と削除の間に新しい参照が生まれます。

**判定の入口を 1 つにします。** 容量超過による自動削除、保存期間による期限削除、利用者による手動削除のいずれも、この関数を通します。手動削除だけを例外にしません。利用者が「削除」を押した時点で処理中のバッチが消えてよい理由はありません。

削除できない場合の扱いです。

| 契機 | 扱い |
| --- | --- |
| 容量超過による自動削除 | 次の候補へ進む。全候補が削除不可なら、利用者へ空き容量の確保を求める |
| 保存期間による期限削除 | **保留する。** 参照が消えた時点で削除対象へ戻る |
| 利用者による手動削除 | 理由を提示して拒否する（「この写真は処理中です」） |

#### 7.5.1 出力の削除

**「ファイルを消す」だけでは `OutputRecord` が孤児になります。** 実体の無いレコードが残ると、期限判定や復旧案内の枚数（6.2.2.1）が実態と食い違います。

**すべての出力削除を単一の経路へ統一します。**

| 順 | 操作 |
| --- | --- |
| 1 | DB トランザクションで `OutputRecord` を削除する |
| 2 | **同じトランザクション内で** `PendingFileDeletion(file:)` を追加する |
| 3 | DB のコミット後にファイルを削除する |
| 4 | 成功したら `PendingFileDeletion` の行を削除する |
| 5 | 失敗したら起動時 GC で再試行する（8.4.1） |

対象は次のすべてです。**入口ごとに別の順序を実装しません。**

- `Delivered` 状態で完了画面を離れた
- 利用者が破棄した
- `Generated` が 24 時間経過した
- 壊れた出力を復元できなかった（7.4.3 の「コミット削除後にファイルが失われた場合」）

順序の根拠は 8.4.1 と同じです。**失っても復旧できないほうを避けます。** ファイルを先に消して DB が失敗すると、レコードだけが残って実体を指せません。DB を先に更新すれば、残るのは孤児ファイルだけで、GC が回収します。

#### 7.5.2 `ExportRecord` と履歴の削除

`ExportRecord` は「いつ何を書き出したか」の履歴であり、24 時間では消えません（7.4.3）。**そのため、履歴設定の対象になります。**

以前の版では、「履歴を保存しない」設定の例外として `未受け渡し出力` / `UsageLedger` / `未完了 ExportCommit` の 3 つを挙げていましたが、`ExportRecord` の扱いが抜けていました。この状態では**履歴を保存しない設定でも書き出し記録が残ります。**

| 保存期間の設定 | `ExportRecord` の扱い |
| --- | --- |
| 履歴を保存しない | **完了画面を離れた時点で削除する** |
| 7 日 / 30 日 | 期限で削除する |
| 保存期限なし | 容量上限に達したら古いものから削除する |

**`ExportRecord` は、対応する `Project` または `Batch` と同じトランザクションで削除します。** 別々に消すと、履歴一覧に「プロジェクトはあるが書き出し記録が無い」または「書き出し記録はあるがプロジェクトが無い」が生じます。

**完了済みのキュー項目（`ExportQueueItem`）も同じ扱いです。** 履歴を残さない設定では、バッチ完了時に削除します。残すと、バッチの成功件数（キューからの導出値。7.4.3）だけが履歴として残ります。

未完了のキュー項目は削除しません。処理中のバッチを失うことになります。

### 7.6 メタデータ

撮影日時には **ファイル内の EXIF** と **写真ライブラリの登録日時** の 2 層があります。写真アプリの並び順を決めているのは後者です。

EXIF の撮影日時を一律に削除すると、加工後の写真がすべて当日の撮影として並び、運動会や旅行の写真を一括処理した際に元の時系列が失われます。そこで両者を分離して扱います。

| 設定 | 初期値 | 利用者による変更 |
| --- | --- | --- |
| 位置情報を削除 | ON | 可 |
| 撮影機器情報を削除 | ON | 可 |
| コメント・編集ソフト情報を削除 | ON | 可 |
| EXIF の撮影日時を保持 | ON | 可（OFF にすると日時も削除） |
| **写真ライブラリの登録日時を元画像から引き継ぐ** | **取得できる場合に引き継ぐ** | **不可** |

最後の 1 行が要点です。`PHAssetCreationRequest.creationDate` は保存時に明示指定できるため、**EXIF から日時を消しても、ライブラリ側の日時を引き継げば並び順は保たれます**。

これにより、プライバシーを最優先して EXIF 日時を削除した利用者でも、写真アプリ内の並び順は崩れません。外部へファイルを共有した場合のみ日時が失われます。

##### 引き継ぐ日時が無い場合

**`PHAsset.creationDate` は `Optional` です。** 「常に引き継ぐ」は成立しません。優先順位を定めます。

| 順 | 取得元 | 条件 |
| --- | --- | --- |
| 1 | `PHAsset.creationDate` | **PhotoKit の読み取り権限が既にある場合のみ**（5.4.2） |
| 2 | EXIF の `DateTimeOriginal` | 常に試みる |
| 3 | **`creationDate` を設定しない**（OS が保存日時を使う） | どちらも無い場合 |

**3 の場合に現在時刻を明示指定しません。** 設定しないのと同じ結果になりますが、「日時を引き継いだ」と記録が残ると、あとから不具合を追うときに誤解の元になります。取得できなかったことを区分値として記録します（9.2）。

##### 6.2.4 の `capturedAt` と実装を共有しない

**この優先順位表を `contentFingerprint` に流用しません。**

`contentFingerprint` の撮影日時は **EXIF のみ**です（6.2.4）。ここで `PHAsset.creationDate` を優先するのは、保存する写真の属性としてより正確だからであり、**同一性の判定には使えないためです。**

| 用途 | 取得元 | 理由 |
| --- | --- | --- |
| `contentFingerprint`（6.2.4） | **EXIF のみ** | 権限の有無で値が変わってはいけない |
| 写真ライブラリ保存時の `creationDate`（本節） | `PHAsset` → EXIF → 未設定 | より正確な値を使ってよい |

以前の版は両者を同じ優先順位としていましたが、これは誤りでした。権限を得た前後で同じ写真の fingerprint が変わり、無料枠を二重に消費します。**共有するのは EXIF の読み取り処理までとし、優先順位の合成は共有しません。**

**権限を持たない状態が既定です**（5.4.2）。したがって通常の経路では、どちらも EXIF が取得元になります。

画像方向とピクセルサイズは常に保持します。

### 7.7 画面スナップショット対策

履歴サムネイルを加工後にしても、**OS のタスクスイッチャには編集中の未加工画面がそのまま残ります**。プライバシー保護アプリとして最も目につく穴であるため、対策を必須とします。

編集画面がフォアグラウンドから外れる際にプライバシーオーバーレイを表示します（`scenePhase` が `.inactive` へ遷移した時点）。

スクリーンショットの全面禁止は採りません。利用者自身が結果を記録する手段まで塞ぐためです。

---

## 8. カスタムスタンプ

Standard および Pro で利用可能とします（仕様 12.4）。

### 8.1 登録できるもの

| 項目 | 仕様 |
| --- | --- |
| 取り込み元 | 写真ライブラリ、およびファイルアプリ（`fileImporter`。5.4.1） |
| 対応形式 | PNG、JPEG、HEIF / HEIC |
| 透過 PNG | 透過状態を維持する |
| 非透過画像 | 円形または角丸マスクで切り抜く |
| 自動背景除去 | **v1 では行わない** |
| 名前 | 利用者が設定できる |
| 並べ替え | できる |
| 削除 | できる |

ファイルアプリからの取り込みを含める理由は、透過 PNG を確実に扱うためです。写真ライブラリ経由では透過が失われる経路があります。

自動背景除去を v1 で行わない理由は、Vision の前景マスク生成の品質が素材に大きく依存し、失敗時の利用者への説明が難しいためです（仕様 12.5 とも一致）。v1.x では Android に等価機能が無いことを理由にしていましたが、iOS 単独になったため理由を差し替えます。

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

##### `CustomStamp` も `StampAsset` を参照する

**「プロジェクトで使った時点で `StampAsset` を作る」だけでは、一覧登録から初回使用までの間、元の画像を保持するものがありません。** また `CustomStamp` を削除しても `StampAsset` を消さない規則だと、**一覧でしか使われていない画像が永久に残ります。**

参照の起点を 2 つにします。

```
StampAsset.referenceCount
    = （その実体を参照する CustomStamp の数）
    + （その実体を参照する Project の数）
```

規則は以下とします。

| 契機 | 操作 |
| --- | --- |
| カスタムスタンプを**一覧へ登録**した | `StampAsset` を作成（または既存を再利用）し、**参照カウントを 1 増やす**。`CustomStamp.assetHash` がそれを指す |
| プロジェクトがそのスタンプを**使用**した | 同じ `StampAsset` の**参照カウントを 1 増やす**。`EffectSetting.stampID` がそれを指す |
| `CustomStamp` を**一覧から削除**した | **参照カウントを 1 減らす**。新規編集では選択できなくなる |
| `Project` を削除した | **参照カウントを 1 減らす** |
| 参照カウントが **0** になった | **実体を削除する**（8.4.1 の順序） |

`StampAsset` は**内容ハッシュで重複排除**します。同じ画像を一覧へ 2 回登録しても、複数プロジェクトで使っても、実体は 1 つです。

**この構成なら、一覧削除で過去プロジェクトの実体が消えません。** プロジェクト側の参照が残っている限り参照カウントは 0 になりません。以前の版が「`CustomStamp` を削除しても `StampAsset` は削除しない」という特例で達成しようとしたことが、参照カウントの規則だけで自然に成立します。

削除時の表示例を示します。

> スタンプ一覧から削除します。過去の加工履歴では引き続き使用されます。

##### 内容ハッシュの対象を固定する

**「内容ハッシュ」だけでは実装が一意に定まりません。** 同じ画像から 3 つの異なるハッシュが作れます。

| 候補 | 問題 |
| --- | --- |
| 入力ファイルそのもののバイト列 | 同じ画像を PNG と HEIC で取り込むと別実体になる。取り込み元による差も残る |
| 正規化済みピクセル | デコードの実装差（色空間変換の丸め）で値が揺れる |
| **最終保存バイト列** | — |

**最終保存バイト列の SHA-256 を採用します。**

| 項目 | 規約 |
| --- | --- |
| 対象 | 8.5 の解像度規則に従って**縮小・変換したあとの保存バイト列** |
| アルゴリズム | SHA-256 |
| 計算時点 | `ManagedFileStore` へ書く直前（7.3.4 の手順 1 と 2 の間） |
| 重複排除 | 同じハッシュの `StampAsset` があれば、書いたファイルを破棄して既存を再利用する |

保存バイト列を対象にするのは、**それが実際にディスク上にある唯一の表現**だからです。参照カウントが指すものと、ハッシュが指すものが一致します。デコード実装が将来変わっても、既存の `StampAsset` のハッシュは変わりません。

アプリ提供の基本スタンプと追加スタンプは、5.1 のとおりベクターとしてコードに持つため実体の消失が起きません。`StampAsset` の対象はカスタムスタンプのみです。

#### 8.4.1 DB とファイルの更新順序

**`StampAsset` は DB の参照カウントとファイル実体にまたがります。** 「参照数が 0 なら削除」だけでは、どちらを先に更新するかが決まりません。

- ファイルを先に消すと、DB トランザクションが失敗したときに**参照中のスタンプを失います**（復旧不能）
- DB を先に更新すると、ファイル削除に失敗したときに**孤児ファイルが残ります**（容量を食うだけ）

**失っても復旧できないほうを避けます。DB を先に更新します。**

###### 作成

| 順 | 操作 |
| --- | --- |
| 1 | 一時ファイルへ書く |
| 2 | 完成ファイルへ **atomic rename** する |
| 3 | DB トランザクションで `StampAsset` を upsert し、参照を追加する |
| 4 | DB が失敗した場合、そのファイルを**孤児として削除対象へ入れる** |

###### 削除

| 順 | 操作 |
| --- | --- |
| 1 | DB トランザクションで参照数を減らす |
| 2 | 0 になった `contentHash` を**削除候補として同じトランザクション内で記録する** |
| 3 | DB のコミット後にファイルを削除する |
| 4 | 削除に失敗した場合、**次回起動時の GC で再試行する** |

削除候補は `PendingFileDeletion` テーブルへ記録します。データベースのトランザクションに含めることで、「参照は 0 になったが削除候補の記録が無い」という状態を作りません。

###### 孤児ファイルの GC

`PendingFileDeletion` だけでは、作成の手順 3 で失敗したファイルを回収できません（記録する前に落ちるため）。起動時に、**専用ディレクトリの実体と DB 上の参照一覧を突き合わせ**、どちらにも属さないファイルを削除します。

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
| 保存形式 | 透過を維持できる圧縮形式。`ImageEncoder` が PNG または HEIC を選ぶ |
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

仕様 26.1 の 20 コードを `enum AppError: Error` として表現します。各要素は再試行可否、利用者向けメッセージ、診断フィールドを持ちます。

仕様 26.2 の再試行可否は型の上で表現し、実行時判断に委ねません。

### 9.2 ログの型による防御

Logger が自由文字列を受け取らない設計とします。

##### `code: String` と `[String: LogValue]` では防げない

**以前の版は値だけを制約していました。**

```swift
// 旧案 — 成立していない
protocol LogEvent: Sendable {
    var code: String { get }                    // ← 任意文字列
    var fields: [String: LogValue] { get }      // ← キーが任意文字列
}
```

`LogValue` が列挙値と数値だけであっても、次はすべて型として通ります。

```swift
code   = "/Users/…/IMG_0421.HEIC"          // イベント名に埋める
fields = ["/var/mobile/…/photo.jpg": .ok]  // 辞書のキーに埋める
```

**「型として渡せない」という保証になっていません。** 埋める先が値からキーへ移っただけです。

##### イベントごとの具象型にする

**イベント名とフィールド名を、どちらも閉じた集合にします。**

```swift
struct ExportCompletedFields: Sendable {
    let faceCountBucket: FaceCountBucket
    let resolutionBucket: ResolutionBucket
    let planKind: PlanKind
    let accountingMode: ExportAccountingMode
}

struct ExportFailedFields: Sendable {
    let errorCode: AppErrorCode          // 9.1 の列挙
    let retryCount: Int
    let sourceRepresentation: SourceRepresentation
}

enum AnalyticsEvent: Sendable {
    case exportCompleted(ExportCompletedFields)
    case exportFailed(ExportFailedFields)
    // 仕様 28.2 のイベントを 1 case ずつ定義する
}

func log(_ event: AnalyticsEvent)   // log(String) も log(code:fields:) も存在しない
```

| 要素 | 表現 |
| --- | --- |
| イベント名 | **`enum` の `case`。** 文字列ではない |
| フィールド名 | **`struct` のプロパティ名。** 辞書のキーではない |
| フィールド値 | 列挙値・区分値・数値のみ |
| 送信時の文字列化 | **アダプタ層で `case` から固定文字列へ写す。** 呼び出し側は文字列に触れない |

**モジュール境界で `[String: LogValue]` を受け取りません。** 自由な辞書を 1 か所でも通せば、そこがすべての制約の抜け道になります。

これにより、仕様 22.5 が禁じるファイル名、パス、顔座標、EXIF、ユーザー入力文字列が **型として渡せなくなります**。レビューでの目視チェックに依存しません。

**6.9 のドメイン識別子も渡せません。** `ProjectID` などを `LogValue` に適合させず、`CustomStringConvertible` にも適合させないため、フィールドとしても文字列補間としても入りません。

顔数や解像度は仕様 22.3 の粗い区分値（顔数は 0 / 1 / 2〜5 / 6 以上など）としてのみフィールドになります。動画長の区分は v2 で追加します。

新しいイベントの追加は `AnalyticsEvent` への `case` 追加と `struct` の定義を伴います。**この手間が、任意文字列を追加しにくくする仕組みそのものです。**

### 9.3 握りつぶしの禁止

すべての `catch` 節で `AppError` へ変換したうえで `log` を通すことを規約とします。`try?` による握りつぶしは lint で禁止し、`do / catch` または `Result` で明示的に扱います。

### 9.4 クラッシュ解析

Sentry へ送信するのは **クラッシュと未分類例外（`UNKNOWN_ERROR`）のみ** とします。

`AD_LOAD_FAILED`、`STORAGE_INSUFFICIENT`、`SAVE_PERMISSION_DENIED` のような想定内のエラーは Sentry へ送らず、分析イベントの区分値として計測します（`VIDEO_TOO_LONG` など動画由来のコードは v1 では発火しません）。Sentry 無料枠（月 5,000 エラーイベント、ユーザー 1 名、保持 30 日）を超過させないためであり、同時にプライバシー面でも正しい方向です。

スパイク保護とサンプリングを有効化し、不良リリース時の突発的な消費を抑えます。

Sentry Cocoa SDK は `Domain` が定義する `CrashReporter` プロトコルの背後に配置します。9.4.1 の送信前フィルタをこの実装へ集約するためであり、差し替え可能性のためだけではありません。

#### 9.4.1 型付き Logger では防げない経路

**型付き分析イベントによる制約が効くのは、アプリ自身が書くログだけです。** Sentry や診断 SDK は `Logger` を通らずに、次を独自に収集します。

- 例外メッセージ（任意文字列。ファイルパスや URL を含みうる）
- スタックトレース中のファイルパス
- breadcrumbs（SDK が自動記録する画面遷移・ネットワーク・タップ）
- HTTP のリクエスト URL とヘッダ
- UI 階層やセッション記録（有効化した場合）
- SDK が自動付与する端末情報

**型付き分析イベントの制約はこの経路を含みません。** `CrashReporter` の実装契約として制約を明記します。

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

仕様 28.2 のイベント名をそのまま `enum AnalyticsEvent: Sendable` として表現します。

仕様 28.3 の禁止項目（元ファイル名、ファイルパス、写真ライブラリ ID、正確な顔座標、画像ハッシュ、SNS アカウント名、カスタムスタンプ画像、写真・動画の内容、音声内容）について、経路ごとに保証の根拠が異なります。

| 送信経路 | 保証 |
| --- | --- |
| **アプリが明示的に送る分析イベント** | 9.2 の型付き `AnalyticsEvent` により、禁止データを**型として渡せない** |
| **クラッシュ解析（Sentry）** | 9.4.1 の送信前フィルタと許可リストを**別途適用する** |
| **診断送信（`/v1/diagnostics`）** | 9.4.1 の型付きリクエストモデルと、サーバー側の未知フィールド拒否（11.2） |

**型付き分析イベントだけでは後 2 者を防げません。** SDK は `Logger` を通らずに例外メッセージやファイルパスを収集します（9.4.1）。

---

## 11. バックエンド

### 11.1 役割の縮小

購入検証、ストア通知の受信、権限管理は RevenueCat が担います。自前サーバーは以下 2 本のみとします。

| エンドポイント | 内容 |
| --- | --- |
| `GET /v1/config` | Free 月間書き出し数、一括処理上限、トライアルクレジット数、トリアージ閾値、履歴の容量上限、カスタムスタンプの保存解像度、有効なスタンプパック、広告表示頻度、**更新誘導（`minimumSupportedVersion` / `recommendedVersion` / `appStoreID`。6.8）**、障害中の機能停止フラグ |
| `POST /v1/diagnostics` | ユーザーが明示的に同意した場合のみ受信 |

仕様 21.5 の `POST /v1/installations` は実装しません。匿名インストール ID は RevenueCat の App User ID と兼用します。仕様 21.4 の要件（Keychain への保存、広告 ID を利用者 ID として使わない、ハードウェア識別子を収集しない）は満たされます。

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

#### 11.2.1 診断エンドポイントの運用制約

型制約に加えて、運用面の上限を定めます。**型が正しくても、量と保持期間が無制限なら別の問題になります。**

| 項目 | 規約 |
| --- | --- |
| リクエストサイズ上限 | **8KB**。超過は 413 |
| レート制限 | **IP 単位で 10 件 / 分**。超過は 429 |
| 保存期間 | **30 日**。Sentry の無料枠と揃える（9.4） |
| 自動削除 | 保存期間を過ぎた行を日次で削除する |
| 同意撤回後 | **送信しない。** 撤回時点でクライアント側の送信キューも破棄する |
| サーバーログ | **リクエスト本文を出力しない。** アクセスログはメソッド・パス・ステータス・所要時間のみ |

**サーバーログへ本文を出さないことを明記します。** アプリ側で許可フィールドだけに絞っても、サーバーが本文をそのままログへ流せば、そのログが第 2 の収集経路になります。ログ基盤の保持期間はアプリの設計と無関係に決まるため、ここで塞ぎます。

**同意撤回後にキューを破棄するのは、送信前のデータが端末に残るためです。** オフライン時に貯めた診断を、撤回後にオンラインになった時点で送るのは同意の趣旨に反します。

### 11.3 リモート設定の検証とキャッシュ

**`/v1/config` は静的 JSON と ETag だけでは不十分です。** この JSON は無料枠、トライアル枚数、一括処理上限、並列数、トリアージ閾値、広告頻度、最低バージョン、機能停止フラグを変更できます。**壊れた値や古い値をそのまま適用すると、アプリ更新なしで全利用者を壊せます。**

##### エンベロープ

```swift
struct RemoteConfigEnvelope: Sendable, Decodable {
    let schemaVersion: Int
    let configVersion: Int64
    let issuedAt: Date
    let expiresAt: Date
    let payload: RemoteConfig
}
```

##### クライアント側の規則

| 状況 | 扱い |
| --- | --- |
| `schemaVersion` が未知 | **設定全体を拒否する** |
| 数値がアプリ内の許容範囲外 | **その設定全体を拒否する**（該当項目だけ捨てない） |
| enum に未知の値がある | **設定全体を拒否する** |
| `configVersion` が `highestAcceptedVersion` より大きい | 検証を通れば**受理する** |
| `configVersion` が `highestAcceptedVersion` と等しく、**canonical payload が同一** | **無視する**（同じ設定の再配信） |
| `configVersion` が `highestAcceptedVersion` と等しく、**内容が異なる** | **拒否する**（下記） |
| `configVersion` が `highestAcceptedVersion` より小さい | **拒否する**（ロールバック攻撃と配信事故の両方を防ぐ） |
| 取得失敗 | 最後に検証成功した設定（last-known-good）を使う |
| last-known-good も無い | **バンドル済みの既定値**を使う |
| `expiresAt` を過ぎた設定 | **機能停止フラグ以外をバンドル既定値へ戻す** |

**部分的に採用しません。** 「この項目だけ範囲外だから既定値で埋める」を許すと、配信された設定の一部と既定値が混ざった、テストされていない組み合わせが動きます。全体を拒否すれば、動くのは「配信された設定」か「既定値」のどちらかだけです。

**期限切れで機能停止フラグだけを残すのは、それが障害対応の手段だからです。** サーバーが落ちている間に機能停止を解除してしまうと、止めたかった機能が動きます。逆に上限値や閾値は、古い値を使い続けるより既定値のほうが安全です。

##### 同一バージョンでの内容差し替えを拒否する

**「小さいバージョンを拒否する」だけでは、同じ `configVersion` で別の内容を配ることを検出できません。**

以前の版は `incoming < saved` のみを拒否していました。等号の場合は素通りするため、次が受理されます。

- 配信事故（誤った内容を上げ、バージョンを上げ忘れた）
- 意図的な差し替え（CDN やバックエンドの侵害）

どちらも「バージョンは同じなのに内容が違う」という形で現れます。**これは正常な配信では起こりえない状態です。**

判定には canonical payload を使います（7.4.3 のエンコーダ）。`highestAcceptedVersion` に対応する canonical bytes を `RemoteConfigState` に保持し、比較します。JSON の文字列比較では、キー順や空白の違いで誤って「変更あり」になります。

**運用側の規約として、内容を変更するときは必ず `configVersion` を増加させます。** 増加を忘れた配信は、既存端末に届きません（新規インストールには届くため、不整合として運用で検知できます）。

##### 時刻の表現形式を固定する

**`Date` を `JSONDecoder` の既定に任せません。** 既定は `.deferredToDate`（Apple の参照日からの秒数）であり、Rust 側が `chrono` などで出力する形式と一致しません。**`issuedAt` と `expiresAt` が誤った値としてデコードされれば、設定が即座に期限切れになるか、永久に期限切れにならないかのどちらかです。**

| 項目 | 規約 |
| --- | --- |
| 形式 | **UTC epoch milliseconds の `Int64`** |
| Swift 側 | `JSONDecoder.dateDecodingStrategy = .millisecondsSince1970` を明示指定する |
| Rust 側 | `i64` として出力する（`serde` の既定表現に任せない） |
| タイムゾーン | UTC 固定。オフセット付き文字列を使わない |

`/v1/diagnostics` の `occurred_at`（11.2）と同じ形式です。**アプリとサーバーの間で時刻表現を 1 つに統一します。** RFC 3339 UTC 文字列も候補ですが、パーサの差（小数秒の桁数、`Z` と `+00:00`）が残るため採りません。

##### キャッシュを保護する

**last-known-good を平文で保存すると、防御が成立しません。**

リモート設定は無料枠、トライアル枚数、一括上限、スタンプ上限、広告頻度、強制更新、機能停止を変更できます。**キャッシュを `UserDefaults` や平文ファイルへ置けば、利用者が値を書き換えて無料枠を増やせます。** `UsageLedger` を HMAC で保護しても、判定に使う上限値そのものが改変可能なら意味がありません。

**`ProtectedBlobStore` へ保存します**（6.2.5 と同じ HMAC 保護）。

```swift
struct RemoteConfigState: Sendable {
    let highestAcceptedVersion: Int64
    let acceptedPayloadDigest: Data      // highestAcceptedVersion の canonical payload の SHA-256
    let lastKnownGood: RemoteConfigEnvelope
}
```

| 規則 | 内容 |
| --- | --- |
| 保存 | HTTPS 取得と検証に成功した後、HMAC 付きで保存する |
| 署名対象 | **`highestAcceptedVersion` も含める**（バージョンだけ下げる改変を防ぐ） |
| `payloadType` | `remoteConfigState` を追加する（7.4.3） |
| HMAC 不一致 | **バンドル既定値へ戻す。** 改変された値で動かさない |
| `expiresAt` の判定 | **`retentionNow` を使う**（6.2.2.5。`nil` の間は削除しない） |
| `appStoreID` | **数字のみの形式検証**（6.8.7。任意の URL を差し込ませない） |
| 強制更新 | **キャッシュの改変から `.required` を発生させない。** HMAC 不一致なら既定値＝更新なし（6.8.3） |

**最後の行が重要です。** キャッシュを書き換えて `minimumSupportedVersion` を上げれば、他人の端末でアプリを止められます。HMAC 不一致を既定値へ倒すことで、改変は「更新なし」にしかなりません。

##### サーバー側の署名は v1 の範囲外

**上記が守るのは端末上の改変までです。** CDN やバックエンドの侵害には対応しません。

対応するには、サーバーが設定へ Ed25519 で署名し、公開鍵をアプリへ埋め込む方式が必要です。v1 では実装せず、**脅威モデルとして範囲外**と記録します（7.4.3 の HMAC 脅威モデルと同じ扱い）。設定の内容が枠数と表示に限られ、金銭や個人情報へ直結しないためです。

##### リモート設定で変更できないこと

**次はリモート設定から無効化できません。** 安全性の中核であり、サーバー側の事故や侵害で外せる状態にしません。

- 6.5.3 の確認画面（`ReviewRequired` の解消なしに書き出せない）
- 6.1 の全顔初期マスク
- 7.4.1 のファイル検証（サイズ・SHA-256・デコード）
- 7.4.3 のコミットジャーナルと最終確定境界
- 5.1.2 の未解決 `bitmapID` によるエラー
- **6.8.4 の「未受け渡し出力があるときは受け渡し導線を先に出す」**（強制更新で成果物を失わせない）

これらに対応する設定キー自体を `RemoteConfig` に持たせません。「フラグはあるが既定で有効」ではなく、**フラグを存在させない**という形にします。

**更新誘導は逆方向の扱いです。** `minimumSupportedVersion` はリモートから変更できますが、**取得に失敗した場合の既定は「更新なし」**です（6.8.3 の手順 1）。バンドル既定値にも強制更新は含めません。サーバーが応答しないことがアプリの停止を意味しない、という 11.4 の方針と一致します。

**一括処理の同時並列数は、アプリが対応を宣言した最大値を超えません。** リモートで 8 を指定されても、アプリ側の上限（v1 は 2）でクランプします。並列数は実装が想定するメモリ使用量と直結するため、サーバーから引き上げられる形にしません。

### 11.4 障害時

リモート設定の取得に失敗した場合はアプリ内の安全な既定値を使用します。バックエンド障害で編集処理を停止させません（仕様 21.6）。

---

## 12. テスト戦略

### 12.1 テストの層

**「純粋な判定」と「実ストレージの原子性」と「プロセス強制終了後の状態」は、同じ層では検証できません。** 前 2 者を混ぜると、判定のテストにシミュレータが要るようになり、実行が遅くなって回されなくなります。

四層へ分けます。フレームワークは **Swift Testing**（`@Test`）を使い、UI テストのみ XCTest とします。

| 層 | 実行環境 | 対象 |
| --- | --- | --- |
| **domain unit test** | **`swift test`**（数秒。シミュレータ不要） | クォータ、トリアージ、座標変換、`compileRenderDraft`、状態機械 |
| **application saga test** | **`swift test`**（数十秒） | 偽 DB・偽 `ProtectedBlobStore`・偽ファイルによる**各中断点**の検証 |
| **adapter integration test** | シミュレータ / 実機 | 実 GRDB、実 保護ファイル、実 Keychain 鍵、Vision、Core Image |
| **process-death fault injection test** | **実機** | **各手順の直後に強制終了**し、再起動後の状態を検証 |

**`Domain` と `Persistence` の一部を SwiftPM の独立ターゲットにする理由がここにあります**（4 章）。`swift test` で走る層は Xcode プロジェクトのビルドを経由せず、シミュレータも起動しません。

##### 障害注入テストは実機で行う

**コミットジャーナルは、実ストレージを使った障害注入テストを必須とします。** 偽ストアの saga テストは「順序どおりに書けば整合する」ことしか示しません。GRDB のトランザクションが実際に原子的か、`FileManager.replaceItemAt` が中断で切れないか、`fsync` のタイミングはどうか — これらは実装と OS の性質であり、偽物では検証できません。

**シミュレータではなく実機を使います。** シミュレータのファイルシステムは macOS のものであり、iOS のストレージスタック（データ保護クラス、ジャーナリングの挙動）と一致しません。強制終了の再現も、シミュレータではプロセスの kill にしかならず、OS によるジェッツァム（メモリ逼迫時の強制終了）の挙動と異なります。

強制終了の手段は次とします。

| 手段 | 用途 |
| --- | --- |
| テスト用フックによる **`_exit(1)`** | 各手順の直後で決定的に落とす。`exit(0)` は正常終了であり `atexit` ハンドラやバッファのフラッシュが走るため、クラッシュ境界の検証にならない |
| 外部プロセスからの `SIGKILL` | シグナルハンドラを経由しない終了。テストランナーとは別プロセスから送る |
| メモリ圧迫によるジェッツァム | 実運用に最も近い経路。一括処理 50 枚で再現する |

**強制終了フックはテスト専用ビルドにのみ含めます。** 手順ごとの中断点を製品ビルドへ残しません。ビルド構成のコンパイル条件（`#if DEBUG_FAULT_INJECTION`）で分離し、リリースビルドに含まれないことを CI で確認します。

各項目は、**検証が成立する最も低い層**へ置きます。以下 12.1.1〜12.1.4 で層ごとに列挙します。対象は仕様 30.1 の全項目に加え、本設計で追加した判定を含みます。

#### 12.1.1 domain unit test（`swift test`、数秒）

純粋関数と状態機械のみ。ストレージもプロセスも関与しません。

- `QuotaPolicy`（月跨ぎ、TZ 変更、時刻巻き戻し、うるう年、月末 23:59:59 → 00:00:00、24 時間境界）
- `EntitlementResolver`（仕様 27.4 の全購入状態）
- `BatchTriagePolicy`（6 つの要確認理由の各単独・複合、空集合）
- `triage` の入力が 5.7.1 の共通モデルだけであること。OS 固有の値に依存しないこと（6.5.2）
- `ReviewIssue` が**発生単位**で列挙され、小さい顔が 3 人なら 3 件になること（6.5.2）
- `issueID` が `detectionRevision` を含み、`OverlappingFaces` では顔 ID が辞書順に並ぶこと（6.5.2）
- 再検出で `detectionRevision` が増え、その写真の `ReviewIssue` / `ReviewDecision` / `Reviewed` が破棄されること（6.5.2）
- `ReviewDecision` が `issueID` ごとに記録され、全 `ReviewIssue` が埋まるまで `Reviewed` にならないこと（6.5.4）
- 1 人分の `issueID` へ判断を記録しただけでは `Reviewed` にならないこと（6.5.4）
- `ManualRegionAdded` が `regionID` を保持し、その領域の削除で判断が破棄されること（6.5.4）
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
- 同一素材の再書き出しで `firstSuccessAt` が更新されないこと（6.2.0）
- 端末時刻を過去へ戻しても 24 時間の窓が延びないこと。`usageNow` が後退しないこと（6.2.2.5）
- `Domain` の時間判定が `now` ではなく `usageNow` / `retentionNow` だけを受け取ること（6.2.2.5）
- **`isSameSource` を直接使わず、`sourceID` で同一性を判定していること**（6.2.4）
- **provider 一致と content 一致が別レコードを指す場合に、1 件へ統合されること**（6.2.4）
- **統合時に最も古い `firstSuccessAt` が維持され、トライアルが消費済みへ倒れること**（6.2.4）
- **`SourceRecord` が grant / trial / reservation / lease のどれからも参照されなくなった場合だけ削除されること**（6.2.4）
- **`paidUnlimited` の書き出し中に `SourceRecord` が GC されないこと**（`SourceLease` が効いていること。6.2.4）
- **`ReviewIssueID` が `projectID`（`ProjectID` 型）を含み、同じ revision の別写真の `noFaceDetected` が別 ID になること**（6.5.2 / 6.9）
- **`affectedFaceTrackIDs` が ID から導出され、二重に保持されないこと**（6.5.2）
- **`opacity = 0` / `cellSizePx < 2`（特に 1px） / `sigmaPx = 0` / 幅 0 の領域が `throw` されること**（5.2）
- **`RenderOpSpec` / `RenderOp` / `RenderOpDraft` に生の `Double` が残っていないこと**（5.2）
- **`NaN` や無限大の座標が `throw` されること**（5.2）
- **完全に透明なカスタムスタンプ画像が取り込み時に拒否されること**（5.2 / 8.1）
- **`isMasked == true` の顔に no-op 相当の値が渡されたとき `compileRenderDraft` が `throw` すること**（5.2）
- **`evaluateUpdate` が `appStoreID` の数字のみ形式を検証すること**（11.3）
- **`DetectedFace` の角度が非 Optional であり、`Measurement<UnitAngle>` から度へ変換されること**（5.7.1）
- **`lowConfidence` が顔ごとに 1 件の `ReviewIssue` になること**（6.5.2）
- **6 種類の要確認理由すべてについて、単独・複合・空の判定が正しいこと**（6.5.2）
- 未受け渡し出力の削除期限が端末時刻の変更で延びないこと（6.2.2.5）
- `monthlyIntegrityLock` が解除条件を満たさないとき、`consumedExportIDs` が空でも `Blocked(LedgerIntegrityFailure)` になること（6.2）
- **端末時刻をどう変更しても `monthlyIntegrityLock` が解除されないこと。信頼できる時刻の観測だけが解除条件であること**（6.2.2.5）
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
- `compileRenderDraft` が `RenderPlan` へ絶対ピクセル値のみを入れ、比率を残さないこと。**`SourcePlacement.sourceRect` と `BackgroundOp.blurFromSource.sourceRect` も `PixelRect` であること**（5.2）
- `compileRenderDraft` が `sourceSize` を受け取り、元画像基準の正規化値をピクセルへ変換すること（5.2）
- `bindRasterAssets` が `stampKeys` に対応する asset を 1 件でも欠けば失敗すること（5.2）
- `left`/`top` が floor、`right`/`bottom` が ceil で丸められ、領域が外側へ広がること（5.2.1）
- `RenderRegion.bounds` が出力キャンバス基準へ変換されること（5.2）
- `sourceCrop` の不変条件違反が例外になり、クランプで黙って直されないこと（5.2）
- `Manual` の領域が `Auto` より後の `order` になること（5.2.1）
- `Domain` が `StampRasterizer` プロトコルのみを持ち、`CoreGraphics` を参照しないこと（4.1 / 5.1.1）
- `StampRasterKey` に位置・回転・不透明度・形状が含まれないこと（5.1.1）
- `contentFingerprint` が長さ前置き・ビッグエンディアン・UTC epoch ms で計算されること（6.2.4）
- 64KB 未満のファイルで先頭・末尾チャンクが重複しても正しく計算されること（6.2.4）
- 撮影日時が無い場合に長さ 0 のフィールドとして扱われること（6.2.4）
- 撮影日時の優先順位がライブラリ → EXIF → `null` であること。更新日時を使わないこと（6.2.4）
- `representation` が `contentFingerprint` の入力に含まれないこと（6.2.4）
- 設定ハッシュが `Map` のキー順・**`Double.bitPattern`（64 ビット）**・内容ハッシュ参照で正準化され、DB ID に依存しないこと（6.2.4）
- **`Float` へ丸めた場合に区別できなくなる 2 つの `Double` が、異なる設定ハッシュになること**（6.2.4）
- プロジェクト設定ハッシュの一致判定により、Free の「変更せず再書き出し」が許可されること（6.7）
- キーフレーム補間（v2 機能だが仕様確定のため v1 で実装・テスト。5.5）
- ストレージ必要量計算、`ExportQueue` 状態機械、`AdFrequencyPolicy`
- 履歴の保存期間と容量判定。7.2.4 の保持保証が容量超過時にも守られること
- リモート設定のフォールバック
- `AppVersion` の比較が数値の組で行われ、`1.10.0 > 1.9.0` になること（6.8.2）
- `CFBundleShortVersionString` のパース失敗で `.none` になり、強制更新へ倒れないこと（6.8.2）
- `config == nil`（取得失敗）で `.none` になること（6.8.3）
- `skippedVersion` と一致する `recommendedVersion` を再提示しないこと（6.8.3）
- 前回提示から 24 時間未満なら `.recommended` を返さないこと。判定に `usageNow` を使うこと（6.8.3）
- `recommendedVersion` が上がれば、スキップ済みでも再提示されること（6.8.6）

#### 12.1.2 application saga test（`swift test`、偽ストア）

偽 DB・偽 `ProtectedBlobStore`・偽ファイルを注入し、**各中断点**での挙動を検証します。実ストレージの原子性は検証しません（12.1.3 の役割）。

- `ExportCommit` が各段階で中断しても、起動時に整合が回復すること（7.4.3）
- `Prepared` / `FileVerified` / `Finalizing` / `AccountingCommitted` / `ReadyToPublish` のいずれからもコミット行が最終的に消えること（7.4.3）
- 復旧が終わるまで新しい書き出しを開始できないこと（7.4.3）
- `ExportCommit` の署名検証失敗が復旧エラーになり、自動破棄されないこと（7.4.3）
- 復旧エラーを「破棄して続ける」で解除でき、孤立 lease が 1 件なら予約が `TrialEntry` へ確定した上でコミットが削除されること（7.4.3）
- **孤立 lease が 0 件のとき（`AccountingCommitted` / `ReadyToPublish` で壊れた場合）、台帳を変更せずコミット行だけが削除されること**（7.4.3）
- **署名不正行の `outputFile` / `projectID` が参照されず、他の正常な出力と履歴が削除されないこと**（7.4.3）
- **署名不正行がある間、孤児予約と孤児 lease の自動回収が保留されること**（7.4.3）
- 手順 4 と 5 の間で中断しても、台帳更新を冪等に再適用できること（7.4.3）
- `finalizedAt` が `Finalizing` の保存時点で決まり、`FileVerified` では `null` であること（7.4.3）
- 中断して復旧した場合、月跨ぎの有無にかかわらず新しい `finalizedAt` で再適用されること（7.4.3）
- **プロセスが生きたまま手順 3 と 7 の間で長時間停止した場合、手順 7-b の再確認で手順 3 から再確定されること**（7.4.3）
- **`restoreOutput` が `UsageLedger` を 1 バイトも変更せず、`generatedAt` / `expiresAt` を延長せず、`ExportRecord` を追加しないこと**（7.4.3）
- **`originalExpiresAt` が過去なら `restoreOutput` を実行せず、`OutputRecord` を削除すること**（7.4.3）
- `generatedAt` / `expiresAt` / grant の起点が `finalizedAt` と一致すること（7.4.3）
- `PreserveAuthorized` を起動時復旧から適用しても、`finalizedAt` で grant が作られないこと（7.4.3）
- 認可時の grant が会計時に期限切れでも、その 1 回は完了し、grant は再登録されないこと（7.4.3）
- `AccountingCommitted` からの復旧でファイル欠損時、実際に追加した会計要素だけが取り消されること（7.4.3）
- 既存 grant を再利用しただけのコミットのロールバックで、その grant が削除されないこと（7.4.3）
- 手順 4 の直後（`applied` 未保存）に落ちても、`ownerExportID` から正しくロールバックできること（7.4.3）
- 書き出し開始前に `Blocked` なら `ExportCommit` を作らないこと（7.4.3）
- 開始後に契約が失効しても、その書き出しは開始時の権限で完了すること（7.4.3）
- 失効時、`Prepared` 以降の写真は完了し `waiting` の写真は開始しないこと（7.4.3）
- **書き出しが全体で同時に 1 件までに制限されること**（7.4.3 の `withExclusivePermit`）
- **`withExclusivePermit` の内側で、alias 解決から認可までが 1 回の `transact` で完了すること**（7.4.3）
- **ゲートがコミット行の削除またはロールバック完了まで保持されること**（7.4.3）
- **`Prepared` の保存に失敗したとき、補償トランザクションが予約・lease・未参照 `SourceRecord` を削除しゲートを解放すること**（7.4.3）
- 並列書き出し時も `UsageLedgerStore.transact` が直列化され、更新が失われないこと（7.4.3）
- クォータ消費が `exportID`、トライアル消費が素材の同一性で冪等であること（7.4.3）
- 検証済みファイルが手順 7 の完了まで UI・`MediaSaver`・`SharePresenter` へ公開されないこと（7.4.1）
- `FileVerified` で落ちた場合、`verifiedOutput` と実体を突き合わせて復旧できること（7.4.3）
- 手順 7 のサイズ・SHA-256 が `verifiedOutput` からのコピーであり、再計算でないこと（7.4.3）
- 0 バイト・破損・SHA 不一致の出力ファイルで `ReadyToPublish` のコミット行が削除されないこと（7.4.3）
- 手順 6 の失敗時、ロールバックが台帳 → `OutputRecord` → ファイル → コミット → ゲートの順で実行されること（7.4.3）
- ロールバック手順 1 が失敗した場合、コミットとファイルが残り復旧エラーになること（7.4.3）
- コミット行削除後にファイルを失っても、月間枠・grant・トライアルが戻らないこと（7.4.3）
- コミット削除済みの Export A のファイル欠損で、同一素材を再書き出しした Export B の grant が消えないこと（7.4.3）
- 生成完了後の異常終了では消費が戻らないこと（6.2.1）
- 残 1 枚で異なる素材の 2 件が並行認可されても、両方が `BatchTrial(true)` にならないこと（6.5.6.1）
- 予約が手順 −2 で作られ、手順 4 の台帳トランザクション内で `trialEntries` へ移ること（6.5.6.1）
- 手順 0 の `Prepared` 保存失敗で、補償トランザクションが**予約・`SourceLease`・未参照 `SourceRecord`** をすべて取り消すこと（6.5.6.1 / 6.2.4）
- 同じ素材が `trialEntries` と `trialReservations` の両方に存在しないこと（6.5.6.1）
- 同じ素材の再書き出しでトライアルクレジットが二重に減らないこと（6.5.6.1）
- トライアルクレジットが成功枚数分だけ減り、失敗と中止では減らないこと（6.5.6）
- `UsageLedger` の署名検証失敗時、修復済み台帳が作られ、翌月に月間枠が再開しトライアルは封じられたままであること（6.2.5）
- 修復済み台帳の `trialReservations` が空であること（6.2.5）
- `Missing` で通常台帳が作られ、初回起動の利用者が封鎖されないこと（6.2.5）
- `TemporarilyUnavailable` で台帳が上書きされず、書き出し開始が保留されること（6.2.5）
- `SubscriptionState` の署名不正時、オフラインで有料権限が新規付与されず、カスタムスタンプと履歴が削除されないこと（6.3）
- `OutputRecord` が `ExportCommit` 削除後も単独で期限判定できること（7.4.3）
- 未受け渡しの出力が破棄または 24 時間経過まで保持されること（6.2.2）
- 受け渡し成功後も完了画面を離れるまで出力が保持され、保存と共有を任意の順序で実行できること（6.2.2）
- 消費確定が手順 7 であり、保存や共有の回数に影響されないこと（6.2.1）
- 異常終了後の起動時、`Generated` では復旧案内が出て、`Delivered` では出ないこと（6.2.2.1）
- 「履歴を保存しない」設定で、未受け渡し出力・`UsageLedger`・未完了 `ExportCommit`・**トライアル用 `SourceRecord`** の 4 つ以外が残らないこと（7.2.3）
- `CustomStamp` を削除しても、それを使用したプロジェクトが再書き出しできること（8.4）
- `StampAsset` が**最終保存バイト列**の内容ハッシュで重複排除され、参照カウントが 0 になったときのみ削除されること（8.4）
- **`CustomStamp` の登録で参照カウントが 1 増え、一覧削除で 1 減ること。一覧でしか使われていない実体が一覧削除で消えること**（8.4）
- 一括削除が `CustomStamp` のみを対象とし、参照中の `StampAsset` を消さないこと（8.5.2）
- 削除で DB が先に更新され、`PendingFileDeletion` が同じトランザクションへ記録されること（8.4.1）
- Free が既存プロジェクトの編集画面を開けること。変更操作の時点で案内が出ること（6.7）
- **更新判定が復旧手順 0〜7 の完了後に実行されること**（6.8.5）
- **`.required` かつ `Generated` の出力があるとき、受け渡し導線が先に提示されること**（6.8.4）
- **その画面から新規加工・履歴・設定へ進めないこと**（6.8.4）
- **保存または破棄で `Generated` が 0 件になった時点で、通常の強制更新画面へ切り替わること**（6.8.4）
- **`.recommended` が編集中・書き出し中・未受け渡し出力があるときに表示されないこと**（6.8.6）

#### 12.1.3 adapter integration test（シミュレータ / 実機）

実 GRDB、実 保護ファイル、実 Keychain 鍵を使います。

- **プロトコル適合テスト** — `MediaKit` / `Persistence` / `Billing` / `Ads` の各プロトコルに対し、実装と偽実装の**両方へ同じスイート**を実行します。偽実装が本物と違う挙動をすると 12.1.2 の saga テストが無意味になるため、この一致を検証します
- 手順 7 の DB トランザクションが原子的であり、`OutputRecord` / `ExportRecord` / キュー状態 / `Project` の更新とコミット削除が同時に成立すること（7.4.3）
- 「コミットあり・`OutputRecord` なし」または「コミットなし・`OutputRecord` あり」以外の状態が観測されないこと（7.4.1）
- `ExportCommit` が状態遷移のたびに再署名され、正規の更新で検証失敗しないこと（7.4.3）
- `SignedPayload` の署名対象に `payloadType` が含まれ、種別間の付け替えが検出されること（7.4.3）
- 実 Keychain の鍵で署名・検証が往復すること。鍵の破棄が `IntegrityFailure` になること（6.2.5）
- `ProtectedBlobStore` のデータと HMAC 鍵がともにバックアップ対象外であること（6.2.5 / 7.3.1）
- **blob `Missing` / 鍵 `Missing` で新規台帳が作られること**（7.3.2）
- **blob `Missing` / 鍵 `Existing` でも新規台帳が作られ、復旧エラーにならないこと**（7.3.2）
- 各ディレクトリのデータ保護クラスが 7.3.3 の表と一致すること
- ロック中に `.complete` のファイルへアクセスした場合、破損ではなく「保護データ利用不可」として処理が一時停止すること（7.3.3）
- `OutputRecord` の実体解決が `ManagedFileRef` 経由であり、パス文字列の改変で専用ディレクトリ外を削除できないこと（7.4.3 / 7.3.4）
- **`ManagedFileKind` が異なれば同じ `fileID` でも別ファイルとして扱われること**（7.3.4）
- `StampAsset` の作成が atomic rename を経ること（8.4.1）
- 写真ライブラリ登録日時の引き継ぎ（7.6）を、保存後に読み戻して検証すること。**権限がある場合とない場合の両方で検証する**
- **`contentFingerprint` の撮影日時が EXIF のみから決まり、PhotoKit 権限の有無で変わらないこと**（6.2.4 / 5.4.2）
- `NormalizedRect` の `right` / `bottom` が排他的境界として扱われること（5.2.1）
- `rotationDegrees` が時計回り正・領域中心基準で描画されること（5.2.1）
- `opacity` がレンダラーで 1 回だけ乗算され、ドメイン側で色へ焼き込まれないこと（5.2.1）
- クリップが回転の後に行われ、キャンバス端の回転領域が露出しないこと（5.2.1）
- 背景処理が顔エフェクトより先に適用されること（5.2.1）
- 重なり時に後のエフェクトが加工済み画像へ作用すること（5.2.1）
- Vision の左下原点座標が左上原点へ変換されること。**角度が非 Optional の `Measurement<UnitAngle>` から度へ変換され、符号の向きが 5.7.1 と一致すること**（5.2.1 / 5.7.1）
- `FaceObservation.confidence` の分布が 1.0 に張り付いていないこと（5.7.1 の受入条件 / 12.2）
- `Domain` の `PixelRect` が Core Image の Cartesian 矩形へ正しく変換されること。上端のみ・下端のみに顔がある素材で上下が入れ替わらないこと（5.2.1）
- `CIAffineClamp` を経ることで、画像端の顔のぼかしが薄くならないこと（5.2.1）
- `extent` の原点が `(0, 0)` でない `CIImage` でも座標がずれないこと（5.2.1）
- `plan` が参照する `bitmapID` が `rasterAssets` に無い場合、描画を開始せずエラーになること（5.1.2）
- 同一 `StampRasterKey` のラスタライズが 1 回で済み、複数領域から再利用されること。**`rasterize(_ keys:)` が与えた全 key に対応する値を返すこと**（5.1.1 / 5.1.2）
- `RasterizedStampAsset` の `bitmapID` スコープが `render` 呼び出し内に閉じ、並列レンダリングで衝突しないこと（5.1.2）
- ラスタ一時ファイルの解放が冪等であること。二重解放でエラーにならないこと（5.1.2）
- `CrashReporter` が例外メッセージ・パス・URL を除去し、breadcrumbs を列挙済みイベントに限定すること（9.4.1）
- `/v1/diagnostics` が未知フィールドを拒否すること（9.4.1 / 11.2）
- **ゴールデン画像テスト** — 同じ `RenderSpec` から生成したプレビュー用と原寸用の出力が一致すること。`sourceCrop` / `scaleMode` / `background` を適用した結果が設定と一致すること。仕様 30.4 の条件（強度の最小・最大、顔の回転、領域が画面端、領域の重なり、透明度、4 形状）を素材として固定化します

#### 12.1.4 process-death fault injection test（実機）

**各手順の直後にプロセスを強制終了し、再起動後の状態を検証します。** 偽ストアでは検証できない、実ストレージと OS の性質を対象とします。

- 手順 −2 / 0 / 1 / 2 / 3 / 4 / 5 / 6 / 7 の**各直後**で強制終了し、再起動後に整合が回復すること（7.4.3）
- ロールバック手順 1 の完了後に落ちても、再起動時の再実行が冪等であること（7.4.3）
- 予約を作った直後に落ちた場合、孤児予約が起動時に回収され、その完了後に新規認可が許可されること（6.5.6.1）
- `StampAsset` の作成で手順 3 の直前に落ちた場合、孤児ファイルが起動時 GC で回収されること（8.4.1）
- `PendingFileDeletion` の削除に失敗した場合、次回起動時の GC で再試行されること（8.4.1）
- 書き出し一時ファイルとラスタ一時ファイルの孤児が、起動時に回収されること（7.3 / 5.1.2）

### 12.2 検出品質

仕様 30.2 の検出条件（正面、横顔、斜め、部分的な遮蔽、マスク、サングラス、暗所、逆光、遠景、集合写真、子ども、高齢者、異なる肌色、イラストの顔、鏡像、写真内の写真）は、**合否判定ではなく検出率の回帰監視** として計測します。

仕様 34.5 が「完全自動を約束しない」と定めている以上、閾値でビルドを落とすのは不適切です。リリース間で検出率が有意に低下した場合のみ調査対象とします。

同じ素材セットで `BatchTriagePolicy` の要確認率も計測します。要確認率が高すぎると Pro の価値が失われ、低すぎると見落としが増えるためです。`extremePose` の角度閾値と `lowConfidence` の信頼度閾値（16 節）はこの計測から決めます。

**固定の素材セットを流し、検出率と要確認率をリリース間で監視します。** iOS のバージョン更新で Vision の検出特性が変わることがあり、閾値の妥当性が崩れます。前リリースとの差が一定以上に開いた場合は閾値を見直します。

##### `confidence` の有効性を先に判定する

**`confidence` は 6.5.2 のトリアージに使います**（v1.x では使わないとしていましたが、iOS 単独化で方針が変わりました）。

ただし、閾値を有効にする前に **5.7.1 の受入条件**を満たすことを確認します。この計測を先に行い、値が変動しない、あるいは検出品質と相関しない場合は `lowConfidence` をトリアージから外します。

| 計測項目 | 判定 |
| --- | --- |
| `confidence` の分布（ヒストグラム） | 常に `1.0` に張り付いていないこと |
| 目視で誤検出・見落とし近傍と判定した顔の `confidence` | 全体分布より有意に低いこと |
| リビジョンを変えたときの分布の差 | 採用するリビジョンを固定する根拠として記録する |

### 12.3 プライバシーの受入テスト

以下を明示的に検証します。

- 履歴一覧とサムネイルに未加工の顔が現れないこと
- タスクスイッチャのスナップショットに編集中の未加工画面が残らないこと（7.7）
- アプリ専用領域に元画像の永続コピーが残らないこと
- 出力ファイルから位置情報・機器情報・編集ソフト情報が除去されていること
- 写真ライブラリの登録日時が元画像から引き継がれていること

### 12.4 アクセシビリティ

仕様 29 章を受入条件とします。SwiftUI の `Canvas` は既定でアクセシビリティ要素を持たないため、`accessibilityLabel` / `accessibilityValue` / `accessibilityRepresentation` の明示的な付与が必須です。以下を明示的にテストします。

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

**v1 では動画を一切露出させません。** ピッカーは画像限定とします（`PHPickerFilter.images`）。

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

動画の除去、確認モードの 2 分岐、検出／確認の 2 軸、**写真ごとの出力状態と部分的な受け渡し**、トライアルクレジット（台帳からの導出を含む）、メタデータの項目別設定、スタンプの参照用コピー、降格後の閲覧と変更の分離、**`Entitlement`（plan + status）からの権限導出**、履歴の容量超過による自動削除、**警告の発生単位管理（`ReviewIssue`）**、**再検出による判断の破棄（`detectionRevision`）**、**`lowConfidence` のトリアージ**、**アプリ更新の誘導と未保存出力の保護**。

### 14.1 モックが再現しないこと

Web モックである以上、以下は本書の記述どおりには再現できません。実装時に本書へ従います。

| 項目 | モック | 実装 |
| --- | --- | --- |
| 顔検出・加工・保存・課金 | ダミーデータと固定の座標 | Vision、Core Image、PhotoKit、RevenueCat |
| 時間経過に依存する判定 | 24 時間の窓、月初リセット、保存期限は経過を再現しない | `usageNow` / `retentionNow` による判定（6.2.2.5 / 6.2.3 / 7.2.3） |
| 台帳の永続化と署名 | React の状態として保持。HMAC も改ざん検知もない | `UsageLedger` を `ProtectedBlobStore` へ署名付きで保存（6.2 / 6.2.5） |
| 書き出しの耐久性 | 中断・復旧の概念がない | `ExportCommit` によるコミットジャーナルと起動時の復旧（7.4.3） |
| 排他制御 | なし | `ExportStartGate` と `UsageLedgerStore.transact` による直列化（7.4.3） |
| 共有結果の写像 | デモ用のトグルで切り替える | `SharePresenter` が `UIActivityViewController` の結果を 4 種へ写像する（7.4.2） |
| `StampAsset` の寿命 | 履歴からの参照有無で判定する簡易版 | 内容ハッシュを主キーとする参照カウント（8.4） |
| 一覧の拡大操作 | タップで全画面プレビューのみ | ピンチ拡大も要件（6.5.3） |
| 支援技術での末尾到達 | スクロール検知のみ | VoiceOver の走査でも成立させる（6.5.3） |
| 素材の同一性 | 写真 ID をそのまま使う | `SourceAlias` の解決・統合と `sourceID`（6.2.4） |
| データ保護クラス | Web では概念がない | ロック中は `.complete` のファイルへアクセスせず処理を一時停止（7.3.3） |
| ファイル属性の検証 | なし | `ManagedFileStore` が保存のたびに設定し読み返す（7.3.4） |
| リモート設定 | 定数として埋め込み | エンベロープ検証と `ProtectedBlobStore` への署名付きキャッシュ（11.3） |
| 更新判定 | 設定画面から手動で発火する | 起動時と復帰時に `evaluateUpdate`（6.8） |

### 14.2 モックから引き継ぐもの

- 画面構成（タブ 4、アップグレード訴求モーダル、単体処理の 5 画面）
- 単体処理フロー `home → ピッカー → detect → effect → export → processing → done`
- 配色、余白、角丸、タイポグラフィなどのビジュアル言語
- 課金訴求の分類（13.5 の `UpgradeReason` 表）

---

## 15. 上位仕様書からの逸脱一覧

| 仕様書 | 仕様書の内容 | 本設計 | 理由 |
| --- | --- | --- | --- |
| 4.2 / 32.1 | **iOS / Android の二本立てでリリースする** | **v1 は iOS 単独。** 技術スタックは Swift + SwiftUI | 1.2 / 3 節。v1 の検証を優先する。Android は再実装が必要になることを受け入れる |
| 4.1 | 対応 OS の下限を明示していない | **iOS 26 以降** | 3.2。回避策のコストを負わず、SwiftUI と Swift 6 の機能を前提にする |
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
| **App Store ID** | 更新誘導のリンク先に必要（6.8.7）。App Store Connect でアプリを作成した時点で確定 | ストア登録時 |
| **`lowConfidence` の閾値** | `FaceObservation.confidence` の下限。実素材の分布を見て決定（5.7.1 / 6.5.2） | v1 実機検証時 |
| プライバシーポリシーの記載 | トライアル台帳（`SourceRecord`）を期限なく端末内へ保持することを記載し、7.2.3 の例外と整合させる | ストア申請前 |
| 共有結果 `Unknown` 後の利用者操作 | `Generated` を維持するため、共有後に画面を離れると「保存していない写真があります」が出る。「共有できましたか？」と明示確認して `Delivered` にするか、`Generated` のまま保存・再共有・破棄を選ばせるか。OS 結果の写像だけでなく、その後の操作まで定義が必要（7.4.2） | 実装計画で確定 |
| 基本スタンプの意匠 | ベクターで自作する 12〜20 種の具体的な図案 | v1 実装中 |
| `extremePose` の角度閾値 | yaw / pitch の絶対値が何度を超えたら警告するか。検出品質テストの結果から決定（6.5.2） | v1 実機検証時 |
| 履歴の使用容量上限 | 初期値 200MB は暫定。加工後サムネイルの実サイズを計測して確定 | v1 実装中 |
| カスタムスタンプの保存解像度 | 長辺 1,024px は暫定。顔が大きく写る素材での見え方を実機で確認して確定（8.5） | v1 実機検証時 |
| トライアルのクレジット数 | 5 枚は暫定。転換率を見て調整可能な設定値とする | リリース後 |
| 一括処理の同時並列数 | 写真のみのため 2 まで許容可能だが、初期値は 1。実機計測後に判断 | v1 実機検証時 |
| **ファイル同期の方式** | `F_FULLFSYNC` と通常の `fsync` の所要時間差を実機計測し、耐久性とのつり合いで決定（7.1） | v1 実機検証時 |
| **手順 7-b の再確認しきい値** | `usageNow - finalizedAt` の許容差 5 分は暫定。手順 3〜7 の実測時間から確定（7.4.3） | v1 実機検証時 |
| **信頼できる時刻の取得元** | `retentionNow` と `MonthlyIntegrityLock` の解除に使う時刻を、`/v1/config` のレスポンスヘッダから取るか RevenueCat の `CustomerInfo` から取るか（6.2.2.5） | 実装計画で確定 |

---

## 17. 次の手順

本設計の承認後、`superpowers:writing-plans` により実装計画を作成します。サブプロジェクトへの分解単位は以下を想定します。

1. プロジェクト基盤（Xcode プロジェクトと SwiftPM ローカルパッケージの骨格、CI、SwiftLint、`swift test` の実行基盤）
2. ドメイン層（`QuotaPolicy`、`EntitlementResolver`、`BatchTriagePolicy`、`compileRenderDraft`、キーフレーム補間、`ExportQueue`）
3. プラットフォーム層（5.4 のプロトコル一覧と、`App` 所有のピッカーの実装・適合テスト）。**モジュールは責務ごとに分ける**（下表）。`SharePresenter` は結果写像を先に定義してから実装する（7.4.2）
4. 永続化とコミットジャーナル（GRDB、2 DB 構成と `ATTACH`、`ProtectedBlobStore`、`CryptoKeyStore`、障害注入テスト基盤）
5. 編集フロー UI（detect / effect / export / processing / done）
6. 課金と権限（RevenueCat、Paywall、復元、`SubscriptionState` の読み込み失敗経路）
7. 広告
8. 一括処理とトリアージ
9. 履歴・カスタムスタンプ・設定
10. バックエンド（Rust + Axum。リモート設定の検証規則を含む。11.3）
11. リリース準備（アクセシビリティ、プライバシー受入テスト、実機マトリクス、ストア申請物）

**サブプロジェクト 4 を独立させます。** コミットジャーナルは本設計で最も密度が高く、実機の障害注入テストを伴います。UI と並行して進めると、どちらの不具合か切り分けられません。

サブプロジェクト 3 の内訳は次のとおりです。**すべてを `MediaKit` へ実装しません**（5.4）。プロトコルの一覧は 5.4 を正とし、ここでは個数を数えません（`CrashReporter`、各 Repository、`UsageLedgerStore`、`ExportStartGate` も `Domain` のプロトコルです）。

| モジュール | プロトコル |
| --- | --- |
| `MediaKit` | `PickedPhotoLoader` / `FaceDetector` / `ImageEffectRenderer` / `ImageEncoder` / `MediaSaver` / `SharePresenter`（MainActor） |
| `Rendering` | `StampRasterizer` |
| `Persistence` | `ProtectedBlobStore`、`ManagedFileStore`、GRDB、ファイル管理 |
| `Persistence/Security` | `CryptoKeyStore` |
| `Ads` | `AdPresenter` |
| `App` | `PrivacyShield`、`PhotosPicker` / `fileImporter` の提示、**`PhotoSelectionBridge` / `FileSelectionBridge`**、`ProtectedDataAvailability` の実装（5.4 / 7.3.3） |

各サブプロジェクトは個別に spec → plan → 実装のサイクルを回します。
