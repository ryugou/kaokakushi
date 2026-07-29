# 顔かくし アーキテクチャ設計

| 項目 | 内容 |
| --- | --- |
| 対象 | 写真向け顔匿名化アプリ（**iOS 単独**） |
| バージョン | 4.0 |
| 上位文書 | 写真・動画向け顔匿名化アプリ 仕様書 v0.1 |
| この文書の役割 | 全体の構成と、モジュール・ドメイン・永続化・セキュリティの正本 |

**この文書が親文書です。** 各領域の正本は下表の文書にあり、ここには要約と参照だけを置きます。

## 関連文書

| 文書 | 扱う責務 |
| --- | --- |
| **本書** | 目的、技術スタック、モジュール構成と依存方向、並行性、ドメインモデル、永続化、セキュリティ境界、リモート設定、テスト戦略、逸脱と未決事項 |
| [画像処理アーキテクチャ](image-pipeline.md) | `RenderSpec` / `RenderDraft` / `RenderPlan`、座標・色・合成規約、スタンプラスタライズ、写真選択の境界型 |
| [書き出し Saga](export-saga.md) | 認可、`ExportCommit` の状態、手順 0〜7、ロールバック、起動時復旧、実体喪失時の扱い、受け渡し |
| [正準スキーマ](canonical-schema.md) | HMAC 署名対象のバイト表現、型ごとのフィールド順、`enum` の固定番号 |
| [運用](operations.md) | 更新誘導の運用、審査への配慮、リモート設定の配信規約、診断と Sentry の運用制約 |
| [商品面の決定](product-decisions.md) | v1 のリリース範囲、動画の扱い、課金訴求の分類、利用者向け表現 |
| [実装計画](implementation-plan.md) | サブプロジェクトへの分解、依存、モジュール割り当て |
| [テスト計画](test-plan.md) | 層ごとの個別テスト項目 |
| [ADR](adr/) | 技術選定とその理由 |

**推奨読書順**

1. 本書の 1〜4 章（目的、技術スタック、モジュール境界、並行性）
2. 本書の 5〜6 章（ドメインモデル、永続化）
3. [画像処理アーキテクチャ](image-pipeline.md)
4. [書き出し Saga](export-saga.md) → [正準スキーマ](canonical-schema.md)
5. 本書の 9〜11 章（セキュリティ、リモート設定、テスト戦略）

**文書間の依存**

```
architecture.md（型と境界の正本）
  ├─→ image-pipeline.md   （RenderSpec 系の正本。architecture の ManagedFileRef に依存）
  ├─→ export-saga.md      （手順と状態の正本。architecture の UsageLedger に依存）
  │     └─→ canonical-schema.md（バイト表現の正本）
  ├─→ operations.md       （運用規則。architecture の判定結果に依存）
  └─→ product-decisions.md（商品面の決定。architecture の能力判定に依存）
```

---

## 1. 目的・前提・対象範囲

### 1.1 本書の役割

本書は **実装時に参照する現在の設計** を定めます。型、不変条件、状態遷移、処理順、障害時の挙動を一意に決めることが目的です。

**挙動の定義については本設計が正であり、`ui-mock/` は本設計に追従します。** モックのコードは実装へ流用しません。

上位仕様書からの逸脱は 12.1 に集約します。

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
| 共有 | `UIActivityViewController`（[書き出し Saga](export-saga.md)） |
| 署名鍵の保管 | Keychain（**鍵のみ**） |
| 署名付きデータの保管 | アプリ専用ディレクトリ上のファイル（HMAC 付き、原子的置換） |

**鍵とデータ本体を分けます。** Keychain は台帳のような可変データを繰り返し置き換える用途に向きません。`UsageLedger` や `SubscriptionState` の本体はファイルへ置き、Keychain の鍵で HMAC を付けます。`CryptoKeyStore`（鍵）と `ProtectedBlobStore`（署名付きデータ）の 2 プロトコルに分けます。

**`ImageRenderer`（SwiftUI）ではなく `CGContext` を使います。** `ImageRenderer` は `@MainActor` に隔離されており、一括処理 50 枚のラスタライズを直列化します。`CGContext` はバックグラウンドで実行でき、ピクセル形式とストライドも明示できます（[画像処理](image-pipeline.md) の規約に必要）。

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
│   ├── Selection/           PhotoSelectionBridge / FileSelectionBridge（[画像処理](image-pipeline.md)）
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
| 例外の範囲 | `PhotoSelectionBridge` と `FileSelectionBridge` の 2 型のみ（[画像処理](image-pipeline.md)） |
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

**`CGSize` や `CGRect` も使いません。** 必要な値型は `PixelSize` / `PixelRect` / `NormalizedRect` としてドメイン側で定義します（[画像処理](image-pipeline.md)）。`CoreGraphics` の型を持ち込むと、暗黙に「原点は左下か左上か」といった描画系の前提が混入します。

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

##### 登録前キャンセルを取りこぼさない

**キャンセルハンドラがキューから削除するだけでは足りません。** 次の順序が起こりえます。

```
1. waiter ID を作る
2. タスクがキャンセルされ、キャンセルハンドラが動く
3. まだ登録されていないので、削除対象が無い
4. その後 continuation がキューへ登録される
5. 二度目のキャンセル通知は来ない → キャンセル済み waiter が残る
```

**actor 内部に tombstone を持ちます。**

```swift
actor FileUsageLedgerStore: UsageLedgerStore {
    private var waiters: [Waiter] = []            // FIFO
    private var canceledWaiterIDs: Set<UUID> = [] // 登録前キャンセルの記録
}
```

| 契機 | 操作 |
| --- | --- |
| キャンセルハンドラ | キューに居れば除去して resume。**居なければ `canceledWaiterIDs` へ記録する** |
| enqueue 時 | `canceledWaiterIDs` に自分が居るか、`Task.isCancelled` が真なら、**登録せず即座に `CancellationError` で resume する** |
| 記録の掃除 | resume した時点で `canceledWaiterIDs` から除く |

**`Task.isCancelled` の確認だけでは不足です。** `withTaskCancellationHandler` の登録と `Task.isCancelled` の読み取りの間にもキャンセルは起こりえます。tombstone と併用して、どちらの経路でも捕捉します。

##### 二重 resume の防止

キャンセルと permit 解放が競合すると、同じ continuation を 2 回 resume してクラッシュします。actor 内部で次の順に行います。

1. **waiter ID をキューから原子的に除去する**
2. **除去できた場合だけ** `CancellationError` で resume する
3. permit 解放側は、キューの先頭から取り出す時点で存在を確認し、既に除去済みの waiter を resume しない

「除去できたか」を resume の条件にすることで、どちらの経路が先に走っても resume は 1 回に収まります。**登録前キャンセルの経路でも、tombstone を確認した側だけが resume します。**

**`CancellationError` は業務エラーとして扱いません。** Sentry へ送らず（9.2）、キュー項目を `canceled` へ遷移させる制御フローとします。

##### キャンセルの境界

| 時点 | 扱い |
| --- | --- |
| 手順 4 より前 | ロールバック。消費なし |
| 手順 4 以降・手順 7 より前 | 暫定会計を取り消してロールバック（[書き出し Saga](export-saga.md)） |
| 手順 7 の完了後 | **キャンセルではなく破棄として扱う。** 枠は戻さない |

手順 7 が完了した時点で成果物は公開されており、正常生成が確定しています。UI 上も、手順 7 の完了後は取り消せるかのような文言にしません。

### 4.3 Application 層

次の処理は `Domain`（純粋 Swift）にも `App`（SwiftUI）にも置けません。

- 書き出しの手順 −2〜7（[書き出し Saga](export-saga.md)）と補償トランザクション
- 起動時復旧、ロールバック
- DB・台帳・ファイルの協調、ゲートの取得と解放
- 出力の受け渡し

`App` の `View` や状態オブジェクトへ置くと **UI 状態と永続化 Saga が結合し**、画面を離れたら復旧処理が止まる経路ができます。`Domain` へ置くと副作用と `await` が入り、純粋 Swift の制約が壊れます。

```swift
// Application — Domain のプロトコルだけを使う
actor ExportCoordinator { }           // 手順 −2〜7、ロールバック
actor StartupRecoveryCoordinator { }  // 起動時復旧（[書き出し Saga](export-saga.md)）
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


## 5. 画像処理

**正本は [画像処理アーキテクチャ](image-pipeline.md) です。** ここには境界の要約だけを置きます。

**エフェクトの数学をすべて `Domain` に置き、`MediaKit` には描画プリミティブのみを残します。** 目的は、エフェクトの計算をシミュレータなしでテストできる状態に保つことです。

```
MediaKit   Vision で顔検出 → DetectedFace（正規化座標・角度・信頼度）
    ↓
Domain     拡張率適用、形状決定 → RenderSpec（正規化座標・相対強度）
    ↓
Domain     compileRenderDraft(spec, sourceSize, targetSize) → RenderDraft（絶対ピクセル）
    ↓
Rendering  StampRasterizer で一括ラスタライズ
    ↓
Domain     bindRasterAssets(draft, assets) → RenderPlan
    ↓
