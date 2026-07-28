# 顔かくし 技術スタックおよびアーキテクチャ設計

| 項目 | 内容 |
| --- | --- |
| 文書名 | 顔かくし 技術スタックおよびアーキテクチャ設計 |
| バージョン | 3.0 |
| 作成日 | 2026-07-27 |
| 対象 | 写真向け顔匿名化アプリ（**iOS 単独**） |
| 上位文書 | 写真・動画向け顔匿名化アプリ 仕様書 v0.1 |
| 関連文書 | `docs/adr/`（採用理由）、`docs/test-plan.md`（テスト項目の網羅一覧） |

---

## 1. 目的・前提・対象範囲

### 1.1 本書の役割

本書は **実装時に参照する現在の設計** を定めます。型、不変条件、状態遷移、処理順、障害時の挙動を一意に決めることが目的です。

| 範囲 | 内容 |
| --- | --- |
| 本書 | モジュール境界、ドメインモデル、永続化、書き出し Saga、セキュリティ、テスト戦略の骨子 |
| `docs/adr/` | 技術選定の背景と採用理由 |
| `docs/test-plan.md` | 層ごとの個別テスト項目 |
| 上位仕様書 | 商品仕様、料金、画面の操作仕様 |
| `ui-mock/` | 画面構成とビジュアル言語の参照実装 |

**挙動の定義については本書が正であり、`ui-mock/` は本書に追従します。** モックのコードは実装へ流用しません。

上位仕様書からの逸脱は 12.4 に集約します。

### 1.2 実装体制と前提

実装者は Claude Code 単独です。支配的な制約は次の 2 点です。

- **プラットフォームの機能をそのまま使えること。** 抽象化層を挟まない分、Vision や Core Image の新機能を即座に利用できる
- **単一言語で完結すること。** ビルド構成、テスト実行、デバッグ経路がすべて Xcode に閉じる

**Android を後から追加する場合、ドメイン層の再実装が必要になります。** これは iOS 単独リリースを選んだことの帰結です。移植時に参照できるよう、ドメイン層の設計判断を本書へ文章として残します。コードだけが仕様になる状態を避けます。

### 1.3 本書の対象外

- 画面ごとの視覚デザイン（配色・余白・タイポグラフィは `ui-mock/`）
- スタンプの意匠
- 完成した UI 文言、Paywall の文面、商品説明
- 個別テストケースの網羅一覧（`docs/test-plan.md`）
- 技術選定に至る比較検討（`docs/adr/`）

---

## 2. 技術スタック

### 2.1 全体

| 領域 | 採用技術 |
| --- | --- |
| 言語 | Swift 6（strict concurrency） |
| UI | SwiftUI |
| 状態管理 | Observation（`@Observable`） |
| 非同期・排他 | Swift Concurrency（`actor`） |
| ローカル DB | GRDB（SQLite） |
| DI | イニシャライザ注入（フレームワーク不使用） |
| 課金 | RevenueCat iOS SDK |
| 広告 | Google Mobile Ads iOS SDK |
| クラッシュ解析 | Sentry Cocoa SDK |
| バックエンド | Rust + Axum（リモート設定と診断のみ） |
| 対応 OS | iOS 26 以降 |

採用理由は ADR 0001（iOS 単独と SwiftUI）、ADR 0002（GRDB）、ADR 0004（最小バックエンド）にあります。

### 2.2 プラットフォーム API

| 用途 | 採用 API |
| --- | --- |
| 顔検出 | Vision（`DetectFaceRectanglesRequest` / `FaceObservation`） |
| 写真選択 | PhotosPicker |
| カスタムスタンプの取り込み | `fileImporter`（UIDocumentPicker） |
| 画像読み込み・向き正規化 | Image I/O |
| エフェクト描画 | Core Image（`CIPixellate` / `CIGaussianBlur`） |
| スタンプのラスタライズ | Core Graphics（`CGContext`） |
| エンコード・メタデータ除去 | Image I/O |
| 写真ライブラリ保存 | PhotoKit（`PHAssetCreationRequest`） |
| 共有 | `UIActivityViewController`（8.8） |
| 署名鍵の保管 | Keychain（**鍵のみ**） |
| 署名付きデータの保管 | アプリ専用ディレクトリ上のファイル（HMAC 付き、原子的置換） |
| 動画（v2） | AVFoundation / AVAssetWriter |

**鍵とデータ本体を分けます。** Keychain は台帳のような可変データを繰り返し置き換える用途に向きません。`UsageLedger` や `SubscriptionState` の本体はファイルへ置き、Keychain の鍵で HMAC を付けます。`CryptoKeyStore`（鍵）と `ProtectedBlobStore`（署名付きデータ）の 2 プロトコルに分けます。

**`ImageRenderer`（SwiftUI）ではなく `CGContext` を使います。** `ImageRenderer` は `@MainActor` に隔離されており、一括処理 50 枚のラスタライズを直列化します。`CGContext` はバックグラウンドで実行でき、ピクセル形式とストライドも明示できます（5.3 の規約に必要）。

**`UIViewRepresentable` / `UIViewControllerRepresentable` を使うのは広告バナーと共有シートだけ**とします。

---

## 3. モジュール構成と依存方向

### 3.1 パッケージ構成

Swift Package Manager のローカルパッケージとして層を分け、**モジュール境界をコンパイラに強制させます。**

```
kaokakushi/
├── Kaokakushi.xcodeproj
├── App/                     アプリ本体
│   ├── KaokakushiApp.swift  エントリポイント、DI の組み立て
│   ├── Navigation/          Route と画面解決
│   ├── Screens/             SwiftUI の各画面
│   ├── Selection/           PhotoSelectionBridge / FileSelectionBridge（5.5）
│   └── PrivacyShield/       スクリーンショット対策（9.3）
│
├── Packages/
│   ├── Domain/              純粋 Swift。Foundation 以外に依存しない
│   ├── Application/         書き出し Saga、起動時復旧、ロールバック（4.3）
│   ├── Rendering/           StampRasterizer 実装（Core Graphics）
│   ├── Persistence/         GRDB、ファイル管理、ProtectedBlobStore
│   │   └── Security/        CryptoKeyStore（Keychain。HMAC 鍵のみ）
│   ├── MediaKit/            Vision / Image I/O / Core Image / PhotoKit
│   ├── Billing/             RevenueCat ラッパと権限解決
│   ├── Ads/                 AdPresenter（Google Mobile Ads）
│   └── Analytics/           イベント定義と送信
│
├── server/                  Rust + Axum
└── ui-mock/                 Next.js による UI モック（参照専用）
```

### 3.2 依存の向き

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

`Domain` がプロトコルを定義し、各アダプタが実装します。`Application` は `Domain` のプロトコルだけを通してアダプタを操作します。

**`App` が具象アダプタへ依存してよいのは組み立て時に限ります。** `App` の `View` や状態オブジェクトがアダプタを直接呼ぶことは禁止し、呼び先は `Application` の Coordinator だけとします。

**例外は 2 つの境界サービスだけです。**

| 規則 | 内容 |
| --- | --- |
| 例外の範囲 | `PhotoSelectionBridge` と `FileSelectionBridge` の 2 型のみ（5.5） |
| 使ってよいアダプタ | `ManagedFileStore` のみ |
| `View` からの呼び出し | bridge のみ。`ManagedFileStore` には触れない |
| CI のチェック | `App/Sources` 配下で `ManagedFileStore` を参照するファイルを、この 2 つに限定する |

ピッカーは SwiftUI の modifier であり `Domain` のプロトコルにできないため、その結果を境界を越えられる型へ変換する場所が要ります。**範囲を型名で固定すれば、レビューでも CI でも確認できます。**

### 3.3 `Domain` の依存制約

| 使ってよい | 使わない |
| --- | --- |
| `Foundation`（`Date`、`Data`、`UUID`、`Calendar`、`TimeZone`） | `SwiftUI`（`CGSize`、`Color`、`Angle` を含む） |
| Swift 標準ライブラリ | `UIKit` / `CoreGraphics` / `CoreImage` |
| | `GRDB` / `Vision` / `Photos` / `Security` |

**`CGSize` や `CGRect` も使いません。** 必要な値型は `PixelSize` / `PixelRect` / `NormalizedRect` としてドメイン側で定義します（5.2）。`CoreGraphics` の型を持ち込むと、暗黙に「原点は左下か左上か」といった描画系の前提が混入します。

**`Package.swift` の `dependencies` では強制できません。** Apple SDK のシステムモジュールは `dependencies` に列挙しなくても `import` できます。

| 手段 | 内容 |
| --- | --- |
| SwiftLint の `forbidden_imports` | `Domain/Sources/**` に対し上記の禁止モジュールを検出する |
| CI のチェック | `Domain/Sources` 配下の `import` 行を走査し、許可リスト（`Foundation` のみ）以外で失敗させる |
| SwiftLint のカスタムルール | `Domain` ターゲット内の `Date()` を禁止する（6.3 の時刻規約） |

`Application` にも同じ制約を課します（4.3）。

この制約により、仕様 30.1 が要求する単体テスト項目がすべてシミュレータなしで実行できます。

### 3.4 ナビゲーション

画面は `Route` の enum で表現し、`Route` から `View` への解決を 1 箇所の `switch` に集約します。`NavigationStack` の `path` を `[Route]` として `@Observable` な状態オブジェクトが所有します。

**画面遷移をドメインの状態から導出しません。** 「未保存出力があるときは新規加工を開始できない」のような規則はドメインが判定し、UI はその結果を表示するだけです。遷移可否の判断を `View` の中へ書きません。

---

## 4. 並行性と Application 層

### 4.1 隔離の方針

Swift 6 の strict concurrency を有効にします。

| 対象 | 隔離 |
| --- | --- |
| `Domain` の値型 | `Sendable`。判定関数はすべて純粋関数 |
| `UsageLedgerStore` | `Domain` は**プロトコル**。実装は待機キューを持つ `actor`（4.2） |
| `ExportStartGate` | 同上 |
| `Application` の Coordinator | `actor` |
| `SharePresenter` / `AdPresenter` | **`@MainActor`**（UIKit を操作する） |
| UI の状態オブジェクト | `@MainActor` |
| `MediaKit` の重い処理 | `nonisolated` な `async` 関数。呼び出し側が並行度を制御する |

### 4.2 排他区間の実装規則

**Swift の `actor` は再入可能です。** `await` で中断すると、その隙に別の呼び出しが同じ actor のメソッドへ入れます。厳密な FIFO も保証されません。

本設計が要求するのは「読み取りから保存完了まで他を進めない」ことです。`transact` は「台帳を読む → 変換する → 署名してファイルへ保存する」であり、保存が `await` を含みます。**`actor` にするだけでは、この論理的なクリティカルセクションを保持できません。**

実装 actor に**明示的な待機キュー**を持たせます。

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
| 取得 | `isBusy` なら `withCheckedThrowingContinuation` で待機する |
| 保持 | **`await` を含む処理の全体で保持し続ける**（ファイル保存中も解放しない） |
| 解放 | `defer` で必ず行う。`throw` しても解放される |
| 順序 | 待機キューを**明示的に FIFO** とする。actor の暗黙の順序に依存しない |

`ExportStartGate` も同じ構造です。permit を保持したまま `await operation()` を実行し、`withExclusivePermit` から復帰するまで次の要求を待たせます。

##### キャンセル

**`CheckedContinuation<Void, Never>` ではキャンセルを伝えられません。** 利用者が待機中の写真をキャンセルしても continuation はキューに残り、前の処理が終わると resume され、**キャンセル済みのタスクが permit を取得して書き出しを開始します。**

| 規則 | 内容 |
| --- | --- |
| waiter の識別 | 各 waiter へ `UUID` を割り当てる |
| キャンセル時 | `withTaskCancellationHandler` でキューから該当 waiter を除去し、`CancellationError` で resume する |
| permit 取得直後 | `try Task.checkCancellation()` |
| 認可の直前 | **もう一度** `try Task.checkCancellation()` |
| 解放 | `defer` で必ず行う。キャンセル経路でも解放される |

**チェックを 2 回入れます。** permit 取得直後だけだと、その後の `transact` 開始までの間にキャンセルされた場合を拾えません。認可の直前が最後の安全な中断点です。

##### 二重 resume の防止

キャンセルと permit 解放が競合すると、同じ continuation を 2 回 resume してクラッシュします。actor 内部で次の順に行います。

1. **waiter ID をキューから原子的に除去する**
2. **除去できた場合だけ** `CancellationError` で resume する
3. permit 解放側は、キューの先頭から取り出す時点で存在を確認し、既に除去済みの waiter を resume しない

「除去できたか」を resume の条件にすることで、どちらの経路が先に走っても resume は 1 回に収まります。

**`CancellationError` は業務エラーとして扱いません。** Sentry へ送らず（9.2）、キュー項目を `canceled` へ遷移させる制御フローとします。

##### キャンセルの境界

| 時点 | 扱い |
| --- | --- |
| 手順 4 より前 | ロールバック。消費なし |
| 手順 4 以降・手順 7 より前 | 暫定会計を取り消してロールバック（8.4） |
| 手順 7 の完了後 | **キャンセルではなく破棄として扱う。** 枠は戻さない |

手順 7 が完了した時点で成果物は公開されており、正常生成が確定しています。UI 上も、手順 7 の完了後は取り消せるかのような文言にしません。

### 4.3 Application 層

次の処理は `Domain`（純粋 Swift）にも `App`（SwiftUI）にも置けません。

- 書き出しの手順 −2〜7（8.3）と補償トランザクション
- 起動時復旧、ロールバック
- DB・台帳・ファイルの協調、ゲートの取得と解放
- 出力の受け渡し

`App` の `View` や状態オブジェクトへ置くと **UI 状態と永続化 Saga が結合し**、画面を離れたら復旧処理が止まる経路ができます。`Domain` へ置くと副作用と `await` が入り、純粋 Swift の制約が壊れます。

```swift
// Application — Domain のプロトコルだけを使う
actor ExportCoordinator { }           // 手順 −2〜7、ロールバック
actor StartupRecoveryCoordinator { }  // 起動時復旧（8.5）
actor OutputDeliveryCoordinator { }   // MediaSaver / SharePresenter の呼び出しと状態遷移
```

**`Application` が直接 `import` してはいけないもの**を明示します。

| 禁止 | 代わりに使う |
| --- | --- |
| `SwiftUI` / `UIKit` | UI は知らない。保護データの利用可否は `Domain` の `ProtectedDataAvailability`（7.4） |
| `GRDB` | `Domain` の永続化プロトコル |
| `Vision` / `CoreImage` / `Photos` | `Domain` の `FaceDetector` / `ImageEffectRenderer` / `MediaSaver` |
| `Security`（Keychain） | `Domain` の `CryptoKeyStore` |

この制約により、saga テストが偽実装だけで完結します（11 章）。

---

## 5. 画像処理アーキテクチャ

**エフェクトの数学をすべて `Domain` に置き、`MediaKit` には描画プリミティブのみを残します。** 目的は、エフェクトの計算をシミュレータなしでテストできる状態に保つことです。Core Image を呼び出す層に強度計算が混ざると、そのテストに実機が要ります。

```
MediaKit   Vision で顔検出 → 正規化座標の矩形群 + 頭部回転角 + 信頼度 + 小顔フラグ（5.1）
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

### 5.1 顔検出境界

処理手順は仕様 8.3 に従います。

1. 元画像の向き情報を正規化する
2. 検出用に長辺 1,920 ピクセル程度へ縮小する
3. `DetectFaceRectanglesRequest` を実行する
4. **`MediaKit` で正規化座標へ変換して返す**（Y 軸の反転を含む。5.4）
5. 以降、`Domain` は顔領域をピクセル座標として保持しない

検出用画像上で顔の短辺が 24 ピクセル未満の検出結果には `isSmallFace` を立てます（仕様 8.5）。

##### 顔単位の共通モデル

Vision の型（`FaceObservation`）を `Domain` へ流しません。

```swift
struct DetectedFace: Sendable, Equatable {
    let faceTrackID: FaceTrackID  // 6.6
    let bounds: NormalizedRect    // 左上原点へ変換済み（5.4）
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
    bounds: convertBounds(observation.boundingBox),   // Y 軸反転（5.4）
    confidence: Double(observation.confidence),
    yawDegrees: observation.yaw.converted(to: .degrees).value,
    pitchDegrees: observation.pitch.converted(to: .degrees).value,
    rollDegrees: observation.roll.converted(to: .degrees).value,
    isSmallFace: isSmallFace
)
```

**角度は非 Optional です。** `FaceObservation` の `yaw` / `pitch` / `roll` は `Measurement<UnitAngle>` です。新旧 Vision API の型を混在させません。Optional な角度が必要になった場合は、全体を旧 API（`VNDetectFaceRectanglesRequest` / `VNFaceObservation`）へ戻します。

##### `confidence` の受入条件

**Vision の `confidence` は、常に意味のある値とは限りません。** Apple は、`1.0` が最高信頼度を表す場合と、その観測が `confidence` に意味を割り当てていない場合の両方がありうると説明しています。

`lowConfidence` を有効にする前に、採用する `Revision` について実素材で分布を確認します。

- 値が実際に変動する（常に同一値ではない）
- 検出品質と一定の相関がある
- 常に `1.0` ではない

**この条件を満たさない場合、`lowConfidence` をトリアージから外します。** 意味のない値で警告を出すと、警告の総量だけが増えて `smallFace` や `extremePose` まで流し読みされます。閾値は 12.5 の未決事項です。

##### 拡張率の適用

```swift
func expand(face: NormalizedRect, effect: EffectSetting) -> NormalizedRect
```

既定値は上 25% / 下 15% / 左右 15%（仕様 8.4）。スタンプはモザイクより大きめの拡張率を用います。

**画像外へはみ出す場合もクランプしません。** クランプすると顔が露出する方向へ倒れます。はみ出しはマスク描画側で処理します。

### 5.2 RenderSpec / RenderDraft / RenderPlan

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
    let regions: [RenderRegionSpec]      // 順序に意味がある（9.1 の ordered）
}

struct RenderRegionSpec: Sendable, Equatable {
    let bounds: NormalizedRect           // 拡張率適用済み。出力キャンバス基準（5.4）
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

enum SourceScaleMode: Sendable { case fit, fill }

struct RenderRegion: Sendable {
    let bounds: PixelRect                // 出力キャンバス基準の絶対ピクセル
    let rotationDegrees: RotationDegrees
    let shape: MaskShape
    let featherPx: FeatherPx
    let order: Int                       // 描画順（5.4）
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

**`RenderPlan` は正規化座標を 1 つも持ちません。** そのため `compileRenderDraft` は `sourceSize` を受け取ります。これが無ければ元画像基準の正規化値をピクセルへ変換できず、比率計算と丸め規則が `MediaKit` 側へ漏れます。`sourceSize` は向き正規化後の寸法です。

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

| 型 | 条件 |
| --- | --- |
| `EffectOpacity` | 有限かつ **`0 < v <= 1`** |
| `MosaicRatio` / `BlurRatio` | 有限かつ `0 < v <= 上限` |
| `PixelSize` | `width > 0` かつ `height > 0` |
| `PixelRect` / `NormalizedRect` | すべて有限。`left < rightExclusive`、`top < bottomExclusive` |
| `CellSizePx` | **`>= 2`**（1px のモザイクは元画像と同じ） |
| `SigmaPx` | `> 0` |
| `FeatherPx` | `>= 0`（境界のぼかしは匿名化の強度に影響しない） |
| `RotationDegrees` | 有限 |
| `VisibleColor` | **アルファが 0 より大きい** |
| カスタムスタンプ画像 | 最大アルファ値が 0 なら取り込み時に拒否する |

**検証を迂回できないようにします。** Swift は `struct` へ memberwise initializer を自動生成するため、同一モジュール内からは検証を飛ばせます。

- 検証前の initializer をモジュール外へ公開しない（`public` は `throws` 版だけ）
- 同一モジュール内でも直接生成しない規約とし、lint で検出する
- **永続データのデコード時にも同じ検証を通す**（`Decodable` の `init(from:)` で `throws` 版を呼ぶ）

**利用者が「この顔は隠さない」と選ぶ経路は別に存在します。** `isMasked = false` にするか、`ReviewResolution.unmaskedExportConfirmed` を記録するか（6.1）です。`isMasked == true` の顔に no-op 相当の値が渡された場合、`compileRenderDraft` が `throw` します。

### 5.3 スタンプラスタライズ

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
    let rasterFile: ManagedFileRef   // kind は .rasterTemporary（7.3）
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

**パディングをゼロ初期化しないと、未初期化メモリの内容がファイルへ書かれます。** `CGContext` が確保するバッファは行末のアライメント領域を初期化する保証がありません。プライバシー保護を目的とするアプリで、由来不明のメモリ内容を永続化することは許容できません。`CGBitmapContextGetData` の全域を明示的にゼロ埋めしてから描画します。

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

### 5.4 座標・色・合成規約

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
| `featherPx` / `cellSizePx` / `sigmaPx` | 丸めない（`Double` のまま渡す） |

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
}
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

### 5.5 写真選択と PhotoKit 境界

##### `Domain` のプロトコル

| プロトコル | 責務 | 実装モジュール | 使用 API |
| --- | --- | --- | --- |
| `PickedPhotoLoader` | **物質化済みファイル**の読み込み、向き正規化、検出用縮小、HEIC 対応 | `MediaKit` | Image I/O |
| `FaceDetector` | 顔検出。正規化座標で返す | `MediaKit` | Vision |
| `ImageEffectRenderer` | `RenderPlan` の 4 プリミティブ実行 | `MediaKit` | Core Image |
| `ImageEncoder` | JPEG / HEIC エンコード、メタデータ除去 | `MediaKit` | Image I/O |
| `MediaSaver` | 写真ライブラリ保存、登録日時の指定 | `MediaKit` | PhotoKit |
| `StampRasterizer` | スタンプのラスタライズ（5.3） | `Rendering` | Core Graphics |
| `CryptoKeyStore` | HMAC 鍵の生成と保持。**鍵のみ扱う** | `Persistence/Security` | Keychain |
| `ProtectedBlobStore` | 署名済み状態の原子的な読み書き | `Persistence` | 保護ファイル |
| `ManagedFileStore` | 全ファイル生成の共通口（7.3） | `Persistence` | Foundation |
| `ProtectedDataAvailability` | 保護データの利用可否と復帰待ち（7.4） | `App` | `UIApplication` と 2 つの通知 |
| `UsageLedgerStore` | 台帳更新の直列化（4.2 / 6.3） | `Persistence` | — |
| `ExportStartGate` | 書き出し開始の排他（8.1） | `Application` | — |
| `CrashReporter` | クラッシュ送信と送信前フィルタ（9.2） | `Analytics` | Sentry |

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
| `SharePresenter` | `MediaKit` | `UIActivityViewController`（8.8） |
| `AdPresenter` | `Ads` | Google Mobile Ads |

`OutputDeliveryCoordinator`（`actor`）から `await` して呼びます。`@MainActor` の型はアクタによって状態が保護されるため `Sendable` として扱えます。

##### `App` が所有するもの

`PhotosPicker` と `fileImporter` は SwiftUI の modifier であり、画面上の `Binding` と提示状態を必要とします。`Application` から呼ぶ非 UI サービスとして表現できません。

| 対象 | 所有者 | 備考 |
| --- | --- | --- |
| `PhotosPicker` の提示 | `App` | `PhotosPickerItem` は `App` の外へ出さない |
| `fileImporter` の提示 | `App` | 外部 `URL` は `App` の外へ出さない |
| `PrivacyShield` | `App` | `scenePhase` に紐づく（9.3） |

```swift
// App — 境界サービス。View から呼べるのはこの 2 つだけ（3.2）
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

protocol PickedPhotoLoader: Sendable {
    /// 物質化済みファイルを読み、向きを正規化して返す。選択そのものは扱わない
    func load(_ file: ManagedFileRef) async throws -> LoadedPhoto
}
```

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

それでも `Optional` として扱い、取得できない場合は `SourceIdentity.providerAssetKeyHash` を `nil` として `contentFingerprint` だけで判定します（6.4）。

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

`PickedPhotoInput` は一時値であり、再起動後には残りません。一方 6.5 は「アプリ再起動後に未完了キューを復元する」と定めています。復元したキュー項目が参照する処理用ファイルを表す永続モデルが無ければ、**復元しても加工を再開できません。**

```swift
struct WorkingSourceRecord: Sendable {
    let projectID: ProjectID          // 6.6
    let sourceFile: ManagedFileRef    // kind は .processingTemporary
    let createdAt: Date
}
```

| 項目 | 規約 |
| --- | --- |
| 保存先 | `runtime.db`（7.1）。実体は `runtime/processing/`（7.4） |
| 作成 | 手順 3 の物質化と**同一トランザクション**。ファイルを作って行を作らない経路を残さない |
| 参照 | キュー項目・編集中プロジェクトの元素材 |
| 削除 | 書き出し完了時またはプロジェクト破棄時に `PendingFileDeletion` へ（7.5） |
| 起動時 | どのプロジェクトからも参照されない行を回収し、実体も削除する |
| 実体が欠けている | そのキュー項目を **`reselectionRequired`** へ遷移させる。エラーで止めない |

`tmp/` に置くと OS がいつでも削除でき、再起動のたびにキューの復元が失敗します。それでもディスク不足で消える可能性はゼロにならないため、`reselectionRequired` を逃げ道として残し、**該当項目だけを再選択対象としてバッチ全体を失いません。**

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
| クォータ用 `contentFingerprint`（6.4） | **EXIF の `DateTimeOriginal` のみ。** 無ければ `null` |
| 写真ライブラリ保存時の `creationDate`（7.5） | `PHAsset.creationDate`（権限がある場合のみ）→ EXIF → 設定しない |

前者を権限に依存させると、権限を得る前後で同じ写真の fingerprint が変わり、無料枠を二重に消費します。

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
| 保存先 | **`user-data.db` の `Project` のみ** |
| バックアップ | 対象外（7.4） |
| ログ・分析・診断 | **一切出さない。** 分析イベントのフィールド型にしない（9.2） |
| `UsageLedger` への保存 | **しない。** クォータ側は `providerAssetKeyHash` のまま |
| `nil` の場合 | 再編集で再選択を求める |
| `Project` の削除 | 同じ行なので同時に消える |

**クォータ側を平文に戻しません。** 仕様 14.5 が制限しているのは不正利用防止のための識別子収集です。再編集は利用者自身が要求する機能であり、その実現に必要な最小の参照を利用者のデータと同じ寿命・同じ保護で持つことは目的が異なります。**2 つを 1 つのフィールドへまとめないことが要点です。**

### 5.6 動画対応で追加する契約（v2）

以下 4 つを **v1 の設計時点で定義**し、実装のみ v2 に回します。

| プロトコル | 責務 | 使用 API |
| --- | --- | --- |
| `VideoProbe` | 長さ、解像度、コーデック、回転、HDR 判定 | AVAsset |
| `VideoFrameSource` | 時刻指定のフレーム取得 | AVAssetReader |
| `PreviewRenderer` | エフェクト適用済みテクスチャ出力 | MTKView |
| `VideoExporter` | 書き出し | AVAssetWriter |

| 対象 | v1 | 理由 |
| --- | --- | --- |
| 動画用データモデル（`FaceKeyframe` 等） | **実装する** | スキーマを後から足すより安い |
| 上記 4 契約のインターフェース定義 | **実装する** | 境界を先に切る意味がある |
| キーフレーム補間 | **実装する** | 仕様 10.3 で挙動が確定している純粋関数 |
| 顔トラック関連付け / 平滑化 / シーン切替判定 | v2 | 閾値とヒューリスティクスが実際の検出結果に依存する |

手動領域はすべて `Domain` 側で扱います。`MediaKit` は手動領域を認識せず、`RenderPlan` の `RenderRegion` として渡されたものを描画するだけです。写真では手動指定領域を `FaceTrack`（`createdManually = true`）として扱い、動画（v2）ではキーフレーム間で中心 X / 中心 Y / 幅 / 高さ / 回転角度を補間します。

---

## 6. ドメインモデル

### 6.1 顔・レビュー状態

**検出された顔は、すべて加工対象の状態で初期化します。** これはドメインの不変条件とし、UI の慣習に委ねません。`isMasked` は生成時に常に `true` であり、`false` になるのは利用者の明示的な操作によってのみです。

初期状態が「全部残す」だと、一人選び忘れただけで顔が公開されます。初期状態が「全部隠す」なら、選び忘れは「隠しすぎ」に倒れます。**取り返しがつかない方向へ倒さない設計を採ります。**

派生する規則です。

- **検出品質に関する内部値を理由に、顔を自動除外しません**
- **小さい顔には確認を促しますが、加工対象からは外しません**（仕様 8.5）
- **書き出し前に加工後プレビューを必ず表示します**（仕様 10.4）
- **「自動検出に失敗したので何も隠さずに保存」という経路を持ちません**

##### トリアージ判定

写真単位の要確認理由を純粋関数で判定します。

```swift
enum ReviewReason: Sendable, Hashable {
    case noFaceDetected      // 顔を 1 つも検出できなかった
    case lowConfidence       // 検出信頼度が閾値未満（5.1）
    case smallFace           // 検出用画像上で短辺 24px 未満の顔がある
    case extremePose         // 横や上下を大きく向いた顔がある
    case faceAtEdge          // 拡張後の領域が画像境界に接する顔がある
    case overlappingFaces    // 領域同士が重なる顔がある
}

/// 警告 1 件の同一性。理由ではなく「発生」を識別する
struct ReviewIssueID: Sendable, Hashable {
    let projectID: ProjectID                  // 写真を識別する。6.6
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

**警告は発生単位で持ちます。** `Set<ReviewReason>` では同じ理由を持つ複数の顔を区別できず、小さい顔が 3 人写る写真で 1 人に手動領域を追加しただけで 3 人すべてに対応したことになります。

| 理由 | 発生単位 | `affectedFaceTrackIDs` |
| --- | --- | --- |
| `lowConfidence` / `smallFace` / `extremePose` / `faceAtEdge` | **顔ごと**に 1 件 | 対象の `faceTrackID` 1 件 |
| `overlappingFaces` | **重なる顔の組み合わせごと**に 1 件 | 重なる 2 件を**辞書順に並べる** |
| `noFaceDetected` | **写真ごと**に 1 件 | 空。`projectID` と `detectionRevision` が識別を担う |

`lowConfidence` と `extremePose` は捉える失敗が違うため両方を残します。

| 理由 | 判定 | 捉える失敗 |
| --- | --- | --- |
| `lowConfidence` | `confidence` が閾値未満 | 検出器自身が確信を持てていない |
| `extremePose` | `yawDegrees` または `pitchDegrees` の絶対値が閾値超過 | 検出はできているが、**拡張率の既定値では隠しきれない**可能性がある |

##### 再検出時は対応づけを試みない

**「再検出しても同じ顔へ同じ ID が付く」とは保証できません。** 検出順が変わっただけでも別の `faceTrackID` になりえます。誤った対応づけは「別人の顔に対する判断を、この顔の判断として扱う」ことを意味し、匿名化確認としては最悪の失敗です。

- `ReviewIssueID` に `detectionRevision` を含める
- **再検出のたびに `detectionRevision` を増やす**
- 再検出時は、その写真の `ReviewIssue` / `ReviewDecision` / `Reviewed` を**すべて破棄する**

##### トリアージの限界

**このトリアージは、検出された顔の品質しか評価できません。** 検出されなかった顔の存在は、いかなる警告条件にも現れません。

3 人が写る写真で 2 人を十分な大きさ・正面向き・画像中央で検出し、残る 1 人を完全に見落とした場合、`triage` は空集合を返します。この写真は `normal` に分類されますが、実際には 1 人の顔が露出したまま書き出されます。

したがって `normal` は安全の保証ではなく、**検出結果の上で警告すべき点がないこと**を意味するに過ぎません。この限界があるため、確認を必須とします。**アプリ側が `Reviewed` を立てることはありません。**

##### 検出ステータスと確認ステータス

**写真の状態を 2 つの軸で持ちます。** 「アプリが何を検出したか」と「利用者が何を確認したか」は別の情報です。

```swift
enum DetectionStatus: Sendable { case normal, reviewRequired }   // triage の結果
enum ReviewStatus: Sendable { case unreviewed, reviewed }        // 利用者の操作
```

| 軸 | 値 | 決まり方 |
| --- | --- | --- |
| 検出ステータス | `normal` | `triage` が空集合を返した |
| | `reviewRequired` | `triage` が 1 つ以上の警告を返した |
| 確認ステータス | `unreviewed` | 初期値 |
| | `reviewed` | 利用者の操作によってのみ遷移する |

検出ステータスは利用者の操作で変わりません。確認ステータスはアプリの判断で変わりません。

##### 要確認への対応

**`reviewRequired` かつ `unreviewed` の写真が 1 枚でも残っている間は、一括書き出しを開始できません。**

**警告を消すのではなく、警告に対する利用者の判断を記録します。** 検出結果は事実であり、利用者が確認したからといって事実が変わるわけではありません。

```swift
enum ReviewResolution: Sendable, Equatable {
    /// 内容を見て、このままでよいと判断した
    case acceptedAsIs

    /// 手動で隠す範囲を追加した。どの領域かを保持する
    case manualRegionAdded(regionID: RegionID)   // 6.6

    /// 顔を隠さずそのまま保存すると選んだ
    case unmaskedExportConfirmed
}

struct ReviewDecision: Sendable, Equatable {
    let resolutions: [ReviewIssueID: ReviewResolution]
}
```

**`manualRegionAdded` は `regionID` を持ちます。** 単なる列挙値だと、あとから利用者がその領域を削除した場合に判断だけが残って「対応済み」と表示されます。

- 領域の作成と判断の記録は、**1 つのドメインコマンドで原子的に**行う
- 手動領域の作成が失敗すれば、判断も記録しない
- `regionID` の領域が削除されたら、対応する `ReviewResolution` も破棄して `unreviewed` へ戻す

`reviewRequired` の写真が `reviewed` になる条件は、**その写真の `[ReviewIssue]` すべてに対して `ReviewResolution` が記録されていること**です。1 件でも未記録なら `unreviewed` のままです。理由単位ではなく発生単位にすることで、「3 人の小さい顔のうち 1 人だけ対応して先へ進む」経路がなくなります。

`normal` の写真には `ReviewIssue` がないため `ReviewDecision` を作れません。確認の成立はモードで分かれます（6.5）。

**一括対応は理由別のグループ単位でのみ許可します。** 50 枚中 30 枚が同じ理由で警告された場合に個別対応を強いるのは現実的でないためです。条件を 2 つ課します。

- そのグループのサムネイル一覧を表示した状態からのみ実行できる
- **`noFaceDetected` は一括対応の対象外とする。** 何も加工されないまま通過する最も危険な経路であり、個別の判断を要する

**`DetectionStatus` と `ReviewIssue` は利用者の判断で変化しません。** 警告の理由は書き出し後も記録として残り、あとから履歴を辿れます。

##### 単体処理で顔が 1 つも検出されない場合

**この節は単体処理に限ります。** 一括処理の顔 0 件は `noFaceDetected` と勘定の規則（8.1）に従います。

利用不可にはせず、手動で隠す範囲を追加する / 縦横比変更やメタデータ削除だけを行う / 編集を終了する、から選べるようにします。

加工なしの書き出しも仕様 14.2 の定義では消費対象です。不意打ちを避けるため書き出し前に明示しますが、**文言は `QuotaDecision`（6.3）で分岐させます。** 一律に「枠を使う」と表示すると、24 時間以内の再書き出しで誤った案内になります。`unlimited` では無料枠に言及しません。

### 6.2 能力と課金状態

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

- **`pending`（支払い保留）では有料機能を付与しません**（仕様 5.4）。個々の権限フラグはすべて `Entitlement` から導出し、`plan` から直接導出しません
- **オフライン耐性**（仕様 25.3 / 27.3）。最後に検証成功した `Entitlement` を `ProtectedBlobStore` へ保存し、ネットワーク不通時はこのキャッシュで有料機能を維持します。失効が明示的に確認された場合のみ剥奪します
- **バックエンド障害で編集を止めません**（仕様 21.6）

##### 能力の解決

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

enum CapabilityResolution: Sendable {
    case resolved(ResolvedCapabilities)
    case verificationRequired
}

func resolveCapabilities(_ state: SubscriptionCacheState) -> CapabilityResolution
```

**`Plan` を参照してよいのは能力解決の内側だけです。** `QuotaPolicy`、`AdFrequencyPolicy`、開始ゲート、一括処理の可否判定、既存作品の編集可否、UI の活性制御は、すべて `ResolvedCapabilities` を見ます。`Plan` を渡すと `plan = standard` かつ `status = pending` でも `plan != free` が成立し、規則を迂回します。

**「確認できない」を型で表します。** `ResolvedCapabilities` を必ず返す関数では、`metered` を返せば暗黙降格になり、`unlimited` を返せば未検証で有料機能を付与します。

`verificationRequired` の間の挙動です。

- **書き出しの認可を開始しない**（`ExportStartGate` を通さない）
- **有料機能を新規に付与しない**
- **Free へ降格したとも表示しない**
- 再試行と購入の復元を提示する

##### `missing` を Free として扱ってよい条件

キャッシュの不在だけでは、初回インストールなのか再インストールした有料利用者なのかを区別できません。

| 状況 | 解決結果 |
| --- | --- |
| `missing` かつ RevenueCat への問い合わせが**成功**（購読なし） | `resolved`（Free 相当の能力） |
| `missing` かつ問い合わせが**成功**（購読あり） | `resolved`（該当プランの能力） |
| `missing` かつ**オフライン等で問い合わせ不能** | **`verificationRequired`** |
| `valid` かつオフライン | `resolved`（キャッシュで維持） |

**キャッシュが無い状態でオフラインなら、書き出しを止めます。** Free として進めると有料利用者の再インストール直後に無料枠を消費させ、`unlimited` として進めると未検証で有料機能を渡します。どちらも取れません。購読の確認は初回起動時に一度行えば済むため、制約はオフラインでの初回起動という限られた場面だけです。

##### 購入状態キャッシュの読み込み失敗

`SubscriptionState` も `ProtectedBlobStore` 上の署名付きデータであり、`ProtectedLoadResult`（7.2）を返します。

| 結果 | 扱い |
| --- | --- |
| `valid` | オフラインでもこのキャッシュで有料機能を維持する |
| `missing` | RevenueCat へ問い合わせる。成功するまでは `verificationRequired` |
| `integrityFailure` / `unsupportedSchema`（移行不能） | キャッシュを信頼せず、RevenueCat から再取得する |
| `temporarilyUnavailable` | 上書きせず再試行する。判定は保留し、既存の `Entitlement` を維持する |

- 取得に成功すればキャッシュを置き換える
- **オフラインで再取得できない場合、有料権限を新規に付与しません**
- **カスタムスタンプ、履歴、プリセットなどのデータは削除しません**
- 利用者へは購入状態を確認できない旨を提示し、**再試行**と**購入の復元**への導線を出す

**Free へ降格したと表示しません。** 検証できない状態と失効した状態は異なります。

##### 解約・降格後の既存データ

**判定軸は「作成時のプラン」ではなく「現在の設定内容が要求するプラン」です。**

```swift
/// 表示用。Paywall の文言を組み立てるためだけに使う
func requiredPlan(_ project: Project) -> Plan

/// 実装上の判定。プラン名ではなく能力で決める
func canEdit(_ project: Project, capabilities: ResolvedCapabilities) -> Bool
```

**`requiredPlan` の戻り値で可否を決めません。** 必要プラン名と現在のプラン名を比較する実装になると `status = pending` が素通りします。

作成時のプランで判定すると、Standard 時代にモザイクだけで作ったプロジェクトが Free では編集できないのに、同じ元写真を選び直せば Free の機能で同じものを作れる、という説明のつかない差が生まれます。

| 操作 | Free 範囲のプロジェクト | 有料スタンプを含むプロジェクト |
| --- | --- | --- |
| 閲覧 | 可 | 可 |
| 削除 | 可 | 可 |
| 変更せず再書き出し | 可（6.3 のクォータ判定に従う） | 可（同左） |
| **編集して書き出し** | **可（6.3 のクォータ判定に従う）** | Standard 以上 |
| **Free 版として複製** | — | **可** |

Free 範囲のプロジェクトとは、モザイク・ぼかし・黒塗り・基本スタンプ・手動領域・縦横比・メタデータ設定だけを使っているものです。

**「Free 版として複製」** は、有料スタンプを基本の隠し方へ置き換えた複製を作る操作です。元のプロジェクトは変更しません。

- 置き換え先は**利用者に選ばせます**（モザイク / ぼかし / 黒塗り / 基本スタンプ）。自動でモザイクへ決め打ちすると意図しない見た目になります
- 選んだ方法を、有料スタンプを使っていた領域へ一括で適用する
- **領域の位置と大きさ、およびその他の出力設定はそのまま引き継ぐ**

バッチ**全体**に対する操作は内容によらず能力で決まります。

| 操作 | 必要な能力 |
| --- | --- |
| バッチ履歴の閲覧 / バッチ内の個別写真の閲覧 | なし |
| バッチ全体への設定反映 / 再実行 / エラー写真のみの再試行 | `canUseProBatch` |

原則は 4 つです。

- **閲覧と削除は常に可能**とする
- **既存の作品をそのまま取り出す権利は残す**
- **有料機能の新規利用にのみ契約が必要**とする
- **データそのものは削除しない**（仕様 12.6）。再契約時にカスタムスタンプと一括設定プリセットをそのまま再利用できる

**「変更せず再書き出し」は、アプリ提供の追加スタンプとカスタムスタンプを同一に扱います。** 規則を分けると「どちらのスタンプを使ったか」で挙動が変わり、説明できなくなります。判定はプロジェクトの設定内容のハッシュ（6.4）の一致で行います。有料スタンプを含むプロジェクトにおいて、エフェクト・強度・領域・出力設定のいずれかを変更した時点で Standard 以上が必要になります。Free 範囲のプロジェクトではこの判定を行いません。

**降格したという事実は、クォータ判定に影響しません。** 判定に使うのは素材の同一性と経過時間だけです。

##### 広告表示頻度

仕様 15.3 / 15.4 を純粋関数として実装します。

- 検出中、顔選択中、編集中、書き出し中、書き出しエラー対応中、課金処理中は表示しない
- 初回書き出し完了時には全画面広告を表示しない
- 全画面広告は最大でも 2〜3 回の書き出しにつき 1 回
- 同一セッションで連続表示しない
- 広告取得失敗でアプリ処理を止めない

### 6.3 クォータ・grant・トライアル

##### 台帳は 1 つ

**通常クォータ、`ExportGrant`、トライアル台帳を別々の値として持ちません。1 つの署名済みオブジェクトとして原子的に置き換えます。** 3 つを別々に更新すると、片方だけ書けた状態が生じます。

```swift
struct YearMonth: Sendable, Hashable, Comparable {
    let year: Int
    let month: Int          // 1...12
}

struct UsageLedger: Sendable, Equatable {
    let period: YearMonth                        // 消費を計上している年月
    let consumedExportIDs: Set<ExportID>         // 計上済みの書き出し（6.6）
    let sourceRecords: [SourceRecord]            // 素材の正規 ID と alias（6.4）
    let grants: [GrantEntry]
    let trialEntries: [TrialEntry]               // トライアル消費
    let trialReservations: [TrialReservation]    // 認可時の予約
    let sourceLeases: [SourceLease]              // 認可中の書き出しによる参照（6.4）
    let lastObservedAt: Date                     // 後退させない基準時刻
    let monthlyIntegrityLock: MonthlyIntegrityLock  // 破損修復による月間枠の封鎖
    let lastTrustedMonth: YearMonth?             // 信頼できる時刻から導出した最新の年月
    let trialIntegrityLocked: Bool               // 破損修復によりトライアルを封じたか
}

extension UsageLedger {
    var consumed: Int { consumedExportIDs.count }