MediaKit   4 プリミティブのみ実行（マスク内モザイク / ぼかし / 単色塗り / 画像貼り付け）
```

| 不変条件 | 内容 |
| --- | --- |
| 永続化の対象 | `RenderSpec` だけ。ピクセル座標は保存しない |
| `RenderPlan` の座標 | **絶対ピクセルのみ。** 正規化座標を 1 つも持たない |
| `MediaKit` の責務 | 比率計算を一切行わない |
| 検証済み値型 | `RenderOpSpec` / `RenderOp` / `RenderOpDraft` に生の `Double` を持たない |
| 未解決のラスタ | `bindRasterAssets` が `throw` する。描き飛ばさない |
| 境界型 | 実体の参照は `ManagedFileRef` のみ。`URL` もパス文字列も持たない |

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
    case lowConfidence       // 検出信頼度が閾値未満（[画像処理](image-pipeline.md)）
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

**この節は単体処理に限ります。** 一括処理の顔 0 件は `noFaceDetected` と勘定の規則（[書き出し Saga](export-saga.md)）に従います。

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
    let lastVerifiedAt: Date     // 権限を検証できた時刻
}

/// ProtectedBlobStore へ保存する購入状態キャッシュ
struct SubscriptionState: Sendable, Equatable {
    let entitlement: Entitlement
    let willRenew: Bool
    let fetchedAt: Date          // RevenueCat から取得に成功した時刻
}
```

**`fetchedAt` と `Entitlement.lastVerifiedAt` は別の値です。** 前者はキャッシュを書いた時刻、後者は権限を検証できた時刻で、オフライン時にキャッシュを読み直しても後者は動きません。

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
| `temporarilyUnavailable` | 上書きせず再試行する。**メモリ上に検証済みの `Entitlement` があれば維持し、無ければ `verificationRequired`**（下記） |

- 取得に成功すればキャッシュを置き換える
- **オフラインで再取得できない場合、有料権限を新規に付与しません**
- **カスタムスタンプ、履歴、プリセットなどのデータは削除しません**
- 利用者へは購入状態を確認できない旨を提示し、**再試行**と**購入の復元**への導線を出す

**コールドスタートでは維持する値がありません。** プロセス起動直後はメモリ上の `Entitlement` が存在しないため、「既存を維持する」が成立しません。

| 状況 | 扱い |
| --- | --- |
| メモリ上に検証済みの `Entitlement` がある | **維持する**（セッション中の一時障害） |
| 無い（コールドスタート） | **`verificationRequired`。** 書き出しを開始せず、再試行を提示する |

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

**「変更せず再書き出し」は、アプリ提供の追加スタンプとカスタムスタンプを同一に扱います。** 規則を分けると「どちらのスタンプを使ったか」で挙動が変わり、説明できなくなります。有料スタンプを含むプロジェクトにおいて、エフェクト・強度・領域・出力設定のいずれかを変更した時点で Standard 以上が必要になります。Free 範囲のプロジェクトではこの判定を行いません。

##### 比較対象を署名済み台帳へ持つ

**現在の設定ハッシュを何と比べるかが要ります。** 比較対象は「最後に正常書き出しした設定」ですが、**未署名の DB 行へ置くと、書き換えるだけで変更後のプロジェクトを「変更なし」にできます。**

`UsageLedger` と同じ `ProtectedBlobStore` の署名対象へ持たせます。

```swift
/// UsageLedger の一部。正常書き出しで確定した設定を素材ごとに保持する
struct ExportedSettingsEntry: Sendable, Equatable {
    let projectID: ProjectID
    let settingsHash: ProjectSettingsHash
    let exportedAt: Date
}
```

| 契機 | 操作 |
| --- | --- |
| 手順 7 の完了 | **同じ台帳トランザクションでは書けない**ため、手順 4 の `AccountingIntent` へ含めて暫定適用し、手順 7 の完了で確定扱いとする |
| 判定 | `currentSettingsHash == entry.settingsHash` |
| entry が無い | **「変更せず再書き出し」の対象にしない。** Standard 以上を要求する |
| `Project` の削除 | 同じ台帳トランザクションで entry も削除する |

**最初の正常書き出し記録が無いプロジェクトは対象外です。** 有料スタンプを含むプロジェクトが Free 環境で初めて現れる経路（バックアップ復元など）は存在しないため（7.4）、実際には降格前に必ず 1 回は書き出しています。

要素数は `grants` などと同じく有界です。履歴の保存期間を超えた `Project` の entry は `rollPeriod` で整理します。

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
    let year: Int32
    let month: Int32        // 1...12。端末の TimeZone で算出する
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
    let lastTrustedMonth: TrustedUTCMonth?       // 信頼できる時刻から導出した最新の UTC 年月
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
    trustedMonth: TrustedUTCMonth?,  // 封鎖の解除判定に使う。端末時刻由来の値を渡さない
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
| `grants` へ素材を追加する | 利用可能な出力の生成が正常に完了した時点＝手順 7 の完了（[書き出し Saga](export-saga.md)）。プランを問わない |
| `consumedExportIDs` へ `exportID` を追加する | `QuotaDecision` が `consume` のときだけ |
| `firstSuccessAt` を更新する | しない。同一素材の有効な grant があれば維持する |

有料プランで grant を作らないと、Standard で書き出した 1 時間後に Free へ降格して再書き出しした場合に `freeReexport` にならず枠を消費します。

`firstSuccessAt` を更新しないのは、再書き出しのたびに窓が延びると 24 時間の上限が意味を失うためです。**この規則は「会計時に有効な grant があるか」で判断すると破れます。** 認可から会計までの間に窓が切れると新規作成されるため、`freeMonthlyReexport` は認可時の `firstSuccessAt` を保存して維持します（[書き出し Saga](export-saga.md) の preserve）。

##### 時間判定の基準時刻

**すべての時間判定に端末時刻をそのまま使いません。** 正規化を 1 か所に集約します。各判定が個別に `max` を書くと、書き忘れた箇所だけ防御が抜けます。

```swift
struct TimeAnchor: Sendable { let lastObservedAt: Date }

struct ObservedTime: Sendable {
    /// クォータ・grant 用。単調増加する。巻き戻し防止が目的
    let usageNow: Date

    /// 削除・保持期間用。信頼できる時刻を得られない異常ジャンプ中は nil
    let retentionNow: Date?

    /// サーバーまたは RevenueCat から得た絶対時刻。得られなければ nil
    let trustedNow: Date?

    /// trustedNow を UTC で年月へ落としたもの。整合性封鎖の解除に使う唯一の値
    let trustedMonth: TrustedUTCMonth?

    let updatedAnchor: TimeAnchor
}

func observeTime(now: Date, anchor: TimeAnchor, trusted: Date?) -> ObservedTime
```

```swift
usageNow = max(
    now,
    anchor.lastObservedAt,
    trusted ?? .distantPast
)
```

アンカーは `UsageLedger.lastObservedAt` として保持します。

**信頼時刻を `usageNow` の下限に含めます。** 含めないと、封鎖の解除だけが信頼年月を見て、消費判定は端末時刻を見る状態になります。すると「端末時計を前月へ戻す → 台帳を壊す → 前月を基準に封鎖される → サーバーから現在月を取得すると即解除される → 空になった当月枠を使える」という経路が残ります。**同じ時刻源から両方を導きます。**

| 判定 | 使う時刻 | `nil` のときの挙動 |
| --- | --- | --- |
| `ExportGrant` の 24 時間判定 | `usageNow` | — |
| 月次期間の更新 | `usageNow` | — |
| `finalizedAt` の確定（[書き出し Saga](export-saga.md)） | `usageNow` | — |
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
/// 封鎖専用。端末タイムゾーンに依存しない
struct TrustedUTCMonth: Sendable, Equatable, Comparable {
    let year: Int32
    let month: Int32          // 1...12。UTC で算出する
}

enum MonthlyIntegrityLock: Sendable, Equatable {
    case none

    /// 指定した年月より後の「信頼できる UTC 年月」を観測するまで封鎖
    case lockedUntilTrustedMonthAfter(TrustedUTCMonth)