    func grant(forSourceID id: SourceID) -> GrantEntry? {
        grants.first { $0.sourceID == id }
    }
}

struct GrantEntry: Sendable, Equatable {
    let sourceID: SourceID
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

**各要素に `ownerExportID` を持たせます。** ロールバックで「この書き出しが追加したもの」と「以前から存在したもの」を台帳そのものから判別するためです。DB 側の記録だけに頼ると、台帳を書いた直後に落ちた場合に判別できません。

**消費を件数ではなく書き出し ID の集合で持ちます。** `Int` では「同じ `exportID` の再適用を弾く」も「特定の書き出しの消費だけ取り消す」も実装できません。

各集合の要素数には上限があるため、**線形探索で構いません。**

| 集合 | 上限 |
| --- | --- |
| `sourceRecords` | 参照元がある素材のみ。削除規則により有界（6.4） |
| `sourceLeases` / `trialReservations` | 同時実行数。v1 は 1 |
| `grants` | 24 時間以内に成功した書き出しの素材数 |
| `trialEntries` | `configuredCreditCount`（既定 5） |
| `consumedExportIDs` | 月間上限（既定 5） |

##### 判定

```swift
enum QuotaBlockReason: Sendable {
    case monthlyLimitReached      // 通常の月間上限
    case ledgerIntegrityFailure   // 台帳破損による封鎖
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
    access: SingleExportAccess,      // Plan ではない。6.2 が解決した能力
    sourceID: SourceID,              // 6.4 で解決済み
    usageNow: Date,                  // 正規化済み。端末時刻を直接渡さない
    timeZone: TimeZone
) -> QuotaEvaluation
```

**判定結果だけでなく更新後の台帳も返します。** 判定だけでは `lastObservedAt` の前進、月次更新、期限切れ grant の削除を永続化できません。

判定順序です。

1. `lastObservedAt` を `usageNow` へ前進させる
2. 期間更新と期限切れ `grant` の整理を適用する
3. `access == .unlimited` なら `unlimited`
4. **`monthlyIntegrityLock` が解除条件を満たしていなければ `blocked(.ledgerIntegrityFailure)`**
5. `ledger.grant(forSourceID:)` があり `usageNow - firstSuccessAt < 24h` なら `freeReexport`
6. `consumed >= limit` なら `blocked(.monthlyLimitReached, limit)`
7. それ以外は `consume`

**手順 4 を月間上限の判定より前に置きます。** 破損修復後は `consumedExportIDs` が空なので、上限判定だけでは通過してしまいます。

理由を型で分けるのは、破損時に上限到達と表示するのが事実に反するためです。

**有料プランで `unlimited` を返す場合も、手順 1 と 2 は必ず実施してから返します。** 有料期間中に時刻更新と grant 整理を止めると、降格した瞬間に古い状態から判定が始まります。

##### `ExportGrant` の作成規則

**`ExportGrant` は、書き出し時のプランにかかわらず作成します。**

| 動作 | 条件 |
| --- | --- |
| `grants` へ素材を追加する | 利用可能な出力の生成が正常に完了した時点＝手順 7 の完了（8.3）。プランを問わない |
| `consumedExportIDs` へ `exportID` を追加する | `QuotaDecision` が `consume` のときだけ |
| `firstSuccessAt` を更新する | しない。同一素材の有効な grant があれば維持する |

有料プランで grant を作らないと、Standard で書き出した 1 時間後に Free へ降格して再書き出しした場合に `freeReexport` にならず枠を消費します。

`firstSuccessAt` を更新しないのは、再書き出しのたびに窓が延びると 24 時間の上限が意味を失うためです。**この規則は「会計時に有効な grant があるか」で判断すると破れます。** 認可から会計までの間に窓が切れると新規作成されるため、`freeMonthlyReexport` は認可時の `firstSuccessAt` を保存して維持します（8.1 の preserve）。

##### 時間判定の基準時刻

**すべての時間判定に端末時刻をそのまま使いません。** 正規化を 1 か所に集約します。各判定が個別に `max` を書くと、書き忘れた箇所だけ防御が抜けます。

```swift
struct TimeAnchor: Sendable { let lastObservedAt: Date }

struct ObservedTime: Sendable {
    /// クォータ・grant 用。単調増加する。巻き戻し防止が目的
    let usageNow: Date

    /// 削除・保持期間用。信頼できる時刻を得られない異常ジャンプ中は nil
    let retentionNow: Date?

    let updatedAnchor: TimeAnchor
}

func observeTime(now: Date, anchor: TimeAnchor, trusted: Date?) -> ObservedTime
```

`usageNow` は `max(now, anchor.lastObservedAt)` です。アンカーは `UsageLedger.lastObservedAt` として保持します。

| 判定 | 使う時刻 | `nil` のときの挙動 |
| --- | --- | --- |
| `ExportGrant` の 24 時間判定 | `usageNow` | — |
| 月次期間の更新 | `usageNow` | — |
| `finalizedAt` の確定（8.3） | `usageNow` | — |
| 履歴の保存期間判定（7.5） | `retentionNow` | **削除しない** |
| 未受け渡し出力の 24 時間削除（7.5） | `retentionNow` | **削除しない** |
| やり直しの 24 時間保持保証（7.5） | `retentionNow` | **保持を続ける** |

`retentionNow` の決め方です。

| 条件 | 値 |
| --- | --- |
| 信頼できる時刻がある（サーバーまたは RevenueCat から最近取得した値） | その値 |
| 端末時刻が `lastObservedAt` から 30 日を超えて前進している | **`nil`** |
| それ以外 | 端末時刻 |

**2 つに分けるのは、単調性が削除判定と両立しないためです。** 単調な時刻は一度未来へ進むと時計を正しい値へ戻しても未来のままで、削除が保留されません。`retentionNow` に `max` を掛けないからこそ、時計を直したときに通常の判定へ復帰します。巻き戻しによる保持期間の延長は利用者に不利ではないため許容します。

**`Domain` の時間判定は `now` を引数に取りません。** 端末時刻に触れてよいのは `observeTime` の呼び出し口 1 か所だけとします（3.3 の lint 規約）。

**未来への時計変更のうち、枠の前倒し取得は脅威モデルの対象外とします**（9.3）。**破壊的削除だけを保守的に倒します。** 枠の前倒しは利用者に有利で成果物を失いませんが、削除は取り返しがつきません。

##### 整合性封鎖

**封鎖の解除条件を端末年月との比較にすると、年月を作れる側が解除条件を作れます。** 時計を過去月へ変更 → 台帳を破損 → その月として修復 → 時計を戻す、で即座に解除できます。

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
| 解除に使える年月 | **信頼できる時刻から導出した年月のみ** |
| 端末時刻由来の年月 | **解除に使わない。** 何度変更しても封鎖は解けない |
| 信頼できる時刻を一度も得られない | 封鎖は維持される |
| 破損が繰り返される | 2 回目以降は `lockedUntilReinstall` へ引き上げる |

**信頼できる時刻を得られないまま Free 枠が使えない状態は、意図した結果です。** 有料利用者は `paidUnlimited` であり月間枠を参照しないため、課金済みの利用者が締め出される経路は作りません。

##### 月初リセットと時刻巻き戻し

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
        return ledger.with(period: current, consumedExportIDs: [], grants: activeGrants)
    } else {
        // 同一または過去 → 期間はリセットしない
        return ledger.with(grants: activeGrants)
    }
}
```

24 時間の窓は月の境界と無関係です。`grants` を月初に空にすると、7 月 31 日 23:59 の書き出しを 8 月 1 日 00:01 に再書き出しした場合に `freeReexport` になりません。

タイムゾーンを西へ移動して月をまたぎ戻しても、端末時計を手動で戻しても、`period` は後退しません。

##### 一括処理トライアル

Free および Standard の利用者は、Pro の中核である一括処理を一度も試さずに判断することになります。これを避けるため、**一括処理でのみ使える 5 枚分のクレジット**を付与します。

**月間の無料枠とは別勘定とします。** 月間枠から引くと、Free の利用者は一括処理を試しただけでその月の枠を使い切ります。端末内処理のため限界原価はありません。

**回数制ではなくクレジット制とします。**

- **同じ元素材について、初回の正常生成時にだけ 1 クレジットを消費する**
- 使い切るまで有効。失敗した写真では消費しない
- 全件失敗または利用者が中止した場合、クレジットは減らない
- Pro へ加入済みの場合は消費しない

**クレジットの消費判定は `sourceID`（6.4）に従います。** 加工内容が異なっても、同じ元写真であれば追加消費しません。

**残クレジット数は保存せず、台帳から導出します。**

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

残数と台帳の両方を保存すると、更新途中の異常終了で「残 3 枚なのに台帳は 4 件」という判断できない状態が生じます。導出にすれば正が 1 つになり、付与数がリモート設定で変わっても挙動が自動的に決まります。

**`trialIntegrityLocked` を導出に含めます。** 台帳を修復すると `trialEntries` が空になるため、フラグを見なければ表示上 5 枚すべてが復活します。

##### クレジットの予約

**認可だけではクレジットを占有できません。** 認可結果を台帳へ残さなければ、残り 1 枚の状態で異なる素材の 2 件が並行認可されたときに、どちらも同じ件数を見て `batchTrial(true)` になります。

v1 は全体排他ゲート（8.1）により同時 1 件なのでこの経路は塞がれていますが、**予約は並列化後も必要です。**

| 契機 | 操作 |
| --- | --- |
| 認可時（手順 −2） | 該当素材の `TrialReservation` を**同じ `transact` の中で**追加する |
| `Prepared` の保存に失敗（手順 0） | **補償トランザクション**で予約・`SourceLease` を削除し、参照元を失った `SourceRecord` を GC する |
| 台帳への適用（手順 4） | **同じ台帳トランザクション内で**予約を削除し `trialEntries` へ移す。`SourceLease` も削除する |
| 最終確定（手順 7） | **台帳には触らない**（DB のみ） |
| ロールバック | この `exportID` が所有する予約または `trialEntries` を削除する |
| 起動時 | コミットの無い予約を孤児として削除する。**その完了後に新規認可を許可する** |

**消費済み台帳に期限は設けません。これは意図した仕様です。** 結果として、最初に選んだ 5 枚については以後も何度でも試せます。理由は 3 つです。

- 6 枚目以降を処理できるようになるわけではなく、**体験できる範囲は最大 5 枚のまま**である
- 端末内処理のため、繰り返しても限界原価が発生しない
- 期限を設けると、その境界を利用者へ説明する必要が生じ、試用の導線としては複雑になる

**トライアルで解放するのは「一括処理という操作方式」だけです。** エフェクトやスタンプの利用範囲は `ResolvedCapabilities` をそのまま参照し、一括処理へ入ったことで能力を書き換えません。追加スタンプまで一時解放すると Standard の価値が曖昧になります。

##### 改ざん耐性

`UsageLedger` を平文で保存すると、DB を書き換えるだけで無料枠が無制限になります。一方で仕様 14.5 は不正利用防止のためだけの端末固有識別子の収集を禁じています。折衷案として Keychain の鍵で HMAC 署名を付与し（9.1）、サーバー照合も端末識別子の収集も行いません。

`ProtectedBlobStore` の読み込み結果の分類と扱いは 7.2 が正本です。以下は `integrityFailure` に対する規則です。

**空の `UsageLedger` を作り直しません。** 台帳は消費件数だけでなく、どの素材が grant を持ちトライアルを消費したかを保持しています。空にすると無料枠もトライアルも全回復し、改ざんの動機になります。

**`integrityFailure` を一時的な読み取り結果のままにせず、保守的に修復した永続状態へ変換します。** 読み取り失敗のたびに判断すると、正しい `lastObservedAt` を失っているため `usageNow` を算出できず、封鎖を解除する手立てもなく、Standard / Pro が成功しても grant を書き込む先がありません。

検出した時点で、次の内容の**新しい署名済み台帳**を作ります。

| フィールド | 値 |
| --- | --- |
| `lastObservedAt` | **署名失敗を検出した時点の端末時刻**（正しいアンカーを失っているため） |
| `monthlyIntegrityLock` | `.lockedUntilTrustedMonthAfter(現在月)` |
| `trialIntegrityLocked` | `true` |
| `period` | 現在月 |
| `grants` / `consumedExportIDs` / `trialEntries` / `trialReservations` / `sourceRecords` / `sourceLeases` | **すべて空** |

`trialReservations` を空にしないと、修復後も過去の予約が残っているものとして残クレジットが減り、`trialIntegrityLocked` と合わせて二重に封鎖されます。`sourceRecords` と `sourceLeases` を空にしないと、alias だけが残って修復前の同一性判定が部分的に生き残ります。

結果として次のようになります。

- **Free 単体書き出しは不可。** 信頼できる時刻から導出した年月が封鎖時の月より後になった時点で再開する
- **一括処理トライアルは再インストールまで不可**（`trialIntegrityLocked` は解除しない）
- Standard / Pro の通常書き出しは許可。月間枠に依存しない
- 成功した書き出しの grant は、この修復済み台帳へ通常どおり追加できる

**フラグを立てるだけでは効果がありません。** 次の 2 箇所で参照します。

| フラグ | 参照箇所 | 効果 |
| --- | --- | --- |
| `monthlyIntegrityLock` | `evaluate` の判定手順 4 | 月間上限の判定より前に `blocked(.ledgerIntegrityFailure)` を返す |
| `trialIntegrityLocked` | `remainingCredits` の導出 | 残数を 0 とし、一括トライアル画面への進入・写真選択・認可をすべて禁止する |

再インストールで枠が戻ることは仕様 14.5 が明示的に許容しているため、追跡しません。

### 6.4 SourceRecord と素材同一性

仕様 14.3 は「新しいプロジェクトとして作り直しても、元素材識別子とローカルハッシュが一致すれば同一素材として扱う」と定めます。

##### 複合 ID

`contentFingerprint` 1 本にすると、OS が画像を変換した場合に同一素材と判定できません。PhotosPicker は要求形式や iCloud の状態によって HEIC を JPEG へ変換して返し、変換後はバイト列が別物になります。

```swift
struct SourceIdentity: Sendable, Hashable {
    /// 写真ライブラリの asset 識別値を端末内でハッシュ化したもの。
    /// 取得できない場合（ファイル取り込み等）は nil
    let providerAssetKeyHash: String?

    /// サイズ・先頭 64KB・末尾 64KB・撮影日時から算出
    let contentFingerprint: String
}
```

**この 2 つの OR を同一性判定へ直接使えません。推移律が成立しないためです。**

```
A = (provider: P1, fingerprint: F1)
B = (provider: P1, fingerprint: F2)
C = (provider: nil, fingerprint: F2)

A と B は provider が一致、B と C は fingerprint が一致するが、A と C はどちらも一致しない
```

同値関係でない述語を使うと、同じ素材の grant が複数作られ、トライアルを二重消費し、**ゲートが同じ素材を別キーとして扱って同時実行を許します。**

##### 正規 ID と alias

**素材へ正規 ID（`sourceID`）を割り当て、識別情報を alias として管理します。**

```swift
enum SourceAlias: Sendable, Hashable {
    case provider(String)   // providerAssetKeyHash
    case content(String)    // contentFingerprint
}

struct SourceID: Sendable, Hashable { let rawValue: UUID }   // 6.6

struct SourceRecord: Sendable, Equatable {
    let sourceID: SourceID
    var aliases: Set<SourceAlias>   // 空にしない（不変条件 7）
}
```

素材を解決する手順です。

1. `provider` alias に一致する `SourceRecord` を探す
2. `content` alias に一致する `SourceRecord` を探す
3. 両方が見つかり、**別レコードを指していたら 1 件へ統合する**
4. 片方だけ見つかれば、そのレコードへ不足している alias を追加する
5. どちらも見つからなければ新しい `sourceID` を発行する

**以後、grant・トライアル台帳・予約・ゲートはすべて `sourceID` で管理します。** 等価性は通常の `==` であり、推移律は自明に成立します。

`SourceRecord` の集合も `UsageLedger` に持ちます。alias の追加と統合が台帳更新と同一トランザクションで行われる必要があるためです。別の場所に置くと、統合の途中で落ちたときに alias と grant が食い違います。

##### 統合時の規則

| 対象 | 統合結果 |
| --- | --- |
| `aliases` | 両者の和集合 |
| grant | **最も古い `firstSuccessAt` を維持する**（窓を延長しない） |
| トライアル台帳 | **どちらかが消費済みなら消費済み**（払い戻さない） |
| 予約 | 両方を統合する。実行中の export が競合するなら新規開始を止める |
| `ownerExportID` | 維持したほうの値を残す |

**`sourceID` を持つ全集合を勝者へ書き換えます。** 書き換え漏れを型で防げないため、一覧を規則として固定します。

```
grants            の sourceID → 勝者
trialEntries      の sourceID → 勝者
trialReservations の sourceID → 勝者
sourceLeases      の sourceID → 勝者
```

`sourceLeases` を落とすと、起動時の孤児 lease 回収が認可中の書き出しの lease を回収し、その `SourceRecord` が GC されて処理中の素材が消えます。

書き換えの結果、同じ `sourceID` の要素が同じ集合に 2 件できる場合は上の統合規則で 1 件へ畳みます。`sourceLeases` は `exportID` が異なる限り併存して構いません。

##### `SourceRecord` の寿命

**削除規則が無いと alias が永久に蓄積します。** 有料利用者は grant の 24 時間が切れても書き出しを続けるためです。

一方、**単純に「未参照なら削除」もできません。** `paidUnlimited` の通常の単体書き出しには grant も予約もなく、認可から正常生成までの間、その素材を参照するものが台帳に存在しません。`SourceLease` がこの穴を埋めます。

| 契機 | 操作 |
| --- | --- |
| 認可時（手順 −2） | `SourceLease` を追加する。**勘定の種類を問わない** |
| 台帳への適用（手順 4）またはロールバック | 該当 `exportID` の lease を**台帳トランザクション内で**削除する |
| 起動時 | 対応するコミットが無い lease を回収する（8.5 の手順 3） |

**`SourceRecord` を削除してよいのは、`grants` / `trialEntries` / `trialReservations` / `sourceLeases` のすべてから参照されなくなったときだけです。** 削除は `rollPeriod` で期限切れ grant を落とすのと同じタイミングで行います。参照が最も減っている時点だからです。

##### 不変条件

台帳を保存する前と、読み込んで署名を検証した直後の両方で検査します。

| # | 条件 | 破れたときに起こること |
| --- | --- | --- |
| 1 | 同じ `SourceAlias` を 2 つの `SourceRecord` が持たない | 素材解決が 2 レコードを返し、統合が毎回走る |
| 2 | 同じ `sourceID` の要素を、同じ集合内に 2 件持たない | grant の窓が二重になる |
| 3 | `grants` / `trialEntries` / `trialReservations` の `sourceID` が `sourceRecords` に存在する | 参照先の無い権利が残る |
| 4 | `sourceLeases` の `sourceID` が `sourceRecords` に存在する | 認可中の素材が GC される |
| 5 | `trialReservations` の各要素に、同じ `exportID` かつ同じ `sourceID` の `SourceLease` が存在する | 予約だけが残り、素材が GC される |
| 6 | 同じ `sourceID` が `trialEntries` と `trialReservations` の両方に存在しない | 確定済みの素材を二重に予約し、クレジットを余分に数える |
| 7 | `SourceRecord.aliases` が空でなく、全レコードを通じて一意 | alias を持たないレコードは二度と解決されず、永久に残る |

条件 5 は、予約と lease が手順 −2 の同一トランザクションで作られ、手順 4 またはロールバックで同時に消えることの帰結です。条件 7 の前半（空集合の禁止）は条件 1 に違反しないため、別条件として立てます。

##### `providerAssetKeyHash`

**平文で保存しません。** 端末内でソルト付きハッシュへ変換し、元の値を復元できない形で持ちます。**ソルトは台帳署名とは別の鍵から派生させます**（9.1）。

##### `contentFingerprint`

`ファイルサイズ + 先頭 64KB + 末尾 64KB + 撮影日時` の複合とします。48 メガピクセルの HEIC を全読みする負荷を避けるためです。

| 項目 | 規則 |
| --- | --- |
| アルゴリズム | **SHA-256** |
| 形式 | 長さ前置きのバイナリ連結（下記） |
| 整数のバイト順 | **ビッグエンディアン** |
| スキーマバージョン | 先頭に `UInt32` で含める（現行 `1`） |
| 撮影日時 | **UTC の epoch milliseconds を `Int64`**。取得元は **EXIF の `DateTimeOriginal` のみ**（5.5） |
| 撮影日時が無い | 長さ 0 のフィールドとして書く（値 0 で埋めない） |
| 対象データ | ピッカーが返した実データ |

```
schemaVersion : UInt32
fileSize      : UInt32(8)  + Int64
headChunk     : UInt32(n)  + bytes    // 先頭 min(65536, fileSize) バイト
tailChunk     : UInt32(n)  + bytes    // 末尾 min(65536, fileSize) バイト
capturedAt    : UInt32(8)  + Int64    // 無ければ UInt32(0) のみ
```

長さを前置きするのは、フィールド境界を曖昧にしないためです。単純連結だと、末尾チャンクの終わりと日時の始まりを区別できず、異なる入力が同じバイト列になりえます。

**64KB 未満のファイルでは重なりを許容し、両方ともファイル全体を書きます。** 「重複を除く」規則を入れると分岐が増え、境界で取り違えます。

**`PHAsset.creationDate` を入力にしません。** 権限の有無で取得元が変われば、同じ写真が別の `contentFingerprint` になり、無料枠を二重に消費します（5.5）。**ファイル更新日時も使いません。** コピーや同期で容易に変わります。

##### 入力の取得契約

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

| 状況 | 扱い |
| --- | --- |
| 原データを取得できる | `original` としてハッシュを計算する |
| 原データを取得できない | **`transcoded` として、取得できた表現から計算する。処理は拒否しない** |

**処理自体を拒否しません。** 利用者にとって「この写真は加工できません」は理解不能な失敗です。`transcoded` では同一素材の保証が弱まりますが、これは利用者に不利な方向（余分に消費する）であり、枠を水増しする方向ではありません。

**`representation` を `contentFingerprint` の入力には含めません。** 含めると、同じ写真が取得経路によって別ハッシュになります。診断のための区分値としてのみ記録します（9.2）。

##### プロジェクト設定ハッシュ

6.2 の「変更せず再書き出し」の判定にも正準化が必要です。

| 要因 | 規則 |
| --- | --- |
| `Map` の反復順 | **キーの辞書順**でソートしてから書く |
| 浮動小数の表現 | **IEEE 754 の 64 ビット `Double.bitPattern` をビッグエンディアンで**書く |
| DB の自動採番 ID | **含めない。** アプリ更新やデータ移行で変わる |
| スタンプの参照 | DB ID ではなく **`StampAsset` の内容ハッシュ**（7.5） |
| 欠損値 | 長さ 0 のフィールドとして明示する |
| フィールド順 | スキーマで固定する。追加は末尾のみ |

アルゴリズムと形式は `contentFingerprint` と同じ（SHA-256、長さ前置き、スキーマバージョン付き）です。

**`Float`（32 ビット）へ丸めません。** 実際のモデルはすべて `Double` です（5.2）。32 ビットへ丸めると `0.1500000000000000` と `0.1500000059604645` が同じハッシュになり、**設定を変えたのに無料の再書き出しとして通します。**

`-0.0` は符号化の前に `+0.0` へ正規化します。`NaN` は検証済み値型が拒否するためここへ到達しません。

##### バッチ選択時の分類

**選択画面で `SourceIdentity` を素朴に比較できません。** 正規 `sourceID` の解決と alias の統合は、書き出し開始時の `transact` の中でしか行われません。その外で生の OR 述語を使うと、同じ写真を 2 枚と数える／トランスコードされた写真を新規扱いする／選択中の重複を見逃す、が起こります。

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

**alias の共有関係を推移的に閉じる**ことで、`sourceID` 解決と同じ結果になります。

**この分類は表示と入力制限のためのものです。** 選択から実行開始までの間に別の書き出しが台帳を更新しうるため、実行開始の直前に**最新の台帳で全件を原子的に再検証します。** 再検証は開始ゲート（8.1）の内側で行い、分類結果が変わっていれば実行を開始せず、選択画面へ戻して差分を提示します。**選択時の判定だけで消費を認可しません。**

### 6.5 バッチ処理

**一括処理の制限なし利用は `canUseProBatch` が必要です。** `canUseBatchTrial` だけを持つ利用者は、未使用クレジットの範囲で新しい写真を処理するか、消費済み台帳に登録されている写真を再度処理できます。

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

**残クレジットが 0 でも、消費済み台帳に写真があれば一括処理画面を閉じません。** 「同じ 5 枚は期限なく何度でも試せる」が成立しなくなるためです。

**判定に `Plan` を使いません。** 料金表や説明文でプラン名を使うことは構いませんが、実装上の条件式はすべて能力で書きます。

##### 中核となる価値

一括処理の価値は「複数選択できること」ではなく、**50 枚を一枚ずつ編集画面で開かずに済むこと**です。

1. 写真を選択する（Pro は最大 50 枚、トライアルは最大 5 枚）
2. 全写真の顔を自動検出する
3. 検出した全顔を加工対象にする（6.1 の不変条件）
4. **選択した確認モードに応じて、全写真に目を通す**
5. `reviewRequired` の写真について対応方法を記録する
6. 一括書き出しする

**手順 4 は、どちらのモードでも省略できません。** 見せ方がモードで異なるだけで、「全写真に一度は目を通す」という要件は共通です。理由は 6.1 のトリアージの限界にあります。

##### 一括処理モード

| モード | 手順 |
| --- | --- |
| **おまかせ一括** | 全写真の検出顔へ同じ加工を適用 → サムネイル一覧で確認 → 警告のある写真だけを開いて修正 |
| **1 枚ずつ確認** | 全写真を順番に大きく表示 → 一枚ずつ確認 → 一括保存 |

##### 書き出しの成立条件

**おまかせ一括**

1. 全サムネイルの生成が完了している（生成中は書き出しを無効化する）
2. **バッチ内の全写真を加工後サムネイルの一覧として表示し**、一覧の末尾まで到達している
3. `reviewRequired` の写真がすべて `reviewed` になっている
4. 利用者が一覧の確認を明示的に完了操作している

`normal` の写真に個別の `reviewed` 操作は求めません。一覧へ目を通し、手順 4 を行うことが全写真に対する確認にあたります。

**1 枚ずつ確認**

1. 全サムネイルの生成が完了している
2. `normal` / `reviewRequired` を問わず、**全写真が `reviewed` になっている**
3. `reviewRequired` の写真について、対応方法が記録されている
4. 完了サマリを表示する

条件 3 を「警告が解消されている」とは書きません。利用者が問題ないと判断しても、顔を隠さず保存すると選んでも、**警告そのものは消えていません。** 扱いを決めただけです。

このモードでは 1 枚ずつ大きく表示して個別に確認するため、末尾到達と確認操作は求めません。`normal` の写真は「確認して次へ」により `ReviewDecision` なしで `reviewed` へ遷移します。これを定めないと `normal` の写真が永久に `unreviewed` のままになります。

```swift
struct BatchReviewState: Sendable { let overviewConfirmed: Bool }
```

おまかせ一括の一覧確認はバッチ全体の操作なので、写真単位とは独立して持ちます。

##### 一覧の実装制約

**サムネイルは検出漏れを目視で発見できる大きさとします。** タップで全画面プレビューへ遷移でき、一覧上でもピンチ操作で拡大できることを要件とします。未検出の顔は加工されていないため、一覧上では顔が露出した状態で見えます。**この視認性が仕組みの前提です。**

要確認だけを表示して他を隠す既定の表示は採りません。絞り込みは利用者が明示的に選ぶフィルターとしてのみ提供します。

末尾到達判定は、スクロールだけでなく **VoiceOver による走査でも成立させます。**

**末尾までの到達も `reviewed` も、安全の保証ではありません。** 見落としを減らすための手順として扱い、いかなる場合も「安全」という語を状態表示に用いません（仕様 34.5）。

##### 確認状態の解除

**一律に全解除はしません。** 50 枚のうち 1 枚を直しただけで残り 49 枚まで再確認になると、一括処理の価値が失われます。

**判定は設定名の列挙ではなく、原則で行います。** 設定項目を数え上げる形にすると、項目が増えたときに漏れます。

> **匿名化結果または構図に影響する変更**が行われた場合、その変更の影響を受ける写真を `unreviewed` へ戻し、`overviewConfirmed` を `false` にする。

| 変更 | 写真の `ReviewStatus` | `overviewConfirmed` |
| --- | --- | --- |
| 匿名化結果・構図に影響する変更（個別） | その写真だけ `unreviewed` | `false` |
| 匿名化結果・構図に影響する変更（共通） | 影響を受ける写真を `unreviewed`。`hasOverride` の写真は維持 | `false` |
| 影響しない変更 | 維持 | 維持 |

**影響する変更**は、顔のエフェクト・強度・スタンプ、顔領域の追加/移動/削除、縦横比と切り抜き位置、背景処理です。**影響しない変更**は、位置情報の削除、撮影日時の保持、圧縮品質です。

`ReviewResolution` は `unreviewed` へ戻した時点で破棄します。検出ステータスは検出をやり直したときにのみ再計算します。

##### 設定へ戻る経路

**確認段階から設定段階へ戻れます。検出結果は保持し、再検出は行いません。**

**v1 では、この経路から写真の選択は変更できません。** 変更できるのはエフェクト、強度、スタンプ、縦横比などの設定だけです。写真を変えたい場合は現在のバッチを破棄して新しいバッチを作ります。検出後に写真を出し入れできると、「実行開始後はバッチを固定する」と両立しません。

##### 選択枚数の条件

制限は **2 つの独立した条件**です。1 つにまとめると、残クレジット 0 の状態で消費済みの写真すら選べなくなります。

| 条件 | 上限 |
| --- | --- |
| 1 バッチの総枚数 | Pro は 50 枚、トライアルは 5 枚 |
| **選択中のうち、消費済み台帳にない写真の枚数**（6.4 の分類） | 残クレジット数 |

| 分類 | 発火条件 | 誘導 |
| --- | --- | --- |
| `batch-credit` | Free / Standard が、残クレジットを超える**新しい写真**を選ぼうとした | Pro |
| `batch-size` | Free / Standard が**総数 5 枚**を超えて選ぼうとした | Pro |
| `batch-limit` | Pro が**総数 50 枚**を超えて選ぼうとした | 誘導なし。上限の通知のみ |

`batch-size` と `batch-limit` を分けるのは、前者がアップグレードで解消できる制限、後者が仕様上の上限だからです。`batch-credit` だけでは、すでに試した写真だけを 6 枚選ぶ場合（新しい写真は 0 枚）を捕まえられません。この経路を `batch-size` が受けます。

##### キューと付随機能

キューの進行状態は仕様 16.6 の 8 種（`waiting` / `analyzing` / `review_required` / `exporting` / `completed` / `failed` / `canceled` / `paused`）とし、状態機械を `Domain` に置きます。

**キューの進行状態と 6.1 の 2 軸は別物です。**

| 概念 | 何を表すか | 変化させるもの |
| --- | --- | --- |
| キューの進行状態 | その写真が処理のどの段階にいるか | 処理の進行 |
| 検出ステータス | `triage` が警告を出したか | 検出のやり直し |
| 確認ステータス | 利用者が確認を終えたか | 利用者の操作 |

キューの `review_required` は独立した真実を持たず、**利用者の確認待ちを表す導出値**です。

```swift
let requiresUserReview = switch mode {
case .auto:
    detectionStatus == .reviewRequired && reviewStatus == .unreviewed
case .oneByOne:
    reviewStatus == .unreviewed
}
```

1 枚ずつ確認では `normal` の写真も確認を待っているため `review_required` になります。「警告あり」と定義すると、未確認の `normal` 写真が利用者の操作を待っているのにキュー上はそう見えません。

その他の規則は仕様 16.5 / 16.7 / 16.8 に従います。

- 1 バッチ最大 50 枚
- 同時並列処理は初期値 1。写真のみのため最大 2 まで許容可能とするが、実機計測後に判断する
- 一枚の失敗でバッチ全体を停止しない
- **アプリ再起動後に未完了キューを復元する**（5.5 の `WorkingSourceRecord`）
- 元素材へのアクセス権限を失った場合は再選択を求める
- バックグラウンド処理は OS の実行制限に従う。`BGProcessingTask` は使わず、フォアグラウンド継続を前提とする

**実行開始後のバッチへの写真追加は v1 では実装しません。** 追加分の検出開始時期、進行中の確認作業との関係、一括設定の適用範囲、50 枚超過時の分割といった論点が増える割に利用者価値が低いためです。

##### 一括設定と個別修正の優先順位

1. **一括設定は各写真の初期値として適用する**
2. 個別に編集された写真には `hasOverride` を記録する
3. **共通設定を変更しても、`hasOverride` が立った写真は変更しない**
4. 全件を上書きしたい場合のみ、対象件数を提示した確認を経て実行する

`hasOverride` は写真単位のフラグとし、`Domain` が管理します。

##### 対応しないこと

顔認識を行わない以上、**複数写真を横断した同一人物の判定はできません**（仕様 16.4）。「全写真で家族だけ残し、他人だけ隠す」は実現できません。説明文でこれを誤解させないことを制約とします。

### 6.6 ドメイン識別子

**識別子を `String` と `UUID` で混在させません。** 同じ概念が 2 つの型で表現されている状態では、DB の結合も HMAC の正準化も一意に決まりません。

```swift
// Domain — すべて Foundation のみ
struct ProjectID:   Sendable, Hashable { let rawValue: UUID }
struct BatchID:     Sendable, Hashable { let rawValue: UUID }
struct ExportID:    Sendable, Hashable { let rawValue: UUID }
struct RegionID:    Sendable, Hashable { let rawValue: UUID }
struct SourceID:    Sendable, Hashable { let rawValue: UUID }   // 6.4
struct FaceTrackID: Sendable, Hashable { let rawValue: String } // Vision の observation UUID 文字列
```

`FaceTrackID` だけ `String` なのは、値の出所が `observation.uuid.uuidString` でありアプリが採番しないためです。

| 理由 | 内容 |
| --- | --- |
| 誤った受け渡しの防止 | `exportID` を期待する引数へ `projectID` を渡せない。**コンパイルで止まる** |
| DB 結合の一意性 | 2 つの DB を跨ぐ整合検査（7.1）の対象が型で決まる |
| 正準化の一意性 | HMAC 対象の各 ID を「`UUID` の 16 バイト」として符号化できる（9.1） |
| ログ禁止の強制 | 分析イベントのフィールド型にしないことで、送信経路へ入れられない（9.2） |

**いずれの型も `CustomStringConvertible` に適合させません。** 文字列補間で自動的にログや診断へ流れる経路を作らないためです。

### 6.7 アプリ更新の誘導

起動時に新しいバージョンがあれば App Store へ誘導します。判定は純粋関数に閉じます。

##### バージョン情報の取得元

**App Store の Lookup API（`itunes.apple.com/lookup`）を使いません。** CDN のキャッシュにより公開直後は古いバージョンを返すことがあり、レスポンス形式は公開仕様でなく、「公開済みだが、まだ誘導は始めない」を表現できません。

**`GET /v1/config` へ含めます**（10 章）。自前で配信すれば公開とロールアウトを分けられ、審査通過直後に全利用者へ誘導が飛ぶ事故も防げます。

```swift
struct UpdateConfig: Sendable, Decodable {
    let minimumSupportedVersion: AppVersion   // これ未満は使用不可
    let recommendedVersion: AppVersion        // これ未満は任意更新を提示
    let appStoreID: String
}