    /// 端末時刻だけでは解除できない。再インストールを要する
    case lockedUntilReinstall
}
```

**封鎖の年月に `YearMonth` を使いません。** `YearMonth` は端末の `TimeZone` で算出するため、信頼できる絶対時刻を得ても、**月境界付近でタイムゾーンを変えるだけ**で `封鎖の年月 < 観測した年月` を成立させられます。

| 用途 | 年月の型 | 算出 |
| --- | --- | --- |
| 通常クォータの `period` | `YearMonth` | 端末の `TimeZone`（利用者の感覚に合わせる） |
| **整合性封鎖の基準と解除** | **`TrustedUTCMonth`** | **UTC 固定。端末タイムゾーンを一切使わない** |

`lastTrustedMonth` も `TrustedUTCMonth` とします。**封鎖基準と解除観測の両方を UTC で算出することが要点です。** 片方だけ UTC にしても、もう片方が動けば差を作れます。

##### 由来を型で区別する

**`usageNow` だけを渡すと、それが信頼時刻由来か端末時刻由来かを受け手が判別できません。** `usageNow` は `max(now, lastObservedAt, trusted)` なので、信頼時刻が無くても値は入ります。封鎖の解除に使えば、端末時刻で解除できてしまいます。

`observeTime` は `trustedNow` と `trustedMonth` を**別のフィールドとして**返し、`QuotaPolicy.evaluate` は両方を受け取ります。

| 判定 | 使う値 |
| --- | --- |
| 24 時間の窓、月次更新、`finalizedAt` | `usageNow` |
| 削除・保持期間 | `retentionNow` |
| **整合性封鎖の解除** | **`trustedMonth`。`nil` なら解除しない** |
| リモート設定の `expiresAt` | `trustedNow ?? usageNow` |

**`trustedMonth` が `nil` のとき、封鎖は解除されません。** 「信頼時刻を一度も得られなければ封鎖が続く」という規則が、型の上で自明になります。

| 規則 | 内容 |
| --- | --- |
| 解除に使える年月 | **信頼できる時刻から UTC で導出した `TrustedUTCMonth` のみ** |
| 端末時刻・端末タイムゾーン由来の年月 | **解除に使わない。** 何度変更しても封鎖は解けない |
| 封鎖の基準年月 | **端末年月を使わない**（下記） |
| 信頼できる時刻を一度も得られない | 封鎖は維持される |

**修復時の封鎖基準を端末年月にできません。** 時計を過去月へ戻してから台帳を壊せば、その過去月を基準に封鎖され、次に信頼時刻を得た瞬間に「基準より後の年月」が成立して解除されます。**破損させた側が解除条件を選べる状態です。**

| 修復時の状況 | 封鎖 | `period` / `lastObservedAt` / `lastTrustedMonth` |
| --- | --- | --- |
| **ライブの信頼時刻を取得できる** | `.lockedUntilTrustedMonthAfter(信頼時刻の年月)` | **信頼時刻に揃える** |
| **信頼時刻を取得できない** | **`.lockedUntilReinstall`** | 端末時刻を `lastObservedAt` に置き、`lastTrustedMonth` は `nil` |

**信頼時刻が無いまま基準年月を決めません。** 決められないなら `lockedUntilReinstall` へ倒します。あとから信頼時刻を得ても解除しないため、基準年月を偽装する経路そのものが消えます。

**破損回数による段階的な引き上げは行いません。** 回数の保存先が壊れた `UsageLedger` の外に無く、別の署名済み状態を新設しないと信頼できる値を持てないためです。上の 2 分岐で、信頼時刻を得られない破損は最初から再インストール要求になります。

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
- **中止した場合、手順 7 が未完了の写真は消費しない。既に手順 7 まで完了した写真のクレジットは戻さない**
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

v1 は全体排他ゲート（[書き出し Saga](export-saga.md)）により同時 1 件なのでこの経路は塞がれていますが、**予約は並列化後も必要です。**

| 契機 | 操作 |
| --- | --- |
| 認可時（手順 −2） | `SourceLease` に加えて、該当素材の `TrialReservation` を**同じ `transact` の中で**追加する |
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

| フィールド | ライブの信頼時刻がある場合 | 取得できない場合 |
| --- | --- | --- |
| `lastObservedAt` | **信頼時刻** | 検出時点の端末時刻 |
| `period` | **信頼時刻の年月** | 検出時点の端末年月 |
| `lastTrustedMonth` | **信頼時刻の UTC 年月** | `nil` |
| `monthlyIntegrityLock` | `.lockedUntilTrustedMonthAfter(信頼時刻の UTC 年月)` | **`.lockedUntilReinstall`** |
| `trialIntegrityLocked` | `true` | `true` |
| `grants` / `consumedExportIDs` / `trialEntries` / `trialReservations` / `sourceRecords` / `sourceLeases` | **すべて空** | **すべて空** |

**端末年月を封鎖の基準にしません。** 信頼時刻を取得できない場合は基準を決められないため、`lockedUntilReinstall` へ倒します（整合性封鎖の項）。

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

    /// ファイル全体の SHA-256（正準スキーマ 5.1）
    let contentFingerprint: ContentFingerprint
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

// SourceID の定義は 6.6 が正本

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

書き換えの結果、同じ `sourceID` の要素が同じ集合に 2 件できる場合は上の統合規則で 1 件へ畳みます。

**`sourceLeases` だけは畳めません。** 同一素材の非終端書き出しは 1 件だけという設計（[書き出し Saga](export-saga.md)）に対し、統合によって 2 件の実行中 lease が同じ素材へ合流した状態は、その不変条件が既に破れていることを意味します。**通常状態として許容せず、競合として扱い復旧エラーへ倒します。** v1 は全体ゲートによりこの状態が起こりません。

##### `SourceRecord` の寿命

**削除規則が無いと alias が永久に蓄積します。** 有料利用者は grant の 24 時間が切れても書き出しを続けるためです。

一方、**単純に「未参照なら削除」もできません。** `paidUnlimited` の通常の単体書き出しには grant も予約もなく、認可から正常生成までの間、その素材を参照するものが台帳に存在しません。`SourceLease` がこの穴を埋めます。

| 契機 | 操作 |
| --- | --- |
| 認可時（手順 −2） | `SourceLease` を追加する。**勘定の種類を問わない**。`batchTrial(true)` のときだけ追加で `TrialReservation` を作る |
| 台帳への適用（手順 4）またはロールバック | 該当 `exportID` の lease を**台帳トランザクション内で**削除する |
| 起動時 | 対応するコミットが無い lease を回収する（[書き出し Saga](export-saga.md) の起動時復旧 手順 3） |

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
| 8 | **同じ `sourceID` の `SourceLease` が 2 件以上存在しない** | 同一素材の非終端書き出しが 2 件走っており、所有者モデルが壊れる |

条件 5 は、予約と lease が手順 −2 の同一トランザクションで作られ、手順 4 またはロールバックで同時に消えることの帰結です。条件 7 の前半（空集合の禁止）は条件 1 に違反しないため、別条件として立てます。

##### `providerAssetKeyHash`

**平文で保存しません。** 端末内で**派生鍵による HMAC-SHA256** へ変換し、元の値を復元できない形で持ちます。**鍵は台帳署名とは別のラベルから派生させます**（9.1）。アルゴリズムと出力形式は [正準スキーマ](canonical-schema.md) が正本です。
##### `contentFingerprint`

**ファイル全体の SHA-256 とファイルサイズ・撮影日時の複合とします。** バイト表現の正本は [正準スキーマ](canonical-schema.md) です。

**部分ハッシュ（先頭・末尾 64KB）を採りません。** 中央部分だけが異なる 2 枚が同一素材と判定されます。同じカメラの連写では先頭の EXIF ブロック・末尾のパディング・ファイルサイズ・撮影日時が揃いやすく、**無料枠を回避する経路として現実的な難易度になります。**

全体を読む費用はストリーム投入で吸収できます（メモリは一定）。計算は選択直後のインポート Saga で 1 回だけ行います（[画像処理](image-pipeline.md)）。

**`PHAsset.creationDate` を入力にしません。** 権限の有無で取得元が変われば、同じ写真が別の `contentFingerprint` になり、無料枠を二重に消費します（[画像処理](image-pipeline.md)）。**ファイル更新日時も使いません。** コピーや同期で容易に変わります。

理論上の衝突時は「別素材なのに無料で再書き出しできる」方向へ倒れます。SHA-256 の全体ハッシュであれば、これは意図的に作れる衝突ではありません。

##### 入力の取得契約

```swift
struct SourceFingerprintInput: Sendable {
    let fileSize: Int64
    let contentDigest: Data           // ファイル全体の SHA-256（32 バイト）
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

**`Float`（32 ビット）へ丸めません。** 実際のモデルはすべて `Double` です（[画像処理](image-pipeline.md)）。32 ビットへ丸めると `0.1500000000000000` と `0.1500000059604645` が同じハッシュになり、**設定を変えたのに無料の再書き出しとして通します。**

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
4. **その成分に対応する `sourceID` が `trialEntries` に存在するかで分類する**

**alias の共有関係を推移的に閉じる**ことで、`sourceID` 解決と同じ結果になります。

**`SourceRecord` の有無で判定してはいけません。** `SourceRecord` は次のいずれでも作られます。

- 単体書き出しの `grant`
- 認可中の `SourceLease`（勘定を問わない）
- トライアル予約
- 有料書き出し中の参照

つまり **`SourceRecord` の存在だけを見ると、単体処理をしただけの写真が一括トライアルで「消費済み」と判定され、クレジットなしで処理できます。**

| 台帳の状態 | トライアルでの分類 |
| --- | --- |
| `SourceRecord` あり・`TrialEntry` なし | **新規**（クレジットを要する） |
| `TrialEntry` あり | **消費済み**（クレジットを要しない） |
| `TrialReservation` のみ | **新規枠を占有中**（別の書き出しが認可済み。残数計算では消費側に数える） |

`TrialReservation` を「消費済み」に含めないのは、その予約がロールバックされれば新規枠へ戻るためです。残クレジットの導出では `trialEntries.count + trialReservations.count` を引くため、**占有分は残数側で減っており、分類側でも消費済みにすると二重に数えます。**

**この分類は表示と入力制限のためのものです。** 選択から実行開始までの間に別の書き出しが台帳を更新しうるため、実行開始の直前に**最新の台帳で全件を原子的に再検証します。** 再検証は開始ゲート（[書き出し Saga](export-saga.md)）の内側で行い、**上と同じ `trialEntries` の判定条件**を使います。分類結果が変わっていれば実行を開始せず、選択画面へ戻して差分を提示します。**選択時の判定だけで消費を認可しません。**

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

キューの進行状態は仕様 16.6 の 8 種とし、状態機械を `Domain` に置きます。**状態を増やしません。**

```swift
enum ExportQueueState: Sendable, Equatable {
    case waiting
    case analyzing
    case reviewRequired
    case exporting
    case completed
    case failed(ExportQueueFailure)
    case canceled
    case paused(QueuePauseReason)
}

/// 失敗の理由。再試行の可否を型で持つ
struct ExportQueueFailure: Sendable, Equatable {
    let errorCode: AppErrorCode      // 9.2 の列挙
    let isRetryable: Bool
    let occurredAt: Date
}

enum QueuePauseReason: Sendable, Equatable {
    case entitlementExpired            // Pro 契約の終了（書き出し Saga 1.4）
    case storageInsufficient
    case userPaused
    /// 処理用の元素材が失われた。同じ写真を選び直せば再開できる
    case sourceReselectionRequired
}

extension ExportQueueState {
    /// 終端かどうかの判定を 1 か所に置く
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .canceled: return true
        case .waiting, .analyzing, .reviewRequired, .exporting, .paused: return false
        }
    }
}
```

**処理用ファイルが失われた場合も新しい状態を作りません。** `paused(.sourceReselectionRequired)` へ遷移させます。`paused` は「利用者の操作を待って再開できる」という意味であり、再選択を求める状況はこれに当てはまります。**バッチ全体ではなく該当項目だけが `paused` になります。**

**`isTerminal` を各所で書き下しません。** 履歴削除の可否判定（7.5）、バッチの完了判定、復旧の対象選定がすべてこの 1 つの述語を使います。列挙を書き下すと、状態を追加したときに一部だけ更新される事故が起こります。

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

##### 開始時の設定を固定する

**実行中のバッチは、開始時のリモート設定で動きます**（[運用](operations.md) の 2.2）。設定が途中で変わっても、枚数上限や並列数が動きません。

```swift
struct BatchPolicySnapshot: Sendable, Equatable {
    let configVersion: Int64
    let batchSizeLimit: Int32
    let trialCreditCount: Int32
    let concurrencyLimit: Int32
}
```

`Batch` の行が保持し、**再起動後も同じ値を使います。** リモート設定を読み直して適用すると、復元したバッチの上限が実行中に変わります。

新しいバッチの作成時に、その時点の `RemoteConfig` から作ります。

その他の規則は仕様 16.5 / 16.7 / 16.8 に従います。

- 1 バッチ最大 50 枚
- 同時並列処理は初期値 1。写真のみのため最大 2 まで許容可能とするが、実機計測後に判断する
- 一枚の失敗でバッチ全体を停止しない
- **アプリ再起動後に未完了キューを復元する**（[画像処理](image-pipeline.md) の `WorkingSourceRecord`）
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
struct SourceID:    Sendable, Hashable { let rawValue: UUID }   // 素材の正規 ID（6.4）
struct FaceTrackID: Sendable, Hashable { let rawValue: UUID }

/// 認可用。出力へ影響する全設定の正準ハッシュ（正準スキーマ 5.2）
struct ProjectSettingsHash: Sendable, Hashable { let bytes: Data }   // 32 バイト

/// プレビュー確認用。見た目に影響する値だけ（正準スキーマ 5.2）
struct PreviewRenderHash: Sendable, Hashable { let bytes: Data }     // 32 バイト

/// 素材の内容ハッシュ（正準スキーマ 5.1）
struct ContentFingerprint: Sendable, Hashable { let bytes: Data }    // 32 バイト
struct StampAssetHash: Sendable, Hashable { let bytes: Data }        // 32 バイト
```

**`FaceTrackID` も `UUID` です。** 自動検出は `observation.uuid` をそのまま使い、手動領域はアプリが採番します。文字列にすると 2 つの出所で表現が揺れます。

| 理由 | 内容 |
| --- | --- |
| 誤った受け渡しの防止 | `exportID` を期待する引数へ `projectID` を渡せない。**コンパイルで止まる** |
| DB 結合の一意性 | 外部キーと結合の対象が型で決まる（7.1） |
| 正準化の一意性 | HMAC 対象の各 ID を「`UUID` の 16 バイト」として符号化できる（9.1） |
| ログ禁止の強制 | 分析イベントのフィールド型にしないことで、送信経路へ入れられない（9.2） |

**いずれの型も `CustomStringConvertible` に適合させません。** 文字列補間で自動的にログや診断へ流れる経路を作らないためです。

### 6.7 アプリ更新の判定

起動時に新しいバージョンがあれば App Store へ誘導します。**判定は純粋関数に閉じます。** 提示条件・審査への配慮・配信の運用規則は [運用](operations.md) が正本です。

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

`AppVersion` は数値の組で比較します（[正準スキーマ](canonical-schema.md)）。**文字列比較を使いません。** `"1.10.0" < "1.9.0"` が文字列としては真になり、新しいバージョンを古いと判定します。`CFBundleShortVersionString` のパースに失敗した場合は **`.none`** とします。ここで強制更新へ倒すと、バージョン表記の書式ミスで全利用者がブロックされます。`CFBundleVersion`（ビルド番号）は比較に使いません。

判定は起動時復旧の完了後に行います（[書き出し Saga](export-saga.md) の起動時復旧 手順 8）。復旧前に強制更新画面を出すと、`generated` の件数を正しく数えられません。

`skippedVersion` と `lastPromptedAt` は `UserDefaults` に置きます。改ざんされても更新の再提示が遅れるだけです。

---

## 7. 永続化

### 7.1 app.db

GRDB（SQLite）を使います。採用理由は [ADR 0002](adr/0002-grdb-and-single-database.md) にあります。

**アプリのリレーショナルデータを 1 つの `app.db` へ収めます。**

| テーブル | 備考 |
| --- | --- |
| `Project` | 仕様 19.1。`projectRevision`（下記）と再編集用の `ProjectSourceLocator` を持つ（[画像処理](image-pipeline.md)）。**ここにのみ平文の `localIdentifier` が存在する** |
| `FaceTrack` | 仕様 19.2。手動領域は `createdManually = true` |
| `EffectSetting` | 仕様 19.4 |
| `ExportSetting` | 仕様 19.5 |
| `CustomStamp` | 仕様 19.6。スタンプ一覧の項目（7.5） |
| `StampAsset` | プロジェクトが参照する不変の画像実体のメタデータ。内容ハッシュを主キーとする（7.5） |
| `ProjectStampAsset` | プロジェクトと `StampAsset` の対応（7.5） |
| `ExportRecord` | 仕様 19.7。`batchID` を追加 |
| `Batch` | バッチ単位の履歴。`BatchPolicySnapshot` を持つ（6.5） |
| `BatchPreset` | 一括設定プリセット |
| `DeliveryAttempt` | 写真ライブラリ保存の試行中を表す（[書き出し Saga](export-saga.md) の 8.0） |
| `ExportCommit` | 書き出しのコミットジャーナル。行に HMAC を付ける（[書き出し Saga](export-saga.md)） |
| `OutputRecord` | 写真ごとの出力状態。`exportID` でコミットと対応づける |
| `ExportQueueItem` | 一括処理のキュー状態（6.5） |
| `WorkingSourceRecord` | 処理用にアプリ領域へ複製した元素材（[画像処理](image-pipeline.md)） |
| `PendingFileDeletion` | 参照 0 になった実体の削除候補（7.5） |

**`app.db` 全体がバックアップ対象外です**（7.4）。復元してはいけない理由は 2 つあり、どちらも DB を分けても解消しません。

- `ExportCommit` を別端末へ復元しても、対応する一時ファイルは存在せず、`UsageLedger`（同じくバックアップ対象外）との整合も失われる
- 写真ライブラリ参照（`ProjectSourceLocator` / `providerAssetKeyHash`）は別端末で意味を持たず、履歴を復元しても再編集できない

##### DB を分けない

**「バックアップの単位はファイルなので分ける」という理由は成立しません。** 両方とも対象外である以上、分割の根拠になりません。保護クラスも両方 `.complete` で同じです（7.4）。

分けないことで次が得られます。

| 得られるもの | 内容 |
| --- | --- |
| **実の外部キー制約** | `OutputRecord.projectID` → `Project`、`ExportQueueItem.batchID` → `Batch` を SQLite が強制する。アプリ側の起動時検査が不要になる |
| 単一トランザクション | 手順 7（[書き出し Saga](export-saga.md)）が `ATTACH` なしで成立する |
| 単一の `DatabaseMigrator` | 2 つの DB のスキーマバージョンが食い違う状態が存在しない |
| 検証の単純化 | `PRAGMA` の確認がスキーマ 1 つで済む |

**将来バックアップを実装する場合も分割は不要です。** [ADR 0003](adr/0003-local-only-data-and-backup-policy.md) のとおり、OS による生ファイルのバックアップではなく検証可能なアーカイブとして書き出す設計を採るため、**対象テーブルを選ぶだけで足ります。**

##### `projectRevision` の増加規則

出力へ影響する値は `Project` 以外のテーブルにもあります。**「`Project` の変更ごとに増える」だけでは、`EffectSetting` だけを書き換えても revision が動かない実装が成立します。**

> **出力・検出結果・レビュー結果・プレビュー結果のいずれかへ影響する子行の作成・更新・削除は、必ず同一 DB トランザクションで `Project.projectRevision` を増加させる。**

対象の子テーブルです。

| テーブル | 影響する先 |
| --- | --- |
| `FaceTrack` | 検出結果・プレビュー |
| `EffectSetting` | プレビュー・出力 |
| `ExportSetting` | 出力 |
| `ProjectStampAsset` | プレビュー・出力 |

**編集操作を個別 Repository へ分散させません。** プロジェクト変更コマンドへ集約し、そのコマンドだけが子行と `projectRevision` を同時に更新します。個別の `update` を公開すると、revision の更新を忘れた経路ができます。

`detectionRevision` は再検出でのみ増え、`projectRevision` とは独立です（6.1）。

##### 一意制約と外部キー

**不変条件をアプリのコードだけで守りません。** DB 制約として固定できるものは固定します。

| 対象 | 制約 |
| --- | --- |
| `ExportCommit.exportID` | **PRIMARY KEY** |
| `OutputRecord.exportID` | **PRIMARY KEY** |
| `OutputRecord.projectID` | **UNIQUE**（1 プロジェクト 1 出力） |
| `WorkingSourceRecord.projectID` | **PRIMARY KEY** |
| `PendingFileDeletion(kind, fileID)` | **UNIQUE** |
| `ProjectStampAsset(projectID, assetHash)` | **UNIQUE** |
| `StampAsset.contentHash` | **PRIMARY KEY** |
| `ExportQueueItem(batchID, projectID)` | **UNIQUE** |

外部キーは `PRAGMA foreign_keys = ON` で有効化し、次を宣言します。

| 子 | 親 | 削除時 |
| --- | --- | --- |
| `OutputRecord.projectID` | `Project` | **RESTRICT**（未受け渡し出力があるプロジェクトを消さない。7.5） |
| `OutputRecord.batchID` | `Batch` | SET NULL |
| `ExportCommit.projectID` | `Project` | **RESTRICT** |
| `ExportCommit.batchID` | `Batch` | SET NULL |
| `WorkingSourceRecord.projectID` | `Project` | CASCADE |
| `FaceTrack.projectID` | `Project` | CASCADE |
| `EffectSetting.projectID` | `Project` | CASCADE |
| `EffectSetting.faceTrackID` | `FaceTrack` | CASCADE |
| `ExportSetting.projectID` | `Project` | CASCADE |
| `ExportQueueItem.projectID` | `Project` | CASCADE |
| `ExportQueueItem.batchID` | `Batch` | CASCADE |
| `ExportRecord.projectID` | `Project` | CASCADE |
| `ExportRecord.batchID` | `Batch` | SET NULL |
| `ProjectStampAsset.projectID` | `Project` | CASCADE |
| `ProjectStampAsset.assetHash` | `StampAsset` | RESTRICT |
| `CustomStamp.assetHash` | `StampAsset` | RESTRICT |

**`batchID` を `SET NULL` にするのは、バッチ履歴を消しても出力と書き出し記録を残すためです。** バッチは集約単位であり、個々の出力の存在条件ではありません。

**宣言していない参照は `PRAGMA foreign_key_check` で検出できません。** 上の表が外部キーの全体です。新しい参照を追加するときは、必ずこの表へ加えます。

**`RESTRICT` を使うのは、削除可否の判定（7.5）を DB 側でも二重に担保するためです。** アプリ側の判定を通り抜けた削除は制約違反として失敗します。

**「同一 `sourceID` の非終端コミットは 1 件」は DB 制約にできません。** `sourceID` は署名対象であり、部分インデックスで状態を条件にすると署名不正行まで巻き込みます。これは開始ゲート（[書き出し Saga](export-saga.md)）と台帳の不変条件 8 で担保します。

**手順 0 の再試行は同じ `exportID` で冪等です。** `PRIMARY KEY` 制約により二重 insert は失敗し、再試行時は既存行の状態を読んで続きから進めます。

##### 接続と journal

| 項目 | 規約 |
| --- | --- |
| 接続 | **`DatabaseQueue` を 1 つだけ**使う |
| `journal_mode` | **`DELETE`**（下記）。`TRUNCATE` / `PERSIST` / `WAL` を使わない |
| `synchronous` | **`EXTRA`** |
| `foreign_keys` | **`ON`** |
| 起動時検査 | `journal_mode` / `synchronous` / `foreign_keys` を読み返して検証する |

**`DELETE` へ固定するのは、常時存在するサイドカーファイルを作らないためです。**

| モード | サイドカー |
| --- | --- |
| **`DELETE`** | **トランザクション終了時に消える** |
| `TRUNCATE` / `PERSIST` | journal ファイルが**残り続ける** |
| `WAL` | `-wal` と `-shm` が**常時存在する** |

残るファイルには**バックアップ除外とデータ保護クラスを個別に設定・検証する必要**が生じ、7.3 の「すべてのファイル生成を `ManagedFileStore` へ通す」から外れた経路が増えます。`DELETE` ならその経路自体が存在しません。

本アプリの DB アクセスは書き出しの前後に集中し、同時読み書きの負荷が高くないため、WAL の並行性は必要ありません。

`DatabasePool`（複数接続）も使いません。`synchronous = EXTRA` の効果と書き込み順序の推論を単純に保ちます。

##### 耐久性の水準

**保証の強さを段階で書き分けます。** SQLite の `synchronous = EXTRA` は rollback journal に対する追加の同期であって、ハードウェアを含むあらゆる条件での絶対的な電源断保証ではありません。Apple の強制同期 API（`F_FULLFSYNC`）にも同じことが言えます。

| 障害 | 保証の水準 | 根拠 |
| --- | --- | --- |
| **プロセス強制終了**（`_exit` / SIGKILL / jetsam） | **保証する** | コミット Saga と単一トランザクション |
| **OS クラッシュ・電源断** | **best effort の耐久性** | `synchronous = EXTRA`、ファイルと親ディレクトリの同期 |
| 復帰後の整合 | **回復する** | コミットジャーナルと起動時復旧 |

**要点は「書き込みが必ず届く」ことではなく、「どこで切れても整合を回復できる」ことです。** 電源断で最後の書き込みが失われた場合、その書き出しは 1 つ前の状態から再開されます。

v1 では、**出力ファイルと保護ブロブについてもファイルと親ディレクトリを同期します。** 台帳と出力の整合が崩れると不変条件が壊れるため、DB と同じ水準に揃えます。**同期方式（`F_FULLFSYNC` か通常の `fsync` か）は実機計測後に決めます**（12.2）。

### 7.2 ProtectedBlobStore

以下は DB ではなく `ProtectedBlobStore` へ保存します。改ざんで権限や枠を書き換えられないようにするためです（9.1 の HMAC 署名つき）。

- `UsageLedger`（6.3）
- `SubscriptionState`（6.2 の `Entitlement` キャッシュ）
- `RemoteConfigState`（10 章）

**鍵の保管とデータの保管を分けます。**

| 役割 | プロトコル | 実装 |
| --- | --- | --- |
| 鍵 | `CryptoKeyStore` | Keychain（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`。7.4） |
| 署名済みデータ本体 | `ProtectedBlobStore` | アプリ専用ディレクトリ上のファイル（原子的置換） |

原子的な置き換えができることを要件とします。台帳は 1 つのオブジェクトとして丸ごと差し替えるため、部分更新の途中状態が観測されてはいけません。実装は一時ファイルへ書いてから `FileManager.replaceItemAt` です。

##### 論理キーで解決する

**`ManagedFileID` のランダムな `UUID` だけでは、再起動後に blob を見つけられません。** `ManagedFileStore` は呼び出し元へパスを返さず、採番した ID をどこかへ保存しなければ次回起動時に対応づけられません。

**`ProtectedBlobStore` は固定の論理キーで解決します。**

```swift
/// 署名対象になれる型。正準化とデコードの方法を型が持つ
protocol ProtectedPayload: Sendable {
    static var blobKeyRawValue: UInt32 { get }   // ファイル名の決定に使う
    static var payloadType: PayloadType { get }
    static var schemaVersion: UInt32 { get }

    init(canonicalBytes: Data) throws
    func canonicalBytes() -> Data
}

extension UsageLedger: ProtectedPayload { }
extension SubscriptionState: ProtectedPayload { }
extension RemoteConfigState: ProtectedPayload { }

/// 値の型がキーに結びついている。型引数を取り違えられない
struct ProtectedBlobKey<Value: ProtectedPayload>: Sendable {
    static var usageLedger: ProtectedBlobKey<UsageLedger> { .init() }
    static var subscriptionState: ProtectedBlobKey<SubscriptionState> { .init() }
    static var remoteConfigState: ProtectedBlobKey<RemoteConfigState> { .init() }
}

protocol ProtectedBlobStore: Sendable {
    func load<Value>(
        _ key: ProtectedBlobKey<Value>
    ) async -> ProtectedLoadResult<Value>

    func save<Value>(
        _ value: Value,
        for key: ProtectedBlobKey<Value>
    ) async throws
}
```

**`Sendable` だけでは足りません。** 型引数が自由だと `.usageLedger` を `SubscriptionState` として読むコードがコンパイルを通り、デコード方法も決まりません。`ProtectedPayload` が正準バイト列との相互変換を持ち、`ProtectedBlobKey<Value>` がキーと型を結びつけます。**取り違えはコンパイルで止まります。**

| 項目 | 規約 |
| --- | --- |
| キーからの解決 | **`blobKeyRawValue` ごとに固定された内部ファイル名**（`protected/` 配下） |
| ID の保存 | **不要。** `ManagedFileID` を外部へ持ち出さない |
| `ManagedFileStore` との関係 | 原子的書き込み・保護属性の設定・バックアップ除外の**共通処理だけを共有する** |
| `ManagedFileKind` | `.protectedBlob`。ディレクトリの決定にのみ使う |
| 検証 | 読み込み時に `payloadType` と `schemaVersion` が型の宣言と一致することを確認する |

**`ProtectedBlobStore` までランダム UUID で管理する必要はありません。** 論理キーは 3 つに固定されており、増減はスキーマ変更を伴います。ID による間接参照は、任意個のファイルを扱う `ManagedFileStore` の要件であって、この 3 つには当てはまりません。

`blobKeyRawValue` は `UInt32` で固定します。ファイル名の決定に使うため、宣言順が変わってもファイルの対応が変わってはいけません。`payloadType` の検証と併せて、**種別をまたいだ付け替えを実行時にも弾きます**（9.1）。

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

**属性の設定を rename の後だけに置けません。** 書き込み中や rename 前に終了した場合、**一時ファイルが無保護のまま残ります。** 未加工の顔画像や未受け渡し出力を扱う以上、完成ファイルだけを保護しても足りません。

| 順 | 操作 |
| --- | --- |
| 1 | **最終ファイルと同じディレクトリ内に**一時ファイルを作る |
| 2 | **書き込み前に** `isExcludedFromBackup` と `FileProtectionType` を設定し、読み返して確認する |
| 3 | データを書き、ファイルと親ディレクトリを同期する |
| 4 | atomic rename / `replaceItemAt` で最終 URL へ移す |
| 5 | **最終 URL へ属性を再設定する** |
| 6 | 属性を**読み返して検証する** |
| 7 | 失敗したら `ManagedFileRef` を返さず、即時削除するか孤児 GC の対象にする |

**手順 1 で同じディレクトリを使うのは、ディレクトリの既定保護クラスを最初から効かせるためです。** 別ディレクトリで作ってから移すと、その間だけ保護レベルが下がります。

**手順 2 と 5 の両方で設定します。** `replaceItemAt` は置換先の属性を引き継ぐとは限らないため rename 後の再設定が要り、rename 前の設定は中断時の保護のために要ります。どちらも省けません。

**手順 6 の読み返しを省きません。** 設定が反映されなかった場合、次回起動まで気づけません。

対象は次のすべてです。**個別に `FileManager` を呼ぶ実装を許しません。**

- 処理中の一時ファイル、未受け渡し出力、ラスタスタンプ一時ファイル
- カスタムスタンプ実体、履歴サムネイル、`ProtectedBlobStore` の blob

SQLite のファイル群は GRDB が生成するため `ManagedFileStore` を通せません。ディレクトリの既定保護クラスで覆い、起動時に DB ファイルの属性を検証します。

##### スコープ付きアクセス

**「パスを返さない」だけでは、`MediaKit` と `Rendering` がファイルを開けません。** Image I/O、Core Image、`CGDataProvider(url:)` はいずれも `URL` を要求します。

**永続的な `URL` は公開せず、処理中だけ有効なスコープを渡します。**

```swift
protocol ManagedFileStore: Sendable {
    /// 読み取り。body の実行中だけ URL が有効
    func withReadAccess<R: Sendable>(
        _ ref: ManagedFileRef,
        _ body: @Sendable (URL) async throws -> R
    ) async throws -> R

    /// 新規作成。body が書いた一時ファイルを、復帰後に上の順序で確定する
    func createFile<R: Sendable>(
        kind: ManagedFileKind,
        _ body: @Sendable (URL) async throws -> R
    ) async throws -> (ref: ManagedFileRef, result: R)

    func delete(_ ref: ManagedFileRef) async throws
}
```

| 規約 | 内容 |
| --- | --- |
| `URL` の寿命 | `body` の実行中のみ。外へ保持したら未定義動作とする |
| 保護データ利用不可 | `withReadAccess` が `ProtectedDataAvailability` を確認し、`unavailable` なら専用エラーを投げる（7.4） |
| 存在しない `ref` | エラー。空ファイルを作らない |
| `createFile` の失敗 | `ref` を返さない。一時ファイルは削除するか孤児 GC へ |

##### 種別つきの参照

`ManagedFileRef` を汎用のまま各所へ渡すと、**`kind` の取り違えをコンパイラが検出できません。**

```swift
struct OutputFileRef: Sendable, Hashable { let ref: ManagedFileRef }        // .output
struct WorkingSourceFileRef: Sendable, Hashable { let ref: ManagedFileRef } // .processingTemporary
struct RasterFileRef: Sendable, Hashable { let ref: ManagedFileRef }        // .rasterTemporary
struct StampAssetFileRef: Sendable, Hashable { let ref: ManagedFileRef }    // .stampAsset
```

各 initializer は `kind` を検証し、一致しなければ `nil` を返します。**デコード時も同じ検証を通し、`kind` 不一致の行は不正として扱います。** `OutputRecord.outputFile` は `OutputFileRef`、`WorkingSourceRecord.sourceFile` は `WorkingSourceFileRef` を持ちます。

### 7.4 ファイル保護とバックアップ

##### 配置

**SQLite の rollback journal を確実に除外するため、DB を専用ディレクトリへ置きます。** これらは DB と同じディレクトリに作られるため、DB ファイルだけを指定しても覆えません。

```
Library/Application Support/db/app.db
Library/Application Support/working/
Library/Application Support/stamps/
Library/Application Support/thumbnails/
Library/Application Support/outputs/
Library/Application Support/protected/
Library/Caches/stamp-thumbnails/
tmp/raster/
```

**DB を専用ディレクトリへ置くのは、rollback journal と一時 DB ファイルを確実に覆うためです。** これらは DB と同じディレクトリに作られるため、ファイル単位の指定では届きません。

**処理中ファイルを `tmp/` に置きません。** `tmp/` は OS がいつでも削除でき、再起動のたびにキューの復元が失敗します（[画像処理](image-pipeline.md)）。`raster/` は `tmp/` のままです。1 回の `render` 呼び出し内でのみ有効であり、消えて困る状況が存在しません。

##### バックアップ

**アプリが所有する DB・画像・保護 blob を対象外とします**（ADR 0003）。下表が対象の全体であり、`UserDefaults` や第三者 SDK の保存領域は含みません（それらに保護すべきデータを置かないことは 9.2 で担保します）。

| パス | 根拠 |
| --- | --- |
| `db/`（`app.db` と journal） | 復元しても整合しない（7.1） |
| `working/` | 処理中の元素材。復元しても意味がない |
| `tmp/raster/` | `render` 呼び出し内でのみ有効 |
| `Library/Caches/stamp-thumbnails/` | 実体から再生成できるキャッシュ |
| `outputs/` | 24 時間で消えるもの。復元しても期限切れ |
| `protected/` | HMAC 鍵と寿命を揃えるため |
| **`stamps/` / `thumbnails/`** | 商品説明との整合、復元の同時点性、参照の失効、復旧 Saga の増加 |

**設定画面と初回起動時に、履歴とマイスタンプが端末内にのみ保存され、アプリの削除や端末の変更では引き継がれないことを明示します。** 黙って失われる状態を作りません。

除外の指定は各パスへ `isExcludedFromBackup = true` を設定します。**ディレクトリへ一度設定すれば足りるとは考えません。** Apple は、一般的なファイル操作で値が `false` へ戻りうるため**ファイルを保存するたびに設定する**よう明記しています。**すべてのファイル生成を `ManagedFileStore` へ通します**（7.3）。ディレクトリ単位の設定は保険であり、保証ではありません。

##### データ保護クラス

バックアップ対象外にしても、端末が盗まれてロック画面の状態で解析されれば、保護クラスが低いファイルは読めます。

**アプリが置くファイルはすべて `.complete` とします。**

| 対象 | 保護クラス |
| --- | --- |
| 処理中の元画像コピー（`working/`） | `.complete` |
| 未受け渡し出力（`outputs/`） | `.complete` |
| ラスタ一時ファイル（`tmp/raster/`） | `.complete` |
| カスタムスタンプ実体（`stamps/`） | `.complete` |
| 履歴サムネイル（`thumbnails/`） | `.complete` |
| **`db/` の `app.db` と journal** | **`.complete`** |
| **`ProtectedBlobStore`** | **`.complete`** |
| **HMAC マスター鍵**（Keychain） | **`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`** |

**アプリ全体の既定を `.complete` にします。** 設定漏れが「保護が弱い」方向へ倒れないためです。SQLite の rollback journal と一時 DB ファイルにも同じ保護が必要で、これらは自動生成されるため**ディレクトリの既定保護クラス**で覆います。

**DB を下げる理由がありません。** 起動時復旧の最初の手順は「保護データが利用可能になるまで待つ」であり、その後に DB を開きます（[書き出し Saga](export-saga.md) の起動時復旧）。v1 は `BGProcessingTask` を使わずフォアグラウンド継続を前提とするため、**ロック中に DB を開く必要が現在の設計にはありません。**

`app.db` には写真ライブラリの平文 `localIdentifier`、顔領域、編集内容が入ります。これらを `.completeUntilFirstUserAuthentication` に置く理由は、実行モデルと照らして残っていません。

**ロック中の復旧を要件にする場合は、手順 −4 より前に DB を開く別設計が必要です。** 両方を同時には満たせません。その場合は実行時状態だけを別 DB へ切り出して `.completeUntilFirstUserAuthentication` とし、利用者データと `ProtectedBlobStore` は `.complete` を維持します。v1 では採りません。

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

3 つ目は保持期間が無期限である点が他と異なります。**プライバシーポリシーの記載と整合させる必要があります**（12.2）。

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

消費は手順 7 の完了で確定します（[書き出し Saga](export-saga.md)）。**したがって、生成直後の失敗や異常終了によって利用者が成果物を失う経路を作りません。** ただし保持は無期限ではなく **24 時間で削除します。**

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
| **非終端のキュー項目**（`isTerminal == false`。6.5） | 処理中のバッチが消える |
| **`OutputRecord`** | 未受け渡し出力の実体だけが残り、レコードが孤児になる |
| **非終端の `ExportCommit`** | 復旧の手がかりを失い、会計を戻せなくなる |
| **`WorkingSourceRecord`**（[画像処理](image-pipeline.md)） | 処理用の元素材が消え、キューを復元できない |
| 24 時間のやり直し保証 | やり直しができなくなる |

**判定と削除は同一トランザクション内で行います。** 別トランザクションに分けると、判定と削除の間に新しい参照が生まれます。外部キーの `RESTRICT`（7.1）が二重の防御として働きます。

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

対象は `delivered` で完了画面を離れた場合、利用者が破棄した場合、`generated` が 24 時間経過した場合、壊れた出力を復元できなかった場合（[書き出し Saga](export-saga.md)）のすべてです。**入口ごとに別の順序を実装しません。**

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
| ディレクトリ | `thumbnails/` |
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
    = CustomStamp.assetHash の行数
    + ProjectStampAsset の行数
```

**「プロジェクトの数」では単位が決まりません。** 1 つのプロジェクト内で同じスタンプを複数の顔領域へ使えるため、`EffectSetting` 1 件につき 1 参照なのか、プロジェクト内の重複を畳むのか、一部の顔からだけスタンプを外したときにいつ減算するのかが定まりません。

**中間表を置いて、参照の単位を「プロジェクトと実体の組」に固定します。**

```
ProjectStampAsset(
    projectID,
    assetHash,
    UNIQUE(projectID, assetHash)
)
```

| 契機 | 操作 |
| --- | --- |
| カスタムスタンプを**一覧へ登録**した | `StampAsset` を作成（または既存を再利用）し、`CustomStamp.assetHash` がそれを指す |
| プロジェクトの**いずれかの領域**がその実体を使うようになった | `ProjectStampAsset` へ upsert する（既にあれば何もしない） |
| プロジェクトから**その実体を使う領域がすべて無くなった** | `ProjectStampAsset` の行を削除する |
| `CustomStamp` を**一覧から削除**した | その行を削除する。新規編集では選択できなくなる |
| `Project` を削除した | その `projectID` の `ProjectStampAsset` を**すべて削除する** |
| 参照が **0** になった | **実体を削除する**（下記の順序） |

**同じプロジェクト内の重複は `UNIQUE` 制約が畳みます。** 1 枚の写真に同じスタンプを 10 個置いても参照は 1 です。1 個だけ外しても減算されず、**最後の 1 個を外した時点で行が消えます。**

`StampAsset.referenceCount` を保存値としても持つ場合は、**同じ DB トランザクションで更新し、起動時に導出値との一致を検査します。** 不一致は保存値ではなく導出値を正とし、保存値を書き直します。

**この構成なら、一覧削除で過去プロジェクトの実体が消えません。** プロジェクト側の参照が残っている限り参照数は 0 になりません。削除確認では、過去の加工履歴で引き続き使用される旨を示します。

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

##### 出力メタデータは許可リストで構築する

**元のメタデータ辞書をコピーして既知キーだけ削除する実装を許しません。** 未知の EXIF タグ、XMP、IPTC、メーカー固有情報（MakerNote）が残ります。削除リストは、知らないキーを取りこぼす方向へ倒れます。

**出力メタデータ辞書を空から構築します。**

| 分類 | 扱い |
| --- | --- |
| ICC プロファイル | **必要な場合のみ含める**（色が変わらないようにするため） |
| ピクセル寸法 | 含める |
| `DateTimeOriginal` | **設定で保持を選んだ場合のみ**含める |
| 向き（Orientation） | ピクセルへ適用済みなので**通常値（1）を書く** |
| GPS / `Make` / `Model` / `Software` / `UserComment` / `Artist` / `Copyright` | **コピーしない** |
| XMP / IPTC / MakerNote の全 namespace | **コピーしない** |
| 上記以外のすべて | **コピーしない** |

```swift
/// 出力メタデータ。許可フィールド以外を構造的に持てない
struct OutputMetadata: Sendable, Equatable {
    let pixelSize: PixelSize
    let iccProfile: Data?              // 色が変わる場合のみ埋める
    let dateTimeOriginalUTCMillis: Int64?   // 設定で保持を選んだ場合のみ
    // 向きは常に通常値（1）として書くため、フィールドを持たない
}
```

**`ImageEncoder` はこの型だけを受け取ります**（[画像処理](image-pipeline.md)）。元のメタデータ辞書を渡せる形にすると、コピーして削除する実装が可能になります。

**保存後に読み返し、許可されていない namespace とキーが 1 つも無いことを検査します。** 検査に失敗した出力は完成扱いにせず、[書き出し Saga](export-saga.md) の手順 1 の検証失敗として扱います。

**カスタムスタンプも同じ方針で再エンコードします。** 取り込み時に縮小・変換するため、そこで元のメタデータを捨てます。スタンプ画像は出力へ合成されるだけですが、実体がアプリ内に残る以上、位置情報を保持する理由がありません。

**`PHAsset.creationDate` は `Optional` です。** 優先順位を定めます。

| 順 | 取得元 | 条件 |
| --- | --- | --- |
| 1 | `PHAsset.creationDate` | **読み取り権限が既にある場合のみ**（[画像処理](image-pipeline.md)） |
| 2 | EXIF の `DateTimeOriginal` | 常に試みる |
| 3 | **`creationDate` を設定しない**（OS が保存日時を使う） | どちらも無い場合 |

**3 の場合に現在時刻を明示指定しません。** 設定しないのと同じ結果になりますが、「日時を引き継いだ」と記録が残ると不具合を追うときに誤解の元になります。取得できなかったことを区分値として記録します（9.2）。

**この優先順位表を `contentFingerprint` に流用しません。** fingerprint の撮影日時は EXIF のみです（6.4）。ここで `PHAsset.creationDate` を優先するのは保存する写真の属性としてより正確だからであり、同一性の判定には使えません。**共有するのは EXIF の読み取り処理までとし、優先順位の合成は共有しません。**

画像方向とピクセルサイズは常に保持します。

---

---

## 8. 書き出し Saga

**正本は [書き出し Saga](export-saga.md) です。** 状態遷移表、手順 0〜7、ロールバック順序、起動時復旧順序をここへ複製しません。

書き出しの完了で確定する事柄は、ファイルシステム・DB・`ProtectedBlobStore` の 3 か所に分かれており、**単一トランザクションで更新できません。** 異常終了の位置によって「出力だけ残り枠が消費されない」「枠だけ消費され出力が残らない」が起こります。**永続的なコミットジャーナル（`ExportCommit`）を置きます。**

本書の他の章が依存する不変条件だけを示します。

| 不変条件 | 内容 |
| --- | --- |
| **確定点** | 会計の最終確定は**コミット行の削除（手順 7）**ただ 1 点。それ以前は成果物を公開しない |
| **公開の観測可能性** | `OutputRecord` の insert とコミット行の delete は同一トランザクション。「両方ある」状態は存在しない |
| **会計時刻** | `finalizedAt` は `finalizing` の保存時点の `usageNow`。`generatedAt` / `expiresAt` / grant の起点はすべてここから導出する |
| **所有者** | ロールバックの根拠は台帳側の `ownerExportID` のみ。`AccountingApplied` は単独の根拠にならない |
| **`SourceLease`** | 認可時に**勘定を問わず**追加し、手順 4 またはロールバックで削除する |
| **直列化** | 同一素材の非終端コミットは同時 1 件。台帳では「同一 `sourceID` の `SourceLease` は最大 1 件」として現れる |
| **復旧の開始条件** | 起動時復旧を終えるまで新しい書き出しを開始しない |

`ExportAuthorization` / `ExportAccountingMode` / `GrantAction` / `ExportCommit` / `OutputRecord` の型定義も [書き出し Saga](export-saga.md) が正本です。

---

## 9. セキュリティとプライバシー

### 9.1 HMAC と正準化

**バイト表現の正本は [正準スキーマ](canonical-schema.md) です。** 型ごとのフィールド順、`enum` の固定番号、payload の定義をここへ複製しません。

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

| 規則 | 内容 |
| --- | --- |
| 署名対象 | `signature` 自身を除く全永続フィールド |
| 正準形 | **専用のバイナリエンコーダ**で作る |
| 含めるもの | `payloadType` と `schemaVersion` を署名対象へ含める |
| 再署名 | `ExportCommit` の insert / update のたび、`transact` の保存のたびに行う |
| 検証 | バイト列の**定数時間比較** |
| 移行 | 旧形式で検証してから新形式で再署名する |

**`payloadType` を含めないと、種別をまたいだ付け替えを検出できません。** 4 種のデータが同じ鍵で署名されているため、有効な `SubscriptionState` の blob を `UsageLedger` の保存先へ置いても検証を通ります。復号ではなく検証しかしていないため、内容の構造が偶然パースできれば通過します。

**`JSONEncoder` や binary plist を正準形として使いません。** 集合と配列の順序、`Date` の表現、辞書のキー順が実装とバージョンに依存し、**同じ意味の値から別の署名が出れば正規の起動が `integrityFailure` になります。**

##### 鍵と派生

**アルゴリズム・鍵長・派生ラベル・出力形式の正本は [正準スキーマ](canonical-schema.md) の 1.1 です。** 要点だけを示します。

| 項目 | 値 |
| --- | --- |
| 署名 | HMAC-SHA256（32 バイト固定） |
| 鍵導出 | HKDF-SHA256。マスター鍵 256 bit、派生鍵 32 バイト、`salt` は空 |
| 用途の分離 | 署名（`payload-signing-v1`）と `providerAssetKeyHash` のソルト（`source-provider-key-v1`）を別の派生鍵にする |

**署名とソルトを分けるのは、性質が違うからです。** ソルトは値の秘匿が目的、署名鍵は完全性の保証が目的であり、同じ鍵を使うと片方の運用（ローテーション等）がもう片方へ波及します。

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

> **対象とする:** 署名対象 payload（`UsageLedger` / `SubscriptionState` / `RemoteConfigState`）と署名付き `ExportCommit` 行の値改変、および 4 種の相互の付け替え。
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

運用面の上限（サイズ、レート制限、保存期間、同意撤回後の扱い、サーバーログ）は [運用](operations.md) が正本です。

### 10.2 リモート設定の検証とキャッシュ

`/v1/config` は無料枠、トライアル枚数、一括処理上限、並列数、トリアージ閾値、広告頻度、最低バージョン、機能停止フラグを変更できます。**壊れた値や古い値をそのまま適用すると、アプリ更新なしで全利用者を壊せます。**

```swift
struct RemoteConfigEnvelope: Sendable, Decodable {
    let schemaVersion: Int32
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

判定には canonical payload を使います（[正準スキーマ](canonical-schema.md)）。JSON の文字列比較では、キー順や空白の違いで誤って「変更あり」になります。**運用側の規約として、内容を変更するときは必ず `configVersion` を増加させます。**

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
| `expiresAt` の判定 | **`trusted ?? usageNow` を使う**（下記）。`retentionNow` は使わない |
| `appStoreID` | **数字のみの形式検証**（任意の URL を差し込ませない） |
| 強制更新 | **キャッシュの改変から `.required` を発生させない。** HMAC 不一致なら既定値＝更新なし |

**最後の行が重要です。** キャッシュを書き換えて `minimumSupportedVersion` を上げれば、他人の端末でアプリを止められます。HMAC 不一致を既定値へ倒すことで、改変は「更新なし」にしかなりません。

**設定の期限判定に `retentionNow` を使いません。** `retentionNow` は時計を過去へ戻すことを許容する時刻であり（6.3）、これを使うと**古い設定を延命できます。** 無料枠やトライアル枚数を高く設定していた時期の設定を、時計を戻すだけで使い続けられます。

| 条件 | 使う時刻 |
| --- | --- |
| 信頼できる時刻がある | **その値** |
| 無い | **`usageNow`**（単調。過去へ戻せない） |

失効の方向は利用者に不利ですが、**設定は失効してもバンドル既定値へ戻るだけで成果物を失いません。** 削除と違い取り返しがつくため、保守的に倒す方向が逆になります。

### 10.3 リモート設定で変更できないこと

**次はリモート設定から無効化できません。** 安全性の中核であり、サーバー側の事故や侵害で外せる状態にしません。

- 6.5 の確認画面（`reviewRequired` の解消なしに書き出せない）
- 6.1 の全顔初期マスク
- [書き出し Saga](export-saga.md) のファイル検証（サイズ・SHA-256・デコード）
- [書き出し Saga](export-saga.md) のコミットジャーナルと最終確定境界
- [画像処理](image-pipeline.md) の未解決 `bitmapID` によるエラー
- [運用](operations.md) の「未受け渡し出力があるときは受け渡し導線を先に出す」

**これらに対応する設定キー自体を `RemoteConfig` に持たせません。** 「フラグはあるが既定で有効」ではなく、**フラグを存在させない**という形にします。

**更新誘導は逆方向の扱いです。** `minimumSupportedVersion` はリモートから変更できますが、**取得に失敗した場合の既定は「更新なし」**です。バンドル既定値にも強制更新は含めません。

**一括処理の同時並列数は、アプリが対応を宣言した最大値を超えません。** リモートで 8 を指定されても、アプリ側の上限（v1 は 2）でクランプします。並列数は実装が想定するメモリ使用量と直結するため、サーバーから引き上げられる形にしません。

### 10.4 障害時

リモート設定の取得に失敗した場合はアプリ内の安全な既定値を使用します。**バックエンド障害で編集処理を停止させません**（仕様 21.6）。

---

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

同じ素材セットで要確認率も計測します。要確認率が高すぎると Pro の価値が失われ、低すぎると見落としが増えます。`extremePose` の角度閾値と `lowConfidence` の信頼度閾値はこの計測から決めます（[画像処理](image-pipeline.md) の受入条件）。

**iOS のバージョン更新で Vision の検出特性が変わることがあり、閾値の妥当性が崩れます。** 前リリースとの差が一定以上に開いた場合は閾値を見直します。

### 11.3 プライバシーとアクセシビリティ

プライバシーの受入テストとして、履歴一覧に未加工の顔が現れないこと、タスクスイッチャに未加工画面が残らないこと、アプリ専用領域に元画像の永続コピーが残らないこと、出力ファイルからメタデータが除去されていることを明示的に検証します。

アクセシビリティは仕様 29 章を受入条件とします。SwiftUI の `Canvas` は既定でアクセシビリティ要素を持たないため、`accessibilityLabel` / `accessibilityValue` / `accessibilityRepresentation` の明示的な付与が必須です。

実機マトリクスは仕様 30.8 に従います。

---

## 12. 逸脱と未決事項

v1 のリリース範囲、動画の扱い、課金訴求の分類、利用者向け表現は [商品面の決定](product-decisions.md) が正本です。

### 12.1 上位仕様書からの逸脱

| 仕様書 | 仕様書の内容 | 本設計 | 理由 |
| --- | --- | --- | --- |
| 4.2 / 32.1 | iOS / Android の二本立て | **v1 は iOS 単独。** Swift + SwiftUI | ADR 0001 |
| 4.1 | 対応 OS の下限を明示していない | **iOS 26 以降** | ADR 0001 |
| 12.7 | カスタムスタンプ上限 Standard 30 / Pro 100 | 両プラン 100 | 差別化として機能せず、Pro の焦点をぼかす |
| 13.8 | 撮影日時を削除対象に含む | EXIF 日時は既定で保持。ライブラリ登録日時は取得できる場合に引き継ぐ | 7.5。日時削除は写真アプリの並び順を壊す |
| 14.2 | 消費条件の解釈 | 「利用可能な加工済み出力の生成が完了した時点」＝手順 7。写真ライブラリ保存時点ではない | [書き出し Saga](export-saga.md)。保存せず OS 共有だけで無料枠を回避できる経路を塞ぐ |
| 16.3 | 一括処理モードは「全顔を同じ方法で隠す」「素材ごとに確認する」 | 「おまかせ一括」「1 枚ずつ確認」。どちらでも全写真に一度は目を通す | 6.5。トリアージは検出漏れを判定できない |
| 18.4 | 保存上限は 100 プロジェクト | 件数上限を撤廃し、保存期間（既定 30 日）と使用容量上限（既定 200MB）で管理 | 7.5。1 バッチ 50 枚に対して 2 バッチで枯渇する |
| 20.3 | 原子的書き出しの第 4 段階を「写真ライブラリへ保存する」とする | 生成と受け渡しの 2 段階に分離。生成の完了は手順 7 | [書き出し Saga](export-saga.md) |
| 21.5 | `/v1/installations` と購入検証 API | 実装しない | ADR 0004 |
| 32.1 | 初回リリース必須機能に動画を含む | v1 では動画を含めない | [商品面の決定](product-decisions.md)。段階リリース |

### 12.2 未決事項

| 項目 | 内容 | 決定時期 |
| --- | --- | --- |
| 商品 ID | 仕様 27.1 の商品 ID は暫定 | ストア登録時 |
| App Store ID | 更新誘導のリンク先に必要（[運用](operations.md)） | ストア登録時 |
| `lowConfidence` の閾値 | `FaceObservation.confidence` の下限。実素材の分布を見て決定（[画像処理](image-pipeline.md) / 6.1） | v1 実機検証時 |
| `extremePose` の角度閾値 | yaw / pitch の絶対値の上限。検出品質テストの結果から決定（6.1） | v1 実機検証時 |
| プライバシーポリシーの記載 | トライアル台帳（`SourceRecord`）を期限なく端末内へ保持することを記載し、7.5 の例外と整合させる | ストア申請前 |
| 共有結果 `.unknown` 後の利用者操作 | `generated` を維持するため、共有後に画面を離れると未保存の確認が出る。明示確認して `delivered` にするか、`generated` のまま保存・再共有・破棄を選ばせるか（[書き出し Saga](export-saga.md)） | 実装計画で確定 |
| 基本スタンプの意匠 | ベクターで自作する 12〜20 種の具体的な図案 | v1 実装中 |
| 履歴の使用容量上限 | 初期値 200MB は暫定。加工後サムネイルの実サイズを計測して確定 | v1 実装中 |
| カスタムスタンプの保存解像度 | 長辺 1,024px は暫定。顔が大きく写る素材での見え方を実機で確認（7.5） | v1 実機検証時 |
| トライアルのクレジット数 | 5 枚は暫定。転換率を見て調整可能な設定値とする | リリース後 |
| 一括処理の同時並列数 | 初期値は 1。写真のみのため 2 まで許容可能だが実機計測後に判断 | v1 実機検証時 |
| ファイル同期の方式 | `F_FULLFSYNC` と通常の `fsync` の所要時間差を実機計測し、耐久性とのつり合いで決定（7.1） | v1 実機検証時 |
| 手順 7-b の再確認しきい値 | `usageNow - finalizedAt` の許容差 5 分は暫定。手順 3〜7 の実測時間から確定（[書き出し Saga](export-saga.md)） | v1 実機検証時 |
| 信頼できる時刻の取得元 | `retentionNow` と `MonthlyIntegrityLock` の解除に使う時刻を、`/v1/config` のレスポンスヘッダから取るか RevenueCat の `CustomerInfo` から取るか（6.3） | 実装計画で確定 |