struct AppVersion: Sendable, Comparable, Decodable {
    let major: Int
    let minor: Int
    let patch: Int
}
```

**文字列比較を使いません。** `"1.10.0" < "1.9.0"` が文字列としては真になり、新しいバージョンを古いと判定します。

`CFBundleShortVersionString` を数値の組へパースします。**パースに失敗した場合は更新なしと判定します。** ここで強制更新へ倒すと、バージョン表記の書式ミスで全利用者がブロックされます。`CFBundleVersion`（ビルド番号）は比較に使いません。

##### 判定

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

1. `config == nil` なら **`.none`**
2. `current < config.minimumSupportedVersion` なら **`.required`**
3. `current >= config.recommendedVersion` なら `.none`
4. `skippedVersion == config.recommendedVersion` なら `.none`
5. `usageNow - lastPromptedAt < 24h` なら `.none`（1 日 1 回まで）
6. それ以外は **`.recommended`**

**手順 1 が最も重要です。** サーバー障害や通信不良で設定を取得できないときに強制更新へ倒すと、**バックエンドの障害が全利用者のアプリ停止に直結します。**

##### 未受け渡し出力を失わせない

**強制更新は「消費したのに成果物を受け取れない」を作りかねません。** 利用者が書き出しを完了し（消費が確定し）、保存する前にアプリを再起動した場面で全画面ブロックを最優先で表示すると、`generated` 状態の出力を受け取る手段が消え、24 時間後には出力も消えます。

| 状態 | 強制更新の扱い |
| --- | --- |
| `generated` の出力が 1 件もない | **即座に強制更新画面を表示する** |
| `generated` の出力がある | **受け渡しの導線を先に提示する** |

後者の画面では、未保存の枚数を示し、保存してから更新するよう促します。**この画面から到達できるのは保存・共有・破棄だけ**とし、新規の加工・履歴の閲覧・設定へは進めません。保存または破棄によって `generated` が 0 件になった時点で、通常の強制更新画面へ切り替えます。

##### 復旧処理との順序

**更新判定は、起動時復旧（8.5）より後に行います。** 復旧を止めても未完了の `ExportCommit` が残ったまま次回起動を迎えるだけで何も解決せず、むしろ `generated` 件数を正しく数えられません。起動順序の手順 8 に組み込みます。

##### 任意更新の提示条件

`.recommended` のダイアログは、**割り込んでよい場面でのみ表示します。**

- 検出中、顔選択中、編集中、書き出し中、書き出しエラー対応中、課金処理中は**表示しない**
- `generated` の未受け渡し出力があるときは**表示しない**
- ホーム画面または履歴画面を表示している時点でのみ提示する

「後で」を選んだバージョンを `skippedVersion` として記録します。`recommendedVersion` が上がれば再び提示されます。チェックの契機は**起動時とフォアグラウンド復帰時**です。

##### App Store を開く

```swift
URL(string: "https://apps.apple.com/app/id\(config.appStoreID)")
```

SwiftUI の `openURL` 環境値で開きます。`itms-apps://` スキームは使いません。App Store アプリが無い環境（企業端末等）でリンクが失敗するためです。**`SKOverlay` は使いません。** 他アプリの推薦を意図した API であり用途が異なります。

`appStoreID` は**数字のみの形式検証**を通します（任意の URL を差し込ませないため）。

##### 審査への配慮

審査担当者は App Store 公開前のビルドを実行します。`minimumSupportedVersion` を「これから公開するバージョン」に設定すると、審査中のビルド自身がブロックされリジェクトされます。

- `minimumSupportedVersion` を上げるのは、**そのバージョンが公開され、十分に普及したあと**
- 新バージョンの審査提出時は `minimumSupportedVersion` を変更しない
- 強制更新は、**セキュリティ上の問題やサーバー側の互換性が切れた場合に限る**

保存されるのは `skippedVersion` と `lastPromptedAt` のみで、いずれも `UserDefaults` に置きます。改ざんされても更新の再提示が遅れるだけです。

---

## 7. 永続化

### 7.1 runtime.db / user-data.db

**バックアップの単位はファイルであり、テーブルではありません。** 保存するデータの性質でファイルを分けます（ADR 0002 / 0003）。

**`runtime.db`**

| テーブル | 備考 |
| --- | --- |
| `ExportCommit` | 書き出しのコミットジャーナル。行に HMAC を付ける（8.2） |
| `OutputRecord` | 写真ごとの出力状態。`exportID` でコミットと対応づける（8.3） |
| `ExportQueueItem` | 一括処理のキュー状態（6.5） |
| `WorkingSourceRecord` | 処理用にアプリ領域へ複製した元素材。キューの再起動復元に必須（5.5） |
| `PendingFileDeletion` | 参照 0 になった実体の削除候補（7.5） |

**`user-data.db`**

| テーブル | 備考 |
| --- | --- |
| `Project` | 仕様 19.1。再編集用の `ProjectSourceLocator` を持つ（5.5）。**ここにのみ平文の `localIdentifier` が存在する** |
| `FaceTrack` | 仕様 19.2 |
| `FaceKeyframe` | 仕様 19.3。v2 で使用 |
| `EffectSetting` | 仕様 19.4 |
| `ExportSetting` | 仕様 19.5 |
| `CustomStamp` | 仕様 19.6。スタンプ一覧の項目（7.5） |
| `StampAsset` | プロジェクトが参照する不変の画像実体のメタデータ。内容ハッシュを主キーとし参照カウントを持つ（7.5） |
| `ExportRecord` | 仕様 19.7。`batchID` を追加 |
| `Batch` | バッチ単位の履歴 |
| `BatchPreset` | 一括設定プリセット |

**両方ともバックアップ対象外です**（7.4）。`runtime.db` を復元してはいけない理由は特に明確で、`ExportCommit` を別端末へ復元しても対応する一時ファイルは存在せず、`UsageLedger` との整合も失われ、復元された途端に全件が復旧エラーになります。

##### 1 接続と `ATTACH DATABASE`

手順 7 の単一トランザクション（8.3）は `OutputRecord`・`ExportRecord`・キュー状態・`Project` を同時に更新しますが、このうち `ExportRecord` と `Project` は `user-data.db` 側です。**`ATTACH DATABASE` を使い、1 つの接続から両ファイルを扱います。**

**「`ATTACH` すれば原子的」ではありません。** 複数 DB トランザクションがクラッシュをまたいで原子的になるのは条件を満たす場合だけで、**特に WAL では、DB ごとの原子性は保たれても複数 DB の一部だけがコミットされることがあります。**

| 項目 | 規約 |
| --- | --- |
| 接続 | **`DatabaseQueue` を 1 つだけ**使う |
| main database | **`runtime.db`**（`:memory:` にしない） |
| attach | 接続確立のたびに `user-data.db` を `ATTACH` する |
| `journal_mode` | **`DELETE` / `TRUNCATE` / `PERSIST` のいずれか** |
| WAL | **使用しない** |
| `DatabasePool` | **使用しない**（複数接続になり `ATTACH` の前提が崩れる） |
| 配置 | 両ファイルを**同一ファイルシステム・同一 VFS 上**に置く |
| `synchronous` | **`EXTRA`** |
| 起動時検査 | **両スキーマの `journal_mode` と `synchronous` を検証する** |

**`PRAGMA journal_mode` はスキーマ単位です。** 片方だけ確認しても意味がありません。

```sql
PRAGMA main.journal_mode;
PRAGMA user_data.journal_mode;
PRAGMA main.synchronous;
PRAGMA user_data.synchronous;
```

いずれかが WAL なら復旧エラーとし、書き出しを開始しません。マイグレーションツールや将来の GRDB が既定で WAL へ切り替える可能性があるため、**設定したつもりが変わっていた**を検出できる形にします。

##### 耐久性の水準

**保証の強さを段階で書き分けます。** SQLite の `synchronous = EXTRA` は rollback journal に対する追加の同期であって、ハードウェアを含むあらゆる条件での絶対的な電源断保証ではありません。Apple の強制同期 API（`F_FULLFSYNC`）にも同じことが言えます。

| 障害 | 保証の水準 | 根拠 |
| --- | --- | --- |
| **プロセス強制終了**（`_exit` / SIGKILL / jetsam） | **保証する** | コミット Saga と単一トランザクション（8 章） |
| **OS クラッシュ・電源断** | **best effort の耐久性** | `synchronous = EXTRA`、ファイルと親ディレクトリの同期 |
| 復帰後の整合 | **回復する** | コミットジャーナルと起動時復旧（8.5） |

**要点は「書き込みが必ず届く」ことではなく、「どこで切れても整合を回復できる」ことです。** 電源断で最後の書き込みが失われた場合、その書き出しは 1 つ前の状態から再開されます。

v1 では、**出力ファイルと保護ブロブについてもファイルと親ディレクトリを同期します。** 台帳と出力の整合が崩れると不変条件が壊れるため、DB と同じ水準に揃えます。**同期方式（`F_FULLFSYNC` か通常の `fsync` か）は実機計測後に決めます**（12.5）。

##### 外部キーはスキーマ境界をまたげない

**SQLite の外部キー制約は `ATTACH` した別 DB を参照できません。** したがって、この整合性はアプリ側が保証します。

| 保証する場所 | 内容 |
| --- | --- |
| 手順 7（8.3） | 同一トランザクション内で両 DB を更新し、参照先が存在する状態でのみコミットする |
| 起動時検査（8.5 の手順 5） | 下記の不一致を検出する |

起動時に次を検査します。

- `OutputRecord.projectID` に対応する `Project` が存在する
- `ExportQueueItem.batchID` に対応する `Batch` が存在する
- `ExportCommit.projectID` に対応する `Project` が存在する

| 状況 | 扱い |
| --- | --- |
| `OutputRecord` の参照先が無い | **孤児として削除する**（7.5 の経路。ファイルも削除） |
| `ExportCommit` の参照先が無い | **復旧エラー。** 会計済みか判断できないため自動削除しない |
| `ExportQueueItem` の参照先が無い | 孤児として削除する |

`ExportCommit` だけ扱いが違うのは、それが会計の根拠だからです。

### 7.2 ProtectedBlobStore

以下は DB ではなく `ProtectedBlobStore` へ保存します。改ざんで権限や枠を書き換えられないようにするためです（9.1 の HMAC 署名つき）。

- `UsageLedger`（6.3）
- `SubscriptionState`（6.2 の `Entitlement` キャッシュ）
- `RemoteConfigState`（10 章）

**鍵の保管とデータの保管を分けます。**

| 役割 | プロトコル | 実装 |
| --- | --- | --- |
| 鍵 | `CryptoKeyStore` | Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`） |
| 署名済みデータ本体 | `ProtectedBlobStore` | アプリ専用ディレクトリ上のファイル（原子的置換） |

原子的な置き換えができることを要件とします。台帳は 1 つのオブジェクトとして丸ごと差し替えるため、部分更新の途中状態が観測されてはいけません。実装は一時ファイルへ書いてから `FileManager.replaceItemAt` です。

##### 読み込み結果の分類

読み込みが失敗する理由は 1 つではありません。初回起動・改ざん・ストレージの一時障害・スキーマ更新を同じ結果にまとめると、**初回起動の利用者が最初から Free 枠とトライアルを封じられ**、逆に**一時障害のたびに正常な台帳を保守状態で上書きします。**

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
| `valid` | そのまま使う |
| `missing` | **新規利用者用の通常状態を作る** |
| `integrityFailure` | 保守的な修復（6.3 の台帳、10 章のリモート設定、6.2 の購入状態） |
| `temporarilyUnavailable` | **上書きしない。** 再試行し、書き出しの開始を一時停止する。再試行可能なエラーを提示する |
| `unsupportedSchema` | 定義済みの移行処理を実行し、移行後に再検証する |
| 移行不能 | 復旧エラーとして扱う。**自動初期化しない** |

**`temporarilyUnavailable` と `integrityFailure` を混同しないことが要点です。** 鍵ストアが一時的に利用できないだけの状態を改ざんとして修復すると、正常な利用者の枠を消します。両者は「署名検証まで到達したか」で区別できます。データを読めて HMAC が一致しない場合のみ `integrityFailure` であり、読み込み自体の失敗や鍵を取得できなかった場合は `temporarilyUnavailable` です。

**HMAC 鍵そのものが失われた場合は `integrityFailure` として扱います。** 鍵の喪失と改ざんは端末側から区別できません。

##### 再インストール後に鍵だけが残る場合

**`ThisDeviceOnly` が保証するのは「別端末へ移行しないこと」であり、アンインストール時に削除されることではありません。** 実際、再インストール後に Keychain の項目が残る事例が知られています。

| `ProtectedBlobStore` | `CryptoKeyStore` | 扱い |
| --- | --- | --- |
| `missing` | `missing` | 通常の新規台帳を作る |
| `missing` | **`existing`** | **同じく通常の新規台帳を作る。** 鍵はそのまま再利用してよい |
| `valid` | `existing` | 通常経路 |
| `integrityFailure` | `existing` | 保守的台帳へ修復（6.3） |

**「データが無いのに鍵がある」を異常として扱いません。** 再インストール直後の正常な状態でありえます。ここで復旧エラーにすると、再インストールした利用者がアプリを使えません。鍵を再利用するか新しく生成するかで安全性は変わらないため、**再利用します。** 削除自体が失敗しうる余計な経路を増やさないためです。

### 7.3 ManagedFileStore

**ファイル生成を 1 か所へ集約します。** バックアップ除外と保護クラスを、生成のたびに確実に設定するためです。`Domain` がプロトコルを定義し、`Persistence` が実装します。

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

**`ManagedFileStore` は `ManagedFileRef` だけを受け取り、呼び出し元へパスを返しません。** パスの解決は `kind` からディレクトリを決め、`fileID` を連結する形に閉じます。削除・属性設定・孤児 GC・バックアップ判定のすべてが同じ型で処理できます。

**`kind` を含めるのは、ID だけでは削除先を識別できないためです。** `PendingFileDeletion` は出力・履歴サムネイル・`StampAsset` のすべてに使われるため、同じ ID が別のディレクトリに存在すれば誤ったファイルを削除します。

**`fileID` を `String` にしません。** `String` である限り `"../protected/…"` も `"a/b"` も型として作れ、DB を書き換えられた場合や外部由来の文字列が流れ込んだ場合にパス連結の結果が専用ディレクトリを脱出します。`UUID` を内部表現にすれば `/` も `.` も含まない値しか存在せず、**構造的に脱出できません。**

| 経路 | 規約 |
| --- | --- |
| 生成 | `ManagedFileStore` が採番する。呼び出し元は値を作らない |
| DB への保存 | `UUID` として保存する（文字列カラムでも `UUID` としてデコードする） |
| デコード失敗 | **その行を不正として扱う。** 文字列へフォールバックしない |
| HMAC 正準化 | `UUID` の 16 バイトをそのまま符号化する（9.1） |

##### 解決側の二重防御

型だけに頼らず、解決処理でも次を行います。

1. `kind` から基準ディレクトリの `URL` を得る
2. `fileID` を連結し、`standardizedFileURL` で正規化する
3. **正規化後のパスが基準ディレクトリ配下であることを確認する**
4. 配下でなければ `open` も `delete` も行わず、エラーとして記録する

`UUID` を通した時点で 3 が失敗することは起こりませんが、将来 `ManagedFileID` の内部表現を変えた場合にこの検査だけが残ります。

##### 保存の順序

| 順 | 操作 |
| --- | --- |
| 1 | 一時ファイルへ書く |
| 2 | atomic rename / `replaceItemAt` で最終 URL へ移す |
| 3 | **最終 URL へ `isExcludedFromBackup` を設定する** |
| 4 | **最終 URL へ `FileProtectionType` を設定する** |
| 5 | 属性を**読み返して検証する** |
| 6 | 検証に失敗したら**完成扱いにしない**（一時ファイルとして残し、GC 対象とする） |

**手順 3 と 4 を rename の後に行います。** `replaceItemAt` は置換先の属性を引き継ぐとは限らないため、置換前に設定しても意味がありません。

**手順 5 の読み返しを省きません。** 設定が反映されなかった場合、次回起動まで気づけません。

対象は次のすべてです。**個別に `FileManager` を呼ぶ実装を許しません。**

- 処理中の一時ファイル、未受け渡し出力、ラスタスタンプ一時ファイル
- カスタムスタンプ実体、履歴サムネイル、`ProtectedBlobStore` の blob

SQLite のファイル群は GRDB が生成するため `ManagedFileStore` を通せません。ディレクトリの既定保護クラスで覆い、起動時に DB ファイルの属性を検証します。

### 7.4 ファイル保護とバックアップ

##### 配置

**SQLite の journal と super-journal を確実に除外するため、DB をディレクトリで分けます。** これらは DB と同じディレクトリに作られるため、DB ファイルだけを指定しても覆えません。

```
Library/Application Support/runtime/runtime.db
Library/Application Support/runtime/processing/
Library/Application Support/user-data/user-data.db
Library/Application Support/user-data/stamps/
Library/Application Support/user-data/thumbnails/
Library/Application Support/outputs/
Library/Application Support/protected/
Library/Caches/stamp-thumbnails/
tmp/raster/
```

同一ファイルシステム上にあるため、`ATTACH` の条件（7.1）は維持されます。

**処理中ファイルを `tmp/` に置きません。** `tmp/` は OS がいつでも削除でき、再起動のたびにキューの復元が失敗します（5.5）。`raster/` は `tmp/` のままです。1 回の `render` 呼び出し内でのみ有効であり、消えて困る状況が存在しません。

##### バックアップ

**アプリが保存するすべてを対象外とします**（ADR 0003）。

| パス | 根拠 |
| --- | --- |
| `runtime/`（`processing/` を含む） | 復元しても整合しない |
| `tmp/raster/` | `render` 呼び出し内でのみ有効 |
| `Library/Caches/stamp-thumbnails/` | 実体から再生成できるキャッシュ |
| `outputs/` | 24 時間で消えるもの。復元しても期限切れ |
| `protected/` | HMAC 鍵と寿命を揃えるため |
| **`user-data/`（DB・スタンプ・サムネイルを含む）** | 商品説明との整合、復元の同時点性、参照の失効、復旧 Saga の増加 |

**設定画面と初回起動時に、履歴とマイスタンプが端末内にのみ保存され、アプリの削除や端末の変更では引き継がれないことを明示します。** 黙って失われる状態を作りません。

除外の指定は各パスへ `isExcludedFromBackup = true` を設定します。**ディレクトリへ一度設定すれば足りるとは考えません。** Apple は、一般的なファイル操作で値が `false` へ戻りうるため**ファイルを保存するたびに設定する**よう明記しています。**すべてのファイル生成を `ManagedFileStore` へ通します**（7.3）。ディレクトリ単位の設定は保険であり、保証ではありません。

##### データ保護クラス

バックアップ対象外にしても、端末が盗まれてロック画面の状態で解析されれば、保護クラスが低いファイルは読めます。

| 対象 | 保護クラス |
| --- | --- |
| 処理中の元画像コピー（`runtime/processing/`） | **`.complete`** |
| 未受け渡し出力（`outputs/`） | **`.complete`** |
| ラスタ一時ファイル（`tmp/raster/`） | **`.complete`** |
| カスタムスタンプ実体（`user-data/stamps/`） | **`.complete`** |
| 履歴サムネイル（`user-data/thumbnails/`） | **`.complete`** |
| `runtime/` / `user-data/` の DB | `.completeUntilFirstUserAuthentication` |
| `ProtectedBlobStore` | `.completeUntilFirstUserAuthentication` |

**アプリ全体の既定を `.completeUntilFirstUserAuthentication` にし、画像系ファイルだけ `.complete` へ上書きします。** 既定を低いままにして個別に引き上げる構成だと、設定漏れが「保護が弱い」方向へ倒れます。SQLite の rollback journal、super-journal、一時 DB ファイルにも同じ保護が必要で、これらは自動生成されるため**ディレクトリの既定保護クラス**で覆う必要があります。

**DB を `.complete` にしません。** `.complete` はロック中に読み書きできず、**ロック中に起動時復旧を実行できません。** 復旧の完了が不定になり、その間の新規書き出しをブロックし続けることになります。DB は画像そのものを含まない（サムネイルは別ファイル）ため、この差を許容します。

##### ロック中のアクセス

**`.complete` のファイルへロック中にアクセスできないことを、破損や欠損として扱いません。** ファイルは存在しており、読めないだけです。

| 誤った扱い | 正しい扱い |
| --- | --- |
| ファイル欠損としてロールバック | **「保護データ利用不可」として処理を一時停止する** |
| 復旧エラーにする | ロック解除後に再試行する |
| `verifiedOutput` との不一致として扱う | 照合を行わず、判断を保留する |

欠損と誤認すると**ロールバックが走って会計を戻します。** 実際には出力は無事なので、消費だけが取り消されて出力が残るか、無事な出力が削除されます。

**エラーコードだけで判断しません。** `NSFileReadNoPermissionError` / `EPERM` は他の原因でも返りえます。

| 手段 | 用途 |
| --- | --- |
| `UIApplication.isProtectedDataAvailable` | **アクセス前に**利用可否を確認する |
| `protectedDataDidBecomeAvailableNotification` | ロック解除後に**処理を再開する** |
| `protectedDataWillBecomeUnavailableNotification` | 進行中の処理を安全な位置で止める |
| `NSFileReadNoPermissionError` / `EPERM` | 上記で捕捉できなかった場合の**補助的な**判定 |

`AppError` に保護データ利用不可の専用コードを設け、**再試行可能**として分類します。

##### 利用可否を取得する契約

上の 3 つはいずれも `UIKit` の API であり、`Application` は `UIKit` を `import` できません（4.3）。`Domain` にプロトコルを置きます。

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

`waitUntilAvailable()` は**キャンセルに応答します**（`withTaskCancellationHandler`）。

`willBecomeUnavailable` を購読するのは、`.complete` のファイルを読み書きしている最中にロックへ入る場合があるためです。書き出しの手順 3〜7 の途中でこれを受けた場合は、次のジャーナル保存点まで進めてから停止し、`waitUntilAvailable()` で再開します。**処理の途中でエラーにしてロールバックしません。**

### 7.5 履歴・出力・スタンプの寿命

##### 履歴とプライバシー

プライバシー保護を目的とするアプリが、アプリ内部に未加工の顔画像を蓄積することは避けます。

- **履歴のサムネイルには加工後の画像のみを使用します。** 履歴一覧に隠す前の顔が並ぶことがないようにします
- **アプリ専用領域へ元画像の完全コピーを永続保存しません。** 保持するのは写真ライブラリへの参照と編集設定のみです。処理用のコピーは書き出し完了後に削除します

元素材が削除された、またはアクセス権限を失った場合、過去の設定情報は表示できますが再編集はできません（仕様 18.3）。

##### 保存期間と容量

**仕様 18.4 の 100 プロジェクト件数上限は採用しません。** Pro は 1 バッチ 50 枚であり、写真 1 枚につき 1 プロジェクトを作る以上、2 バッチで上限に達します。代わりに保存期間と使用容量で管理します。

| 設定 | 選択肢 | 初期値 |
| --- | --- | --- |
| 保存期間 | 履歴を保存しない / 7 日間 / 30 日間 / **保存期限なし** | **30 日間** |
| 履歴の使用容量上限 | — | **200MB** |

**「制限なし」ではなく「保存期限なし」と表記します。** 容量上限は別に存在するため、「制限なし」では容量も無制限だと誤解されます。設定画面には、保存期限なしを選んだ場合も容量上限を超えると古い履歴から削除されることを併記します。

容量上限を超えた場合、古いプロジェクトから順に削除します。サムネイルだけを削除して設定を残す中間状態は設けません。

**「履歴を保存しない」を選んだ場合、本当に保存しません。** 完了画面を離れた時点で次をすべて削除します。

- プロジェクト設定、検出結果、サムネイル、加工用の中間ファイル
- `ProjectSourceLocator`（`Project` と同じ行なので同時に消える）
- `WorkingSourceRecord` と処理用ファイル
- `ExportRecord`、完了済みの `ExportQueueItem`

例外は 4 つです。

- **未受け渡しの出力ファイル。** 利用者がまだ受け取っていない成果物であり、履歴とは性質が異なる。保存・共有・破棄のいずれかで解消する
- **`UsageLedger` の `SourceRecord` と初回成功時刻。** 無料枠の判定に必要な最小限であり、画像の内容を復元できる情報を含まない
- **一括処理トライアルの消費済み素材識別値。** 5 枚分のトライアル対象を判定するために `SourceRecord` を**期限なく**保持する
- **未完了の `ExportCommit` と、それが参照する検証済み出力ファイル。** 中断した処理の後始末であり、履歴ではない

3 つ目は保持期間が無期限である点が他と異なります。**プライバシーポリシーの記載と整合させる必要があります**（12.5）。

この設定ではやり直しができません。24 時間以内であれば grant により無料枠は追加消費されませんが、編集内容は復元されません。設定画面にその旨を明記します。

##### やり直しのための保持保証

**履歴を保存する設定では、保存期間の長短にかかわらず直近の作業を 24 時間保持します。**

| 処理 | 保持対象 |
| --- | --- |
| 単体処理 | 直近 1 プロジェクト |
| 一括処理 | 直近 1 バッチと、そのバッチに属する全プロジェクト（最大 50 件） |

一括処理で「直近 1 プロジェクト」だけを保持すると、バッチ内の残り 49 枚が失われて再編集が成立しません。

保持の目的は無料枠の再書き出しだけではなく**編集のやり直し全般**であるため、**プランを問わず同一の扱いとします。** 期間は仕様 14.3 の無償再書き出しの窓と一致させます。

##### 未受け渡し出力の状態

消費は手順 7 の完了で確定します（8.3）。**したがって、生成直後の失敗や異常終了によって利用者が成果物を失う経路を作りません。** ただし保持は無期限ではなく **24 時間で削除します。**

```swift
enum OutputState: Sendable { case generated, delivered, discarded }
```

| 状態 | 意味 | 保持する期間 |
| --- | --- | --- |
| `generated` | 生成済み。受け渡しは未成功 | 明示的に破棄するまで、または 24 時間経過するまで |
| `delivered` | 保存または共有が 1 回以上成功した | **完了画面を離れるまで** |
| `discarded` | 利用者が明示的に破棄した | 直ちに削除する |

**保存や共有が 1 回成功しても、その場では削除しません。** 何度実行しても追加消費しない以上、1 回目の受け渡しでファイルを消すと、共有したあとに写真ライブラリへも保存する操作が成立しなくなります。

**状態は写真ごとの出力レコードに保持します。バッチ単位では持ちません。** 一括処理では部分的な成功が起こるためです。32 枚のうち 20 枚を保存し 12 枚が空き容量不足で保存できなかった状態は、バッチ全体に 1 つの状態では表現できません。バッチの状態は各 `OutputRecord` から集計して導出します。一括保存が部分的に成功した場合、**すでに `delivered` の写真を再保存せず、`generated` の写真だけを再試行**します。

**`generated` の出力が 1 枚以上残った状態で完了画面を離れようとした場合、確認を表示します。** 判定は `generated` の残数で行い、文言にも枚数を含めます。一括処理では 20 枚を保存した時点で「保存はした」ことになりますが、残る 12 枚は受け取れていません。

| 履歴の設定 | 提示する選択肢 |
| --- | --- |
| 保存する | あとで保存 / 破棄 / 戻る。あとで保存は履歴に未保存として残り、24 時間以内は再開できる |
| 保存しない | 破棄 / 戻る |

異常終了後の起動時も、写真ごとの状態で分けます。

| 状態 | 起動時の動作 |
| --- | --- |
| `generated` | **復旧案内の対象に含める**（枚数は `generated` の数。バッチ総枚数ではない） |
| `delivered` | 一時ファイルを削除し、**復旧案内の対象に含めない** |
| `discarded` | 残存ファイルを削除する |

これは履歴の復元ではなく**未完了の受け渡し処理の復旧**として扱うため、「履歴を保存しない」を選んでいる利用者にも表示します。

##### 未保存出力の容量制限と排他

Pro は 1 バッチ 50 枚のため、完成物が数百 MB から 1GB を超えることがあります。

**一括処理の開始前に、推定出力容量・一時処理容量・未保存出力として保持する容量・現在の空き容量を確認します。** 開始条件は**推定必要容量の 1.2 倍以上の空き容量**とします（仕様 24.4）。

- 保持できる未保存バッチは**最大 1 件**、保持期間は最大 24 時間
- 空き容量が一定値を下回った場合、保存または破棄を促す
- **未保存出力は、単体・一括を問わず一度に 1 つの処理単位まで**とする。残っている状態で新しい加工を始めようとした場合、先に解消を求める

組み合わせ（単体の未保存で一括を開始、等）ごとに規則を分けません。

##### 削除の可否判定

**除外条件を文章で列挙すると、参照元が増えるたびに書き漏らします。** 判定を 1 か所へ集約します。

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
| **`WorkingSourceRecord`**（5.5） | 処理用の元素材が消え、キューを復元できない |
| **出力再生成の対象**（8.7） | 再生成中の対象が消える |
| 24 時間のやり直し保証 | やり直しができなくなる |

**判定と削除は `ATTACH` した同一トランザクション内で行います。** 2 つの DB を跨いで見る必要があり、別トランザクションに分けると判定と削除の間に新しい参照が生まれます。

**判定の入口を 1 つにします。** 容量超過による自動削除、期限削除、利用者による手動削除のいずれもこの関数を通します。手動削除だけを例外にしません。

| 契機 | 削除できない場合の扱い |
| --- | --- |
| 容量超過による自動削除 | 次の候補へ進む。全候補が削除不可なら空き容量の確保を求める |
| 保存期間による期限削除 | **保留する。** 参照が消えた時点で削除対象へ戻る |
| 利用者による手動削除 | 理由を提示して拒否する |

**写真ライブラリへ保存済みの加工済み画像は削除されません。** この点を設定画面と削除確認の両方に明示します。

##### 出力の削除経路

**「ファイルを消す」だけでは `OutputRecord` が孤児になります。** すべての出力削除を単一の経路へ統一します。

| 順 | 操作 |
| --- | --- |
| 1 | DB トランザクションで `OutputRecord` を削除する |
| 2 | **同じトランザクション内で** `PendingFileDeletion` を追加する |
| 3 | DB のコミット後にファイルを削除する |
| 4 | 成功したら `PendingFileDeletion` の行を削除する |
| 5 | 失敗したら起動時 GC で再試行する |

対象は `delivered` で完了画面を離れた場合、利用者が破棄した場合、`generated` が 24 時間経過した場合、壊れた出力を復元できなかった場合（8.7）のすべてです。**入口ごとに別の順序を実装しません。**

**失っても復旧できないほうを避けます。** ファイルを先に消して DB が失敗するとレコードだけが残って実体を指せません。DB を先に更新すれば、残るのは孤児ファイルだけで GC が回収します。

##### `ExportRecord` と履歴の削除

`ExportRecord` は「いつ何を書き出したか」の履歴であり、24 時間では消えません。**そのため履歴設定の対象になります。**

| 保存期間の設定 | `ExportRecord` の扱い |
| --- | --- |
| 履歴を保存しない | **完了画面を離れた時点で削除する** |
| 7 日 / 30 日 | 期限で削除する |
| 保存期限なし | 容量上限に達したら古いものから削除する |

**`ExportRecord` は、対応する `Project` または `Batch` と同じトランザクションで削除します。** 別々に消すと「プロジェクトはあるが書き出し記録が無い」または逆が生じます。完了済みのキュー項目も同じ扱いです。未完了のキュー項目は削除しません。

一括処理した写真は履歴へ 50 件並べるのではなく、**バッチ単位で 1 件に集約します。** 開くと個別の写真を確認でき、エラーのみの再試行へ遷移できます。

##### 履歴サムネイル

| 項目 | 規約 |
| --- | --- |
| ディレクトリ | `user-data/thumbnails/` |
| 参照 | ファイル名ではなく `ManagedFileRef(.historyThumbnail, ...)`（`Project` が保持） |
| 保護クラス | `.complete`（加工後とはいえ顔を含む画像） |
| バックアップ | 対象外 |
| 生成 | `ManagedFileStore` を通す |
| 削除 | `Project` 削除と**同じ DB トランザクション**で `PendingFileDeletion` へ追加 |
| 孤児 GC | 起動時に `Project` から参照されない実体を回収 |
| 復元時に実体が無い | プレースホルダを表示する。**履歴自体は消さない** |

`CustomStamp` の一覧サムネイルは、`StampAsset` の実体から再生成できるキャッシュとして扱います。欠損時は実体から作り直します。

##### カスタムスタンプの実体

| 項目 | 仕様 |
| --- | --- |
| 取り込み元 | 写真ライブラリ、およびファイルアプリ（`fileImporter`） |
| 対応形式 | PNG、JPEG、HEIF / HEIC |
| 透過 PNG | 透過状態を維持する |
| 非透過画像 | 円形または角丸マスクで切り抜く |
| 自動背景除去 | **v1 では行わない**（前景マスク生成の品質が素材に依存し、失敗時の説明が難しい） |
| 登録上限 | **Standard・Pro ともに 100 個**（仕様 12.7 から変更。12.4） |
| 登録時の縮小 | 長辺 1,024px を上限とする |
| 保存形式 | 透過を維持できる圧縮形式（PNG または HEIC） |

ファイルアプリからの取り込みを含めるのは、写真ライブラリ経由では透過が失われる経路があるためです。

**スタンプ一覧の項目と、プロジェクトが参照する画像実体を別々に管理します。**

| 概念 | テーブル | 役割 |
| --- | --- | --- |
| スタンプ一覧の項目 | `CustomStamp` | 名前、並び順、サムネイル。新規適用の選択肢 |
| 画像実体 | `StampAsset` | 内容ハッシュを主キーとする不変のコピー。参照カウントを持つ |

```
StampAsset.referenceCount
    = （その実体を参照する CustomStamp の数）
    + （その実体を参照する Project の数）
```

| 契機 | 操作 |
| --- | --- |
| カスタムスタンプを**一覧へ登録**した | `StampAsset` を作成（または既存を再利用）し、**参照カウントを 1 増やす** |
| プロジェクトがそのスタンプを**使用**した | 同じ `StampAsset` の**参照カウントを 1 増やす** |
| `CustomStamp` を**一覧から削除**した | **参照カウントを 1 減らす**。新規編集では選択できなくなる |
| `Project` を削除した | **参照カウントを 1 減らす** |
| 参照カウントが **0** になった | **実体を削除する**（下記の順序） |

**この構成なら、一覧削除で過去プロジェクトの実体が消えません。** プロジェクト側の参照が残っている限り参照カウントは 0 になりません。削除確認では、過去の加工履歴で引き続き使用される旨を示します。

**内容ハッシュの対象は最終保存バイト列の SHA-256 とします。**

| 候補 | 問題 |
| --- | --- |
| 入力ファイルそのもののバイト列 | 同じ画像を PNG と HEIC で取り込むと別実体になる |
| 正規化済みピクセル | デコードの実装差（色空間変換の丸め）で値が揺れる |
| **最終保存バイト列** | — |

計算時点は `ManagedFileStore` へ書く直前（保存の手順 1 と 2 の間）です。同じハッシュの `StampAsset` があれば、書いたファイルを破棄して既存を再利用します。保存バイト列を対象にするのは、**それが実際にディスク上にある唯一の表現**だからです。デコード実装が将来変わっても既存のハッシュは変わりません。

アプリ提供の基本スタンプと追加スタンプはベクターとしてコードに持つため、実体の消失が起きません。`StampAsset` の対象はカスタムスタンプのみです。

##### DB とファイルの更新順序

**失っても復旧できないほうを避けます。DB を先に更新します。** ファイルを先に消すと DB トランザクションの失敗で参照中のスタンプを失い（復旧不能）、DB を先に更新すればファイル削除の失敗は孤児ファイルが残るだけです（容量を食うだけ）。

**作成**

| 順 | 操作 |
| --- | --- |
| 1 | 一時ファイルへ書く |
| 2 | 完成ファイルへ **atomic rename** する |
| 3 | DB トランザクションで `StampAsset` を upsert し、参照を追加する |
| 4 | DB が失敗した場合、そのファイルを**孤児として削除対象へ入れる** |

**削除**

| 順 | 操作 |
| --- | --- |
| 1 | DB トランザクションで参照数を減らす |
| 2 | 0 になった実体を**削除候補として同じトランザクション内で記録する** |
| 3 | DB のコミット後にファイルを削除する |
| 4 | 削除に失敗した場合、**次回起動時の GC で再試行する** |

##### 孤児ファイルの GC

`PendingFileDeletion` だけでは、作成の手順 3 で失敗したファイルを回収できません（記録する前に落ちるため）。起動時に、**専用ディレクトリの実体と DB 上の参照一覧を突き合わせ**、どちらにも属さないファイルを削除します。

対象は `StampAsset` の実体、ラスタスタンプ一時ファイル、書き出しの一時ファイル、処理用ファイル、履歴サムネイルです。

**履歴削除、`CustomStamp` 削除、容量超過削除も、すべてこの経路を通します。** 削除の入口ごとに別の順序を実装すると、片方だけが孤児を残します。

##### 使用容量の表示

一覧から削除しても過去プロジェクトが参照する `StampAsset` は残るため、使用容量を 1 つの数値で示すと「すべて削除したのに容量がゼロにならない」という説明できない状態が生まれます。**内訳を分けて表示します**（登録中のマイスタンプ / 過去の加工履歴で使用中 / 合計）。

一括削除は `CustomStamp` の一覧のみを対象とし、参照中の `StampAsset` は削除しません。履歴で使用中のぶんも消したい場合は、対象の履歴を削除する必要があることを併記します。**参照中の `StampAsset` を強制削除する機能は提供しません。**

##### メタデータ

撮影日時には **ファイル内の EXIF** と **写真ライブラリの登録日時** の 2 層があります。写真アプリの並び順を決めているのは後者です。

EXIF の撮影日時を一律に削除すると、加工後の写真がすべて当日の撮影として並び、一括処理した際に元の時系列が失われます。

| 設定 | 初期値 | 利用者による変更 |
| --- | --- | --- |
| 位置情報を削除 | ON | 可 |
| 撮影機器情報を削除 | ON | 可 |
| コメント・編集ソフト情報を削除 | ON | 可 |
| EXIF の撮影日時を保持 | ON | 可（OFF にすると日時も削除） |
| **写真ライブラリの登録日時を元画像から引き継ぐ** | **取得できる場合に引き継ぐ** | **不可** |

`PHAssetCreationRequest.creationDate` は保存時に明示指定できるため、**EXIF から日時を消してもライブラリ側の日時を引き継げば並び順は保たれます。**

**`PHAsset.creationDate` は `Optional` です。** 優先順位を定めます。

| 順 | 取得元 | 条件 |
| --- | --- | --- |
| 1 | `PHAsset.creationDate` | **読み取り権限が既にある場合のみ**（5.5） |
| 2 | EXIF の `DateTimeOriginal` | 常に試みる |
| 3 | **`creationDate` を設定しない**（OS が保存日時を使う） | どちらも無い場合 |

**3 の場合に現在時刻を明示指定しません。** 設定しないのと同じ結果になりますが、「日時を引き継いだ」と記録が残ると不具合を追うときに誤解の元になります。取得できなかったことを区分値として記録します（9.2）。

**この優先順位表を `contentFingerprint` に流用しません。** fingerprint の撮影日時は EXIF のみです（6.4）。ここで `PHAsset.creationDate` を優先するのは保存する写真の属性としてより正確だからであり、同一性の判定には使えません。**共有するのは EXIF の読み取り処理までとし、優先順位の合成は共有しません。**

画像方向とピクセルサイズは常に保持します。

---

## 8. 書き出し Saga

書き出しの完了で確定する事柄は、**保存先が 3 つに分かれています。**

| 更新対象 | 保存先 |
| --- | --- |
| 完成済みファイルの公開 | ファイルシステム |
| `OutputRecord` = `generated` | DB |
| Free 枠の消費、`ExportGrant` の作成、トライアル台帳への素材追加 | ProtectedBlobStore |

**単一トランザクションで更新できません。** 異常終了の位置によって「出力だけ残り枠が消費されない」「枠だけ消費され出力が残らない」が起こります。2 つ目は「消費したのに成果物を受け取れない」そのものです。

**永続的なコミットジャーナルを置きます。**

### 8.1 認可

**`blocked` になりうる評価を、生成が終わったあとに行いません。**

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
    case ledgerIntegrityFailure         // 台帳破損による封鎖（6.3）
    case trialCreditsUnavailable        // トライアルのクレジットが残っていない
    case trialIntegrityLocked           // トライアル台帳の破損による封鎖
    case capabilityVerificationRequired // 権限の再検証が必要（6.2）
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
    let sourceID: SourceID          // このトランザクションで確定した（6.4）
    let authorization: ExportAuthorization
}

/// どの勘定を使う書き出しか。blocked は含めない
enum ExportAccountingMode: Sendable {
    case paidUnlimited                          // 月間枠の対象外
    case freeMonthlyConsume                     // 月間枠を 1 消費
    case freeMonthlyReexport                    // 24 時間以内の再書き出し
    case batchTrial(consumesTrialCredit: Bool)
}
```

書き出し開始時点で利用権限と勘定を確定し、その書き出しについて固定します。`blocked` なら `ExportCommit` を作らず、生成も開始しません。**型に `blocked` を含めないことで、検証済みファイルを抱えたまま上限超過で破棄する経路を表現できなくします。**

**`ExportStartBlock` は開始を止める理由だけを持ちます。** `QuotaDecision` を連想値にすると `.blocked(.unlimited)` のような無意味な値が構築でき、型で分けた目的を果たしません。`evaluate` が `.blocked(reason:limit:)` を返した場合に開始トランザクションが写し、`unlimited` / `freeReexport` / `consume` はいずれも `ExportAccountingMode` へ写ります。

##### 勘定の使い分け

| 勘定 | 月間枠 | トライアル台帳 | grant |
| --- | --- | --- | --- |
| `paidUnlimited` | 使わない | 使わない | ensure |
| `freeMonthlyConsume` | **1 消費** | 使わない | ensure |
| `freeMonthlyReexport` | 使わない | 使わない | **preserve** |
| `batchTrial(true)` | **使わない** | **1 消費** | ensure |
| `batchTrial(false)` | 使わない | 使わない | ensure |

**月間クォータを使うのは Free の単体処理だけです。** したがって **Free 利用者が月 5 枚を使い切っていても、クレジットが残っていれば一括トライアルを実行できます。**

```swift
/// grant の操作。ensure と preserve を型で分ける
enum GrantAction: Sendable {
    /// 有効な grant がなければ firstSuccessAt で新規作成してよい
    case ensure(sourceID: SourceID, firstSuccessAt: Date)

    /// 認可時の grant を維持するだけ。新規作成は禁止
    case preserveAuthorized(sourceID: SourceID, firstSuccessAt: Date)
}
```

**単一フィールドでは preserve を表現できません。** どの勘定でも「新規作成してよい」という指示になり、後段の文章だけで例外を設けることになります。通常処理と起動時復旧が同じ `AccountingIntent` を読む以上、復旧側が ensure してしまう経路が残ります。型で分ければ `switch` の網羅で強制されます。

**ensure**（`paidUnlimited` / `freeMonthlyConsume` / `batchTrial` の両方）

> 正常生成時に有効な grant が存在すれば、既存の `firstSuccessAt` を維持する。存在しなければ、`finalizedAt` を `firstSuccessAt` とする新しい grant を作る。

`batchTrial(false)` が意味するのは「その写真のトライアルクレジットを**過去に**消費済み」であって、「いま有効な 24 時間 grant が存在する」ではありません。1 週間前にトライアルした写真を再処理する場合、クレジットは消費しませんが**新しい正常生成として grant は作ります。** 混同すると再処理直後の再書き出しが有料になります。

**preserve**（`freeMonthlyReexport`）

認可と会計の間に時間差があるため、ensure を適用すると次が成立します。初回成功から 23 時間 59 分で再書き出しを開始 → 認可時点では有効な grant があるので `freeMonthlyReexport` → 生成中に 24 時間を超える → ensure により `finalizedAt` を起点とする**新しい grant** ができる。無料の再書き出しを繰り返すだけで窓を無期限に更新できてしまいます。

> 認可時に保存した `authorizedGrant.firstSuccessAt` をそのまま維持する。会計時点で新しい `firstSuccessAt` を作らない。

- 同じ `firstSuccessAt` の grant がまだ存在する → **変更しない**
- 期限切れとして既に削除されている → **再追加しない**
- 別の `firstSuccessAt` へ差し替えない

会計時点で認可時の grant が既に期限切れになっていた場合は、**再登録せずそのまま落とします。** 無料で開始したその 1 回は完了させますが、次回の再書き出し権は与えません。

##### 開始後の権限変化

開始後に有料契約の失効・月間上限への到達・リモート設定の変更が起きても、その書き出しは開始時の権限で完了させます。

**認可の粒度は写真ごとの `exportID` です。** バッチ単位ではありません。

| Pro 失効時点の状態 | 扱い |
| --- | --- |
| `prepared` 以降へ進んでいる写真 | 開始時の認可で**完了させる** |
| まだ認可されていない `waiting` の写真 | 開始しない。バッチを `paused` にする |

##### 開始ゲート

**「同時 1 件」という規則だけでは競合を防げません。** 認可を通ってから `Prepared` を書くまでの間に、別の書き出しが同じ認可を通過できます。**認可の前にゲートを取ります。**

**`sourceID` をゲートのキーにできません。** 正規 `sourceID` は `UsageLedger` 内の alias を検索・統合して確定するため、`sourceID` を得るには `transact` が必要で、`transact` はゲートの内側にあります。**ゲート取得に必要な値が、ゲート取得後にしか分かりません。** 台帳をゲートの外で先読みして解決すると、統合処理そのものが競合対象なので意味がありません。

同時並列数の初期値が 1 である以上、素材単位の粒度は実質使われません。**ゲートを全体で 1 件にします。**

```swift
// Domain — プロトコル。実装は 4.2 の待機キュー規則に従う
protocol ExportStartGate: Sendable {
    func withExclusivePermit<R: Sendable>(
        operation: @Sendable () async throws -> R
    ) async throws -> R
}
```

**その内側の 1 回の `UsageLedgerStore.transact` で、次をすべて行います。**

1. alias を解決・統合し、**`sourceID` を確定する**（6.4）
2. 時刻を正規化し、月次更新と期限切れ grant の整理を行う
3. クォータまたはトライアルを認可する
4. 必要な予約と `SourceLease` を追加する
5. 更新済み台帳と `ExportStartDecision` を返す

**1 回の `transact` にまとめるのが要点です。** 解決と認可を別々のトランザクションに分けると、その間に別の処理が同じ alias を解決できます。

開始の順序は次のとおりです。

1. 復旧完了ゲートを確認する（8.5）
2. **`withExclusivePermit` を取得する**
3. **その内側で** `transact` を 1 回実行し、`ExportStartDecision` を得る
4. `.blocked` なら生成せずに終える。ゲートは解放する
5. `ExportCommit(prepared)` を保存する
6. 処理を開始する
7. 手順 7 の完了またはロールバック完了で**ゲートを解放する**

**ゲートは認可の完了では解放しません。コミット行の削除またはロールバックの完了まで保持します。** ロールバックの途中で次の認可が走ると、戻す前の台帳を根拠に判定してしまいます。

##### 同一素材の直列化

**同じ素材の非終端 `ExportCommit` は同時に 1 件だけとします。** この不変条件がないと所有者方式が壊れます。Export A が grant を作り所有者になる → 同じ素材の Export B も正常完了する（既存 grant を使うので所有者にならない）→ A のファイル異常でロールバックし A 所有の grant を削除する → **B は成功しているのに grant が消える。**

- 並列処理は異なる素材の間だけ許可する
- 同一素材は直列化する。バッチ内に重複があっても同様
- **コミット行の削除またはロールバック完了まで**、その素材をロックする

ロックを `readyToPublish` で解放してはいけません。その保存後、コミット行の削除前にも復旧対象となる区間が残っています。

v1 は全体ゲートによりこの条件を自動的に満たします。

##### 並列数を 2 へ上げるときの移行

**現在の全体ゲートをそのまま外せません。** 並列化する場合は 2 段構えにします。

| 段 | ゲート | 内容 |
| --- | --- | --- |
| 1 | **alias 単位の解決ゲート** | alias から `sourceID` を確定するまでを排他する |
| 2 | `sourceID` 単位のゲート | 確定した `sourceID` で以降を排他する |

第 1 段が短時間で終わるため、実質的な並列度は保たれます。あわせて、月間枠を消費する単体書き出しを同時 1 件に制限するゲートを第 2 段で復活させます（消費するかどうかは認可の結果であり、ゲートを取る時点では未確定なので、条件式ではなく粒度で担保します）。この設計は並列数を上げる時点で行い、v1 では実装しません。

##### 台帳更新の直列化

```swift
struct LedgerTransaction<R: Sendable>: Sendable {
    let ledger: UsageLedger
    let result: R
}

// Domain はプロトコルだけを定義する
protocol UsageLedgerStore: Sendable {
    func transact<R: Sendable>(
        _ transform: @Sendable (UsageLedger) throws -> LedgerTransaction<R>
    ) async throws -> R
}
```

オブジェクトの置換が原子的でも、**並列処理が同じ旧台帳を読んで別々に書き戻せば一方の更新が失われます。** 読み取り・変更・署名・保存を単一の更新口へ通します。実装規則は 4.2 です。

**更新後の台帳だけを返す API では足りません。** 同じ排他区間の中で、認可時の `ExportAccountingMode`、会計時の `AccountingApplied`、正規化後の `usageNow`、月次更新後の `period` も取り出す必要があります。外側で読んで結果を計算してから `update` すると競合が再発します。

**書き出し処理は並列でも、台帳のコミットは直列とします。**

### 8.2 ExportCommit の状態

```swift
struct ExportCommit: Sendable {
    let exportID: ExportID                  // 6.6
    let projectID: ProjectID
    let batchID: BatchID?
    let sourceID: SourceID                  // 6.4 で解決済み
    let outputFile: ManagedFileRef          // 種別つきの参照（7.3）
    let authorization: ExportAuthorization  // 開始前に固定する
    let verifiedOutput: VerifiedOutput?     // prepared では nil。fileVerified 以降は必須
    let finalizedAt: Date?                  // finalizing で確定する usageNow
    let finalizedPeriod: YearMonth?         // 計上先の年月。finalizedAt から導出
    let intent: AccountingIntent?           // finalizing で確定する
    let applied: AccountingApplied?         // 台帳へ適用したあとに埋まる
    let state: ExportCommitState
    let signature: Data                     // Keychain の鍵による HMAC
}

/// 手順 1 の検証結果。これ自体も HMAC の対象に含める
struct VerifiedOutput: Sendable {
    let byteSize: Int64
    let sha256: Data
}

/// 台帳へ適用しようとする内容。時刻は finalizedAt から導出する
struct AccountingIntent: Sendable {
    let consumeExportID: ExportID?
    let grantAction: GrantAction
    let trialSourceIDToEnsure: SourceID?
}

/// 台帳へ実際に適用された結果
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
    case readyToPublish        // 手順 7 の直前。まだ非公開
}
```

| 状態 | 必須フィールド |
| --- | --- |
| `prepared` | `authorization` のみ |
| `fileVerified` | 上記 ＋ `verifiedOutput` |
| `finalizing` | 上記 ＋ `finalizedAt` / `finalizedPeriod` / `intent` |
| `accountingCommitted` | 上記 ＋ `applied` |
| `readyToPublish` | 上記 ＋ ファイル再検証済み |

**`readyToPublish` は成果物がまだ非公開で、コミット行も残っている状態です。**

**「適用しようとする内容」と「実際に適用された結果」を分けます。** 台帳を更新する前に「実際に新規追加した値」を確定することはできません。ただし `AccountingApplied` を DB へ書く前に落ちる可能性があるため、**これだけを根拠にロールバックできません。** 台帳側の `ownerExportID` が最終的な判断材料です。

##### 検証結果をジャーナルへ持つ

`fileVerified` で落ちた場合、`OutputRecord` はまだ存在しません（作られるのは手順 7）。検証済みファイルと同じ内容かを起動時に確認する材料が、コミット側になければ復旧できません。

- 復旧時は実体のサイズ・SHA-256・デコードを再確認し、`verifiedOutput` と突き合わせる
- 手順 7 の `OutputRecord` 作成時は、`verifiedOutput` から値を**コピーする（再計算しない）**
- `verifiedOutput` は HMAC 対象に含める

再計算ではなくコピーにするのは、手順 1 と手順 7 の間にファイルが差し替えられた場合に検出するためです。再計算すると差し替え後の内容を「正しい記録値」として固定してしまいます。

**アルゴリズムを名前で固定します。** `outputDigest` のような抽象名にすると実装ごとに別のアルゴリズムを選ぶ余地が残ります。**サイズも記録します。** ダイジェストだけでは手順 6 のサイズ照合ができず、サイズ比較はダイジェスト計算より安く途中書き込みを先に弾けます。

##### 会計時刻は最終確定処理から導出する

**会計時刻を `fileVerified` で確定すると、成功時点と食い違います。** 7 月 31 日に `fileVerified` となり 8 月 1 日に復旧して公開された場合、利用者が受け取るのは 8 月なのに消費は 7 月扱いになり、grant の 24 時間も 7 月から開始します。**月をまたぐ場合だけの問題ではありません。** 2 時間後の復旧でも窓と期限が 2 時間ずれます。

そこで **`fileVerified` では `finalizedAt` を確定しません。** 最終確定を試みる直前に `finalizing` を保存し、そこで初めて時刻を決めます。

| 値 | 導出元 |
| --- | --- |
| `finalizedAt` | **`finalizing` を保存する時点**の `usageNow` |
| `finalizedPeriod` | `finalizedAt` の年月 |
| grant の `firstSuccessAt` | `finalizedAt`（ensure の場合） |
| `OutputRecord.generatedAt` | `finalizedAt` |
| `OutputRecord.expiresAt` | `finalizedAt + 24h` |

これにより「利用者が受け取った時刻」と「消費を計上した時刻」が必ず一致します。`authorization` は開始時に固定したままです。長時間の中断後に復旧しても、**権限は開始時のもの、時刻は確定時のもの**を使います。

### 8.3 手順 0〜7

保存先が DB と ProtectedBlobStore にまたがるため、**書き込み順を固定します。**

**この表が唯一の正です。** 他の節が手順番号や状態遷移に言及する場合は、必ずこの表を参照します。

| 順 | 操作 | 保存先 | 遷移後の状態 |
| --- | --- | --- | --- |
| −2 | `transact` 内で時刻正規化・月次更新・期限切れ grant の整理を**永続化**する。`batchTrial(true)` なら**同じトランザクション内で**トライアル予約と `SourceLease` を作る | ProtectedBlobStore | — |
| −1 | `transact` の結果として `ExportStartDecision` を得る。`.blocked` なら以降へ進まない | — | — |
| 0 | `ExportCommit` を保存（`verifiedOutput` / `intent` / `finalizedAt` はすべて `nil`）。**保存に失敗したら補償トランザクションで予約・lease・未参照 `SourceRecord` を削除し、ゲートを解放する** | DB | **`prepared`** |
| 1 | 一時ファイルを生成し、サイズ・SHA-256・デコードを検証して `VerifiedOutput` を得る | ファイルシステム | — |
| 2 | `verifiedOutput` を確定して保存（`finalizedAt` はまだ `nil`） | DB | **`fileVerified`** |
| 3 | **`finalizedAt` を決め、`intent` を確定して**保存 | DB | **`finalizing`** |
| 4 | `UsageLedger` を冪等に**暫定適用**する。**予約の `trialEntries` への移動と `SourceLease` の削除も同じ台帳トランザクション内** | ProtectedBlobStore | — |
| 5 | `applied` を埋めて保存 | DB | **`accountingCommitted`** |
| 6 | `verifiedOutput` と出力ファイルの**健全性**を確認して保存 | ファイルシステム / DB | **`readyToPublish`** |
| 7 | **単一トランザクション**（下記）。`OutputRecord` を作り、コミット行を削除する。**ここが会計の最終確定境界** | DB | （行が消える） |

```
prepared → fileVerified → finalizing → accountingCommitted → readyToPublish
                                                                   ↓
                                              手順 7 の単一トランザクションで削除
```

**手順 4 と 5 を逆にしてはいけません。** 先に `accountingCommitted` を書くと、台帳が未反映のまま「反映済み」として復旧されます。この順なら 4 と 5 の間で落ちても状態は `finalizing` のままなので、台帳更新を冪等に再適用できます。

**手順 0 で `prepared` を先に書くのは、生成中に落ちたときに孤児となる一時ファイルを起動時に特定するため**です。ジャーナルに記録のない一時ファイルは掃除対象になります。

**台帳の更新は手順 4 です。手順 7 ではありません。** 手順 7 は DB だけのトランザクションであり、`ProtectedBlobStore` を同時に更新できません。

**手順 7 を省くと、書き出しのたびにコミット行が永久に蓄積します。** ジャーナルは中断からの復旧のためだけに存在するので、役目を終えたら消します。

冪等性の鍵は 2 種類です。**クォータ消費は `exportID`、トライアル消費は素材の同一性。** 前者は同じ書き出しの再実行、後者は同じ写真の再書き出しを弾くもので、目的が異なります。

##### 確定点は 1 つだけ

> **検証済みファイルは、手順 7 が完了するまで UI・`MediaSaver`・`SharePresenter` へ公開しません。**
>
> 手順 4 で台帳へ会計を暫定適用し、**手順 7 のコミット行削除で最終確定します。**
>
> 本書における「利用可能な出力の生成が正常に完了した時点」とは、**手順 7 まで完了した時点**を指します。

| 区間 | 性質 |
| --- | --- |
| 手順 7 より前 | 復旧またはロールバックが可能。成果物は非公開 |
| 手順 7 以降 | 成果物を利用者へ公開する。会計は戻さない |

これは仕様 14.2 の「保存処理または共有可能な状態になった」と一致します。手順 7 の完了が、まさに保存・共有が可能になる時点だからです。

以下では消費しません。検出のみ、プレビューのみ、キャンセル、生成の失敗、生成前の空き容量不足、**生成中の**異常終了、対応外形式。

**生成が完了したあとの異常終了では消費が確定したままです。** 出力は残り再起動後に受け取れるため、ここで消費を戻すと二重取りになります。**写真ライブラリへの保存は消費の条件に含みません。** 保存せず OS 共有だけで完結する経路が成立するためです。

##### 非公開を構造で保証する

**「公開しない」と文章で書くだけでは防げません。** `OutputRecord` を会計直後に作ると、GRDB の `ValueObservation` はその時点から `generated` を観測でき、UI の購読先が `OutputRecord` である以上、最終確定より前に画面へ現れます。

**`OutputRecord` の作成を手順 7 へ移し、コミット行の削除と同一の DB トランザクションで実行します。**

| DB の状態 | 意味 |
| --- | --- |
| コミットあり・`OutputRecord` なし | **非公開**（処理中または復旧対象） |
| コミットなし・`OutputRecord` あり | **公開済み**（会計確定済み） |
| 両方あり | **起こらない**（トランザクションが保証する） |

手順 6 の健全性確認が `OutputRecord` ではなく `verifiedOutput` を参照するのは、この順序変更のためです。

##### 手順 6 の確認内容

**存在確認だけでは不足です。** 0 バイトのファイル、途中まで書かれたファイル、デコードできないファイルも「存在する」ため、その状態でコミット行を削除できてしまいます。削除後は会計を戻すためのジャーナルが失われ、消費だけが残ります。

| 確認項目 | 目的 |
| --- | --- |
| `outputFile` から解決したファイルが存在する | 実体がある |
| ファイルサイズが 0 でなく、`verifiedOutput.byteSize` と一致する | 途中書き込みでない |
| SHA-256 が `verifiedOutput.sha256` と一致する | 内容が入れ替わっていない |
| 簡易デコードが成功する | 画像として開ける |

いずれかが不成立なら削除せず、そのコミットをロールバック対象として扱います。この時点ではジャーナルが残っているため、会計を正しく戻せます。

##### 手順 7 の直前に時刻を再確認する

**「異常終了したら手順 3 へ戻る」だけでは `finalizedAt` の陳腐化を防げません。** 同じプロセスが生き続けたまま、手順 3 で `finalizing` を保存 → バックグラウンドへ移行 → 数時間または数日停止 → 同じ Task が再開 → 手順 7 を実行、という経路をたどれます。プロセスは落ちていないため起動時復旧を通りません。

| 順 | 操作 |
| --- | --- |
| 7-a | 新しい `usageNow` を取得する |
| 7-b | `finalizedAt` との差、および `finalizedPeriod` との一致を確認する |
| 7-c | いずれかが規定を外れていれば、**暫定会計を取り消して手順 3 から再確定する** |
| 7-d | 規定内なら、そのまま手順 7 の単一トランザクションを実行する |

| 条件 | 扱い |
| --- | --- |
| `usageNow` の年月 ≠ `finalizedPeriod` | **再確定する**（計上月がずれる） |
| `usageNow - finalizedAt` > **5 分** | **再確定する** |
| 上記以外 | そのまま進む |

5 分は、正常な処理で手順 3 から 7 までに要する時間を十分に上回り、かつ 24 時間の期限に対して無視できる大きさとして選びます（12.5 で実測後に調整）。

あわせて、**バックグラウンド移行時に手順 3〜7 を進めません。** シーンの非活性化を受けたら次の保存点で停止し、復帰時に上記の再確認から再開します。停止位置は必ずいずれかの `ExportCommitState` であり、中間状態で止まりません。

##### 手順 7 の内容

**DB に保存する状態は `OutputRecord` だけではありません。** `ExportRecord` と写真ごとのキュー状態も同じ DB にあり、`OutputRecord` の insert とコミットの delete だけでは「出力は公開済みだがキューは `exporting`」「キューは `completed` だが `ExportRecord` が無い」が残ります。

| 操作 | 対象 |
| --- | --- |
| `OutputRecord(generated)` を insert | `OutputRecord` |
| 成功記録を insert | `ExportRecord` |
| 対象キュー項目を `completed` へ更新 | キュー状態 |
| プロジェクトの最終更新時刻を更新 | `Project` |
| `ExportCommit` を delete | `ExportCommit` |

バッチの成功件数・失敗件数は、**キュー項目からの導出値**とします。二重管理を避けるためです。

`ExportRecord` は「いつ何を書き出したか」の記録で 24 時間では消えません。`OutputRecord` が「いま手元にある未受け渡し出力」を表すのに対し役割が異なるため、両方を残します。

```swift
struct OutputRecord: Sendable {
    let exportID: ExportID                  // 6.6
    let projectID: ProjectID
    let batchID: BatchID?
    let outputFile: ManagedFileRef          // 種別つきの参照（7.3）
    let outputByteSize: Int64               // verifiedOutput からコピー
    let outputSHA256: Data                  // verifiedOutput からコピー
    let state: OutputState
    let generatedAt: Date                   // ExportCommit.finalizedAt からコピー
    let expiresAt: Date                     // finalizedAt + 24h
}
```

**パスを DB へ直接持ちません。** パス文字列を保存すると、DB を書き換えるだけで `../` を含む値を注入でき、期限切れ削除の処理に別のアプリ内部ファイルを消させる経路ができます。ID からの解決なら、削除対象が構造的に専用ディレクトリの外へ出ません。

**期限を `OutputRecord` 自身が持ちます。** 判定は `retentionNow >= expiresAt` であり、`retentionNow` が `nil` の間は削除しません（6.3）。`ExportCommit` は完了後に削除するため、**コミットが消えたあとも単独で期限を判定できる**必要があります。

### 8.4 ロールバック

| 順 | 操作 | 保存先 |
| --- | --- | --- |
| 1 | `transact` で、この `exportID` が所有する会計要素（消費・grant・トライアル台帳・トライアル予約・**`SourceLease`**）を**冪等に**取り消す | ProtectedBlobStore |
| 2 | 台帳の保存が成功したことを確認する | ProtectedBlobStore |
| 3 | `OutputRecord` を削除する（存在する場合のみ） | DB |
| 4 | `outputFile` のファイルを削除する | ファイルシステム |
| 5 | `ExportCommit` を削除する | DB |
| 6 | 開始ゲートを解放する | メモリ |

- **手順 1 が失敗した場合、2 以降を実行しません。** コミットとファイルを残したまま復旧エラーとします。台帳を戻せていないのにジャーナルを消すと、消費だけが残って根拠が失われます
- **手順 1 の完了後に落ちても、再起動時に同じロールバックを冪等に再実行できます。** 取り消しは集合からの削除であり、二重実行は無害です
- **`ExportCommit` の削除後にのみゲートを解放します。** 解放が早いと、ロールバック途中の台帳を次の認可が読みます
- 取り消してよいのは、台帳の `ownerExportID` がこの `exportID` と一致する要素だけです

取り消しの判断材料は台帳側の `ownerExportID` です。`AccountingApplied` は DB へ書く前に落ちうるため、単独では根拠になりません。

```
consumedExportIDs に対象 exportID があれば削除
grants           のうち ownerExportID == 対象 exportID の要素を削除
trialEntries     のうち ownerExportID == 対象 exportID の要素を削除
trialReservations のうち exportID == 対象 exportID の要素を削除
sourceLeases     のうち exportID == 対象 exportID の要素を削除
別の exportID が作った要素は削除しない
```

既存の grant を再利用しただけの書き出しは `ownerExportID` が一致しないため、以前から存在した権利を巻き添えで消しません。

| 状態 | 台帳への適用 | ロールバック経路 |
| --- | --- | --- |
| `prepared` | **`SourceLease`**、トライアル時のみ予約 | 手順 1〜6。lease・予約・未参照 `SourceRecord` の取り消しは必要。`OutputRecord` は未作成 |
| `fileVerified` | 同上。`finalizedAt` は未確定 | 手順 1〜6 |
| `finalizing` | 上記 ＋ **暫定会計が存在しうる** | 手順 1〜6。`intent` の内容を `ownerExportID` と突き合わせて取り消す |
| `accountingCommitted` | 適用済み | 手順 1〜6。`applied` ではなく台帳の `ownerExportID` を根拠にする |
| `readyToPublish` | 適用済み | **同一プロセス内なら**手順 7 を実行して完了。**起動時に発見した場合は**暫定会計を取り消して手順 3 から再開（8.5） |

##### 会計の最終確定境界

**コミット行の削除をもって会計を最終確定とします。ジャーナルが残っている間だけ、会計をロールバックできます。**

理由は 2 つです。

**1. 消費の確定点が曖昧になる。** 生成完了後の異常終了では消費を戻さず、利用者が破棄しても戻さず、トライアルは初回の正常生成で消費します。コミット削除まで完了した出力は正常生成が確定済みであり、その後のストレージ障害だけを払い戻し対象にすると「異常終了では戻さないがストレージ障害では戻す」という区別が必要になります。

**2. 所有者モデルが破綻する。** Export A が grant を作り所有者になる → A のコミットを正常に削除する → 同じ素材を Export B で正常に再書き出しする（B は既存 grant を利用するため所有者は A のまま）→ 後から A の出力ファイルが失われる → `ownerExportID` を根拠に grant を削除する → **B も正常成功しているのに grant が消える。** 非終端コミットの直列化は非終端の間しか効かず、A のコミットは既に削除済みなので B の開始を止められません。

### 8.5 起動時復旧

**復旧を終えるまで、新しい書き出しを開始させません。** 先に許可すると、あとから古いコミットをロールバックした際に、すでに進んだ現在の台帳まで壊しかねません。

**各手順が前の手順の結果に依存します。**

| 順 | 操作 | 依存 |
| --- | --- | --- |
| −4 | **保護データが利用可能になるまで待つ**（7.4） | — |
| −3 | `runtime.db` を開き、`user-data.db` を `ATTACH` する | −4 の完了 |
| −2 | 両スキーマの `journal_mode` と `synchronous` を設定・検証する（7.1） | −3 の完了 |
| −1 | **両 DB のスキーマ移行を実行する**（下記） | −2 の完了 |
| 0 | **`ProtectedBlobStore` のスキーマ移行を実行する** | −1 の完了 |
| 1 | `UsageLedger` を読み込み、検証し、必要なら修復する（6.3） | 0 の完了 |
| 2 | `ExportCommit` を読み込み、行ごとの署名を検証する | 0 の完了 |
| 3 | **有効なコミットに対応しない `trialReservations` と `sourceLeases` を削除する** | 1・2 の完了 |
| 4 | 有効な未完了コミットを復旧する（下表） | 1・2・3 の完了 |
| 5 | **DB 間参照の整合を検査する**（7.1） | 4 の完了 |
| 6 | `PendingFileDeletion` と孤児ファイルを回収する（7.5） | 5 の完了 |
| 7 | 未受け渡し出力を復元する（7.5） | 5 の完了 |
| 8 | **`evaluateUpdate` を実行する**（6.7） | 7 の完了。`generated` の件数が必要 |
| 9 | `.required` なら更新画面、それ以外は通常画面を表示し、**新しい書き出しを許可する** | 全手順の完了 |

- **手順 −4 を最初に置くのは、`.complete` のファイルがロック中に読めないためです。** DB を開く前に待ちます
- **手順 3 を手順 4 より前に置きます。** 孤児予約はクレジットを占有したままなので、回収前に新しい認可を許可すると、実際には空いているクレジットを「使用中」と判定します
- **手順 5 を手順 4 の後に置きます。** ロールバックが `OutputRecord` を削除するため、先に検査すると存在しない不一致を検出します
- **手順 6 を手順 5 の後に置きます。** ロールバックと孤児削除が `PendingFileDeletion` へ行を追加しうるため、先に GC を走らせるとその回で回収できません
- **署名検証に失敗したコミットに対応する予約と lease は、手順 3 で自動削除しません**（8.6）

##### 2 つの DB の移行は 1 トランザクションで行う

**個別の `DatabaseMigrator` を順に commit しません。** 片方だけ移行が済んだ状態で落ちると、2 つの DB のスキーマバージョンが食い違い、次回起動でどちらを正とするか決められません。

両 DB を変更する移行は、**`ATTACH` 済みの単一トランザクション**で実行します。片方の DB だけを変更する移行は、その DB に閉じたトランザクションで構いません。ただし**移行の版番号は 1 系列で管理し**、どちらの DB を変更したかを記録します。

##### 状態別の復旧

| 中断位置 | 復旧 |
| --- | --- |
| `prepared` | 一時ファイルを削除し、**トライアル予約・`SourceLease`・未参照になった `SourceRecord`** を取り消してコミットを破棄する。生成未完了なので消費しない |
| `fileVerified` | ファイルが健在なら**手順 3 からやり直す**（新しい `finalizedAt` を決める）。失われていればロールバック |
| `finalizing` | 暫定適用があれば冪等に取り消し、**手順 3 からやり直す** |
| `accountingCommitted` | **出力ファイルを再検証**する（下記）。正常なら暫定適用を取り消し、**手順 3 からやり直す** |
| `readyToPublish` | 出力ファイルを `verifiedOutput` と照合する。正常なら暫定適用を取り消し、**手順 3 からやり直す**。不一致ならロールバック |
| 署名検証に失敗 | 復旧エラー。自動破棄しない（8.6） |

**`finalizing` 以降からの復旧は、`readyToPublish` を含めて必ず手順 3 へ戻ります。例外はありません。** `readyToPublish` で異常終了し数日後に再起動した場合、`finalizedAt` は数日前で `expiresAt = finalizedAt + 24h` はすでに過ぎており、**公開した瞬間に期限切れの出力ができます。** ファイル検証が済んでいることと、時刻が妥当であることは別の話です。

再確定のコストは暫定適用の取り消しと再適用だけであり、どちらも `ownerExportID` を根拠とする冪等な操作です。

**`readyToPublish` を無条件に削除しません。** 手順 6 と 7 の間で落ちた可能性があり、**コミット行だけが復旧の手がかり**だからです。この時点では `OutputRecord` がまだ無いため、コミットを消すと出力が孤児ファイルになります。

##### `accountingCommitted` からの復旧

台帳は暫定適用済みなので、**ファイルが失われていれば「消費したのに受け取れない出力」になります。**

| 再検証の結果 | 対応 |
| --- | --- |
| 正常 | 暫定適用を取り消し、手順 3 からやり直す（`OutputRecord` は手順 7 で作る） |
| 欠損・破損 | **このコミットが実際に追加した会計要素だけ**を取り消す（8.4） |
| 取り消し不能 | 復旧エラーとして新規書き出しをブロックする。自動削除しない |

### 8.6 署名不正コミット

`ExportCommit` は DB にありますが、その内容が ProtectedBlobStore の台帳更新を駆動します。**DB を書き換えれば台帳を任意に操作できてしまう**ため、コミット行にも HMAC を付けます（9.1）。

**署名検証に失敗した行を自動破棄しません。** 破棄すると、すでに反映済みの `UsageLedger` だけが残る可能性があります。会計済みかどうかを判断できない以上、**復旧エラーとして扱い**、新規書き出しをブロックしたうえで利用者へ提示します。ファイルも自動削除しません。

##### 復旧エラーの解消

**ブロックしたまま解除手段がないと、破損したコミット 1 件でアプリが永久に書き出し不能になります。** 利用者には「もう一度試す」と「破損した処理を破棄して続ける」を提示します。

「破棄して続ける」の挙動です。

- クォータやトライアルクレジットを払い戻さない
- **台帳側の予約を先に確定させる**（下記）
- 該当の `ExportCommit` を**行 ID で**削除する。**出力ファイルと `OutputRecord` には触れない**
- 復旧エラーを解除し、新規書き出しを許可する

払い戻さないため利用者に不利になりえますが、**破損した DB の情報を根拠に権利を増やす方が危険**です。改ざんによる枠の水増しに直結します。

##### 署名不正行のフィールドを一切使わない

**HMAC 検証に失敗した時点で、その行の全フィールドが信用できません。**

| 改ざん先 | 起こること |
| --- | --- |
| `exportID` を別の正規予約のものへ | **無関係なクレジットを消費させられる** |
| `outputFile` を別の正常な出力へ | 専用ディレクトリ外へは出られないが、**他の正常な出力を削除できる** |
| `projectID` を別の履歴へ | 無関係な履歴を巻き込む |

**復旧の根拠は署名済み `UsageLedger` 側だけとします。** まず、有効な署名済みコミットに対応しない `SourceLease`（孤立 lease）を抽出します。v1 は全体ゲートにより同時 1 件なので、孤立 lease は 0 件か 1 件のはずです。

| 孤立 lease | 処理 |
| --- | --- |
| **0 件** | **台帳を一切変更せず**、署名不正行を DB 内部の行 ID だけで削除する |
| **1 件** | その `exportID` の `TrialReservation` を同じ `sourceID` の `TrialEntry` へ変換し、`SourceLease` を削除する。台帳の保存成功を確認してから、署名不正行を行 ID で削除する |
| **2 件以上** | 対応を一意に決められない。**復旧エラーを維持し、台帳へ触れない** |

**0 件は正常な状態です。** `SourceLease` は手順 4 の台帳トランザクションで削除されるため、`accountingCommitted` / `readyToPublish` / 手順 4 完了後・手順 5 保存前にコミット行だけが壊れた場合、孤立 lease は 0 件になります。0 件は「台帳側にこの書き出しの痕跡が残っていない」ことを意味し、**台帳へ何もしないことが正しい対応**です。会計は既に確定しており、払い戻しは行いません。

2 件以上は全体ゲートが 1 件しか許さないはずの状態と矛盾するため、自動で決めず復旧エラーを維持します。

**1 件の場合に台帳の保存が失敗したら、コミットを削除せず復旧エラーを維持します。** 台帳を確定できていないのにコミットを消すと、次回起動で孤児予約として払い戻されます。

**署名不正行が存在する間は、孤児 `TrialReservation` と孤児 `SourceLease` の自動回収を全件保留します**（8.5 の手順 3）。どの孤児が破損行に対応するかを識別できないためです。

##### ファイルには触れない

署名不正行の `outputFile` と `projectID` は信用できません。`ManagedFileRef` により専用ディレクトリの外へは出られませんが、**同じディレクトリ内の別の正常な出力を指すことは可能です。**

行を削除したあと、その出力ファイルはどこからも参照されなくなります。**起動時の孤児ファイル GC が回収します。** 参照の有無だけを根拠にするため、改ざんされたフィールドの影響を受けません。

`TrialEntry` の `ownerExportID` には対象の `exportID` をそのまま入れます。**その書き出しは成功していませんが、クレジットは消費されたものとして扱います。** 同じ素材を再度処理する場合は `batchTrial(false)` となり追加のクレジットは消費しないため、利用者から見れば「1 枚分の試用機会を使ったが、その素材はまた試せる」状態になります。

### 8.7 出力再生成

ジャーナルを消したあとで `OutputRecord` と実体が食い違うことは、外部要因（OS によるキャッシュ削除、ストレージ障害）で起こりえます。**この経路では `UsageLedger` を変更しません。**

| 状況 | 扱い |
| --- | --- |
| 元素材と設定から再生成できる | 同じ `exportID` の復旧として、**追加消費なしで再生成する** |
| 再生成できない（元素材が削除された等） | 出力を復元できない旨を利用者へ通知し、壊れた `OutputRecord` を削除する |
| 月間枠 / grant / トライアルクレジット | **戻さない** |

**「追加消費なしで再生成する」を既存の `ExportAccountingMode` で実行できません。** どの勘定を選んでも Saga は台帳と履歴を更新し、grant を新規作成または延長し、`OutputRecord` を insert し、`ExportRecord` を追加し、`generatedAt` / `expiresAt` を更新し、キューの成功件数を増やします。

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

**期限切れなら再生成しない**のが要点です。再生成しても即座に削除されるだけであり、「作り直せた」と見せてから消えるほうが体験として悪くなります。この場合は、期限切れであること、および新しい書き出しとして扱われることを提示します。

### 8.8 利用者への受け渡し

- 写真ライブラリへ保存する（`MediaSaver`）
- OS 共有へ渡す（`SharePresenter`）

いずれも任意であり、何度実行しても追加消費しません。失敗した場合は生成済み出力を保持したまま再試行でき、**再書き出しは不要です。** 空き容量不足で保存に失敗しても、空き容量を作って同じファイルを保存し直せます。

##### 共有結果の扱い

「共有シートを開いた」ことは受け渡しの成功ではありません。

```swift
enum ShareResult: Sendable { case completed, canceled, unknown, failed }
```

| 結果 | 出力状態 | 扱い |
| --- | --- | --- |
| `.completed` | `generated` → **`delivered`** | 受け渡し成功 |
| `.canceled` | `generated` を維持 | 利用者が取りやめた |
| `.failed` | `generated` を維持 | 再試行できる |
| `.unknown` | **`generated` を維持** | 安全側へ倒す |

`.unknown` は、共有先アプリが完了を返さない場合に生じます。ここで `delivered` にすると、実際には渡っていない写真を「保存済み」として一時ファイルを消しかねません。**受け取れていない可能性がある側へ倒します。**

##### `ShareLink` では実装できない

**`SharePresenter` は `UIActivityViewController` だけで実装します。** `ShareLink` は共有 UI を提示する `View` であり、**完了結果を返す API を持ちません。** 上の 4 値を返せない以上、`delivered` への遷移条件を判定できません。SwiftUI 標準であることより、結果を取得できることを優先します。

`completionWithItemsHandler` からの写像は次とします。

| 条件 | 結果 |
| --- | --- |
| `activityError != nil` | **`.failed`** |
| `completed == true` | **`.completed`** |
| `completed == false` かつ `activityType == nil` | **`.canceled`**（シートを閉じた） |
| それ以外 | **`.unknown`** |

最後の行が要点です。`completed == false` でも `activityType` が入っている場合は、**共有先アプリが結果を返さなかった**ことを意味します。取りやめとは区別できないため `.unknown` とします。

`UIViewControllerRepresentable` で包み、`CheckedContinuation` で `async` 関数として公開します。

---

## 9. セキュリティとプライバシー

### 9.1 HMAC と正準化

##### 署名の対象と再署名

`ExportCommit` は状態遷移のたびに内容が変わります。初回挿入時の署名を残したまま状態だけ更新すると、正規の更新なのに次回起動で検証失敗になります。

```swift
enum PayloadType: UInt32, Sendable {
    case usageLedger = 1
    case subscriptionState = 2
    case exportCommit = 3
    case remoteConfigState = 4
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
- **`schemaVersion` と `payloadType` を署名対象へ含める**
- `ExportCommit` の insert / update の**たびに再署名する**
- `transact` の保存時にも必ず再署名する
- 検証はバイト列の**定数時間比較**で行う
- マイグレーション時は旧形式で検証してから新形式で再署名する

**`payloadType` を含めないと、種別をまたいだ付け替えを検出できません。** 4 種のデータが同じ鍵で署名されているため、有効な `SubscriptionState` の blob を `UsageLedger` の保存先へ置いても検証を通ります。復号ではなく検証しかしていないため、内容の構造が偶然パースできれば通過します。

##### 正準形は専用エンコーダで作る

**`JSONEncoder` や binary plist を正準形として使いません。** 集合と配列の順序、`Date` の表現、辞書のキー順が実装とバージョンに依存します。**同じ意味の台帳から別の署名が出れば、正規の起動が `integrityFailure` になります。**

| 型 | 符号化 |
| --- | --- |
| 先頭 | `payloadType`（`UInt32`）＋ `schemaVersion`（`UInt32`） |
| 整数 | **ビッグエンディアン**の固定長 |
| `enum` | 固定の `UInt32`（`case` の宣言順に依存させない） |
| 可変長データ | `UInt32` の長さ前置き |
| `Date` | **UTC epoch milliseconds の `Int64`** |
| `Double` | **IEEE 754 の `bitPattern`**（文字列化しない） |
| `UUID` | 16 バイトのビッグエンディアン |
| `Optional` | **`0` / `1` のタグ** ＋ 値（`nil` はタグのみ） |
| `String` | **UTF-8** バイト列 |
| コレクション | **先頭に `UInt32` の要素数**、各要素は長さ前置き |
| **unordered collection** | 各要素を符号化し、**バイト列の辞書順にソート**してから連結 |
| **ordered array** | **元の順序を保持する。ソートしない** |

**順序に意味を持つ配列が存在します。** 一律にソートすると `RenderSpec.regions` の描画順を変え、署名のための正準化が意味を持つデータを壊します。

| 分類 | 対象 | 符号化 |
| --- | --- | --- |
| unordered | `consumedExportIDs`、`sourceRecords`、`grants`、`trialEntries`、`trialReservations`、`sourceLeases`、`SourceRecord.aliases` | **ソートする** |
| ordered | `RenderSpec.regions`、`ReviewIssueID.affectedFaceTrackIDs`、リモート設定内の順序付きリスト | **保持する** |

`affectedFaceTrackIDs` は「辞書順にソート済み」として構築されますが、それは**構築時の規則**であり、正準化がソートするのではありません。順序は値の一部です。

**分類は型に付けます。** unordered な集合は Swift の `Set` として宣言し、`Array` はすべて ordered として扱うのが原則です。`grants` などが `Array` なのは要素が `Hashable` でないためであり、この場合は**エンコーダ側に unordered として明示的に登録します。**

##### 型ごとの符号化順

| 型 | フィールドの符号化順 |
| --- | --- |
| `consumedExportIDs` | 要素（`ExportID` の 16 バイト）を昇順にソート |
| `SourceRecord` | `sourceID` → `aliases`（各 alias を正準バイト順にソート） |
| `SourceAlias` | **case 番号（固定 `UInt32`）** → 値（`String`） |
| `ProjectID` / `BatchID` / `ExportID` / `RegionID` / `SourceID` / `ManagedFileID` | **`UUID` の 16 バイト** |
| `ManagedFileRef` | `kind`（固定 `UInt32`）→ `fileID`（16 バイト） |
| `MonthlyIntegrityLock` | case 番号（固定 `UInt32`）→ 連想値 |
| `GrantEntry` | `sourceID` → `firstSuccessAt` → `ownerExportID` |
| `TrialEntry` | `sourceID` → `ownerExportID` |
| `TrialReservation` / `SourceLease` | `sourceID` → `exportID` |

**`SourceAlias` の case 番号を固定します。** `enum` の宣言順に依存させると、`case` を追加した時点で全台帳の署名が変わります。

##### トップレベル payload のフィールド順

**型ごとの符号化順を決めても、payload そのもののフィールド順が無ければ正準形は一意になりません。**

| payload | `schemaVersion` 1 のフィールド順 |
| --- | --- |
| `UsageLedger` | `period` → `consumedExportIDs` → `sourceRecords` → `grants` → `trialEntries` → `trialReservations` → `sourceLeases` → `lastObservedAt` → `monthlyIntegrityLock` → `lastTrustedMonth` → `trialIntegrityLocked` |
| `SubscriptionState` | `plan` → `status` → `expiresAt` → `willRenew` → `fetchedAt` |
| `ExportCommit` | `exportID` → `projectID` → `batchID` → `sourceID` → `outputFile` → `authorization` → `verifiedOutput` → `finalizedAt` → `finalizedPeriod` → `intent` → `applied` → `state` |
| `RemoteConfigState` | `highestAcceptedVersion` → `acceptedPayloadDigest` → envelope の固定フィールド順 → payload の固定フィールド順 |

**追加は末尾のみ**とし、既存フィールドの順序を変えません。順序を変える必要が生じた場合は `schemaVersion` を上げ、旧バージョンのデコーダを残します。

**リファクタリングで正準形が変わると、既存利用者の台帳がすべて `integrityFailure` になります。** 各 `schemaVersion` について canonical bytes と HMAC 値のゴールデンテストを置きます（11 章）。

##### `RemoteConfig` の値域検証

署名の検証とは別に、内容の整合も確認します（10 章の「設定全体を拒否する」の判定材料）。

- `minimumSupportedVersion <= recommendedVersion`
- `issuedAt <= expiresAt`
- 各閾値が有限（`isFinite`）かつアプリ内の許容範囲内

`contentFingerprint` の正準化（6.4）と同じ方式ですが、**エンコーダは共用しません。** 用途が違えばスキーマ変更のタイミングも違い、片方の変更がもう片方の署名を壊します。

##### 鍵の用途を分離する

| 用途 | 派生ラベル |
| --- | --- |
| 台帳・購入状態・コミット・リモート設定の署名 | `payload-signing-v1` |
| `providerAssetKeyHash` のソルト（6.4） | `source-provider-key-v1` |

`CryptoKeyStore` が保持するマスター鍵から **HKDF** で派生させます。**署名とソルトを分けるのは、性質が違うからです。** ソルトは値の秘匿が目的、署名鍵は完全性の保証が目的であり、同じ鍵を使うと片方の運用（ローテーション等）がもう片方へ波及します。

### 9.2 ログ・分析・診断

**イベント名とフィールド名を、どちらも閉じた集合にします。**

```swift
struct ExportCompletedFields: Sendable {
    let faceCountBucket: FaceCountBucket
    let resolutionBucket: ResolutionBucket
    let planKind: PlanKind
    let accountingMode: ExportAccountingMode
}

struct ExportFailedFields: Sendable {
    let errorCode: AppErrorCode          // 仕様 26.1 の 20 コード
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

**値だけを制約しても不十分です。** イベント名を `String`、フィールドを `[String: 値]` の辞書にすると、機密情報の置き場所が値から**イベント名や辞書のキー**へ移るだけです。**モジュール境界で自由な辞書を受け取りません。** 1 か所でも通せば、そこがすべての制約の抜け道になります。

これにより、仕様 22.5 が禁じるファイル名、パス、顔座標、EXIF、ユーザー入力文字列が**型として渡せなくなります。** 6.6 のドメイン識別子と `ProjectSourceLocator` も、フィールド型にせず `CustomStringConvertible` にも適合させないため、文字列補間としても入りません。

顔数や解像度は仕様 22.3 の粗い区分値（顔数は 0 / 1 / 2〜5 / 6 以上など）としてのみフィールドになります。新しいイベントの追加は `case` 追加と `struct` 定義を伴います。**この手間が、任意文字列を追加しにくくする仕組みそのものです。**

##### エラー型と握りつぶしの禁止

仕様 26.1 の 20 コードを `enum AppError: Error` として表現し、各要素は再試行可否、利用者向けメッセージ、診断フィールドを持ちます。**仕様 26.2 の再試行可否は型の上で表現し、実行時判断に委ねません。**

すべての `catch` 節で `AppError` へ変換したうえで `log` を通すことを規約とします。`try?` による握りつぶしは lint で禁止し、`do / catch` または `Result` で明示的に扱います。

##### クラッシュ解析

Sentry へ送信するのは **クラッシュと未分類例外（`UNKNOWN_ERROR`）のみ**とします。想定内のエラー（広告読み込み失敗、容量不足、保存権限拒否など）は Sentry へ送らず、分析イベントの区分値として計測します。Sentry 無料枠を超過させないためであり、同時にプライバシー面でも正しい方向です。スパイク保護とサンプリングを有効化します。

Sentry Cocoa SDK は `Domain` が定義する `CrashReporter` プロトコルの背後に配置します。送信前フィルタをこの実装へ集約するためです。

**型付き分析イベントによる制約が効くのは、アプリ自身が書くログだけです。** Sentry や診断 SDK は `Logger` を通らずに、例外メッセージ（任意文字列。パスや URL を含みうる）、スタックトレース中のファイルパス、breadcrumbs、HTTP のリクエスト URL とヘッダ、UI 階層やセッション記録、端末情報を独自に収集します。

`CrashReporter` の実装契約として制約を明記します。

| 制約 | 内容 |
| --- | --- |
| 送信前フック | `beforeSend` で**許可フィールドだけを残す**。既定は除去 |
| 例外メッセージ | **任意文字列をそのまま送らない。** 例外の型名と `AppError` のコードへ置き換える |
| パスと URL | ファイルパス、写真ライブラリ ID、URL を除去する |
| 利用者入力 | カスタムスタンプ名などの入力値を送らない |
| 添付 | 画像、添付ファイル、画面キャプチャを**送らない** |
| セッション記録 | UI 階層の収集とセッションリプレイを**有効化しない** |
| breadcrumbs | SDK の自動記録を無効化し、**列挙済みのイベントだけ**を手動で記録する |

例外メッセージを型名とコードへ置き換えるのは、メッセージが最も混入しやすい経路だからです。ファイル入出力の例外は既定でパスを本文に含みます。

##### 送信経路ごとの保証

仕様 28.3 の禁止項目（元ファイル名、ファイルパス、写真ライブラリ ID、正確な顔座標、画像ハッシュ、SNS アカウント名、カスタムスタンプ画像、写真・動画の内容、音声内容）について、経路ごとに保証の根拠が異なります。

| 送信経路 | 保証 |
| --- | --- |
| **アプリが明示的に送る分析イベント** | 型付き `AnalyticsEvent` により、禁止データを**型として渡せない** |
| **クラッシュ解析（Sentry）** | `CrashReporter` の送信前フィルタと許可リストを**別途適用する** |
| **診断送信（`/v1/diagnostics`）** | 型付きリクエストモデルと、サーバー側の未知フィールド拒否（10 章） |

**型付き分析イベントだけでは後 2 者を防げません。**

### 9.3 脅威モデル

##### HMAC が守る範囲

**HMAC が防げるのは改変であって、リプレイではありません。** 過去の正しい署名済み台帳をファイルごと保存しておき、枠を使い切ったあとで書き戻す攻撃は、署名が正当なため検出できません。完全に防ぐにはサーバー照合か端末外の単調増加カウンタが必要ですが、仕様 14.5 は不正利用防止のためだけの端末識別子収集を禁じています。

> **対象とする:** DB の直接編集、値の書き換え、`UsageLedger` / `SubscriptionState` / `ExportCommit` / `RemoteConfigState` の相互の付け替え。
>
> **対象としない:** ルート化 / Jailbreak 済み端末で、過去の正規 blob を丸ごと復元するリプレイ攻撃。

対象外とする根拠は、この攻撃に必要な手間（rootfs へのアクセスと blob の退避）に対して、得られる利益が「月 5 枚の無料枠」であることです。

`lastObservedAt` の単調性は端末時刻の巻き戻しには有効ですが、台帳ごと差し替えられれば一緒に戻るため、リプレイには効きません。

##### 端末時計の変更

`max(now, lastObservedAt)` が防ぐのは、時計を過去へ戻して期限を延長する操作だけです。未来へ進める操作には無力です。

| 影響 | 内容 |
| --- | --- |
| 月間枠 | 先の月へリセットされ、**枠を前倒しで取得できる** |
| 履歴・未受け渡し出力 | **即座に期限切れになる** |
| リモート設定 | 即座に失効する |

> **対象としない:** 端末時計を進めることによる月間枠の前倒し取得。検出手段がサーバー照合なしには存在せず、得られる利益に対して対策のコストが見合いません。
>
> **対象とする:** 時計操作による破壊的削除の誘発。`retentionNow` が `nil` の間は削除を保留します（6.3）。
>
> **対象とする:** 時計操作による整合性封鎖の解除。`MonthlyIntegrityLock` は信頼できる時刻から導出した年月でのみ解除します（6.3）。

**取り返しのつかない方向にだけ保守的に倒します。** 枠の前倒しは利用者に有利で成果物を失いませんが、削除は取り返しがつきません。

##### サーバー側の署名

**端末上の改変は `ProtectedBlobStore` の HMAC で防ぎますが、CDN やバックエンドの侵害には対応しません。** 対応するにはサーバーが設定へ Ed25519 で署名し公開鍵をアプリへ埋め込む方式が必要です。v1 では実装せず、**脅威モデルとして範囲外**と記録します。設定の内容が枠数と表示に限られ、金銭や個人情報へ直結しないためです。

##### 画面スナップショット

履歴サムネイルを加工後にしても、**OS のタスクスイッチャには編集中の未加工画面がそのまま残ります。** プライバシー保護アプリとして最も目につく穴であるため、対策を必須とします。

編集画面がフォアグラウンドから外れる際にプライバシーオーバーレイを表示します（`scenePhase` が `.inactive` へ遷移した時点）。

**スクリーンショットの全面禁止は採りません。** 利用者自身が結果を記録する手段まで塞ぐためです。

---

## 10. リモート設定とバックエンド

自前サーバーは 2 本のエンドポイントのみとします（ADR 0004）。

| エンドポイント | 内容 |
| --- | --- |
| `GET /v1/config` | Free 月間書き出し数、一括処理上限、トライアルクレジット数、トリアージ閾値、履歴の容量上限、カスタムスタンプの保存解像度、有効なスタンプパック、広告表示頻度、**更新誘導**（`minimumSupportedVersion` / `recommendedVersion` / `appStoreID`。6.7）、障害中の機能停止フラグ |
| `POST /v1/diagnostics` | 利用者が明示的に同意した場合のみ受信 |

実装は Rust + Axum。`/v1/config` は静的 JSON と ETag による配信とします。

### 10.1 診断エンドポイント

仕様 21.3 の送信禁止データは、**送信経路を持たせないこと**で担保します。

```rust
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]      // 未知フィールドを拒否する
pub struct DiagnosticsRequest {
    pub schema_version: u32,
    pub app_version: String,
    pub os: OsKind,                // 列挙。自由文字列ではない
    pub os_version: String,
    pub error_code: AppErrorCode,  // 列挙（9.2）
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

**`serde(deny_unknown_fields)` を必須とします。** 既定の serde は未知フィールドを黙って捨てるため、クライアント側の不具合で自由文字列が送られても気づけません。拒否すれば送信側の実装ミスが 400 として即座に露見します。

`String` を許すのは `app_version` と `os_version` だけで、いずれも形式を正規表現で検証します。9.2 のクライアント側フィルタとこの型定義の**両方**で防ぎます。片方だけでは、もう片方の実装ミスを吸収できません。

| 項目 | 規約 |
| --- | --- |
| リクエストサイズ上限 | **8KB**。超過は 413 |
| レート制限 | **IP 単位で 10 件 / 分**。超過は 429 |
| 保存期間 | **30 日** |
| 自動削除 | 保存期間を過ぎた行を日次で削除する |
| 同意撤回後 | **送信しない。** 撤回時点でクライアント側の送信キューも破棄する |
| サーバーログ | **リクエスト本文を出力しない。** アクセスログはメソッド・パス・ステータス・所要時間のみ |

**サーバーログへ本文を出さないことを明記します。** アプリ側で許可フィールドだけに絞っても、サーバーが本文をログへ流せば、そのログが第 2 の収集経路になります。ログ基盤の保持期間はアプリの設計と無関係に決まるため、ここで塞ぎます。

**同意撤回後にキューを破棄するのは、送信前のデータが端末に残るためです。** オフライン時に貯めた診断を撤回後に送るのは同意の趣旨に反します。

### 10.2 リモート設定の検証とキャッシュ

`/v1/config` は無料枠、トライアル枚数、一括処理上限、並列数、トリアージ閾値、広告頻度、最低バージョン、機能停止フラグを変更できます。**壊れた値や古い値をそのまま適用すると、アプリ更新なしで全利用者を壊せます。**

```swift
struct RemoteConfigEnvelope: Sendable, Decodable {
    let schemaVersion: Int
    let configVersion: Int64
    let issuedAt: Date
    let expiresAt: Date
    let payload: RemoteConfig
}
```

| 状況 | 扱い |
| --- | --- |
| `schemaVersion` が未知 | **設定全体を拒否する** |
| 数値がアプリ内の許容範囲外 | **その設定全体を拒否する**（該当項目だけ捨てない） |
| enum に未知の値がある | **設定全体を拒否する** |
| `configVersion` > `highestAcceptedVersion` | 検証を通れば**受理する** |
| `configVersion` == `highestAcceptedVersion` かつ **canonical payload が同一** | **無視する**（同じ設定の再配信） |
| `configVersion` == `highestAcceptedVersion` かつ **内容が異なる** | **拒否する**（下記） |
| `configVersion` < `highestAcceptedVersion` | **拒否する**（ロールバック攻撃と配信事故の両方を防ぐ） |
| 取得失敗 | 最後に検証成功した設定（last-known-good）を使う |
| last-known-good も無い | **バンドル済みの既定値**を使う |
| `expiresAt` を過ぎた設定 | **機能停止フラグ以外をバンドル既定値へ戻す** |

**部分的に採用しません。** 「この項目だけ範囲外だから既定値で埋める」を許すと、配信された設定の一部と既定値が混ざった、テストされていない組み合わせが動きます。全体を拒否すれば、動くのは「配信された設定」か「既定値」のどちらかだけです。

**期限切れで機能停止フラグだけを残すのは、それが障害対応の手段だからです。** サーバーが落ちている間に機能停止を解除すると、止めたかった機能が動きます。逆に上限値や閾値は、古い値を使い続けるより既定値のほうが安全です。

**同一 `configVersion` での内容差し替えを拒否します。** 配信事故（内容を上げてバージョンを上げ忘れた）と意図的な差し替え（CDN やバックエンドの侵害）は、どちらも「バージョンは同じなのに内容が違う」という形で現れます。**正常な配信では起こりえない状態です。**

判定には canonical payload を使います（9.1 のエンコーダ）。JSON の文字列比較では、キー順や空白の違いで誤って「変更あり」になります。**運用側の規約として、内容を変更するときは必ず `configVersion` を増加させます。**

##### 時刻の表現形式

**`Date` を `JSONDecoder` の既定に任せません。** 既定は `.deferredToDate`（Apple の参照日からの秒数）であり、Rust 側の出力形式と一致しません。誤ってデコードされれば、設定が即座に期限切れになるか永久に期限切れにならないかのどちらかです。

| 項目 | 規約 |
| --- | --- |
| 形式 | **UTC epoch milliseconds の `Int64`** |
| Swift 側 | `JSONDecoder.dateDecodingStrategy = .millisecondsSince1970` を明示指定する |
| Rust 側 | `i64` として出力する（`serde` の既定表現に任せない） |
| タイムゾーン | UTC 固定。オフセット付き文字列を使わない |

`/v1/diagnostics` の `occurred_at` と同じ形式です。**アプリとサーバーの間で時刻表現を 1 つに統一します。** RFC 3339 UTC 文字列も候補ですが、パーサの差（小数秒の桁数、`Z` と `+00:00`）が残るため採りません。

##### キャッシュを保護する

リモート設定は無料枠、トライアル枚数、一括上限、スタンプ上限、広告頻度、強制更新、機能停止を変更できます。**キャッシュを `UserDefaults` や平文ファイルへ置けば、利用者が値を書き換えて無料枠を増やせます。** `UsageLedger` を HMAC で保護しても、判定に使う上限値そのものが改変可能なら意味がありません。

```swift
struct RemoteConfigState: Sendable {
    let highestAcceptedVersion: Int64
    let acceptedPayloadDigest: Data      // その版の canonical payload の SHA-256
    let lastKnownGood: RemoteConfigEnvelope
}
```

| 規則 | 内容 |
| --- | --- |
| 保存 | HTTPS 取得と検証に成功した後、`ProtectedBlobStore` へ HMAC 付きで保存する |
| 署名対象 | **`highestAcceptedVersion` も含める**（バージョンだけ下げる改変を防ぐ） |
| HMAC 不一致 | **バンドル既定値へ戻す。** 改変された値で動かさない |
| `expiresAt` の判定 | **`retentionNow` を使う**（`nil` の間は失効させない） |
| `appStoreID` | **数字のみの形式検証**（任意の URL を差し込ませない） |
| 強制更新 | **キャッシュの改変から `.required` を発生させない。** HMAC 不一致なら既定値＝更新なし |

**最後の行が重要です。** キャッシュを書き換えて `minimumSupportedVersion` を上げれば、他人の端末でアプリを止められます。HMAC 不一致を既定値へ倒すことで、改変は「更新なし」にしかなりません。

### 10.3 リモート設定で変更できないこと

**次はリモート設定から無効化できません。** 安全性の中核であり、サーバー側の事故や侵害で外せる状態にしません。

- 6.5 の確認画面（`reviewRequired` の解消なしに書き出せない）
- 6.1 の全顔初期マスク
- 8.3 のファイル検証（サイズ・SHA-256・デコード）
- 8.3 のコミットジャーナルと最終確定境界
- 5.3 の未解決 `bitmapID` によるエラー
- 6.7 の「未受け渡し出力があるときは受け渡し導線を先に出す」

**これらに対応する設定キー自体を `RemoteConfig` に持たせません。** 「フラグはあるが既定で有効」ではなく、**フラグを存在させない**という形にします。

**更新誘導は逆方向の扱いです。** `minimumSupportedVersion` はリモートから変更できますが、**取得に失敗した場合の既定は「更新なし」**です。バンドル既定値にも強制更新は含めません。

**一括処理の同時並列数は、アプリが対応を宣言した最大値を超えません。** リモートで 8 を指定されても、アプリ側の上限（v1 は 2）でクランプします。並列数は実装が想定するメモリ使用量と直結するため、サーバーから引き上げられる形にしません。

### 10.4 障害時

リモート設定の取得に失敗した場合はアプリ内の安全な既定値を使用します。**バックエンド障害で編集処理を停止させません**（仕様 21.6）。

---

## 11. テスト戦略

**「純粋な判定」と「実ストレージの原子性」と「プロセス強制終了後の状態」は、同じ層では検証できません。** 前 2 者を混ぜると、判定のテストにシミュレータが要るようになり、実行が遅くなって回されなくなります。

四層へ分けます。フレームワークは **Swift Testing**（`@Test`）を使い、UI テストのみ XCTest とします。

| 層 | 実行環境 | 保証する内容 |
| --- | --- | --- |
| **domain unit test** | `swift test`（数秒。シミュレータ不要） | 純粋関数と状態機械。クォータ、トリアージ、座標変換、`compileRenderDraft`、正準化 |
| **application saga test** | `swift test`（数十秒） | 偽 DB・偽 `ProtectedBlobStore`・偽ファイルによる**各中断点**の挙動 |
| **adapter integration test** | シミュレータ / 実機 | 実 GRDB、実 保護ファイル、実 Keychain、Vision、Core Image |
| **process-death fault injection test** | **実機** | **各手順の直後に強制終了**し、再起動後の状態を検証 |

**各項目は、検証が成立する最も低い層へ置きます。** 個別のテスト項目は `docs/test-plan.md` が正本です。

### 11.1 必須とする保証

##### コミット Saga への障害注入（実機）

**偽ストアの saga テストは「順序どおりに書けば整合する」ことしか示しません。** GRDB のトランザクションが実際に原子的か、`replaceItemAt` が中断で切れないか、同期のタイミングはどうか — これらは実装と OS の性質であり、偽物では検証できません。

**シミュレータではなく実機を使います。** シミュレータのファイルシステムは macOS のものであり、iOS のストレージスタック（データ保護クラス、ジャーナリングの挙動）と一致しません。強制終了の再現も、シミュレータではプロセスの kill にしかならず、jetsam の挙動と異なります。

| 手段 | 用途 |
| --- | --- |
| テスト用フックによる **`_exit(1)`** | 各手順の直後で決定的に落とす。`exit(0)` は正常終了であり `atexit` ハンドラやバッファのフラッシュが走るため、クラッシュ境界の検証にならない |
| 外部プロセスからの `SIGKILL` | シグナルハンドラを経由しない終了 |
| メモリ圧迫によるジェッツァム | 実運用に最も近い経路。一括処理 50 枚で再現する |

**強制終了フックはテスト専用ビルドにのみ含めます。** コンパイル条件（`#if DEBUG_FAULT_INJECTION`）で分離し、リリースビルドに含まれないことを CI で確認します。

##### HMAC canonical bytes のゴールデンテスト

各 `schemaVersion` について、固定の canonical bytes と HMAC 値をテストへ埋め込みます。**リファクタリングで正準形が変わると既存利用者の台帳がすべて `integrityFailure` になり、単体テストで気づけなければリリース後に発覚します。**

##### Core Image 出力のゴールデン画像テスト

同じ `RenderSpec` から生成したプレビュー用と原寸用の出力が一致することを検証します。**素材には上端のみ・下端のみに顔があるものを含めます。** 上下の非対称性は Y 軸反転の誤りが最も現れやすい形であり、中央に顔がある素材では反転しても差が出ません。

##### 実ストレージを使う integration test

**プロトコル適合テスト**として、各プロトコルに対し実装と偽実装の**両方へ同じスイート**を実行します。偽実装が本物と違う挙動をすると saga テストが無意味になるためです。

### 11.2 検出品質

仕様 30.2 の検出条件は、**合否判定ではなく検出率の回帰監視**として計測します。仕様 34.5 が「完全自動を約束しない」と定めている以上、閾値でビルドを落とすのは不適切です。

同じ素材セットで要確認率も計測します。要確認率が高すぎると Pro の価値が失われ、低すぎると見落としが増えます。`extremePose` の角度閾値と `lowConfidence` の信頼度閾値はこの計測から決めます（5.1 の受入条件）。

**iOS のバージョン更新で Vision の検出特性が変わることがあり、閾値の妥当性が崩れます。** 前リリースとの差が一定以上に開いた場合は閾値を見直します。

### 11.3 プライバシーとアクセシビリティ

プライバシーの受入テストとして、履歴一覧に未加工の顔が現れないこと、タスクスイッチャに未加工画面が残らないこと、アプリ専用領域に元画像の永続コピーが残らないこと、出力ファイルからメタデータが除去されていることを明示的に検証します。

アクセシビリティは仕様 29 章を受入条件とします。SwiftUI の `Canvas` は既定でアクセシビリティ要素を持たないため、`accessibilityLabel` / `accessibilityValue` / `accessibilityRepresentation` の明示的な付与が必須です。

実機マトリクスは仕様 30.8 に従います。

---

## 12. リリース範囲と未決事項

### 12.1 v1 に含めるもの

- 写真の選択、顔自動検出、隠す顔と残す顔の指定、手動領域追加
- モザイク、ぼかし、黒塗り、スタンプ（ベクター自作）、カスタムスタンプ登録
- 出力比率（元比率 / 1:1 / 4:5 / 9:16）、背景ぼかし、メタデータ設定
- 写真ライブラリ保存、OS 共有
- Free / Standard / Pro の 3 プラン、購入復元
- **Pro の一括処理（1 バッチ 50 枚）、トリアージ、2 つの確認モード、処理キュー、一括設定プリセット、バッチ履歴**
- **一括処理トライアル（全プラン共通。月間枠とは別勘定の 5 枚クレジット）**
- 広告（Free のみ）
- ローカル履歴、保存期間設定、エラー復旧、アプリ更新の誘導

### 12.2 v1 に含めないもの

- **利用者向けの動画選択・編集・書き出し機能**
- 4K 出力（写真は元解像度維持のため差別化要因にならない）
- カスタムスタンプの自動背景除去

**「動画に関する一切の機能」とは書きません。** 5.6 のとおり、v1 では動画用のモデル・契約・補間関数を内部実装します。除外するのは利用者から見える機能です。

##### 動画の扱い

**v1 では動画を一切露出させません。** ピッカーは画像限定とします（`PHPickerFilter.images`）。

- App Store Review Guideline 2.1（App Completeness）はプレースホルダや未完成コンテンツをリジェクト対象としており、「動画は次回対応」という導線がこれに該当しうる
- 無料アプリで「選べるのに使えない」は低評価レビューの典型的原因であり、初期レビューは母数が少ないぶん平均点への影響が大きい
- ピッカーを画像限定にする方が、動画を出して選択後に弾くより分岐とエラー導線が少ない

**この結果、v1 では素材の種類選択が不要になります。** v1 の単体処理フローは `ホーム → 写真を選ぶ → 顔検出 → 加工 → 書き出し` です。種類選択は動画を追加する v2 で初めて導入します。

**設定画面に「今後のアップデート予定」セクションは置きません。** 写真アプリとして満足している利用者に未完成という印象を与え、**動画目的の利用者が対応まで課金を控える**ためです。需要はストアレビュー、問い合わせ、動画対応後の告知反応で測ります。

### 12.3 課金訴求の分類

**Paywall で動画の制限や 4K 出力を訴求してはいけません。** 存在しない機能を根拠にサブスクリプションを販売することになり、App Store Review Guideline 3.1.2 が求める「契約期間中に実際に提供される価値」の要件に反します。

Pro の説明は機能の列挙ではなく体験として記述し、**一枚ずつ編集画面を開く必要がないことが価値である**ことを示します。確認そのものが不要になるとは書きません（6.1 のトリアージの限界）。横断的な人物判定はできないため、説明文でこれを誤解させないことも制約とします。

`UpgradeReason` は v1 では以下に限定します。

| 分類 | 発火条件 | 誘導先 |
| --- | --- | --- |
| `export-limit` | Free の月間枠を使い切った（`blocked(.monthlyLimitReached)`） | Standard |
| `ledger-blocked` | 台帳の整合性検証に失敗し Free 枠が封じられている（`blocked(.ledgerIntegrityFailure)`） | Standard |
| `premium-stamp` | 追加スタンプを選ぼうとした | Standard |
| `custom-stamp` | カスタムスタンプを使おうとした | Standard |
| `edit-locked` | **有料スタンプを含む**既存作品を編集しようとした（6.2） | Standard |
| `batch-credit` | Free / Standard が残クレジットを超える**新しい写真**を選ぼうとした。または残 0 枚かつ消費済み台帳が空で一括処理へ入ろうとした | Pro |
| `batch-size` | Free / Standard が**総数 5 枚**を超えようとした | Pro |
| `batch-limit` | Pro が**総数 50 枚**を超えようとした | 誘導なし。上限の通知 |

`batch-standard`（Standard が通常の一括処理を開いた）は設けません。その状況は「残クレジット 0 かつ台帳が空」と同じであり `batch-credit` が受けます。動画対応時に `long-video` と `export-4k` を追加します。

**v1 では利用者向けの表現を「写真」に統一します。** 内部モデルは `Media` のままとし、動画追加時に「写真・動画」または「素材」へ変更します。

### 12.4 上位仕様書からの逸脱

| 仕様書 | 仕様書の内容 | 本設計 | 理由 |
| --- | --- | --- | --- |
| 4.2 / 32.1 | iOS / Android の二本立て | **v1 は iOS 単独。** Swift + SwiftUI | ADR 0001 |
| 4.1 | 対応 OS の下限を明示していない | **iOS 26 以降** | ADR 0001 |
| 12.7 | カスタムスタンプ上限 Standard 30 / Pro 100 | 両プラン 100 | 差別化として機能せず、Pro の焦点をぼかす |
| 13.8 | 撮影日時を削除対象に含む | EXIF 日時は既定で保持。ライブラリ登録日時は取得できる場合に引き継ぐ | 7.5。日時削除は写真アプリの並び順を壊す |
| 14.2 | 消費条件の解釈 | 「利用可能な加工済み出力の生成が完了した時点」＝手順 7。写真ライブラリ保存時点ではない | 8.3。保存せず OS 共有だけで無料枠を回避できる経路を塞ぐ |
| 16.3 | 一括処理モードは「全顔を同じ方法で隠す」「素材ごとに確認する」 | 「おまかせ一括」「1 枚ずつ確認」。どちらでも全写真に一度は目を通す | 6.5。トリアージは検出漏れを判定できない |
| 18.4 | 保存上限は 100 プロジェクト | 件数上限を撤廃し、保存期間（既定 30 日）と使用容量上限（既定 200MB）で管理 | 7.5。1 バッチ 50 枚に対して 2 バッチで枯渇する |
| 20.3 | 原子的書き出しの第 4 段階を「写真ライブラリへ保存する」とする | 生成と受け渡しの 2 段階に分離。生成の完了は手順 7 | 8.3 |
| 21.5 | `/v1/installations` と購入検証 API | 実装しない | ADR 0004 |
| 32.1 | 初回リリース必須機能に動画を含む | v1 では動画を含めない | 12.2。段階リリース |

### 12.5 未決事項

| 項目 | 内容 | 決定時期 |
| --- | --- | --- |
| 商品 ID | 仕様 27.1 の商品 ID は暫定 | ストア登録時 |
| App Store ID | 更新誘導のリンク先に必要（6.7） | ストア登録時 |
| `lowConfidence` の閾値 | `FaceObservation.confidence` の下限。実素材の分布を見て決定（5.1 / 6.1） | v1 実機検証時 |
| `extremePose` の角度閾値 | yaw / pitch の絶対値の上限。検出品質テストの結果から決定（6.1） | v1 実機検証時 |
| プライバシーポリシーの記載 | トライアル台帳（`SourceRecord`）を期限なく端末内へ保持することを記載し、7.5 の例外と整合させる | ストア申請前 |
| 共有結果 `.unknown` 後の利用者操作 | `generated` を維持するため、共有後に画面を離れると未保存の確認が出る。明示確認して `delivered` にするか、`generated` のまま保存・再共有・破棄を選ばせるか（8.8） | 実装計画で確定 |
| 基本スタンプの意匠 | ベクターで自作する 12〜20 種の具体的な図案 | v1 実装中 |
| 履歴の使用容量上限 | 初期値 200MB は暫定。加工後サムネイルの実サイズを計測して確定 | v1 実装中 |
| カスタムスタンプの保存解像度 | 長辺 1,024px は暫定。顔が大きく写る素材での見え方を実機で確認（7.5） | v1 実機検証時 |
| トライアルのクレジット数 | 5 枚は暫定。転換率を見て調整可能な設定値とする | リリース後 |
| 一括処理の同時並列数 | 初期値は 1。写真のみのため 2 まで許容可能だが実機計測後に判断 | v1 実機検証時 |
| ファイル同期の方式 | `F_FULLFSYNC` と通常の `fsync` の所要時間差を実機計測し、耐久性とのつり合いで決定（7.1） | v1 実機検証時 |
| 手順 7-b の再確認しきい値 | `usageNow - finalizedAt` の許容差 5 分は暫定。手順 3〜7 の実測時間から確定（8.3） | v1 実機検証時 |
| 信頼できる時刻の取得元 | `retentionNow` と `MonthlyIntegrityLock` の解除に使う時刻を、`/v1/config` のレスポンスヘッダから取るか RevenueCat の `CustomerInfo` から取るか（6.3） | 実装計画で確定 |
