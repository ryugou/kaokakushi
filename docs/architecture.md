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
| [書き出し Saga](export-saga.md) | 認可、`ExportCommit` の状態、手順 −2〜9、ロールバック、起動時復旧、実体喪失時の扱い、受け渡し |
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

本書は実装時に参照する現在の設計を定める。型、不変条件、状態遷移、処理順、障害時の挙動を一意に決めることが目的。**挙動の定義は本設計が正であり、`ui-mock/` は本設計に追従する**（モックのコードは実装へ流用しない）。上位仕様書からの逸脱は 12.1 に集約する。

### 1.2 実装体制と前提

実装者は Claude Code 単独。制約は次の 2 点。

- **プラットフォームの機能をそのまま使う。** 抽象化層を挟まず、Vision や Core Image の新機能を即座に利用する
- **単一言語で完結する。** ビルド構成、テスト実行、デバッグ経路をすべて Xcode に閉じる

**Android を後から追加する場合、ドメイン層の再実装が要る。** コードだけを仕様にしないため、ドメイン層の設計判断を本書へ文章として残す。

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
| バックエンド | なし（v1 はサーバレス。ADR 0005） |
| 対応 OS | iOS 26 以降 |

採用理由は ADR 0001（iOS 単独と SwiftUI）、ADR 0002（GRDB）、ADR 0005（自前バックエンドを持たない）にあります。

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

**台帳・購入状態キャッシュは `app.db` の平文テーブルとして保存する**（ADR 0005。改ざん対抗の暗号基盤は持たない）。Keychain は使わない。

**ラスタライズは `CGContext` を使う（`ImageRenderer` は不採用）。** `ImageRenderer` は `@MainActor` 隔離のため一括処理 50 枚が直列化される。`CGContext` はバックグラウンド実行でき、ピクセル形式とストライドも明示できる（[画像処理](image-pipeline.md)）。

**`UIViewRepresentable` / `UIViewControllerRepresentable` は広告バナーと共有シートのみに使う。**

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
│   ├── Persistence/         GRDB、ファイル管理
│   ├── MediaKit/            Vision / Image I/O / Core Image / PhotoKit
│   ├── Billing/             RevenueCat ラッパと権限解決
│   ├── Ads/                 AdPresenter（Google Mobile Ads）
│   └── Analytics/           イベント定義と送信（Sentry のみへ送る。9.2）
│
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

`Domain` がプロトコルを定義し、各アダプタが実装する。`Application` は `Domain` のプロトコルだけを通してアダプタを操作する。

**`App` が具象アダプタへ依存してよいのは組み立て時に限る。** `App` の `View` や状態オブジェクトがアダプタを直接呼ぶことを禁止し、呼び先は `Application` の Coordinator だけとする。**例外は 2 つの境界サービスのみ。**

| 規則 | 内容 |
| --- | --- |
| 例外の範囲 | `PhotoSelectionBridge` と `FileSelectionBridge` の 2 型のみ（[画像処理](image-pipeline.md)） |
| 使ってよいアダプタ | `ManagedFileStore` のみ |
| `View` からの呼び出し | bridge のみ。`ManagedFileStore` には触れない |
| CI のチェック | `App/Sources` 配下で `ManagedFileStore` を参照するファイルを、この 2 つに限定する |

ピッカーは SwiftUI の modifier であり `Domain` のプロトコルにできないため、結果を境界を越えられる型へ変換する場所が要る。範囲を型名で固定することでレビューと CI の両方で確認できる。

### 3.3 `Domain` の依存制約

| 使ってよい | 使わない |
| --- | --- |
| `Foundation`（`Date`、`Data`、`UUID`、`Calendar`、`TimeZone`） | `SwiftUI`（`CGSize`、`Color`、`Angle` を含む） |
| Swift 標準ライブラリ | `UIKit` / `CoreGraphics` / `CoreImage` |
| | `GRDB` / `Vision` / `Photos` / `Security` |

**`CGSize` / `CGRect` も使わない。** 必要な値型は `PixelSize` / `PixelRect` / `NormalizedRect` としてドメイン側で定義する（[画像処理](image-pipeline.md)）。`CoreGraphics` の型は描画系の前提（原点の左上/左下等）を暗黙に持ち込む。

**`Package.swift` の `dependencies` では強制できない**（Apple SDK のシステムモジュールは列挙なしで `import` できるため）。強制手段は次の通り。

| 手段 | 内容 |
| --- | --- |
| SwiftLint の `forbidden_imports` | `Domain/Sources/**` に対し上記の禁止モジュールを検出する |
| CI のチェック | `Domain/Sources` 配下の `import` 行を走査し、許可リスト（`Foundation` のみ）以外で失敗させる |
| SwiftLint のカスタムルール | `Domain` ターゲット内の `Date()` を禁止する（6.3 の時刻規約） |

`Application` にも同じ制約を課す（4.3）。この制約により、仕様 30.1 が要求する単体テスト項目がすべてシミュレータなしで実行できる。

### 3.4 ナビゲーション

画面は `Route` の enum で表現し、`Route` から `View` への解決を 1 箇所の `switch` に集約する。`NavigationStack` の `path` を `[Route]` として `@Observable` な状態オブジェクトが所有する。

**画面遷移をドメインの状態から導出しない。** 「未保存出力があるときは新規加工を開始できない」等の規則はドメインが判定し、UI は結果を表示するだけとする（遷移可否の判断を `View` へ書かない）。

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

**`actor` は再入可能であり、単独では「読み取りから保存完了まで」の論理的クリティカルセクションを保持できない。** `await` で中断すると同じ actor のメソッドへ別の呼び出しが入り、FIFO も保証されない。`transact`（台帳を読む→変換する→署名してファイルへ保存する）は保存が `await` を含むため、実装 actor に**明示的な待機キュー**を持たせる。

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
| **`unverifiedLedgerWrites`** | **保存する直前に、読み取った値 +1 へ更新する**（6.2）。呼び出し側の変換関数には触らせない |

**`unverifiedLedgerWrites` の加算は `transact` 内側・保存直前に無条件で +1 する**（呼び出し側加算では加算漏れが鮮度判定の抜け穴になる。6.2）。加算はトランザクションの一部であり、保存失敗時は増えない。

`ExportStartGate` も同じ構造。permit を保持したまま `await operation()` を実行し、`withExclusivePermit` から復帰するまで次の要求を待たせる。

##### キャンセル

**`CheckedContinuation<Void, Never>` はキャンセルを伝えられないため**、待機中にキャンセルされた continuation がそのままキューに残り、**キャンセル済みのタスクが permit を取得して書き出しを開始する**事故が起こりうる。次の規則で防ぐ。

| 規則 | 内容 |
| --- | --- |
| waiter の識別 | 各 waiter へ `UUID` を割り当てる |
| キャンセル時 | `withTaskCancellationHandler` でキューから該当 waiter を除去し、`CancellationError` で resume する |
| permit 取得直後 | `try Task.checkCancellation()` |
| 認可の直前 | **もう一度** `try Task.checkCancellation()` |
| 解放 | `defer` で必ず行う。キャンセル経路でも解放される |

**チェックは permit 取得直後と認可の直前の 2 回入れる。** 取得直後だけでは、その後 `transact` 開始までの間のキャンセルを拾えない。認可の直前が最後の安全な中断点。

##### 登録前キャンセルを取りこぼさない

**キューへの登録前にキャンセルされると、キャンセルハンドラの除去処理が対象を見つけられずキャンセル済み waiter が残る**（waiter ID 発行とキュー登録の間にキャンセルが割り込む競合）。**actor 内部に tombstone を持つ。**

```swift
// 最終形。上の宣言はこれに置き換わる
actor FileUsageLedgerStore: UsageLedgerStore {
    private var isBusy = false
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var waiters: [Waiter] = []             // FIFO
    private var canceledWaiterIDs: Set<UUID> = []  // 登録前キャンセルの記録
}
```

| 契機 | 操作 |
| --- | --- |
| キャンセルハンドラ | キューに居れば除去して resume。**居なければ `canceledWaiterIDs` へ記録する** |
| enqueue 時 | `canceledWaiterIDs` に自分が居るか、`Task.isCancelled` が真なら、**登録せず即座に `CancellationError` で resume する** |
| 記録の掃除 | resume した時点で `canceledWaiterIDs` から除く |

**`Task.isCancelled` の確認だけでは不足**（`withTaskCancellationHandler` の登録と読み取りの間にもキャンセルが起こりうる）。tombstone と併用してどちらの経路でも捕捉する。

##### 二重 resume の防止

キャンセルと permit 解放が競合すると同じ continuation を 2 回 resume してクラッシュする。actor 内部で **(1) waiter ID をキューから原子的に除去し、(2) 除去できた場合だけ `CancellationError` で resume する。** permit 解放側もキューの先頭を取り出す時点で存在を確認し、除去済み waiter は resume しない。**除去可否を resume の条件にすることで、どちらの経路が先に走っても resume は 1 回に収まる。**

**`CancellationError` は業務エラーとして扱わない**（Sentry へ送らず、キュー項目を `canceled` へ遷移させる制御フローとする。9.2）。

##### キャンセルの境界

| 時点 | 扱い |
| --- | --- |
| 手順 4 より前 | ロールバック。消費なし |
| 手順 4 以降・手順 7 より前（`readyToPublish` を含む） | 暫定会計を取り消してロールバック（[書き出し Saga](export-saga.md)） |
| 手順 7 の完了後 | **キャンセルではなく破棄として扱う。** 枠は戻さない |

手順 7 完了時点で成果物は公開済みであり正常生成が確定するため、UI 文言も取り消し可能であるかのように見せない。

### 4.3 Application 層

次の処理は `Domain`（純粋 Swift）にも `App`（SwiftUI）にも置けません。

- 書き出しの手順 −2〜9（[書き出し Saga](export-saga.md)）と補償トランザクション
- 起動時復旧、ロールバック
- DB・台帳・ファイルの協調、ゲートの取得と解放
- 出力の受け渡し

`App` へ置くと UI 状態と永続化 Saga が結合し画面離脱で復旧処理が止まる経路ができ、`Domain` へ置くと副作用と `await` が入り純粋 Swift の制約が壊れる。

```swift
// Application — Domain のプロトコルだけを使う
actor ExportCoordinator { }            // 手順 −2〜9、ロールバック
actor StartupRecoveryCoordinator { }   // 起動時復旧（[書き出し Saga](export-saga.md)）
actor OutputDeliveryCoordinator { }    // MediaSaver / SharePresenter の呼び出しと状態遷移
actor SourceImportCoordinator { }      // インポート / 再選択 / 再接続 / 複製（[画像処理](image-pipeline.md)）
actor WorkingSourceVerifier { }        // VerifiedWorkingSourceResolver の実装（同上）
actor HistoryDeletionCoordinator { }   // Project / Batch 削除、編集中の破棄（7.5）
```

##### 排他の単位

**`actor` であることを排他の根拠にしない**（4.2）。Coordinator ごとに、何を単位として直列化するかを明示する。

| Coordinator | 排他の単位 | 実装 |
| --- | --- | --- |
| `ExportCoordinator` | **アプリ全体で 1 件**（v1） | `ExportStartGate` の permit（[書き出し Saga](export-saga.md) の 1.5） |
| `OutputDeliveryCoordinator` | **`exportID` ごと** | 明示的な待機キュー（[書き出し Saga](export-saga.md) の 8.0） |
| `SourceImportCoordinator` | **`projectID` ごと**（新規インポートは新しい `projectID` なので競合しない） | 明示的な待機キュー |
| `WorkingSourceVerifier` | **`projectID` ごと**。`SourceImportCoordinator` と**同じ待機キューを共有する** | 明示的な待機キュー |
| `HistoryDeletionCoordinator` | **アプリ全体で 1 件。** 加えて**削除対象の各 `projectID` の待機キューを取得する**（下記） | 明示的な待機キュー |
| `StartupRecoveryCoordinator` | 起動時に 1 回のみ。**完了まで他のすべてを開始させない** | 起動シーケンス |

**`SourceImportCoordinator` を `projectID` で直列化する**（同じ `Project` への再選択と再接続の並行は `WorkingSourceRecord` の主キー衝突または正規化ファイルの孤児化を招く）。検証失敗時の無効化と `withVerifiedSource` のスコープ（[画像処理](image-pipeline.md)）も同じ待機キューで直列化する。

**`WorkingSourceVerifier` が待機キューを共有するのは `withVerifiedSource` の `body` が長時間スコープだからである。** 書き出し手順 1 やプレビュー描画の全体を包む間に `replaceWorkingSource` や無効化が走ると、開いている実体が削除対象になる。読み取りだけでも実体の寿命に対する排他が必要。

**`HistoryDeletionCoordinator` を全体で直列化する**（削除は複数の `Project` を跨ぐため `projectID` 単位の排他では `Batch` 削除を保護できない）。**加えて削除対象の各 `projectID` の待機キューも取得する。** 全体キューだけでは `withVerifiedSource` の `body` と排他されず、再検出が `body` 内側で `FaceTrack` を書き換える途中に同じ `Project` が削除されると外部キー違反になる（プレビュー描画中は `ExportCommit` が存在せず 7.5 の絶対保護も効かない）。

| 規則 | 内容 |
| --- | --- |
| 取得の順序 | **`projectID` の昇順に固定する。** 順序は **`UUID` の 16 バイトを符号なしバイト列として辞書順**（[正準スキーマ](canonical-schema.md) の 2.1 が `FaceTrackID` に定めるのと同じ規則）。`Batch` 削除で複数取得するため、順序が一意でないとデッドロックしうる |
| 取得の位置 | **DB トランザクションへ入る前。** 全体キューを取得したあと |
| 解放 | `defer` で必ず行う |

**`ExportStartGate` は取得しない**（2 つの全体キューを跨ぐ取得はデッドロックの発生源になる）。整合は `canDeleteHistoryUnit` が非終端の `ExportCommit` を絶対保護として同一 DB トランザクション内で見ることで成立する（7.5）。**書き出しと削除は互いに排他ではなく**、判定と削除を同一 DB トランザクションへ閉じることで整合する。`DatabaseQueue` がトランザクションを直列化するため判定と挿入は交差しない。

**`Application` が直接 `import` してはいけないもの**を明示する。

| 禁止 | 代わりに使う |
| --- | --- |
| `SwiftUI` / `UIKit` | UI は知らない。保護データの利用可否は `Domain` の `ProtectedDataAvailability`（7.4） |
| `GRDB` | `Domain` の永続化プロトコル |
| `Vision` / `CoreImage` / `Photos` | `Domain` の `FaceDetector` / `ImageEffectRenderer` / `MediaSaver` |
| `Security`（Keychain） | `Domain` の `CryptoKeyStore` |

この制約により、saga テストが偽実装だけで完結する（11 章）。

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

**検出された顔は、すべて加工対象の状態で初期化する。** ドメインの不変条件とし、UI の慣習に委ねない。`isMasked` は生成時に常に `true` であり、`false` になるのは利用者の明示的な操作によってのみ。**選び忘れが「隠しすぎ」に倒れるようにし、取り返しがつかない方向（露出）へは倒さない。**

派生する規則。

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

**警告は発生単位で持つ**（`Set<ReviewReason>` では同一理由の複数の顔を区別できず、1 人へ対応しただけで全員対応済み扱いになる）。

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

**「再検出しても同じ顔へ同じ ID が付く」とは保証できない**（検出順が変わるだけで別の `faceTrackID` になりうる）。誤った対応づけは別人の顔の判断をこの顔の判断として扱うことになり、匿名化確認として最悪の失敗となる。

- `ReviewIssueID` に `detectionRevision` を含める
- **再検出のたびに `detectionRevision` を増やす**
- 再検出時は、その写真の `ReviewIssue` / `ReviewDecision` / `Reviewed` を**すべて破棄する**

##### トリアージの限界

**このトリアージは検出された顔の品質しか評価できず、検出されなかった顔の存在はいかなる警告条件にも現れない。** 見落とし 1 人がいても他の顔に問題がなければ `triage` は空集合を返し `normal` に分類されるが、実際にはその 1 人が露出したまま書き出される。**`normal` は「検出結果の上で警告すべき点がないこと」を意味するに過ぎず、安全の保証ではない。** この限界があるため確認を必須とし、**アプリ側が `Reviewed` を立てることはない。**

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

検出ステータスは利用者の操作で変わらない。確認ステータスはアプリの判断で変わらない。

##### 認可時に検出ステータスを再導出する

**どちらも未署名の `app.db` にあり、書き換えれば `requiresUserReview`（6.5）が全件 `false` を返し個別確認なしで書き出せてしまう。** 再導出により防ぐ。

| 規則 | 内容 |
| --- | --- |
| `DetectionStatus` | **書き出し認可の内側で `triage` を再実行して再導出する。** 保存値を根拠にしない |
| `ReviewDecision` の完全性 | 再導出した `[ReviewIssue]` のすべてに `ReviewResolution` が記録されていることを**認可時に再検査する** |
| 再導出の入力 | 保存済みの `FaceTrack` と `detectionRevision`。**検出をやり直すのではなく `triage` だけを再実行する** |
| 不成立なら | 開始しない（[書き出し Saga](export-saga.md) の 1.1） |

**`triage` は純粋関数のため再実行費用は無視できる**（顔数に比例するのみで Vision 呼び出しを伴わない）。保存値は表示高速化のキャッシュとして扱い、認可の根拠にしない。

**`ReviewStatus` の書き換えは再導出だけでは防げない**（`reviewRequired` を再導出しても `reviewed` が立っていれば通る）。**`ReviewDecision` の完全性を再検査し、`ReviewIssueID` ごとの判断が実際に記録されていることを要求する。** 偽造には `ReviewIssueID` ごとに `ReviewDecision` 行を作る必要があり、`noFaceDetected` では「顔を隠さず保存する」明示選択（`unmaskedExportConfirmed`）の記録と等価になる。この規則は 10.3「リモート設定で変更できないこと」に対応し、確認画面を DB 直接改変からも守る。

##### 再導出の入力

`triage` は `DetectionResult` を受け取ります（上記）。その材料を `FaceTrack` が列として持ちます。

| `FaceTrack` の列 | 用途 |
| --- | --- |
| `faceTrackID` / `bounds` / `createdManually` | 描画と `RegionOrigin` の決定 |
| **`confidence`** | `lowConfidence` の判定 |
| **`yawDegrees` / `pitchDegrees` / `rollDegrees`** | `extremePose` の判定と描画の回転 |
| **`isSmallFace`** | `smallFace` の判定 |
| **`detectionPixelSize`**（`Project` の列） | 検出時の寸法。`isSmallFace` の根拠 |

**検出品質の列を `FaceTrack` へ持たせる**（持たせないと `triage` を再実行できず再導出が成立しない）。

##### `FaceTrack` の改変は防げないが、倒れる向きが逆になる

**`FaceTrack` も未署名であり、検出品質の列の書き換えや偽の顔行の挿入で `triage` の結果を変えられる。署名では防がない**（顔の集合は編集操作で頻繁に変わり、署名対象にすると編集のたびに台帳更新が要る）。改変で得られる利得は次の通り。

| 改変 | `triage` の結果 | 帰結 |
| --- | --- | --- |
| `isSmallFace` / `confidence` / 角度を書き換える | その警告が消える | 自分の写真について確認を省ける |
| **偽の顔行を挿入して `noFaceDetected` を消す** | 空集合になる | **偽領域が無害な場所を隠し、実際の顔は露出したまま書き出される** |
| 顔行を削除する | その顔の警告が消える | **その顔が加工対象から外れ、露出する** |
| 顔行を追加する（正規の手動領域） | 警告が増える | 確認が増える |

**いずれも「自分の写真を自分の判断で確認せずに書き出す」ことに帰着し、無料枠も有料機能も増えず露出するのは改変者本人の写真であるため、対象としない**（`unmaskedExportConfirmed` という正規の代替経路が既にあるため。9.3）。

**それでも `DetectionStatus` / `ReviewStatus` の再導出は行う。** 攻撃者の利得は同じでも、トラストバウンダリを「検出結果そのもの」まで押し下げる意味がある——`DetectionStatus` 1 列だけの書き換えは偶発的な不整合（バグ・移行失敗）でも起こりうるが、検出品質の列や顔行の整合を保ちながらの偽造は明確に意図した操作だけであり、再導出は前者を通さない。

**顔行を削除して露出させる方向はそもそも防ぐ対象ではない**（「取り返しがつかない方向へ倒さない」はアプリの既定挙動の規則であり、利用者が自分の意思で自分の写真を露出させる操作は禁じない）。

##### 要確認への対応

**`reviewRequired` かつ `unreviewed` の写真が 1 枚でも残っている間は一括書き出しを開始できない。**

**警告を消すのではなく、警告に対する利用者の判断を記録する**（検出結果は事実であり、確認したからといって事実は変わらない）。

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

**`manualRegionAdded` は `regionID` を持つ**（列挙値のみだと領域削除後も判断だけが残り「対応済み」と誤表示される）。

- 領域の作成と判断の記録は、**1 つのドメインコマンドで原子的に**行う
- 手動領域の作成が失敗すれば、判断も記録しない
- `regionID` の領域が削除されたら、対応する `ReviewResolution` も破棄して `unreviewed` へ戻す

`reviewRequired` の写真が `reviewed` になる条件は、その写真の `[ReviewIssue]` すべてに `ReviewResolution` が記録されていること（1 件でも未記録なら `unreviewed`）。発生単位にすることで「3 人のうち 1 人だけ対応して先へ進む」経路をなくす。`normal` の写真には `ReviewIssue` が無く `ReviewDecision` を作れない（確認の成立はモードで分かれる。6.5）。

**一括対応は理由別のグループ単位でのみ許可する**（個別対応を強いるのは現実的でないため）。

- そのグループのサムネイル一覧を表示した状態からのみ実行できる
- **`noFaceDetected` は一括対応の対象外**（何も加工されないまま通過する最も危険な経路であり個別判断を要する）

`DetectionStatus` と `ReviewIssue` は利用者の判断で変化せず、警告理由は書き出し後も記録として残る。

##### 単体処理で顔が 1 つも検出されない場合

**この節は単体処理に限る**（一括処理の顔 0 件は `noFaceDetected` と勘定の規則に従う。[書き出し Saga](export-saga.md)）。利用不可にはせず、手動で隠す範囲を追加する / 縦横比変更やメタデータ削除だけを行う / 編集を終了する、から選べるようにする。

加工なしの書き出しも仕様 14.2 の定義では消費対象。不意打ちを避けるため書き出し前に明示するが、**文言は `QuotaDecision`（6.3）で分岐させる**（一律「枠を使う」は 24 時間以内の再書き出しで誤案内になる。`unlimited` では無料枠に言及しない）。

### 6.2 能力と課金状態

RevenueCat の `CustomerInfo` をアプリ全体に流さず、純粋関数で畳み込みます。

```swift
/// Billing が CustomerInfo から抽出する、Domain が扱える値だけの写像
struct CustomerInfoSnapshot: Sendable, Equatable {
    let activeEntitlementIDs: Set<String>   // RevenueCat の entitlement 識別子
    let expirationDates: [String: Date]     // 同 ID → 失効時刻
    let willRenew: Bool
    let isInBillingRetry: Bool              // 支払い保留（pending の根拠）
    let isSandbox: Bool                     // サンドボックス購読の区分（下記）

    /// CustomerInfo.requestDate。サーバーが応答を生成した時刻。
    /// SDK がキャッシュを返した場合は元の応答時刻のまま動かない（下記）
    let requestDate: Date

    /// この値を Domain へ渡す時点の usageNow。requestDate と混同しない
    let observedAt: Date
}

/// 契約の等級。固定番号は正準スキーマ 3 章
enum Plan: Sendable, Hashable, Comparable {
    case free
    case standard
    case pro
}

/// 契約の状態。pending は支払い保留（仕様 5.4）
enum PlanStatus: Sendable, Hashable {
    case active
    case grace
    case pending
    case expired
    case revoked
}

func resolve(snapshot: CustomerInfoSnapshot, usageNow: Date) -> Entitlement

struct Entitlement: Sendable, Equatable {
    let plan: Plan               // free / standard / pro
    let status: PlanStatus       // active / grace / pending / expired / revoked
    let expiresAt: Date?
    let lastVerifiedAt: Date     // 権限を検証できた時刻
    let isSandbox: Bool          // サンドボックス購読（鮮度上限が 1 日）
}

/// ProtectedBlobStore へ保存する購入状態キャッシュ
struct SubscriptionState: Sendable, Equatable {
    let entitlement: Entitlement
    let willRenew: Bool
    let fetchedAt: Date            // このキャッシュを書いた時刻（usageNow）

    /// 採用した CustomerInfoSnapshot.requestDate。
    /// 「サーバーと本当に往復したか」の唯一の判定材料（下記）
    let lastRequestDate: Date
}
```

**`fetchedAt`（キャッシュを書いた時刻）と `Entitlement.lastVerifiedAt`（権限を検証できた時刻）は別の値**（オフラインでキャッシュを読み直しても後者は動かない）。

##### 「取得に成功」を SDK 境界で定義する

**`Purchases.getCustomerInfo()` はネットワーク不通でも throw せず、既定でキャッシュ済みの `CustomerInfo` を返す。これを「取得に成功」と扱うと、RevenueCat のホストを DNS/VPN で遮断するだけで、`lastVerifiedAt` の 14 日猶予と `unverifiedLedgerWrites` の 2 つの backstop が起動のたびにリセットされてしまう。** 判定材料は、SDK がキャッシュを返した場合は元の値のまま動かない **サーバー側生成時刻** `CustomerInfo.requestDate` とする。

| 規則 | 内容 |
| --- | --- |
| **「取得に成功」の定義** | **`CustomerInfoSnapshot.requestDate` が、`SubscriptionState.lastRequestDate` より新しいこと** |
| 等しいか古い場合 | **「取得に成功していない」と扱う。** キャッシュを置き換えず、`lastVerifiedAt` も動かさず、`recordEntitlementRefresh()` も呼ばない |
| SDK の呼び出し | **`CacheFetchPolicy` を「キャッシュを使わない」相当で明示する。** 既定値に依存しない |
| `CustomerInfoSnapshot.observedAt` | **`requestDate` と混同しない。** 前者は端末側の観測時刻、後者はサーバー側の生成時刻 |
| 保存先 | **`SubscriptionState.lastRequestDate`**（署名対象。[正準スキーマ](canonical-schema.md) の 4.2） |

`requestDate` の単調前進を条件とする（`TrustedTimeState` の受理条件と同形。下記 6.3）。**同じ規則を `/v1/config` にも課す**（`recordConfigRefresh()` は HTTP レスポンスを新規受信したときに呼び、保存の有無とは独立。10.2 の同一 `configVersion` の扱いを参照）。`Cache-Control: no-store` により `URLSession` のキャッシュは効かないが、規則としても固定する。

##### `isSandbox` の用途

サンドボックス購読は実費なしで取得でき更新周期も短いため、本番と同じ扱いにすると区別できない。

| 項目 | 規則 |
| --- | --- |
| 能力の付与 | **本番と同じ。** サンドボックスでも `ResolvedCapabilities` を制限しない（TestFlight と審査で有料機能を検証できなくなる） |
| `Entitlement` への伝搬 | **`isSandbox` を `Entitlement` と `SubscriptionState` へ持たせる**（下記） |
| 鮮度上限 | **サンドボックスは 1 日。** 本番の 14 日を適用しない |
| 分析・診断 | **`PlanKind` の区分値として送る**（9.2 の `sandbox`）。本番の集計へ混ぜない |

**鮮度上限だけを分ける**（サンドボックスの最短購読期間 3 分に対し 14 日の猶予は長すぎるため。能力は制限せず猶予だけを詰めることで検証は通り恒久化は防ぐ）。

要件は 3 点。

- **`pending`（支払い保留）では有料機能を付与しない**（仕様 5.4）。権限フラグはすべて `Entitlement` から導出し `plan` から直接導出しない
- **オフライン耐性**（仕様 25.3 / 27.3）。最後に検証成功した `Entitlement` を `ProtectedBlobStore` へ保存し、鮮度上限（14 日）の範囲でこのキャッシュにより有料機能を維持する
- **バックエンド障害で編集を止めない**（仕様 21.6）

##### 能力の解決

```swift
enum SingleExportAccess: Sendable, Equatable {
    case metered      // 月間枠の対象
    case unlimited    // 月間枠の対象外
}

struct ResolvedCapabilities: Sendable, Equatable {
    let singleExportAccess: SingleExportAccess
    let canUsePremiumStamps: Bool
    let canUseCustomStamps: Bool

    /// 有効な追加スタンプパック。リモート設定から能力解決時に写す（10 章）
    let enabledStampPacks: Set<String>
    let canUseProBatch: Bool      // 制限なしの一括処理
    let canUseBatchTrial: Bool    // クレジット消費による一括トライアル
    let shouldShowAds: Bool
}

enum CapabilityResolution: Sendable, Equatable {
    case resolved(ResolvedCapabilities)
    case verificationRequired
}

/// 能力解決の入力。キャッシュの読み込み結果とメモリ上の検証済み値
enum SubscriptionCacheState: Sendable {
    /// 署名検証を通ったキャッシュがある
    case loaded(SubscriptionState)
    /// キャッシュが存在しない（初回起動・再インストール直後）
    case missing
    /// 保護データ未解放などで今は読めない。verified は同一プロセス内の検証済み値
    case temporarilyUnavailable(verified: Entitlement?)
    /// HMAC 不一致。改変された値では動かさない
    case integrityFailure
}

func resolveCapabilities(
    _ state: SubscriptionCacheState,
    usageNow: Date,                  // 単調（6.3）。巻き戻せない
    trustedNow: Date?,               // 得られていれば優先する
    unverifiedLedgerWrites: Int32    // UsageLedger の 17 番目。時刻から独立した前進源（下記）
) -> CapabilityResolution
```

**`unverifiedLedgerWrites` は `UsageLedger` にあり `SubscriptionCacheState` から到達できないため、呼び出し側が台帳から読んで引数で渡す**（下記の鮮度判定を `resolveCapabilities` 内側で評価するために必須）。

| 状態 | 解決結果 |
| --- | --- |
| `loaded` かつ鮮度内（下記） | `Entitlement` から `ResolvedCapabilities` を導出する |
| **`loaded` かつ鮮度切れ** | **`verificationRequired`**（下記） |
| `missing` かつオンラインで取得成功 | 取得結果で `loaded` として解決する |
| `missing` かつオフライン | **`verificationRequired`** |
| `temporarilyUnavailable(verified: nil)` | **`verificationRequired`**（コールドスタート） |
| `temporarilyUnavailable(verified: 値)` | その値で解決する |
| `integrityFailure` | **`verificationRequired`**。Free へ暗黙降格させない |

##### キャッシュに鮮度上限を課す

**「失効が明示的に確認された場合のみ剥奪する」だけでは、RevenueCat の API ホストを DNS/VPN で落とすだけの端末改造不要の攻撃により、解約後も `loaded` が成立し続け月間枠も整合性封鎖も参照しなくなる。** また `usageNow = max(now, lastObservedAt, trusted)` は後退しないことしか保証せず前進は保証しないため、**通信を遮断して端末時計を据え置けば 14 日は到来しない。** そこで時刻に加え、時刻に依存しない量（台帳への書き込み回数）でも測る。

| 項目 | 規則 |
| --- | --- |
| フィールド | **`UsageLedger.unverifiedLedgerWrites: Int32`**（17 番目。[正準スキーマ](canonical-schema.md) の 4.1） |
| 意味 | **最後に `Entitlement` の取得へ成功して以降、`UsageLedgerStore.transact` が成功した回数** |
| 増加の契機 | **`transact` の内側で無条件に +1。** 呼び出し側が指定するのではなく、台帳を書けば必ず増える |
| 上限 | **2000 回**（1 枚あたり 4 回の換算。下記） |
| リセット | **専用ポート `UsageLedgerStore.recordEntitlementRefresh()` のみ**（下記）。変換関数からは触れない |
| 保存先 | **`UsageLedger`**（署名対象）。DB へ置くと書き換えられる |
| 台帳修復時の値 | **上限値（2000）。** 0 にすると台帳を壊すたびにリセットできる（6.3） |

| 条件 | 判定 |
| --- | --- |
| `Entitlement.expiresAt` が `referenceNow` を過ぎている | **鮮度切れ** |
| `referenceNow − Entitlement.lastVerifiedAt` > **14 日**（`isSandbox` なら **1 日**） | **鮮度切れ** |
| **`unverifiedLedgerWrites` >= 2000** | **鮮度切れ** |
| 上記以外 | 鮮度内 |

**判定は `>=` とする**（`> 2000` では台帳修復時に入れる値 2000 が鮮度内になり、「壊せばリセットできる」を塞ぐという修復値の目的が達成されない。6.3。境界を含めることで修復直後に即座に鮮度切れとする）。

##### リセットを専用ポートへ閉じる

**加算は `transact` の内側で構造的に強制されるが、リセットは変換関数からも呼べてしまう**（4.2。台帳を組み立て直す変換関数はこの 2 フィールドを 0 にできる）。**`UsageLedgerStore` に専用メソッドを 2 つ置く**（宣言は[書き出し Saga](export-saga.md) の 0 章が正本）: `recordEntitlementRefresh()` と `recordConfigRefresh()`。

| 規則 | 内容 |
| --- | --- |
| 変換関数が見る型 | **`LedgerMutableView`。** `UsageLedger` から `unverifiedLedgerWrites` と `ledgerWritesSinceConfigFetch` を除いた射影 |
| リセットの経路 | **上記 2 メソッドのみ。** どちらも内部で `transact` と同じ排他区間を取る |
| リセット後の値 | **0 を書き、保存直前の +1 により保存値は 1 になる**（加算は無条件のため） |

**変換関数が見る型からリセット対象フィールドごと外す**（射影型 `LedgerMutableView`。`transact` にフラグ引数を足す形だとその引数を渡す経路が抜け穴になるが、射影型ならリセットは「書けない」のではなく「存在しない」ため忘れようがない）。

##### リセットと blob 保存の順序

**リセットと `SubscriptionState` / `RemoteConfigState` の保存は別 blob（`UsageLedger` とは別。7.1）のため必ず 2 つの独立した書き込みになり、順序を固定しないと片方だけ成功した状態で古いキャッシュが延命される。**

| 順序 | 中断したときの結果 |
| --- | --- |
| **blob の保存 → リセット**（採用） | 新しいキャッシュに古いカウンタが残り、**早期に鮮度切れ**になる。安全側 |
| リセット → blob の保存 | **古いキャッシュに 2000 回ぶんの寿命が追加される。** 取得成功のたびに保存直前で強制終了すれば、解約済みの `Entitlement` を無期限に延命できる |

| 規則 | 内容 |
| --- | --- |
| `recordEntitlementRefresh()` | **`SubscriptionState` の保存が成功したことを確認してから呼ぶ** |
| `recordConfigRefresh()` | **`/v1/config` の HTTP レスポンスを新規に受信したら呼ぶ。保存の有無に依らない**（下記） |
| リセットが失敗した場合 | **`SubscriptionState` を巻き戻さない。** 次回の取得成功でもう一度リセットを試みる |

加算側と同じ原則で、片方だけ進んだ状態が安全側（早期の鮮度切れ。通信すれば解消し成果物は失わない）へ倒れる順序を選ぶ。

**鮮度上限を課すのは有料権限を持つキャッシュだけとする**（Free のキャッシュには剥奪すべき有料権限が無く、課すとオフライン利用者が無料枠ごと止まり仕様 25.3/27.3/21.6 に反する）。

| キャッシュから導出した `ResolvedCapabilities` | 鮮度判定 |
| --- | --- |
| **有料能力を 1 つ以上含む** | **上表を評価する** |
| **有料能力を 1 つも含まない** | **評価しない。常に鮮度内として扱う** |

**判定キーは導出後の `ResolvedCapabilities` とし、`plan != .free` を直接見ない**（将来 Free へ有料相当の能力を付与する変更が入ると、`plan` 直接参照では鮮度免除が同時に穴になる。導出後の能力で判定すれば能力追加に対して壊れない）。

**カウンタの巻き戻しは対象外**（低かった時点の `UsageLedger` blob を丸ごと差し替えれば鍵が同じため `valid` として検証を通り、無料枠も一緒に巻き戻る。9.3 が「過去の正規 blob を丸ごと復元するリプレイ攻撃」として明示的に対象外とする範囲であり、このカウンタに限った弱点ではない）。

**回数は時計から独立する**（端末時刻の操作に関わらず、書き出せば手順 4 が、月が変われば `rollPeriod` が台帳を書くため、「有料機能を使い続けながら検証を永久に回避する」経路が消える）。

**「起動回数」ではなく「台帳書き込み回数」にする**（起動は台帳を読むだけで書かない。既存の書き込みトランザクションの内側で数えれば、トランザクションの原子性がそのまま冪等性になる。起動時専用の加算にすると中断時の重複/欠落判定が新たに要る）。**手順 4 で数える**（手順 7 は DB のみのトランザクションで `ProtectedBlobStore` を同時更新できず、手順 7 後に別トランザクションを設けると強制終了で加算を落とせる。7.1、[書き出し Saga](export-saga.md) の 4）。使わなければ増えないのは欠陥ではなく、書き出しも月次ロールも起きていない＝有料機能継続利用の利得も発生していない状態を表す。

##### 上限値の換算

**1 枚の書き出しで台帳は複数回書かれるため、上限を枚数へ換算するにはその回数を数える。**

| 契機 | 回数 |
| --- | --- |
| インポート Saga の手順 4（`ProjectSourceSnapshot` の作成。[画像処理](image-pipeline.md)） | 1 |
| 書き出し手順 −2（`SourceLease` と `TrialReservation` の追加） | 1 |
| 書き出し手順 4（台帳への暫定適用） | 1 |
| 書き出し手順 8（pending の昇格） | 1 |
| **合計（新規写真 1 枚の書き出し）** | **4** |

新しい素材を選ばない再書き出しは 3 回（インポートを通らない）。月次ロールと起動時の孤児回収も台帳を書くが、頻度が低いため換算に含めない。

| 単位 | 台帳の書き込み回数 |
| --- | --- |
| 新規写真 1 枚の書き出し | 4 |
| 新しい素材を選ばない再書き出し | 3 |
| **Pro の 1 バッチ（50 枚）** | **200** |

| 上限 | 相当する枚数 | Pro のバッチ数 |
| --- | --- | --- |
| `unverifiedLedgerWrites` **2000** | **約 500〜670 枚**（新規のみ〜再書き出しのみ） | **約 10 バッチ** |
| `ledgerWritesSinceConfigFetch` **4000** | 約 1,000〜1,330 枚 | 約 20 バッチ |

**上限は回数で切る**（2000 回はオフラインで約 500 枚、Pro の一括処理で約 10 バッチに相当し、通常利用でそこまで通信できない状況は起こらない）。旅行や式の写真を数百枚オフラインで処理する利用は通常の範囲であり、上限がそれを止めてはならない。

**本質は「無制限だったものが有限になったこと」である。** 攻撃者は解約後に永久にオフラインを維持する必要があり、一度でもオンラインになれば `requestDate` が前進した取得により Free の `Entitlement` が返って延命が終わる。**正当な Pro 利用者を止める害（旅行先・式当日で成果物を得る機会を失う）と比較し、正当な利用者を止めない側へ寄せた値とする。**

**`TrustedTimeState` の 6 時間鮮度にも同じ「時刻凍結」の問題がある**（`usageNow` を凍結すると `usageNow − observedAtUsageNow` が 0 のままになり、一度得た信頼時刻が永久に鮮度内として通る）。`trustedNow` の用途ごとの影響と対策は次の通り。

| `trustedNow` の用途 | 凍結の影響 | 対策 |
| --- | --- | --- |
| 整合性封鎖の解除（`trustedMonth` 経由） | **利得なし**（下記） | 不要 |
| 台帳修復の分岐選択（「ライブの信頼時刻がある場合」。6.3） | 陳腐な値が「ライブ」として通るが、封鎖の基準が古い月になるだけ | 不要 |
| `rollPeriod` の `ledgerTimeZone` 更新条件 | 条件が恒久的に成立するが、更新は「端末 TZ で求めた年月が保持中の値と等しいとき」に別途縛られる | 不要 |
| **リモート設定の `expiresAt` 判定**（10.2） | **失効しなくなる**（下記） | **要る** |

**封鎖の解除には利得がない**（解除には `trustedMonth` が封鎖時の月より後であることが必要で、時計を止めている間は月も進まず解除も進まない。凍結を解けば `trustedMonth` は進むが同時に `usageNow` も跳ねて `consumedExportIDs` はどのみち空になり、破損させても結果は同じ。逆向き＝時計だけ進めて古い信頼時刻を保持する操作は `trustedNow` が `nil` になり `lockedUntilReinstall` へ倒れるため攻撃者に不利）。

**リモート設定の期限判定にも同じ道具（時刻に依存しない台帳書き込み回数）で対策する**（10.2 の `trustedNow ?? usageNow` のみでは、配信直後に時計を凍結されると同じ理由で恒久化されうるため）。

| 規則 | 内容 |
| --- | --- |
| フィールド | **`UsageLedger.ledgerWritesSinceConfigFetch: Int32`**（18 番目。[正準スキーマ](canonical-schema.md) の 4.1） |
| 増加の契機 | **`transact` の内側で `unverifiedLedgerWrites` と同時に +1**（4.2） |
| 上限 | **4000 回**（`>=` で判定する） |
| 効果 | **上限に達した last-known-good は、`expiresAt` を過ぎたものと同じに扱う**（機能停止フラグ以外がバンドル既定値へ戻る。10.2） |
| リセット | **専用ポート `UsageLedgerStore.recordConfigRefresh()` のみ**（6.2 のリセット規則）。**HTTP レスポンスを新規に受信したら呼ぶ。保存が起きたかどうかとは独立**（下記） |
| 台帳修復時の値 | **上限値（4000）** |

**`RemoteConfigState` ではなく `UsageLedger` に置く**（加算契機が `UsageLedgerStore.transact` である以上、同じトランザクションで書ける場所でなければ冪等性を失う。`RemoteConfigState` は別 blob であり台帳のトランザクションから同時更新できない。7.1）。

**上限は購入状態（2000）より緩い 4000 とする**（失効はバンドル既定値へ戻るだけで操作を止めないため、先に有料権限の再検証を要求する形にする。通信できる状態へ戻れば両方とも同時に解消する）。

**`RemoteConfigState` の保存を条件にできない**（10.2 の「`configVersion` が同じで canonical payload も同一なら無視する」規則により、設定内容が変わらない限り保存は起きないため）。保存を条件にすると次が成立する。

| 経路 | 結果 |
| --- | --- |
| 運用側が `configVersion` を上げない期間に台帳を 4000 回書く | last-known-good が失効し、バンドル既定値へ戻る |
| その後も毎回取得に成功する | **保存が起きないためリセットされない。** 運用側が `configVersion` を上げるまで復帰しない |

条件は「HTTP レスポンスを新規に受信したこと」とし保存に値するかとは独立とする（通信できていることが確認できた時点で last-known-good を信頼し続ける根拠は回復している）。`SubscriptionState` は `requestDate` が前進していれば必ず保存するため同じ問題はない（6.2）。

**`expiresAt` の超過も鮮度切れに含める**（`status == .active` のまま `expiresAt` を過ぎたキャッシュは更新確認が取れていない状態であり有効とする根拠がない）。

**`verificationRequired` は「Free として動かす」ことではない。** 有料機能を新規に付与せず、書き出しの認可も開始しない（未検証での有料機能付与と、正当な利用者の無言降格の両方を避ける）。

**`enabledStampPacks` を能力解決の内側で `ResolvedCapabilities` へ写す**（`Domain` の判定関数はリモート設定の型 `RemoteConfig` を参照しないため。3.3）。

**`Plan` を参照してよいのは能力解決の内側だけとする**（クォータ判定・広告頻度・開始ゲート・一括可否・編集可否・UI 活性制御はすべて `ResolvedCapabilities` を見る。`Plan` を渡すと `status = pending` でも `plan != free` が成立し規則を迂回する）。**「確認できない」を型で表す**（`ResolvedCapabilities` を必ず返す関数では `metered` は暗黙降格、`unlimited` は未検証付与になるため `verificationRequired` を独立させる）。

`verificationRequired` の間の挙動。

- **書き出しの認可を開始しない**（`ExportStartGate` を通さない）
- **有料機能を新規に付与しない**
- **Free へ降格したとも表示しない**
- **カスタムスタンプ・履歴・プリセットを削除しない**
- 再試行と購入の復元を提示する

**`verificationRequired` で書き出しを止める範囲は限られる**（Free のキャッシュは鮮度切れにならない）。この状態へ入るのは、有料権限を持つキャッシュが古くなった場合と、能力をそもそも判定できない場合（`missing` かつオフライン / `temporarilyUnavailable(verified: nil)` / `integrityFailure`）だけ。前者は通信すれば復帰でき、後者はオフラインでの初回起動という限られた場面。

##### `missing` を Free として扱ってよい条件

キャッシュの不在だけでは、初回インストールなのか再インストールした有料利用者なのかを区別できない。

| 状況 | 解決結果 |
| --- | --- |
| `missing` かつ RevenueCat への問い合わせが**成功**（購読なし） | `resolved`（Free 相当の能力） |
| `missing` かつ問い合わせが**成功**（購読あり） | `resolved`（該当プランの能力） |
| `missing` かつ**オフライン等で問い合わせ不能** | **`verificationRequired`** |
| `loaded` かつオフライン かつ鮮度内 | `resolved`（キャッシュで維持） |
| `loaded` かつ**鮮度切れ** | **`verificationRequired`** |

**キャッシュが無い状態でオフラインなら書き出しを止める**（Free として進めると再インストール直後の有料利用者に無料枠を消費させ、`unlimited` として進めると未検証で有料機能を渡すため、どちらも取れない）。購読の確認は初回起動時に一度行えば済むため、制約はオフラインでの初回起動という限られた場面だけ。

##### 購入状態キャッシュの読み込み失敗

`SubscriptionState` も `ProtectedBlobStore` 上の署名付きデータであり `ProtectedLoadResult`（7.2）を返す。

| 結果 | 扱い |
| --- | --- |
| `valid` | オフラインでも**鮮度上限（14 日）の範囲で**このキャッシュで有料機能を維持する |
| `missing` | RevenueCat へ問い合わせる。成功するまでは `verificationRequired` |
| `integrityFailure` / `unsupportedSchema`（移行不能） | キャッシュを信頼せず、RevenueCat から再取得する |
| `temporarilyUnavailable` | 上書きせず再試行する。**メモリ上に検証済みの `Entitlement` があれば維持し、無ければ `verificationRequired`**（下記） |

- 取得に成功すればキャッシュを置き換える
- **オフラインで再取得できない場合、有料権限を新規に付与しません**
- **カスタムスタンプ、履歴、プリセットなどのデータは削除しません**
- 利用者へは購入状態を確認できない旨を提示し、**再試行**と**購入の復元**への導線を出す

**コールドスタートでは維持する値がない**（プロセス起動直後はメモリ上の `Entitlement` が存在しないため「既存を維持する」が成立しない）。

| 状況 | 扱い |
| --- | --- |
| メモリ上に検証済みの `Entitlement` がある | **維持する**（セッション中の一時障害） |
| 無い（コールドスタート） | **`verificationRequired`。** 書き出しを開始せず、再試行を提示する |

**Free へ降格したと表示しない**（検証できない状態と失効した状態は異なる）。

##### 解約・降格後の既存データ

**判定軸は「作成時のプラン」ではなく「現在の設定内容が要求するプラン」とする。**

判定の入力は `Project` 行そのものではなく、出力へ影響する設定だけを集めた値とする（`Project` は `app.db` のテーブルであり `Domain` の型ではない。7.1）。

```swift
/// 能力判定と Paywall 文言の入力。Project とその子行から組み立てる
struct ProjectCapabilityRequirement: Sendable, Equatable {
    /// この Project の RenderSpec が使う全スタンプの必要能力。
    /// StampRequirement の定義は [書き出し Saga](export-saga.md) の 1.1.1
    let stampRequirements: Set<StampRequirement>
}

/// 表示用。Paywall の文言を組み立てるためだけに使う
func requiredPlan(_ requirement: ProjectCapabilityRequirement) -> Plan

/// 実装上の判定。プラン名ではなく能力で決める
func canEdit(
    _ requirement: ProjectCapabilityRequirement,
    capabilities: ResolvedCapabilities
) -> Bool
```

**`RenderSpec` を直接受け取らない**（判定に必要なのはスタンプの必要能力だけであり座標や強度は無関係。同じ `ProjectCapabilityRequirement` を書き出し認可の `authorizeRenderSpec`〈同 1.1.1〉と共有し UI と認可で判定材料を一致させる）。**`requiredPlan` の戻り値で可否を決めない**（プラン名の比較だと `status = pending` が素通りする）。作成時のプランで判定すると、Standard 時代に作ったプロジェクトが Free で編集できないのに同じ元写真を選び直せば Free の機能で同じものを作れるという説明のつかない差が生まれるため、現在の設定内容で判定する。

| 操作 | Free 範囲のプロジェクト | 有料スタンプを含むプロジェクト |
| --- | --- | --- |
| 閲覧 | 可 | 可 |
| 削除 | 可 | 可 |
| 変更せず再書き出し | 可（6.3 のクォータ判定に従う） | 可（同左） |
| **編集して書き出し** | **可（6.3 のクォータ判定に従う）** | Standard 以上 |
| **Free 版として複製** | — | **可** |

Free 範囲のプロジェクトとは、モザイク・ぼかし・黒塗り・基本スタンプ・手動領域・縦横比・メタデータ設定だけを使っているものをいう。

**「Free 版として複製」** は、有料スタンプを基本の隠し方へ置き換えた複製を作る操作（元のプロジェクトは変更しない）。

- 置き換え先は利用者に選ばせる（モザイク / ぼかし / 黒塗り / 基本スタンプ。自動決め打ちは意図しない見た目になる）
- 選んだ方法を、有料スタンプを使っていた領域へ一括で適用する
- **領域の位置と大きさ、およびその他の出力設定はそのまま引き継ぐ**

##### 複製 Saga

**新しい `projectID` が付くため、元の台帳要素をそのまま共有できない**（`ProjectSourceSnapshot` は `projectID` ごとに 1 件であり参照ではなく複製が要る）。

| 順 | 操作 | 保存先 | 失敗時 |
| --- | --- | --- | --- |
| 1 | 新しい `ProjectID` を発行する | — | — |
| 2 | 元素材の実体がある場合、**`VerifiedWorkingSourceResolver` を通してコピー元を取得し**（[画像処理](image-pipeline.md)）、**別の `WorkingSourceFile` を作る**。SHA-256 とサイズを測る | ファイルシステム | 手順 6 へ |
| 3 | **1 つの台帳トランザクション**で、元 snapshot の内容を新しい `projectID` で追加し（`registeredAt` は現在時刻）、実体を作った場合は `WorkingSourceBinding` も同時に追加する。identity は既存 `SourceRecord` へ解決する（無ければ作成） | ProtectedBlobStore | 手順 6 へ |
| 4 | DB トランザクションで `Project` と設定を複製し、有料スタンプの領域を選択された方式へ置換する。実体を作った場合は `WorkingSourceRecord` も作る | DB | 手順 5 へ |
| 5 | 手順 4 が失敗したら、**追加した snapshot と binding を補償削除し、参照されなくなった `SourceRecord` も同じトランザクションで削除する** | ProtectedBlobStore | 起動時 GC へ委ねる |
| 6 | 失敗したら、作成済みのファイルを `PendingFileDeletion` へ積む | ファイルシステム | 起動時 GC へ委ねる |

**手順 3 を 1 トランザクションにする**（snapshot だけが入って binding が入らない状態は実害は無いが補償対象が 2 つに分かれ手順 5 が複雑になる）。**手順 3 で `SourceRecord` を解決する**（通常は既存レコードが見つかるが、不変条件 9 を満たすことを明示的な手順として持つ。6.4）。**処理用ファイルを共有しない**（同じ `WorkingSourceFileRef` を 2 つの `Project` が指すと一方の書き出し完了/破棄が他方の素材を削除する。`WorkingSourceRecord` の削除規則は参照カウントを持たない）。**元素材の実体が無い場合は `WorkingSourceRecord` と binding を作らずに複製する**（利用者の再選択時に通常の再接続〈[画像処理](image-pipeline.md)〉が走り、照合対象は手順 3 で複製した新しい snapshot）。**`ExportedSettingsEntry` は複製しない**（複製先はまだ書き出しておらず「変更せず再書き出し」の対象にならない）。この Saga も `SourceImportCoordinator` が所有する（ファイル・DB・台帳の 3 者を跨ぐ点はインポートと同じ）。

バッチ**全体**に対する操作は内容によらず能力で決まる。

| 操作 | 必要な能力 |
| --- | --- |
| バッチ履歴の閲覧 / バッチ内の個別写真の閲覧 | なし |
| バッチ全体への設定反映 / 再実行 / エラー写真のみの再試行 | `canUseProBatch` |

原則は 4 つです。

- **閲覧と削除は常に可能**とする
- **既存の作品をそのまま取り出す権利は残す**
- **有料機能の新規利用にのみ契約が必要**とする
- **データそのものは削除しない**（仕様 12.6）。再契約時にカスタムスタンプと一括設定プリセットをそのまま再利用できる

**「変更せず再書き出し」はアプリ提供の追加スタンプとカスタムスタンプを同一に扱う**（規則を分けると「どちらのスタンプを使ったか」で挙動が変わり説明できなくなる）。有料スタンプを含むプロジェクトでは、エフェクト・強度・領域・出力設定のいずれかを変更した時点で Standard 以上が必要になる（Free 範囲のプロジェクトではこの判定を行わない）。

##### 比較対象を署名済み台帳へ持つ

**現在の設定ハッシュと比べる対象「最後に正常書き出しした設定」は、未署名の DB 行へ置くと書き換えるだけで変更後のプロジェクトを「変更なし」にできるため、`UsageLedger` と同じ `ProtectedBlobStore` の署名対象へ持たせる**（型は `ExportedSettingsEntry`。6.3）。

**暫定と確定を別の集合に分ける**（1 つにすると、手順 7 前にコミットが破損し孤立 lease 0 件で台帳に触れずコミットだけ削除された場合、成功していない設定が「最後の正常書き出し」として残ってしまう）。

| 契機 | 操作 |
| --- | --- |
| 手順 4 | `AccountingIntent.settingsEntryToApply` を **`pendingExportedSettingsEntries` へ**追加する。確定側には触れない |
| **手順 8** | **`published` に到達した証拠を確認し、`exportedSettingsEntries` へ昇格する**（[書き出し Saga](export-saga.md) の 3） |
| ロールバック | `ownerExportID` がこの `exportID` の pending を削除する。確定側は触らない |
| **署名不正コミットの破棄** | **pending を削除する。** `SourceLease.accountingMode` と同じく、台帳側だけを根拠にする |
| 判定 | `currentSettingsHash == entry.settingsHash` **かつ** 素材が `ProjectSourceSnapshot.identity` と一致する。**pending は判定に使わない** |
| entry が無い | **「変更せず再書き出し」の対象にしない。** Standard 以上を要求する |
| `Project` の削除 | **`Project` 削除 Saga の手順 3**（DB 確定後）で両方とも削除する（7.5） |
| 起動時 | **コミットが存在しない pending を削除する**（手順 5.5） |

**昇格の根拠は `published` 状態のコミット行**（手順 7 でコミットを消さずに `published` を書くため、手順 8 が中断しても次回起動で同じ昇格を冪等に再実行できる。到達していないコミットの pending は昇格せず削除する）。**置換前の確定値を `intent` に持たない**（ロールバックは pending 削除のみで確定側を触らず戻すべき値が存在しない。2 回目以降の書き出しでは手順 8 の昇格が既存確定値を新しい値で上書きする操作になる）。

**設定ハッシュだけでは足りない**（再書き出しには処理用素材が要り、24 時間で消えていれば再接続する。別の写真を結び直せると設定が同じまま中身の違う写真が「変更なし」として無料処理される）。再接続は署名済み `ProjectSourceSnapshot.identity` との一致を必須とする（[画像処理](image-pipeline.md)）。

**最初の正常書き出し記録が無いプロジェクトは対象外**（有料スタンプを含むプロジェクトが Free 環境で初めて現れる経路〈バックアップ復元等〉は存在しないため。7.4。実際には降格前に必ず 1 回は書き出している）。要素数は `grants` などと同じく有界であり、`Project` が消えた entry は起動時復旧の手順 5.5 が回収する（[書き出し Saga](export-saga.md) の 5）。**降格の事実自体はクォータ判定に影響しない**（判定に使うのは素材の同一性と経過時間のみ）。

##### 広告表示頻度

仕様 15.3 / 15.4 を純粋関数として実装する。

- 検出中、顔選択中、編集中、書き出し中、書き出しエラー対応中、課金処理中は表示しない
- 初回書き出し完了時には全画面広告を表示しない
- 全画面広告は最大でも 2〜3 回の書き出しにつき 1 回
- 同一セッションで連続表示しない
- 広告取得失敗でアプリ処理を止めない

### 6.3 クォータ・grant・トライアル

##### 台帳は 1 つ

**通常クォータ、`ExportGrant`、トライアル台帳を別々の値として持たず、1 つの署名済みオブジェクトとして原子的に置き換える**（別々に更新すると片方だけ書けた状態が生じる）。

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
    let pendingExportedSettingsEntries: [ExportedSettingsEntry]  // 手順 4 の暫定適用（6.2）
    let exportedSettingsEntries: [ExportedSettingsEntry]   // 変更せず再書き出しの比較対象（6.2）
    let workingSourceBindings: [WorkingSourceBinding]      // 処理用実体との結び付き（画像処理）
    let projectSourceSnapshots: [ProjectSourceSnapshot]    // 編集中素材の identity（画像処理）
    let lastObservedAt: Date                     // 後退させない基準時刻
    let monthlyIntegrityLock: MonthlyIntegrityLock  // 破損修復による月間枠の封鎖
    let lastTrustedMonth: TrustedUTCMonth?       // 信頼できる時刻から導出した最新の UTC 年月
    let trialIntegrityLocked: Bool               // 破損修復によりトライアルを封じたか
    let ledgerTimeZone: LedgerTimeZone           // 月次更新の基準。信頼時刻を得た起動でのみ更新
    let unverifiedLedgerWrites: Int32            // 最後の Entitlement 取得成功以降の台帳書き込み回数（6.2）
    let ledgerWritesSinceConfigFetch: Int32      // 最後のリモート設定取得成功以降の同回数（定義 6.2 / 効果 10.2）
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
    /// 認可時に確定した勘定。署名不正コミットの破棄で消費を確定するために要る
    let accountingMode: ExportAccountingMode
}

/// 正常書き出しで確定した設定。「変更せず再書き出し」の比較対象（6.2）
struct ExportedSettingsEntry: Sendable, Equatable {
    let projectID: ProjectID
    let settingsHash: ProjectSettingsHash
    let exportedAt: Date
    let ownerExportID: ExportID      // ロールバックの根拠
}

/// プロジェクトの素材 identity。Project の寿命まで保持する
struct ProjectSourceSnapshot: Sendable, Equatable {
    let projectID: ProjectID
    let identity: SourceIdentity
    let representation: SourceRepresentation
    let capture: OriginalCaptureMetadata     // EXIF 由来（正準スキーマ 5.1.1）
    let libraryCreationDate: Date?           // PHAsset 由来。権限がある場合のみ
    let registeredAt: Date                   // 素材を結び付けた時刻
}
```

`exportedSettingsEntries` と `projectSourceSnapshots` を台帳へ置くのは、どちらも認可に使う値であり未署名の DB 行では書き換えられるため。

| 集合 | 一意条件 | 上限 |
| --- | --- | --- |
| `pendingExportedSettingsEntries` | `projectID` ごとに 1 件 | 通常は同時に進行できる書き出しの数（v1 は 1）。**署名不正コミットが残る間は保留された孤児 pending が積み上がる**（下記） |
| `exportedSettingsEntries` | `projectID` ごとに 1 件 | 履歴の保存期間内の `Project` 数 |
| `projectSourceSnapshots` | `projectID` ごとに 1 件 | 履歴の保存期間内の `Project` 数 |
| `workingSourceBindings` | `projectID` ごとに 0 件または 1 件 | 処理用ファイルを持つ `Project` 数 |

**`pendingExportedSettingsEntries` の上限は「同時 1 件」ではない**（署名不正コミットが存在する間、孤児 pending の自動回収は全件保留され〈[書き出し Saga](export-saga.md) の 5 の手順 5.5〉、`Project` 削除 Saga も pending だけを持ち越すため、進行中の書き出しが 0 件でも孤児 pending が複数残りうる。これを不変条件違反として実装しない）。複数残ること自体は異常ではなく、解消時に手順 5.5 がまとめて回収する一時的な状態。ただし 2 件以上の孤立 pending は 6.2 の「一意に決められない」分岐へ倒れ、利用者は最終手段（「すべて破棄して続ける」）を選ぶまで書き出せないことを受容する（署名不正コミットが存在する状態は既に異常であり、復旧手段がある限り袋小路にはならない）。

##### 素材の実体と identity を分ける

処理用ファイルの寿命と、素材が何であったかの記録の寿命は別。

| 対象 | 内容 | 寿命 |
| --- | --- | --- |
| `WorkingSourceRecord`（DB） | 未加工の原寸ファイルへの参照 | **作成から 24 時間**。期限で削除し、キューを `paused(.sourceReselectionRequired)` へ |
| `WorkingSourceBinding`（台帳） | いま処理してよい実体のハッシュとサイズ（画像処理） | **`WorkingSourceRecord` と対応する。** 更新は台帳先行、削除は DB 先行で行い、片側だけ進んだ区間は起動時に解決する |
| `ProjectSourceSnapshot`（台帳） | `SourceIdentity`・撮影日時・登録時刻 | **`Project` の寿命まで**。削除は `Project` 削除時のみ |

**identity と実体は別の集合に分ける**（identity は `Project` の寿命まで要るが実体との結び付きは処理用ファイルが存在する間しか意味を持たず、1 つにまとめると 24 時間で消える値のために snapshot 全体を書き換えることになる）。**snapshot は実体と一緒に消さない**（再選択は候補の `SourceIdentity` を snapshot と比較して同一性判定するため、照合元が消えると判定不能になる。履歴の再編集と「変更せず再書き出し」は署名済みの素材 identity を必要とする）。**`ProjectSourceLocator` では代用できない**（未署名の DB 行にある平文参照でありファイル取り込みでは `nil`。これだけを根拠にすると別の写真を同じ `Project` へ結び直しても設定ハッシュだけが一致し「変更せず再書き出し」が通ってしまう）。

**書き出しが追加する要素（`grants` / `trialEntries` / `exportedSettingsEntries`）には `ownerExportID` を持たせる**（ロールバックで「この書き出しが追加したもの」を台帳そのものから判別するため。DB 側の記録だけでは台帳を書いた直後に落ちた場合に判別できない）。`projectSourceSnapshots` と `workingSourceBindings` は書き出しが追加・削除しないため所有者概念を持たない。`trialReservations` と `sourceLeases` は `exportID` を持つため別途不要。

**消費は件数ではなく書き出し ID の集合で持つ**（`Int` では同一 `exportID` の再適用の拒否も特定書き出しの消費取消も実装できない）。各集合の要素数には上限があるため線形探索で構わない。

| 集合 | 上限 |
| --- | --- |
| `sourceRecords` | 参照元がある素材のみ。削除規則により有界（6.4） |
| `sourceLeases` / `trialReservations` | 同時実行数。v1 は 1 |
| `grants` | 24 時間以内に成功した書き出しの素材数 |
| `trialEntries` | `BatchPolicySnapshot.trialCreditCount`（既定 5・hard max 5。[運用](operations.md) の 2.1） |
| `consumedExportIDs` | 月間上限（既定 5） |
| `exportedSettingsEntries` / `projectSourceSnapshots` | 履歴の保存期間内の `Project` 数。`Project` 削除で回収する（7.5） |

##### 判定

```swift
enum QuotaBlockReason: Sendable, Equatable {
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
    monthlyLimit: Int,               // リモート設定の freeMonthlyExportLimit（10 章）
    usageNow: Date,                  // 正規化済み。端末時刻を直接渡さない
    trustedNow: Date?,               // ledgerTimeZone を更新してよいかの判定に使う
    trustedMonth: TrustedUTCMonth?,  // 封鎖の解除判定に使う。端末時刻由来の値を渡さない
    deviceTimeZone: TimeZone         // 採用の可否は rollPeriod が決める（下記）
) -> QuotaEvaluation
```

**`timeZone` をそのまま使わない**（月次更新の基準は台帳が保持する `ledgerTimeZone` であり、`deviceTimeZone` は「更新してよいか」の判定材料として渡すだけ。下記）。`evaluate` は内部で `rollPeriod` を呼ぶ。**判定結果だけでなく更新後の台帳も返す**（判定だけでは `lastObservedAt` の前進・月次更新・期限切れ grant の削除を永続化できない）。**`monthlyLimit` を引数で受け取る**（上限はリモート設定で変わるため`Domain` の定数にできない。10 章。`RemoteConfig` そのものは渡さず `Domain` がその型構造に依存しないようにする）。

判定順序。

1. `lastObservedAt` を `usageNow` へ前進させる
2. 期間更新と期限切れ `grant` の整理を適用する
3. `access == .unlimited` なら `unlimited`
4. **`monthlyIntegrityLock` が解除条件を満たしていなければ `blocked(.ledgerIntegrityFailure)`**
5. `ledger.grant(forSourceID:)` があり `usageNow - firstSuccessAt < 24h` なら `freeReexport`
6. `consumed >= limit` なら `blocked(.monthlyLimitReached, limit)`
7. それ以外は `consume`

**手順 4 を月間上限の判定より前に置く**（破損修復後は `consumedExportIDs` が空になり上限判定だけでは通過してしまう）。理由を型で分けるのは、破損時に上限到達と表示するのが事実に反するため。**有料プランで `unlimited` を返す場合も手順 1・2 は必ず実施する**（時刻更新と grant 整理を止めると、降格した瞬間に古い状態から判定が始まる）。

##### `ExportGrant` の作成規則

**`ExportGrant` は書き出し時のプランにかかわらず作成する。**

| 動作 | 条件 |
| --- | --- |
| `grants` へ素材を追加する | 利用可能な出力の生成が正常に完了した時点＝手順 7 の完了（[書き出し Saga](export-saga.md)）。プランを問わない |
| `consumedExportIDs` へ `exportID` を追加する | `QuotaDecision` が `consume` のときだけ |
| `firstSuccessAt` を更新する | しない。同一素材の有効な grant があれば維持する |

有料プランで grant を作らないと、Standard で書き出した 1 時間後に Free へ降格して再書き出しした場合に `freeReexport` にならず枠を消費してしまう。`firstSuccessAt` を更新しないのは、再書き出しのたびに窓が延びると 24 時間の上限が意味を失うため（「会計時に有効な grant があるか」で判断すると破れるため、認可時の `firstSuccessAt` を保存して維持する。[書き出し Saga](export-saga.md) の preserve）。

##### 時間判定の基準時刻

**すべての時間判定に端末時刻をそのまま使わず、正規化を 1 か所に集約する**（各判定が個別に `max` を書くと書き忘れた箇所だけ防御が抜ける）。

```swift
struct TimeAnchor: Sendable, Equatable { let lastObservedAt: Date }

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

アンカーは `UsageLedger.lastObservedAt` として保持する。

**信頼時刻を `usageNow` の下限に含める**（含めないと封鎖解除は信頼年月を見て消費判定は端末時刻を見る状態になり、時計を前月へ戻して台帳を壊し前月基準で封鎖させた後サーバーから現在月を取得して即解除し空になった当月枠を使う、という経路が残る。同じ時刻源から両方を導く）。

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
| 信頼できる時刻がある（下記） | その値 |
| 端末時刻が `lastObservedAt` から 30 日を超えて前進している | **`nil`** |
| それ以外 | 端末時刻 |

##### 信頼できる時刻の取得元

**`/v1/config` の HTTPS レスポンスを主取得元とする**（全利用者が通る自前の経路であり契約の有無に依存しない）。

| 項目 | 規則 |
| --- | --- |
| 主取得元 | **`/v1/config` のレスポンス本文に含まれる `serverTime`**（UTC epoch milliseconds の `Int64`） |
| 補助経路 | RevenueCat の `CustomerInfo.requestDate`。設定取得が失敗し、購入状態の取得に成功した場合のみ |
| どちらも失敗 | **`trustedNow = nil`。** 端末時刻を信頼時刻として扱わない |
| 鮮度 | 観測から **6 時間以内**の値だけを「最近取得した信頼時刻」とする。超えたら `nil` |
| 保存 | **独立した `TrustedTimeState`** として `ProtectedBlobStore` へ保存する（下記・7.2） |
| 単調性 | 保存済みの信頼時刻より**過去の値を受理しない**（巻き戻しの防止） |

**HTTP の `Date` ヘッダは使わない**（CDN 等が差し替えた値を掴む可能性があり、キャッシュヒット時は取得のたびに同じ古い値が返る。`serverTime` はレスポンス本文の値とし、`/v1/config` の応答全体を `Cache-Control: no-store` の動的応答とする。10.2）。**鮮度を 6 時間とするのは整合性封鎖の解除に使うため**（長すぎると古い時刻で解除が通り、短すぎるとオフライン利用者が解除できない。封鎖は月単位の判定であり 6 時間の粒度で足りる）。**過去の値を受理しないのはサーバー応答の差し替えによる巻き戻しを防ぐため**（HTTPS で保護されるが保存側でも単調性を守る）。

##### `TrustedTimeState`

**信頼時刻の永続化を `RemoteConfigState` へ相乗りさせない**（設定取得が失敗して RevenueCat だけが成功した場合、保存すべき信頼時刻はあるのに `lastKnownGood` が存在しない可能性がある。独立した署名対象にする）。

```swift
/// 最後に受理した信頼時刻。ProtectedBlobStore の署名対象（7.2）
struct TrustedTimeState: Sendable, Equatable {
    let trustedEpochMillis: Int64      // 受理した信頼時刻（UTC epoch ms）
    let observedAtUsageNow: Date       // 観測した時点の usageNow。鮮度判定の基準
    let source: TrustedTimeSource
}

enum TrustedTimeSource: Sendable, Hashable {
    case remoteConfig    // /v1/config の serverTime
    case revenueCat      // CustomerInfo.requestDate
}
```

| 項目 | 規則 |
| --- | --- |
| 鮮度判定 | **現在の `usageNow` − `observedAtUsageNow` ≤ 6 時間** |
| 基準に端末時刻を使わない理由 | `usageNow` は単調であり、**時計を巻き戻しても鮮度を延ばせない。** 前進ジャンプでは早期に失効するが、封鎖が続くだけで成果物は失わない |
| 受理条件 | `trustedEpochMillis` が保存済みの値以上であること |
| `integrityFailure` | **`missing` と同じ扱い。** 信頼時刻なしとして封鎖側へ倒す。台帳のような修復は不要 |

符号化順・`payloadType`・`blobKeyRawValue` は [正準スキーマ](canonical-schema.md) の 4.4 が正本で、HMAC ゴールデンテストの対象。

**2 つに分けるのは単調性が削除判定と両立しないため**（単調な時刻は一度未来へ進むと時計を戻しても未来のままで削除が保留されない。`retentionNow` に `max` を掛けないことで時計を直したときに通常判定へ復帰する。巻き戻しによる保持期間延長は利用者に不利ではないため許容する）。**`Domain` の時間判定は `now` を引数に取らない**（端末時刻に触れてよいのは `observeTime` の呼び出し口 1 か所のみ。3.3 の lint 規約）。**未来への時計変更のうち枠の前倒し取得は脅威モデルの対象外とし**（9.3）、**破壊的削除だけを保守的に倒す**（前倒しは利用者に有利で成果物を失わないが削除は取り返しがつかない）。

##### 整合性封鎖

**封鎖の解除条件を端末年月との比較にすると、年月を作れる側が解除条件を作れてしまう**（時計を過去月へ変更→台帳を破損→その月として修復→時計を戻す、で即座に解除できる）。

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

**封鎖の年月に `YearMonth` を使わない**（端末の `TimeZone` で算出するため、信頼できる絶対時刻を得ても月境界付近でタイムゾーンを変えるだけで `封鎖の年月 < 観測した年月` を成立させられる）。

| 用途 | 年月の型 | 算出 |
| --- | --- | --- |
| 通常クォータの `period` | `YearMonth` | 端末の `TimeZone`（利用者の感覚に合わせる） |
| **整合性封鎖の基準と解除** | **`TrustedUTCMonth`** | **UTC 固定。端末タイムゾーンを一切使わない** |

`lastTrustedMonth` も `TrustedUTCMonth` とする（封鎖基準と解除観測の両方を UTC で算出することが要点。片方だけ UTC にすると、もう片方が動くだけで差を作れる）。

##### 由来を型で区別する

**`usageNow` だけを渡すと信頼時刻由来か端末時刻由来かを受け手が判別できず、封鎖の解除に使うと端末時刻で解除できてしまう**（`usageNow` は `max(now, lastObservedAt, trusted)` のため信頼時刻が無くても値は入る）。`observeTime` は `trustedNow` と `trustedMonth` を別フィールドとして返し、**封鎖の解除に使うのは `trustedMonth` だけとする**（`evaluate` が引数に取る `trustedNow` は `ledgerTimeZone` 更新可否の判定〈`rollPeriod` 内部手順 2〉、リモート設定の期限判定〈10.2〉、購入状態の鮮度判定〈6.2〉にのみ使う）。

| 判定 | 使う値 |
| --- | --- |
| 24 時間の窓、月次更新、`finalizedAt` | `usageNow` |
| 削除・保持期間 | `retentionNow` |
| **整合性封鎖の解除** | **`trustedMonth`。`nil` なら解除しない** |
| リモート設定の `expiresAt` | `trustedNow ?? usageNow` |

**`trustedMonth` が `nil` のとき封鎖は解除されない**（信頼時刻を一度も得られなければ封鎖が続く、という規則が型の上で自明になる）。

| 規則 | 内容 |
| --- | --- |
| 解除に使える年月 | **信頼できる時刻から UTC で導出した `TrustedUTCMonth` のみ** |
| 端末時刻・端末タイムゾーン由来の年月 | **解除に使わない。** 何度変更しても封鎖は解けない |
| 封鎖の基準年月 | **端末年月を使わない**（下記） |
| 信頼できる時刻を一度も得られない | 封鎖は維持される |

**修復時の封鎖基準を端末年月にできない**（過去月へ戻してから台帳を壊すと、その過去月基準で封鎖され次の信頼時刻取得で即解除される＝破損させた側が解除条件を選べてしまう）。

| 修復時の状況 | 封鎖 | `period` / `lastObservedAt` / `lastTrustedMonth` |
| --- | --- | --- |
| **ライブの信頼時刻を取得できる** | `.lockedUntilTrustedMonthAfter(信頼時刻の年月)` | **信頼時刻に揃える** |
| **信頼時刻を取得できない** | **`.lockedUntilReinstall`** | 端末時刻を `lastObservedAt` に置き、`lastTrustedMonth` は `nil` |

**信頼時刻が無いまま基準年月を決めず、`lockedUntilReinstall` へ倒す**（あとから信頼時刻を得ても解除しないため基準年月を偽装する経路が消える）。**破損回数による段階的な引き上げは行わない**（回数の保存先が壊れた `UsageLedger` の外に無く、新たな署名済み状態が要るため。信頼時刻を得られない破損は上の 2 分岐で最初から再インストール要求になる）。**信頼できる時刻を得られないまま Free 枠が使えない状態は意図した結果**（有料利用者は `paidUnlimited` であり月間枠を参照しないため課金済み利用者が締め出される経路は作らない）。

##### 月初リセットと時刻巻き戻し

**月初にリセットするのは `consumed` だけ。`grants` は月をまたいで保持する。**

```swift
// 完全な引数は下記の「タイムゾーンの前進で月をまたがせない」を参照
func rollPeriod(...) -> UsageLedger {
    // 基準は台帳が保持する ledgerTimeZone。端末の現在値ではない
    let current = YearMonth(from: usageNow, in: effectiveTimeZone)
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

24 時間の窓は月の境界と無関係（`grants` を月初に空にすると 7/31 23:59 の書き出しを 8/1 00:01 に再書き出しした場合に `freeReexport` にならない）。タイムゾーンを西へ移動して月をまたぎ戻しても、端末時計を手動で戻しても `period` は後退しない。

##### タイムゾーンの前進で月をまたがせない

**後退方向だけを保証すると東向きの変更で月をまたげてしまう**（UTC−12 から UTC+14 で最大 26 時間前進し、月末なら `current > ledger.period` が成立して `consumedExportIDs` が空になる。戻しても `period` は後退しないため実際の月境界より最大 26 時間早く枠が回復する）。

| 規則 | 内容 |
| --- | --- |
| 月次更新の判定に使うタイムゾーン | **台帳が保持する `ledgerTimeZone`**。端末の現在値を直接使わない |
| 更新の契機 | **`trustedNow` を得ており、かつ更新後も `period` が前進しない**場合のみ、現在のタイムゾーンへ更新する |
| 更新後に月が変わる場合 | **更新を保留する。** 次の月次更新（保持中のタイムゾーンで月が変わった時点）の後に反映する |
| 信頼時刻が無い間 | 保持している値を使い続ける。端末の現在値へ追従しない |

**更新の可否に「`period` が前進しないこと」を含める**（含めないと、通信できる状態で月末に UTC+14 へ変えるだけで同じ前倒しが成立する）。更新が月境界を越えさせる場合は保留し保持中のタイムゾーンで月が変わってから反映する（利用者の体験は「月替わり通知が数時間ずれる」程度）。渡航した利用者は次の月替わり以降に新しいタイムゾーンで判定される（月の途中で移動した場合はその月の残りを移動前の基準で過ごし、枠の総量は変わらない）。

**更新は `rollPeriod` の内側で行う**（月次更新と同じ関数に閉じることで「更新してから判定する」順序が一意に決まる）。

```swift
func rollPeriod(
    _ ledger: UsageLedger,
    usageNow: Date,
    trustedNow: Date?,               // 更新の可否に使う
    deviceTimeZone: TimeZone         // 端末の現在値。採用するかは内部で決める
) -> UsageLedger
```

| 順 | 操作 |
| --- | --- |
| 1 | `ledger.ledgerTimeZone` で `current = YearMonth(from: usageNow, in:)` を求める |
| 2 | **`trustedNow != nil` かつ `deviceTimeZone` で求めた年月が `current` と等しいなら、`ledgerTimeZone` を更新する** |
| 3 | 等しくないなら更新を保留する（次回以降へ持ち越す） |
| 4 | 更新後の `ledgerTimeZone` で `current > ledger.period` を判定する |

**手順 2 の条件が「月をまたがせない」を実現する**（端末の現在タイムゾーンで求めた年月が保持中の値と同じなら更新しても `period` は動かない。違うならその更新は月境界を越えさせるため保留する）。**保留は永続化しない**（次回起動で同じ判定を行い、月が変わっていれば更新できる。保留回数を数える必要はない）。

```swift
/// UsageLedger の一部。月次更新の基準タイムゾーン
struct LedgerTimeZone: Sendable, Equatable {
    let identifier: String      // "Asia/Tokyo" などの IANA 識別子
}
```

**信頼時刻を得た起動でのみ更新するのは、更新そのものを利得にしないため**（正当な渡航では通信もできるため信頼時刻が得られ数時間〜数日で追従するが、オフラインでタイムゾーンだけ変える操作では追従しない）。**`period` の後退防止（`current > ledger.period`）は独立した防御として維持する**（前進の抑制と後退の禁止の両方を課す）。整合性封鎖の `TrustedUTCMonth`（UTC 固定）とは別の値で、こちらは「利用者の感覚に合う月境界」を保ちながら操作されないようにする値。

##### 一括処理トライアル

Free および Standard の利用者が Pro の中核である一括処理を一度も試さずに判断することを避けるため、**一括処理でのみ使える 5 枚分のクレジット**を付与する。**月間の無料枠とは別勘定とする**（月間枠から引くと一括処理を試しただけでその月の枠を使い切ってしまう。端末内処理のため限界原価はない）。

**回数制ではなくクレジット制とする。**

- **同じ元素材について、初回の正常生成時にだけ 1 クレジットを消費する**
- 使い切るまで有効。失敗した写真では消費しない
- **中止した場合、手順 7 が未完了の写真は消費しない。既に手順 7 まで完了した写真のクレジットは戻さない**
- Pro へ加入済みの場合は消費しない

**クレジットの消費判定は `sourceID`（6.4）に従う**（加工内容が異なっても同じ元写真であれば追加消費しない）。

**残クレジット数は保存せず、台帳から導出する。**

```swift
// policy は BatchPolicySnapshot（6.5）。DB から読んだ直後に hard max へクランプ済み
let remainingCredits =
    usageLedger.trialIntegrityLocked
        ? 0
        : max(
            0,
            policy.trialCreditCount
                - usageLedger.trialEntries.count
                - usageLedger.trialReservations.count
        )
```

**クランプ後の値を使う**（`BatchPolicySnapshot` は未署名の DB 行であり、読み出し直後に hard max〈5〉と最小値〈0〉へ丸める。6.5。丸める前の値を渡すと DB 書き換えでクレジットを増やせる）。残数と台帳の両方を保存すると異常終了時に不整合な状態が生じるため導出とし、正を 1 つにする。**`trialIntegrityLocked` を導出に含める**（台帳を修復すると `trialEntries` が空になり、フラグを見なければ表示上 5 枚すべてが復活する）。

##### クレジットの予約

**認可だけではクレジットを占有できない**（認可結果を台帳へ残さないと、残り 1 枚の状態で異なる素材の 2 件が並行認可されたとき両方とも同じ件数を見て `batchTrial(true)` になる）。v1 は全体排他ゲート（[書き出し Saga](export-saga.md)）により同時 1 件なのでこの経路は塞がれているが、**予約は並列化後も必要。**

| 契機 | 操作 |
| --- | --- |
| 認可時（手順 −2） | `SourceLease` に加えて、該当素材の `TrialReservation` を**同じ `transact` の中で**追加する |
| `Prepared` の保存に失敗（手順 0） | **補償トランザクション**で予約・`SourceLease` を削除し、参照元を失った `SourceRecord` を GC する |
| 台帳への適用（手順 4） | **同じ台帳トランザクション内で**予約を削除し `trialEntries` へ移す。`SourceLease` も削除する |
| 最終確定（手順 7） | **台帳には触らない**（DB のみ） |
| ロールバック | この `exportID` が所有する予約または `trialEntries` を削除する |
| 起動時 | コミットの無い予約を孤児として削除する。**その完了後に新規認可を許可する** |

**消費済み台帳に期限は設けない。これは意図した仕様**（最初に選んだ 5 枚は以後も何度でも試せる。理由: 6 枚目以降を処理できるわけではなく体験範囲は最大 5 枚のまま／端末内処理のため繰り返しても限界原価が発生しない／期限を設けるとその境界の説明が要り試用導線として複雑になる）。**トライアルで解放するのは「一括処理という操作方式」だけ**（エフェクト・スタンプの利用範囲は `ResolvedCapabilities` をそのまま参照し、一括処理へ入ったことで能力を書き換えない。追加スタンプまで一時解放すると Standard の価値が曖昧になる）。

##### 改ざん耐性

`UsageLedger` を平文で保存すると DB 書き換えだけで無料枠が無制限になる。一方で仕様 14.5 は不正利用防止のためだけの端末固有識別子の収集を禁じているため、折衷案として Keychain の鍵で HMAC 署名を付与し（9.1）、サーバー照合も端末識別子の収集も行わない。

`ProtectedBlobStore` の読み込み結果の分類と扱いは 7.2 が正本。以下は `integrityFailure` に対する規則。

**空の `UsageLedger` を作り直さない**（台帳は消費件数に加えどの素材が grant を持ちトライアルを消費したかを保持しており、空にすると無料枠もトライアルも全回復し改ざんの動機になる）。**`integrityFailure` は一時的な読み取り結果のままにせず、保守的に修復した永続状態へ変換する**（読み取り失敗のたびに判断すると `lastObservedAt` を失い `usageNow` を算出できず、封鎖解除の手立ても grant の書き込み先も無くなる）。

検出した時点で、次の内容の**新しい署名済み台帳**を作る。

| フィールド | ライブの信頼時刻がある場合 | 取得できない場合 |
| --- | --- | --- |
| `lastObservedAt` | **信頼時刻** | 検出時点の端末時刻 |
| `period` | **信頼時刻の年月** | 検出時点の端末年月 |
| `lastTrustedMonth` | **信頼時刻の UTC 年月** | `nil` |
| `monthlyIntegrityLock` | `.lockedUntilTrustedMonthAfter(信頼時刻の UTC 年月)` | **`.lockedUntilReinstall`** |
| `trialIntegrityLocked` | `true` | `true` |
| `ledgerTimeZone` | **信頼時刻の取得元と同じ起動の端末タイムゾーン** | **端末の現在タイムゾーン**（封鎖中なので月次判定に利得なし） |
| **`unverifiedLedgerWrites`** | **上限値（2000）** | **上限値（2000）** |
| **`ledgerWritesSinceConfigFetch`** | **上限値（4000）** | **上限値（4000）** |
| `grants` / `consumedExportIDs` / `trialEntries` / `trialReservations` / `sourceRecords` / `sourceLeases` / `pendingExportedSettingsEntries` / `exportedSettingsEntries` / `projectSourceSnapshots` / `workingSourceBindings` | **すべて空** | **すべて空** |

**修復は `transact` を通さないが排他区間は取る**（専用ポート `UsageLedgerStore.repairLedger(evidence:)` で行い、変換関数を適用しないため 4.2 の「保存直前に +1」も適用されず、表の値がそのまま保存される）。

##### カウンタを 0 にできない

**修復が掛ける `monthlyIntegrityLock` と `trialIntegrityLocked` は Free の月間枠とトライアルの封鎖であり有料キャッシュの鮮度には効かない。** 0 へ戻す実装にすると、台帳を壊すたびに鮮度がリセットされ 6.2 で塞いだ経路が復活するため、**取得できないときは最も保守的な値（上限値）を入れる**（空〈0〉は安全側ではなく攻撃側の値であるため）。

**`SubscriptionState` blob を削除する方式は採らない**（修復と同時に購入状態キャッシュを消す方式は次の 2 点が成立しない）。

| 検討した方式の問題 | 内容 |
| --- | --- |
| **直そうとした問題を直さない** | オフラインの有料利用者は、封鎖の理由が「カウンタが上限」から「キャッシュ `missing`」へ変わるだけで**書き出せないまま**。オンラインの有料利用者は**上限値のままでも `recordEntitlementRefresh()` で復帰できる**（6.2） |
| **Free 利用者を止める** | 削除は Free 利用者の `SubscriptionState` にも及ぶ。`missing` かつオフラインは `verificationRequired` なので、**月間無料枠が残っていても書き出せない。** 6.2 が避けた事態そのもの |

さらに、「台帳を壊すと購入状態キャッシュも失う」という結合の前提は、**壊さずに巻き戻せば働かない**（低かった時点の `UsageLedger` blob を丸ごとコピーして戻せば鍵が同じで `valid` として検証を通り `integrityFailure` にならず修復も走らない。9.3 が対象外と宣言した blob リプレイの範囲であり、結合を主軸に据える方式はここで無効になる）。

##### 修復後に書き出せる条件

**「Standard / Pro の通常書き出しは許可」は再検証を済ませた後の状態を指す**（修復直後は上限値が入っているため鮮度切れであり `verificationRequired` の間は認可を開始しない。6.2）。

| 状況 | 書き出し |
| --- | --- |
| 修復直後・**オンライン** | `requestDate` が前進した取得に成功すれば `recordEntitlementRefresh()` が走り、**月間枠に依存せず書き出せる** |
| 修復直後・**オフライン** | **書き出せない。** 再検証まで `verificationRequired` |

**オフラインで書き出せないことを受容する**（台帳が改ざん・鍵喪失〈7.2「HMAC 鍵の喪失と改ざんは端末側から区別できない」〉した状態で有料権限を未検証のまま付与する根拠はない。一度オンラインになれば解消し履歴・マイスタンプ・未受け渡し出力は失われない）。**Free 利用者への影響はない**（6.2 のとおり鮮度判定は有料能力を含む `ResolvedCapabilities` にしか掛からず、修復が課す月間枠封鎖は別規則で信頼できる時刻由来の年月で解除される）。

##### 修復も排他区間の内側で行う

**「`transact` を通さない」と「排他を取らない」は別**（修復済み台帳の保存を `ProtectedBlobStore.save` の直接呼び出しにすると `UsageLedgerStore` の待機キュー〈4.2〉を経由しない書き込み経路が生まれる。4.3 の排他表は `UsageLedgerStore` を台帳書き込みの唯一の直列化主体とする）。

| 並行 | 何が起こるか |
| --- | --- |
| `transact` が排他区間内で保存中、別の読み取り主体が破損を観測して排他外から修復する | 順序次第で**修復（封鎖つき）が正当な保存に上書きされ、封鎖もカウンタも消える** |
| 逆順 | **修復が正当な保存を上書きし、grant・`consumedExportIDs`・`exportedSettingsEntries` が消える** |
| 2 つの読み取り主体が同じ `integrityFailure` を同時に観測 | **修復が 2 回並行する。** `lastObservedAt` / `ledgerTimeZone` の後勝ち規則が無い |

**修復も `UsageLedgerStore` の専用ポートへ置く。**

| 規則 | 内容 |
| --- | --- |
| ポート | **`UsageLedgerStore.repairLedger(evidence:)`**（宣言は[書き出し Saga](export-saga.md) の 0 章） |
| 排他 | **`transact` と同じ待機キューを取る。** 台帳を書く主体を 1 つに保つ |
| 変換関数 | **通さない。** 読めていない台帳に変換は適用できない |
| 加算 | **適用しない。** 表の値がそのまま保存される |
| 検出者 | **`repairLedger` の内側で読み直して判定する。** 呼び出し側の観測を根拠にしない |

**排他区間の内側で読み直す**（呼び出し側が観測した `integrityFailure` を根拠にすると、待機中に別の主体が修復を完了させた場合に二重修復になる。`invalidateWorkingSource` と同じ形。4.2）。これは `recordEntitlementRefresh()` / `recordConfigRefresh()` と同じ構成（変換関数を通さない専用ポートで排他区間は取る）。

**修復は痕跡を 1 つ減らす**（`SubscriptionState` を消すと `PriorUseEvidence.hasSubscriptionStateBlob` が偽になるが、残る 3 つ〈`RemoteConfigState` / `TrustedTimeState` / `AppLifecycle`〉で痕跡は成立し続ける。7.2）。**`RemoteConfigState` は削除しない**（削除すると機能停止フラグが失われるため、`ledgerWritesSinceConfigFetch` を上限値にして「期限切れ」として扱い機能停止フラグは保持する。[運用](operations.md) の 2.1。削除より期限切れの方が安全側）。**端末年月を封鎖の基準にしない**（信頼時刻を取得できない場合は基準を決められないため `lockedUntilReinstall` へ倒す）。`trialReservations` / `sourceRecords` / `sourceLeases` も空にする（残す場合、過去の予約や alias が部分的に生き残り二重封鎖や同一性判定の部分残存が起こる）。

結果として次のようになる。

- **Free 単体書き出しは不可。** 信頼できる時刻から導出した年月が封鎖時の月より後になった時点で再開する
- **一括処理トライアルは再インストールまで不可**（`trialIntegrityLocked` は解除しない）
- Standard / Pro の通常書き出しは許可。月間枠に依存しない
- 成功した書き出しの grant は、この修復済み台帳へ通常どおり追加できる

フラグを立てるだけでは効果がなく、次の 2 箇所で参照する。

| フラグ | 参照箇所 | 効果 |
| --- | --- | --- |
| `monthlyIntegrityLock` | `evaluate` の判定手順 4 | 月間上限の判定より前に `blocked(.ledgerIntegrityFailure)` を返す |
| `trialIntegrityLocked` | `remainingCredits` の導出 | 残数を 0 とし、一括トライアル画面への進入・写真選択・認可をすべて禁止する |

再インストールで枠が戻ることは仕様 14.5 が明示的に許容しているため追跡しない。

### 6.4 SourceRecord と素材同一性

仕様 14.3 は「新しいプロジェクトとして作り直しても、元素材識別子とローカルハッシュが一致すれば同一素材として扱う」と定めます。

##### 複合 ID

`contentFingerprint` 1 本にすると、OS が画像を変換した場合に同一素材と判定できない（PhotosPicker は要求形式や iCloud の状態によって HEIC を JPEG へ変換して返し、変換後はバイト列が別物になる）。

```swift
struct SourceIdentity: Sendable, Hashable {
    /// 写真ライブラリの asset 識別値を端末内でハッシュ化したもの。
    /// 取得できない場合（ファイル取り込み等）は nil
    let providerAssetKeyHash: String?

    /// ファイル全体の SHA-256（正準スキーマ 5.1）
    let contentFingerprint: ContentFingerprint
}
```

**この 2 つの OR を同一性判定へ直接使えない**（推移律が成立しないため。provider だけ一致する組と fingerprint だけ一致する組を橋渡しすると非等価な素材同士が繋がる）。同値関係でない述語を使うと、同じ素材の grant が複数作られトライアルを二重消費し、ゲートが同じ素材を別キーとして扱って同時実行を許してしまう。

##### 正規 ID と alias

**素材へ正規 ID（`sourceID`）を割り当て、識別情報を alias として管理します。**

```swift
enum SourceAlias: Sendable, Hashable {
    case provider(String)               // providerAssetKeyHash（小文字 16 進 64 文字）
    case content(ContentFingerprint)    // 32 バイト
}

// SourceID の定義は 6.6 が正本

struct SourceRecord: Sendable, Equatable {
    let sourceID: SourceID
    var aliases: Set<SourceAlias>   // 空にしない（不変条件 7）
}
```

素材を解決する手順。

1. `provider` alias に一致する `SourceRecord` を探す
2. `content` alias に一致する `SourceRecord` を探す
3. 両方が見つかり、**別レコードを指していたら 1 件へ統合する**
4. 片方だけ見つかれば、そのレコードへ不足している alias を追加する
5. どちらも見つからなければ新しい `sourceID` を発行する

以後、grant・トライアル台帳・予約・ゲートはすべて `sourceID` で管理する（等価性は通常の `==` であり推移律は自明に成立する）。`SourceRecord` の集合も `UsageLedger` に持つ（alias の追加と統合が台帳更新と同一トランザクションで必要なため。別の場所に置くと統合途中で落ちたとき alias と grant が食い違う）。

##### 統合時の規則

| 対象 | 統合結果 |
| --- | --- |
| `aliases` | 両者の和集合 |
| grant | **最も古い `firstSuccessAt` を維持する**（窓を延長しない） |
| トライアル台帳 | **どちらかが消費済みなら消費済み**（払い戻さない） |
| 予約 | 両方を統合する。実行中の export が競合するなら新規開始を止める |
| `ownerExportID` | 維持したほうの値を残す |

**`sourceID` を持つ全集合（`grants` / `trialEntries` / `trialReservations` / `sourceLeases`）を勝者へ書き換える**（書き換え漏れを型で防げないため一覧を規則として固定する。`sourceLeases` を落とすと起動時の孤児 lease 回収が認可中の lease を回収し `SourceRecord` が GC されて処理中の素材が消える）。書き換え結果、同じ `sourceID` の要素が同じ集合に 2 件できる場合は上の統合規則で 1 件へ畳む。**`sourceLeases` だけは畳めない**（同一素材の非終端書き出しは 1 件だけという設計〈[書き出し Saga](export-saga.md)〉に対し、統合で 2 件の実行中 lease が合流した状態は不変条件が既に破れていることを意味するため、競合として復旧エラーへ倒す。v1 は全体ゲートによりこの状態は起こらない）。

##### `SourceRecord` の寿命

**削除規則が無いと alias が永久に蓄積する**（有料利用者は grant の 24 時間が切れても書き出しを続ける）。一方、単純に「未参照なら削除」もできない（`paidUnlimited` の通常の単体書き出しには grant も予約もなく、認可から正常生成までの間その素材を参照するものが台帳に存在しない。`SourceLease` がこの穴を埋める）。

| 契機 | 操作 |
| --- | --- |
| 認可時（手順 −2） | `SourceLease` を追加する。**勘定の種類を問わない**。`batchTrial(true)` のときだけ追加で `TrialReservation` を作る |
| 台帳への適用（手順 4）またはロールバック | 該当 `exportID` の lease を**台帳トランザクション内で**削除する |
| 起動時 | 対応するコミットが無い lease を回収する（[書き出し Saga](export-saga.md) の起動時復旧 手順 3） |

**`SourceRecord` を削除してよいのは、次のすべてから参照されなくなったときだけ。**

| 参照元 | 参照の形 |
| --- | --- |
| `grants` / `trialEntries` / `trialReservations` / `sourceLeases` | `sourceID` |
| **`projectSourceSnapshots`** | **`identity` の alias が、そのレコードの `aliases` と交わる** |

削除は `rollPeriod` で期限切れ grant を落とすのと同じタイミングで行う（参照が最も減っている時点）。**snapshot を参照元に含めないと再接続の照合が成立しなくなる**（`SourceRecord` が消えると alias グラフの連結成分も消え「同じ写真を OS が別形式で返した」経路〈下記〉で一致を判定できない）。`Project` の削除で snapshot が消えたとき、他の参照が無ければ同じ台帳トランザクションで `SourceRecord` も削除する（7.5 の `Project` 削除 Saga）。

##### 素材同一性の照合は alias グラフで行う

**`SourceIdentity` 同士の直接比較（`providerAssetKeyHash` または `contentFingerprint` の一致）は使わない**（同じ写真でも取得経路によって片方しか得られないことがある。例: インポート時に `provider=P1, content=F1` で記録後、OS のトランスコードで同じ写真が `content=F2` になり `SourceRecord` へ追加登録、後日権限なしで `provider=nil, content=F2` として再選択される場合、直接比較では `F2` が元 snapshot の `F1` と一致せず拒否されてしまう）。

| 規則 | 内容 |
| --- | --- |
| 照合 | 候補の `SourceIdentity` と `ProjectSourceSnapshot.identity` が、**同じ `SourceRecord`（alias グラフの同じ連結成分）へ解決されるか**で判定する |
| 解決の場所 | `transact` の内側。台帳の統合規則と同じトランザクション |
| **一致した場合** | **候補の alias を、その `SourceRecord` の `aliases` へ追加する**（再選択・再接続の両方） |
| 不一致 | 別の写真として拒否する。alias は追加しない |

一致時に alias を追加するのは次回の照合を成立させるため（追加しないと `P1 / F2` が台帳のどこにも現れず `F2` だけの再選択が毎回拒否される）。この規則は選択画面の分類（`BatchSelectionClassifier`）と同じであり、照合の実装を 2 つ持たない。

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
| 9 | **`projectSourceSnapshots` の各 `identity` の alias が、いずれかの `SourceRecord` に存在する** | 再接続の照合元が消え、履歴を再編集できなくなる |
| 10 | **`pendingExportedSettingsEntries` / `exportedSettingsEntries` / `projectSourceSnapshots` / `workingSourceBindings` の各集合に、同じ `projectID` が 2 件以上存在しない** | どちらを認可の根拠にするか決まらない |
| 11 | **`workingSourceBindings` の各 `projectID` が `projectSourceSnapshots` にも存在する** | 実体だけがあり identity が無い `Project` ができる |

条件 5 は、予約と lease が手順 −2 の同一トランザクションで作られ手順 4 またはロールバックで同時に消えることの帰結。条件 7 前半（空集合の禁止）は条件 1 に違反しないため別条件として立てる。

##### `providerAssetKeyHash`

**平文で保存しない**（端末内で派生鍵による HMAC-SHA256 へ変換し元の値を復元できない形で持つ。鍵は台帳署名とは別のラベルから派生させる。9.1）。アルゴリズムと出力形式は [正準スキーマ](canonical-schema.md) が正本。

##### `contentFingerprint`

**ファイル全体の SHA-256 だけを入力にする**（バイト表現の正本は [正準スキーマ](canonical-schema.md)）。**部分ハッシュ（先頭・末尾 64KB）は採らない**（中央部分だけが異なる 2 枚が同一素材と判定され、同じカメラの連写では先頭 EXIF・末尾パディング・ファイルサイズ・撮影日時が揃いやすく無料枠回避が現実的な難易度になる）。全体を読む費用はストリーム投入で吸収する（メモリ一定）。計算は選択直後のインポート Saga で 1 回だけ行う（[画像処理](image-pipeline.md)）。**`PHAsset.creationDate` とファイル更新日時は入力にしない**（権限の有無で取得元が変わる／コピーや同期で容易に変わるため、同じ写真が別ハッシュになり無料枠を二重消費しうる）。理論上の衝突時は「別素材なのに無料で再書き出しできる」方向へ倒れるが、SHA-256 の全体ハッシュであるため意図的に作れる衝突ではない。

##### 入力の取得契約

```swift
enum SourceRepresentation: Sendable, Equatable {
    case original      // プロバイダーが返した原データ
    case transcoded    // OS が変換した派生データしか取得できなかった
}

/// EXIF の撮影日時。ローカル表記とオフセットを分けて保持する（正準スキーマ 5.1.1）
struct OriginalCaptureMetadata: Sendable, Equatable {
    let dateTimeOriginal: String?      // "YYYY:MM:DD HH:MM:SS"
    let subSecTimeOriginal: String?
    let offsetTimeOriginal: String?    // "+09:00" など
    let utcMillis: Int64?              // offset がある場合のみ算出する
}
```

**`utcMillis` は `offsetTimeOriginal` がある場合にだけ入り、無い場合は `nil`（端末のタイムゾーンで補完しない。正準スキーマ 5.1.1）。** ローカル表記をそのまま持つのは出力 EXIF へ書き戻すため（UTC 変換後の再構築は往復誤差が出る）。この型を `ProjectSourceSnapshot` と `OutputMetadata` の両方が使う。

| 状況 | 扱い |
| --- | --- |
| 原データを取得できる | `original` としてハッシュを計算する |
| 原データを取得できない | **`transcoded` として、取得できた表現から計算する。処理は拒否しない** |

**処理自体は拒否しない**（`transcoded` では同一素材の保証が弱まるが、これは利用者に不利な方向〈余分に消費する〉であり枠を水増しする方向ではない）。**`representation` は `contentFingerprint` の入力に含めない**（含めると取得経路により同じ写真が別ハッシュになる。診断用の区分値としてのみ記録する。9.2）。

##### プロジェクト設定ハッシュ

6.2 の「変更せず再書き出し」の判定にも正準化が必要（含めるフィールド・符号化規則・最終式はいずれも [正準スキーマ](canonical-schema.md) の 5.2 が正本）。意味の面で決めているのは 2 点。

| 決定 | 内容 |
| --- | --- |
| 用途を 2 つに分ける | 認可用の `ProjectSettingsHash` と確認用の `PreviewRenderHash`。1 つにすると、匿名化結果に影響しない設定を変えただけで書き出せなくなる |
| スタンプの参照 | DB の採番 ID ではなく **`StampAsset` の内容ハッシュ**（7.5）。ID はアプリ更新やデータ移行で変わる |

`contentFingerprint` と同じ式ではない（あちらの入力はファイルの全バイトのみで構造化された符号化を持たない。混同すると片方の規則がもう一方へ持ち込まれる）。

##### バッチ選択時の分類

**選択画面で `SourceIdentity` を素朴に比較できない**（正規 `sourceID` の解決と alias の統合は書き出し開始時の `transact` の中でしか行われず、その外で生の OR 述語を使うと重複数え違い・トランスコード写真の誤新規扱い・選択中重複の見逃しが起こる）。

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

判定は**連結成分**として行う。

1. 台帳の `SourceRecord` が持つ alias 集合と、選択中の各写真の alias 集合を、同じグラフの頂点として扱う
2. 同じ alias を共有する頂点を辺で結ぶ
3. 連結成分ごとに 1 つの正規素材とみなす
4. **その成分に対応する `sourceID` が `trialEntries` に存在するかで分類する**

alias の共有関係を推移的に閉じることで `sourceID` 解決と同じ結果になる。**`SourceRecord` の有無で判定してはいけない**（`SourceRecord` は単体書き出しの `grant` / 認可中の `SourceLease`〈勘定を問わない〉/ トライアル予約 / 有料書き出し中の参照のいずれでも作られるため、存在だけを見ると単体処理をしただけの写真が一括トライアルで「消費済み」と誤判定されクレジットなしで処理できてしまう）。

| 台帳の状態 | トライアルでの分類 |
| --- | --- |
| `SourceRecord` あり・`TrialEntry` なし | **新規**（クレジットを要する） |
| `TrialEntry` あり | **消費済み**（クレジットを要しない） |
| `TrialReservation` のみ | **新規枠を占有中**（別の書き出しが認可済み。残数計算では消費側に数える） |

`TrialReservation` を「消費済み」に含めないのは、ロールバックされれば新規枠へ戻るため（残クレジットの導出は `trialEntries.count + trialReservations.count` を引くため占有分は残数側で既に減っており、分類側でも消費済みにすると二重に数える）。

**この分類は表示と入力制限のためのものであり、選択時の判定だけで消費を認可しない。** 実行開始の直前に最新の台帳で全件を原子的に再検証する（開始ゲート〈[書き出し Saga](export-saga.md)〉の内側、上と同じ `trialEntries` 判定条件）。分類結果が変わっていれば実行を開始せず選択画面へ戻して差分を提示する。

### 6.5 バッチ処理

**一括処理の制限なし利用は `canUseProBatch` が必要。** `canUseBatchTrial` だけを持つ利用者は、未使用クレジットの範囲で新しい写真を処理するか、消費済み台帳に登録されている写真を再度処理できる。

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

**残クレジットが 0 でも消費済み台帳に写真があれば一括処理画面を閉じない**（「同じ 5 枚は期限なく何度でも試せる」を成立させるため）。**判定に `Plan` を使わない**（料金表や説明文でのプラン名使用は構わないが、実装上の条件式はすべて能力で書く）。

##### 中核となる価値

一括処理の価値は「複数選択できること」ではなく、**50 枚を一枚ずつ編集画面で開かずに済むこと。**

1. 写真を選択する（Pro は最大 50 枚、トライアルは最大 5 枚）
2. 全写真の顔を自動検出する
3. 検出した全顔を加工対象にする（6.1 の不変条件）
4. **選択した確認モードに応じて、全写真に目を通す**
5. `reviewRequired` の写真について対応方法を記録する
6. 一括書き出しする

**手順 4 はどちらのモードでも省略できない**（見せ方が異なるだけで「全写真に一度は目を通す」要件は共通。理由は 6.1 のトリアージの限界）。

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

`normal` の写真に個別の `reviewed` 操作は求めない（一覧へ目を通し手順 4 を行うことが全写真に対する確認にあたる）。

**1 枚ずつ確認**

1. 全サムネイルの生成が完了している
2. `normal` / `reviewRequired` を問わず、**全写真が `reviewed` になっている**
3. `reviewRequired` の写真について、対応方法が記録されている
4. 完了サマリを表示する

条件 3 を「警告が解消されている」とは書かない（利用者がどう判断しても警告そのものは消えず、扱いを決めただけ）。このモードでは 1 枚ずつ大きく表示して個別確認するため末尾到達と確認操作は求めない。`normal` の写真は「確認して次へ」により `ReviewDecision` なしで `reviewed` へ遷移する（定めないと永久に `unreviewed` のままになる）。

```swift
// BatchReviewState の定義は [書き出し Saga](export-saga.md) の 1.1 が正本
```

おまかせ一括の一覧確認はバッチ全体の操作であり、写真単位とは独立して持つ。

##### 一覧の実装制約

**サムネイルは検出漏れを目視で発見できる大きさとする**（タップで全画面プレビューへ遷移でき、一覧上でもピンチ拡大できることを要件とする。未検出の顔は加工されず露出した状態で見える。この視認性が仕組みの前提）。要確認だけを表示して他を隠す既定表示は採らず、絞り込みは利用者が明示的に選ぶフィルターとしてのみ提供する。末尾到達判定はスクロールだけでなく VoiceOver による走査でも成立させる。**末尾到達も `reviewed` も安全の保証ではなく、見落としを減らす手順として扱い、いかなる場合も「安全」という語を状態表示に用いない**（仕様 34.5）。

##### 確認状態の解除

**一律に全解除はしない**（50 枚のうち 1 枚を直しただけで残り 49 枚まで再確認になると一括処理の価値が失われる）。判定は設定名の列挙ではなく原則で行う（数え上げる形は項目増加時に漏れる）。

> **匿名化結果または構図に影響する変更**が行われた場合、その変更の影響を受ける写真を `unreviewed` へ戻し、`overviewConfirmed` を `false` にする。

| 変更 | 写真の `ReviewStatus` | `overviewConfirmed` |
| --- | --- | --- |
| 匿名化結果・構図に影響する変更（個別） | その写真だけ `unreviewed` | `false` |
| 匿名化結果・構図に影響する変更（共通） | 影響を受ける写真を `unreviewed`。`hasOverride` の写真は維持 | `false` |
| 影響しない変更 | 維持 | 維持 |

**影響する変更**: 顔のエフェクト・強度・スタンプ、顔領域の追加/移動/削除、縦横比と切り抜き位置、背景処理。**影響しない変更**: 位置情報の削除、撮影日時の保持、圧縮品質。`ReviewResolution` は `unreviewed` へ戻した時点で破棄する。検出ステータスは検出をやり直したときにのみ再計算する。

##### 設定へ戻る経路

**確認段階から設定段階へ戻れる（検出結果は保持し再検出は行わない）。v1 ではこの経路から写真の選択は変更できない**（変更できるのはエフェクト・強度・スタンプ・縦横比等の設定のみ。写真を変えたい場合は現バッチを破棄し新しいバッチを作る。検出後に写真を出し入れできると「実行開始後はバッチを固定する」と両立しない）。

##### 選択枚数の条件

制限は **2 つの独立した条件**（1 つにまとめると残クレジット 0 の状態で消費済みの写真すら選べなくなる）。

| 条件 | 上限 |
| --- | --- |
| 1 バッチの総枚数 | Pro は 50 枚、トライアルは 5 枚 |
| **選択中のうち、消費済み台帳にない写真の枚数**（6.4 の分類） | 残クレジット数 |

| 分類 | 発火条件 | 誘導 |
| --- | --- | --- |
| `batch-credit` | Free / Standard が、残クレジットを超える**新しい写真**を選ぼうとした | Pro |
| `batch-size` | Free / Standard が**総数 5 枚**を超えて選ぼうとした | Pro |
| `batch-limit` | Pro が**総数 50 枚**を超えて選ぼうとした | 誘導なし。上限の通知のみ |

`batch-size` と `batch-limit` を分けるのは、前者がアップグレードで解消できる制限、後者が仕様上の上限のため。`batch-credit` だけでは、既に試した写真だけを 6 枚選ぶ場合（新しい写真 0 枚）を捕まえられず、この経路は `batch-size` が受ける。

##### キューと付随機能

キューの進行状態は仕様 16.6 の 8 種とし、状態機械を `Domain` に置く。**状態を増やさない。**

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

**処理用ファイルが失われた場合も新しい状態を作らず `paused(.sourceReselectionRequired)` へ遷移させる**（`paused` は「利用者操作を待って再開できる」の意で再選択要求もこれに当てはまる。バッチ全体ではなく該当項目だけが `paused` になる）。**`isTerminal` を各所で書き下さない**（履歴削除可否判定〈7.5〉・バッチ完了判定・復旧対象選定がすべてこの 1 述語を使う。書き下すと状態追加時に一部だけ更新される事故が起こる）。

**キューの進行状態と 6.1 の 2 軸は別物。**

| 概念 | 何を表すか | 変化させるもの |
| --- | --- | --- |
| キューの進行状態 | その写真が処理のどの段階にいるか | 処理の進行 |
| 検出ステータス | `triage` が警告を出したか | 検出のやり直し |
| 確認ステータス | 利用者が確認を終えたか | 利用者の操作 |

キューの `review_required` は独立した真実を持たず、**利用者の確認待ちを表す導出値。**

```swift
let requiresUserReview = switch mode {
case .auto:
    detectionStatus == .reviewRequired && reviewStatus == .unreviewed
case .oneByOne:
    reviewStatus == .unreviewed
}
```

1 枚ずつ確認では `normal` の写真も確認を待つため `review_required` になる（「警告あり」定義では未確認の `normal` 写真がキュー上そう見えなくなる）。

##### 開始時の設定を固定する

**実行中のバッチは開始時のリモート設定で動く**（[運用](operations.md) の 2.2。設定が途中で変わっても枚数上限や並列数は動かない）。

```swift
struct BatchPolicySnapshot: Sendable, Equatable {
    let configVersion: Int64
    let kind: BatchKind            // クランプ先を決める（下記）
    let batchSizeLimit: Int32
    let trialCreditCount: Int32
    let concurrencyLimit: Int32
}

/// このバッチが Pro の通常一括かトライアルか。作成時に確定する
enum BatchKind: Sendable, Hashable {
    case proBatch      // canUseProBatch による通常の一括処理
    case trial         // クレジット消費による一括トライアル
}
```

`Batch` の行が保持し再起動後も同じ値を使う（読み直して適用すると復元したバッチの上限が実行中に変わってしまう）。

| `BatchKind` | DB 列値 |
| --- | --- |
| `proBatch` | **1** |
| `trial` | **2** |

**列値を固定する**（`BatchKind` は署名対象外だが `Batch` の DB 列としてスキーマ移行をまたぐため、`case` 宣言順に依存させると版によって `trial` のバッチが `proBatch` として上限 50 でクランプされうる。`OutputState` と同じ規則。7.5）。新しいバッチの作成時は、その時点の `RemoteConfig` から作る。

##### 読み出しのたびに hard max へクランプする

**`BatchPolicySnapshot` は未署名の DB 行であり、`trialCreditCount` を 5→500 へ書き換えれば一括処理を任意枚数の新規写真に無制限に使えてしまう**（`RemoteConfig` を HMAC で保護しても複製した DB 行が無防備では意味がない）。

| フィールド | クランプ先（[運用](operations.md) の 2.1） |
| --- | --- |
| `batchSizeLimit`（`kind == .proBatch`） | `proBatchSizeLimit` の hard max **50** / 最小 1 |
| `batchSizeLimit`（`kind == .trial`） | `trialBatchSizeLimit` の hard max **5** / 最小 1 |
| `trialCreditCount` | hard max **5** / 最小 0 |
| `concurrencyLimit` | `batchConcurrencyLimit` の hard max **1**（v1）/ 最小 1 |
| `configVersion` / `kind` | **クランプの対象外**（記録用の値であり上限を持たない） |

| 規則 | 内容 |
| --- | --- |
| 読み出し | **`app.db` から読んだ直後にクランプする** |
| クランプの向き | **hard max を超える値は hard max へ、最小値を下回る値は最小値へ** |
| 適用箇所 | `remainingCredits` の導出、`canEnterBatch`、選択枚数条件、キューの並列数のすべて |
| `kind` の改変 | **`.trial` → `.proBatch` の書き換えは `batchSizeLimit` の上限を 5 → 50 へ緩めるが、新規写真は `remainingCredits`（≤5）に縛られる**（下記） |

**`kind` を持たせるのは `batchSizeLimit` のクランプ先が 2 つあるため**（`BatchPolicySnapshot` だけでは Pro の 50 とトライアルの 5 のどちらへ丸めるか決まらない）。**`kind` の改変では枚数は増えない**（選択枚数の条件は 2 本独立し、新規写真は `remainingCredits`〈最大 5〉、消費済みは `trialEntries` 件数〈最大 5〉に縛られ、処理できる相異なる素材は 5 枚のまま。重複は `canonicalCount` が畳む。6.4）。**クランプはリモート応答の受理時（配信経路。[運用](operations.md) の 2.1）と DB からの読み出し時の両方で行う**（経路が 2 つあるため）。**署名対象へは移さない**（`Batch` は DB の履歴行であり台帳へ移すと `Project` 数に比例して署名対象が増える。クランプで上限を保証できるため署名は不要）。**下限もクランプする**（`batchSizeLimit` を 0 にして「上限 0 だから何枚でも通る」という実装ミスを誘発させないため）。

その他の規則は仕様 16.5 / 16.7 / 16.8 に従う。

- 1 バッチ最大 50 枚
- 同時並列処理は **v1 では 1 固定**（初期値・hard max とも 1）。2 へ引き上げるには二段階ゲートの実装が要る（[書き出し Saga](export-saga.md) の 1.7）
- 一枚の失敗でバッチ全体を停止しない
- **アプリ再起動後に未完了キューを復元する**（[画像処理](image-pipeline.md) の `WorkingSourceRecord`）
- 元素材へのアクセス権限を失った場合は再選択を求める
- バックグラウンド処理は OS の実行制限に従う。`BGProcessingTask` は使わず、フォアグラウンド継続を前提とする

**実行開始後のバッチへの写真追加は v1 では実装しない**（追加分の検出開始時期・進行中確認との関係・一括設定の適用範囲・50 枚超過時の分割など論点が増える割に利用者価値が低い）。

##### 一括設定と個別修正の優先順位

1. **一括設定は各写真の初期値として適用する**
2. 個別に編集された写真には `hasOverride` を記録する
3. **共通設定を変更しても、`hasOverride` が立った写真は変更しない**
4. 全件を上書きしたい場合のみ、対象件数を提示した確認を経て実行する

`hasOverride` は写真単位のフラグとし `Domain` が管理する。

##### 対応しないこと

顔認識を行わない以上、**複数写真を横断した同一人物の判定はできない**（仕様 16.4）。「全写真で家族だけ残し他人だけ隠す」は実現できず、説明文でこれを誤解させないことを制約とする。

### 6.6 ドメイン識別子

**識別子を `String` と `UUID` で混在させない**（2 つの型で表現されると DB の結合も HMAC の正準化も一意に決まらない）。

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

**`FaceTrackID` も `UUID`**（自動検出は `observation.uuid` をそのまま使い手動領域はアプリが採番するため、文字列だと 2 つの出所で表現が揺れる）。

| 理由 | 内容 |
| --- | --- |
| 誤った受け渡しの防止 | `exportID` を期待する引数へ `projectID` を渡せない。**コンパイルで止まる** |
| DB 結合の一意性 | 外部キーと結合の対象が型で決まる（7.1） |
| 正準化の一意性 | HMAC 対象の各 ID を「`UUID` の 16 バイト」として符号化できる（9.1） |
| ログ禁止の強制 | 分析イベントのフィールド型にしないことで、送信経路へ入れられない（9.2） |

いずれの型も `CustomStringConvertible` に適合させない（文字列補間で自動的にログや診断へ流れる経路を作らないため）。

### 6.7 アプリ更新の判定

起動時に新しいバージョンがあれば App Store へ誘導する。**判定は純粋関数に閉じる**（提示条件・審査への配慮・配信の運用規則は [運用](operations.md) が正本）。

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

**手順 1 が最も重要**（設定取得不能時に強制更新へ倒すと、バックエンド障害が全利用者のアプリ停止に直結する）。`AppVersion` は数値の組で比較する（[正準スキーマ](canonical-schema.md)）。**文字列比較は使わない**（`"1.10.0" < "1.9.0"` が文字列としては真になり新しいバージョンを古いと判定する）。`CFBundleShortVersionString` のパース失敗時は **`.none`**（強制更新に倒すと書式ミスで全利用者がブロックされる）。`CFBundleVersion`（ビルド番号）は比較に使わない。

判定は起動時復旧の完了後に行う（[書き出し Saga](export-saga.md) の起動時復旧 手順 8。復旧前だと `isUndelivered` の件数を正しく数えられない）。`skippedVersion` と `lastPromptedAt` は `UserDefaults` に置く（改ざんされても更新の再提示が遅れるだけ）。

---

## 7. 永続化

### 7.1 app.db

GRDB（SQLite）を使います。採用理由は [ADR 0002](adr/0002-grdb-and-single-database.md) にあります。

**アプリのリレーショナルデータを 1 つの `app.db` へ収めます。**

| テーブル | 備考 |
| --- | --- |
| `Project` | 仕様 19.1。`projectRevision`（下記）、`detectionRevision`、`detectionPixelSize`、再編集用の `ProjectSourceLocator` を持つ（[画像処理](image-pipeline.md)）。**ここにのみ平文の `localIdentifier` が存在する** |
| `FaceTrack` | 仕様 19.2。手動領域は `createdManually = true`。**検出品質の列（`confidence` / `yawDegrees` / `pitchDegrees` / `rollDegrees` / `isSmallFace`）も持つ**（6.1 の再導出に要る） |
| `EffectSetting` | 仕様 19.4 |
| `ExportSetting` | 仕様 19.5 |
| `CustomStamp` | 仕様 19.6。スタンプ一覧の項目（7.5） |
| `StampAsset` | プロジェクトが参照する不変の画像実体のメタデータ。内容ハッシュを主キーとする（7.5） |
| `ProjectStampAsset` | プロジェクトと `StampAsset` の対応（7.5） |
| `ExportRecord` | 仕様 19.7。`batchID` を追加 |
| `Batch` | バッチ単位の履歴。`BatchPolicySnapshot` を持つ（6.5） |
| `BatchPreset` | 一括設定プリセット |
| `DeliveryAttempt` | 写真ライブラリ保存の試行中を表す。`previousState` を持つ（[書き出し Saga](export-saga.md) の 8.0） |
| `UnknownLibrarySave` | 保存結果が不明のまま `delivered` を維持したことの記録（同 8.0） |
| `ExportCommit` | 書き出しのコミットジャーナル。行に HMAC を付ける（[書き出し Saga](export-saga.md)） |
| `OutputRecord` | 写真ごとの出力状態。`exportID` でコミットと対応づける |
| `ExportQueueItem` | 一括処理のキュー状態（6.5） |
| `WorkingSourceRecord` | 処理用にアプリ領域へ複製した元素材（[画像処理](image-pipeline.md)） |
| `PendingFileDeletion` | 参照 0 になった実体の削除候補（7.5） |
| **`AppLifecycle`** | **利用痕跡（7.2）。行は最大 1 件。起動時復旧の手順 9 で挿入し、更新も削除もしない** |

**`app.db` 全体がバックアップ対象外**（7.4）。復元してはいけない理由（DB を分けても解消しない）:

- `ExportCommit` を別端末へ復元しても対応する一時ファイルは存在せず、`UsageLedger`（同じくバックアップ対象外）との整合も失われる
- 写真ライブラリ参照（`ProjectSourceLocator` / `providerAssetKeyHash`）は別端末で意味を持たず、履歴を復元しても再編集できない

##### DB を分けない

**実行時状態と利用者データを 1 つの `app.db` へ置く**（判断の経緯は [ADR 0002](adr/0002-grdb-and-single-database.md)）。設計上の帰結は 3 つ。

| 帰結 | 内容 |
| --- | --- |
| **実の外部キー制約** | `OutputRecord.projectID` → `Project`、`ExportQueueItem.batchID` → `Batch` を SQLite が強制する。アプリ側の起動時検査が不要になる |
| 単一トランザクション | 手順 7（[書き出し Saga](export-saga.md)）が `ATTACH` なしで成立する |
| 単一の `DatabaseMigrator` | 2 つの DB のスキーマバージョンが食い違う状態が存在しない |

##### `projectRevision` の増加規則

出力へ影響する値は `Project` 以外のテーブルにもある（「`Project` の変更ごとに増える」だけでは `EffectSetting` だけ書き換えても revision が動かない実装が成立してしまう）。

> **出力・検出結果・レビュー結果・プレビュー結果のいずれかへ影響する子行の作成・更新・削除は、必ず同一 DB トランザクションで `Project.projectRevision` を増加させる。**

対象の子テーブルです。

| テーブル | 影響する先 |
| --- | --- |
| `FaceTrack` | 検出結果・プレビュー |
| `EffectSetting` | プレビュー・出力 |
| `ExportSetting` | 出力 |
| `ProjectStampAsset` | プレビュー・出力 |

**編集操作を個別 Repository へ分散させない**（プロジェクト変更コマンドへ集約し、そのコマンドだけが子行と `projectRevision` を同時に更新する。個別 `update` の公開は revision 更新忘れの経路を作る）。`detectionRevision` は再検出でのみ増え `projectRevision` とは独立（6.1）。

##### 一意制約と外部キー

**不変条件をアプリのコードだけで守らず、DB 制約として固定できるものは固定する。**

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
| `DeliveryAttempt.exportID` | **PRIMARY KEY** |
| `UnknownLibrarySave.exportID` | **PRIMARY KEY** |
| **`AppLifecycle`** | **`id INTEGER PRIMARY KEY CHECK (id = 1)`。** 1 行しか存在できないことをスキーマで強制する |

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
| `UnknownLibrarySave.exportID` | `OutputRecord` | CASCADE |
| `DeliveryAttempt.exportID` | `OutputRecord` | CASCADE |

**`batchID` を `SET NULL` にするのはバッチ履歴を消しても出力と書き出し記録を残すため**（バッチは集約単位であり個々の出力の存在条件ではない）。宣言していない参照は `PRAGMA foreign_key_check` で検出できないため、上の表が外部キーの全体であり新しい参照は必ずこの表へ加える。**`RESTRICT` は削除可否の判定（7.5）を DB 側でも二重に担保する**（アプリ側判定を通り抜けた削除は制約違反として失敗する）。**「同一 `sourceID` の非終端コミットは 1 件」は DB 制約にできない**（`sourceID` は署名対象であり部分インデックスで状態を条件にすると署名不正行まで巻き込む。開始ゲート〈[書き出し Saga](export-saga.md)〉と台帳の不変条件 8 で担保する）。手順 0 の再試行は同じ `exportID` で冪等（`PRIMARY KEY` 制約により二重 insert は失敗し、再試行時は既存行の状態を読んで続きから進める）。

##### 接続と journal

| 項目 | 規約 |
| --- | --- |
| 接続 | **`DatabaseQueue` を 1 つだけ**使う |
| `journal_mode` | **`DELETE`**（下記）。`TRUNCATE` / `PERSIST` / `WAL` を使わない |
| `synchronous` | **`EXTRA`** |
| `foreign_keys` | **`ON`** |
| 起動時検査 | `journal_mode` / `synchronous` / `foreign_keys` を読み返して検証する |

**`DELETE` へ固定するのは常時存在するサイドカーファイルを作らないため。**

| モード | サイドカー |
| --- | --- |
| **`DELETE`** | **トランザクション終了時に消える** |
| `TRUNCATE` / `PERSIST` | journal ファイルが**残り続ける** |
| `WAL` | `-wal` と `-shm` が**常時存在する** |

残るファイルはバックアップ除外とデータ保護クラスを個別に設定・検証する必要が生じ、7.3 の「すべてのファイル生成を `ManagedFileStore` へ通す」から外れた経路が増える（`DELETE` ならその経路自体が存在しない）。本アプリの DB アクセスは書き出し前後に集中し同時読み書き負荷が高くないため WAL の並行性は不要。`DatabasePool`（複数接続）も使わない（`synchronous = EXTRA` の効果と書き込み順序の推論を単純に保つ）。

##### 耐久性の水準

**保証の強さを段階で書き分ける**（SQLite の `synchronous = EXTRA` は rollback journal に対する追加の同期であり、ハードウェアを含むあらゆる条件での絶対的な電源断保証ではない。Apple の `F_FULLFSYNC` も同様）。

| 障害 | 保証の水準 | 根拠 |
| --- | --- | --- |
| **プロセス強制終了**（`_exit` / SIGKILL / jetsam） | **保証する** | コミット Saga と単一トランザクション |
| **OS クラッシュ・電源断** | **best effort の耐久性** | `synchronous = EXTRA`、ファイルと親ディレクトリの同期 |
| 復帰後の整合 | **回復する** | コミットジャーナルと起動時復旧 |

要点は「書き込みが必ず届く」ことではなく「どこで切れても整合を回復できる」こと（電源断で最後の書き込みが失われた場合、その書き出しは 1 つ前の状態から再開する）。v1 では出力ファイルと保護ブロブについてもファイルと親ディレクトリを同期する（台帳と出力の整合が崩れると不変条件が壊れるため DB と同じ水準に揃える）。**同期方式（`F_FULLFSYNC` か通常の `fsync` か）は実機計測後に決める**（12.2）。

### 7.2 ProtectedBlobStore

以下は DB ではなく `ProtectedBlobStore` へ保存する（改ざんで権限や枠を書き換えられないようにするため。9.1 の HMAC 署名つき）。

- `UsageLedger`（6.3）
- `SubscriptionState`（6.2 の `Entitlement` キャッシュ）
- `RemoteConfigState`（10 章）
- `TrustedTimeState`（6.3 の信頼時刻）

**鍵の保管とデータの保管を分けます。**

| 役割 | プロトコル | 実装 |
| --- | --- | --- |
| 鍵 | `CryptoKeyStore` | Keychain（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`。7.4） |
| 署名済みデータ本体 | `ProtectedBlobStore` | アプリ専用ディレクトリ上のファイル（原子的置換） |

原子的な置き換えを要件とする（台帳は 1 つのオブジェクトとして丸ごと差し替えるため部分更新の途中状態が観測されてはいけない。実装は一時ファイルへ書いてから `FileManager.replaceItemAt`）。

##### 論理キーで解決する

**`ManagedFileID` のランダムな `UUID` だけでは再起動後に blob を見つけられない**（`ManagedFileStore` は呼び出し元へパスを返さず、採番 ID をどこかへ保存しないと次回起動時に対応づけられない）。**`ProtectedBlobStore` は固定の論理キーで解決する。**

```swift
/// 署名対象になれる型。正準化とデコードの方法を型が持つ
protocol ProtectedPayload: Sendable {
    static var blobKeyRawValue: UInt32 { get }   // ファイル名の決定に使う
    static var payloadType: PayloadType { get }
    static var schemaVersion: UInt32 { get }

    /// 型固有フィールドだけの正準バイト列（正準スキーマ 1）
    init(canonicalBodyBytes: Data) throws
    func canonicalBodyBytes() -> Data
}

extension UsageLedger: ProtectedPayload { }
extension SubscriptionState: ProtectedPayload { }
extension RemoteConfigState: ProtectedPayload { }
extension TrustedTimeState: ProtectedPayload { }

// ExportCommit も同じ正準化を使うが、blob ではなく DB 行として保存する。
// blobKeyRawValue を持たないため ProtectedPayload へは適合させず、
// canonicalBodyBytes() と payloadType / schemaVersion を個別に実装する

/// 値の型がキーに結びついている。型引数を取り違えられない
struct ProtectedBlobKey<Value: ProtectedPayload>: Sendable {
    static var usageLedger: ProtectedBlobKey<UsageLedger> { .init() }
    static var subscriptionState: ProtectedBlobKey<SubscriptionState> { .init() }
    static var remoteConfigState: ProtectedBlobKey<RemoteConfigState> { .init() }
    static var trustedTimeState: ProtectedBlobKey<TrustedTimeState> { .init() }
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

**`ProtectedBlobStore` までランダム UUID で管理する必要はない**（論理キーは 4 つに固定され増減はスキーマ変更を伴う。ID による間接参照は任意個のファイルを扱う `ManagedFileStore` の要件でありこの 4 つには当てはまらない）。`blobKeyRawValue` は `UInt32` で固定する（ファイル名の決定に使うため宣言順が変わってもファイル対応が変わってはいけない。`payloadType` の検証と併せて種別をまたいだ付け替えを実行時にも弾く。9.1）。

##### 読み込み結果の分類

読み込みが失敗する理由は 1 つではない。初回起動・改ざん・ストレージの一時障害・スキーマ更新を同じ結果にまとめると、初回起動の利用者が最初から Free 枠とトライアルを封じられ、逆に一時障害のたびに正常な台帳を保守状態で上書きしてしまう。

```swift
enum ProtectedLoadResult<T: Sendable>: Sendable {
    case valid(T)
    case missing                        // まだ存在しない
    case integrityFailure               // HMAC 不一致
    case temporarilyUnavailable         // Keychain・ファイルの一時障害
    case unsupportedSchema(version: UInt32)
}
```

| 結果 | 扱い |
| --- | --- |
| `valid` | そのまま使う |
| `missing` | **利用痕跡が無ければ**新規利用者用の通常状態を作る。**あれば `integrityFailure` と同じ扱い**（下記） |
| `integrityFailure` | 保守的な修復（6.3 の台帳、10 章のリモート設定、6.2 の購入状態） |
| `temporarilyUnavailable` | **上書きしない。** 再試行し、書き出しの開始を一時停止する。再試行可能なエラーを提示する |
| `unsupportedSchema` | 定義済みの移行処理を実行し、移行後に再検証する |
| 移行不能 | 復旧エラーとして扱う。**自動初期化しない** |

##### `UsageLedger` の `missing` を無条件に信用しない

**改変を罰して削除に報酬を与える設計にはできない**（`integrityFailure` では封鎖付き修復を課す一方 `missing` で無条件に新規台帳を作ると、`protected/` から台帳 blob だけ削除すれば無料枠とトライアルが何度でも全回復してしまう。履歴・カスタムスタンプ・購入状態は失われないため再インストール〈仕様 14.5 が許容〉と違い利用者側の損失がない）。**`missing` が真の初回起動なら端末にアプリの利用痕跡は存在しない**（痕跡があるのに台帳だけが無い状態は真の初回起動では成立しない）。**履歴テーブルの行は痕跡にできない**（「履歴を保存しない」設定〈7.5〉や手動の履歴全削除により、アプリ自身が正規機能として `Project` / `ExportRecord` / `WorkingSourceRecord` / `delivered` の `OutputRecord` / `ExportCommit` 等を全消去でき削除の代償がゼロになるため）。**痕跡は「消せないもの」に置く。**

```swift
/// UsageLedger が missing のときだけ評価する。
/// 利用者操作では削除できない場所だけを見る
struct PriorUseEvidence: Sendable, Equatable {
    /// 他の署名済み blob が存在する。真の初回起動では 1 つも存在しない
    let hasSubscriptionStateBlob: Bool
    let hasRemoteConfigStateBlob: Bool
    let hasTrustedTimeStateBlob: Bool

    /// app.db の AppLifecycle 行が存在する。2 回目以降の起動では必ず真
    let hasCompletedStartupBefore: Bool

    var indicatesPriorUse: Bool {
        hasSubscriptionStateBlob || hasRemoteConfigStateBlob
            || hasTrustedTimeStateBlob || hasCompletedStartupBefore
    }
}
```

| 痕跡 | いつ作られるか | 利用者が消せるか |
| --- | --- | --- |
| `RemoteConfigState` | **初回のリモート設定取得に成功した時点**（10.2） | 設定画面から消せない |
| `TrustedTimeState` | **初回の信頼時刻取得に成功した時点**（上記） | 同上 |
| `SubscriptionState` | 初回の購入状態取得に成功した時点（6.2） | 同上 |
| **`AppLifecycle`** | **起動時復旧の全手順を完了した時点**（[書き出し Saga](export-saga.md) の 5 の手順 9） | **設定画面からは消せない。DB への直接書き込みでは消せる**（下記） |

**`AppLifecycle` は 1 行だけのテーブル。**

```swift
/// app.db。行は最大 1 件。更新も削除もしない
struct AppLifecycle: Sendable {
    let firstStartupCompletedAt: Date   // 起動時復旧を初めて完走した時刻
}
```

| 規則 | 内容 |
| --- | --- |
| 書き込み | **起動時復旧の手順 9 で、行が無いときだけ挿入する**（[書き出し Saga](export-saga.md) の 5） |
| 更新 | **しない。** 2 回目以降の起動では既存行をそのまま残す |
| 削除 | **どの経路からも削除しない。** 履歴設定・手動の履歴全削除・容量超過・期限削除のいずれの対象にもしない（7.5） |
| 評価の位置 | **起動時復旧の手順 1**（`UsageLedger` の読み込み判定） |

**真の初回起動では評価時点（手順 1）にまだ存在しない**（書き込みは手順 9。手順の順序そのものが誤検知を構造的に防ぐ）。2 回目以降の起動では必ず存在する（手順 9 未到達で終了した起動は次回また書き込みを試みる。「一度でも復旧を完走した」ことの記録であり履歴設定と独立）。**利用者が作るデータは痕跡にできない**（`StampAsset` は有料能力 `canUseCustomStamps` が要るため狙われる Free 利用者には構造的に存在せず、`BatchPreset` は利用者自身が削除できる）。**スキーマ移行の件数も痕跡にできない**（`DatabaseMigrator` は新規作成時も全 migration を適用するため件数は真の初回起動でも 0 にならず、作成時版を別途記録すればその保存先自体が新たな未署名状態になる。初版のまま更新していない利用者では常に 0 でありリリース時点で全利用者が該当する）。

| `UsageLedger` | 利用痕跡 | 扱い |
| --- | --- | --- |
| `missing` | **無し** | 通常の新規台帳を作る（真の初回起動・再インストール） |
| `missing` | **有り** | **`integrityFailure` と同一の保守的修復**（6.3 の表）。封鎖を掛ける |
| `valid` / `integrityFailure` / その他 | 評価しない | 上表のとおり |

**`protected/` 配下の他の blob も痕跡にする**（台帳だけを消す攻撃者は `protected/` を全部消さなければ痕跡が残る。全部消すと `RemoteConfigState`/`TrustedTimeState` も失われるが再取得できるため利得側の損失にはならず、そこで `app.db` 側の痕跡〈`AppLifecycle`〉も併せて見る。これが `AppLifecycle` を置く唯一の目的であり、`protected/` の 3 blob は次回オンライン起動で自動再生成されるため削除の代償にならない）。

##### `PriorUseEvidence` が守る範囲と、守れない範囲

**`AppLifecycle` は `DELETE FROM AppLifecycle` 1 行で消せ、テーブルは残るためスキーマ移行の記録と食い違わず他のデータも失わない。** `app.db` への直接書き込みは本設計が明示的に前提とする攻撃者能力であり（1.1.1 の `EffectSetting` 改変、6.1 の `FaceTrack` 改変）、`protected/` を消せる攻撃者は同じアクセス権で `sqlite3` を 1 回叩ける。

| 操作 | `indicatesPriorUse` | 判定 |
| --- | --- | --- |
| 台帳 blob だけを削除 | **真**（他の 3 blob が残る） | 保守的修復 |
| `protected/` を全消去 | **真**（`AppLifecycle` が残る） | 保守的修復 |
| **`protected/` 全消去 ＋ `DELETE FROM AppLifecycle`** | **偽** | **通常の新規台帳。塞げない**（9.3） |

**この経路を完全に塞ぐ構成は存在しない。** 痕跡は次の 3 性質を同時に満たす必要があるが両立しない。

| 性質 | 要求 | 根拠 |
| --- | --- | --- |
| **健全性** | 真の初回起動**と正当な再インストール**の直後は痕跡が**無い** | 仕様 14.5 が再インストールでの枠回復を明示的に許容する。痕跡が残れば正当な再インストール利用者が封鎖され、`trialIntegrityLocked` は二度と解除されない |
| **完全性** | 一度でも利用した後は痕跡が**ある** | 痕跡の目的そのもの |
| **耐久性** | 攻撃者がゼロコストで消せない | 塞ぎたい経路 |

**健全性と完全性を満たせる置き場所はアプリコンテナ内（`app.db` / `protected/` / `UserDefaults` / App Group）に限られるが、コンテナ内は 9.3 が「差し替えの対象とする」と宣言した攻撃者の書き込み範囲そのものであり耐久性と両立しない。** コンテナ外の代替候補とその欠陥は次の通り。

| コンテナ外の候補 | 壊れる性質 |
| --- | --- |
| Keychain | **健全性。** 再インストール後に残る事例があり、正当な利用者を封鎖する（下記） |
| iCloud Key-Value Store | **健全性と商品仕様。** 端末変更でも残り、7.4 の「端末内にのみ保存し、端末変更では引き継がれない」に反する |
| **DeviceCheck / App Attest** | **仕様 14.5。** 技術的にはこの用途の唯一の正解だが、Apple のサーバーへの問い合わせに自前サーバーが要る |

**これは実装の不備ではなく、唯一の技術的正解である DeviceCheck を仕様 14.5 が排除した結果生じる仕様上のトレードオフである**（次の担当者が置き場所を探し直さないよう不可能性として記録する）。**したがって `PriorUseEvidence` はセキュリティ制御ではなく、低労力の初期化に対するガードである。**

| 対象 | 扱い |
| --- | --- |
| **ファイル削除だけで完結する操作** | **塞ぐ。** Jailbreak 端末で最も手軽であり、塞ぐ価値がある |
| **SQL を伴う操作** | **塞げない。** 上記の不可能性により原理的に不可能 |

引き上げた水準は「`rm` 1 回」から「`rm` 1 回 ＋ `DELETE` 1 回」（小さいが実在。過大には書かない）。**`sqlite_sequence` の残渣は痕跡に使わない**（`DELETE` が 2 回になるだけで攻撃者の能力区分は変わらず、SQLite 内部テーブルへの依存が `VACUUM`/マイグレーションで正当な利用者を封鎖する事故を招く。検証できない防御は「守れている」と誤読される副作用の方が大きい）。**鍵の有無も痕跡に含めない**（再インストール後に Keychain の項目だけ残る事例があり、正常な再インストールを封鎖してしまう）。**サーバー照合は採らない**（仕様 14.5 が端末識別子の収集を禁じる）。**`SubscriptionState`/`RemoteConfigState`/`TrustedTimeState` には同じ規則を課さない**（いずれも `missing` で保守側へ倒れるため削除が利得にならない）。

**`temporarilyUnavailable` と `integrityFailure` を混同しないことが要点**（鍵ストアの一時的利用不可を改ざんとして修復すると正常な利用者の枠を消す）。両者は「ファイルを読み切れたか」で区別する（[正準スキーマ](canonical-schema.md) の 1 章）: 読み切れなかった場合が `temporarilyUnavailable`、読み切れたうえで長さ・`payloadType`・HMAC のいずれかが合わない場合が `integrityFailure`。**「署名検証まで到達したか」を基準にしない**（末尾 1 バイトの切り詰めだけで長さ検査に落ち `temporarilyUnavailable` に分類されると、修復も `transact` の加算も走らず、6.2 の「時刻に依存しない前進源」が 1 バイトの改変で永久に止まる）。

**台帳が `valid` でないときの `resolveCapabilities` の引数を定める。**

| `UsageLedger` の読み込み結果 | `unverifiedLedgerWrites` に渡す値 |
| --- | --- |
| `valid` | 読み込んだ値 |
| **それ以外**（`missing` / `integrityFailure` / `temporarilyUnavailable` / `unsupportedSchema`） | **上限値（下記の上限）** |

**引数は非 Optional**（`0` を渡す実装だと台帳を読めない状態が恒久的に鮮度内になるため、取得できないときは最も保守的な値を渡す。`ledgerWritesSinceConfigFetch` も同様）。これは 6.3 の修復時の値とは別規則（修復は台帳を作り直し `SubscriptionState` を削除するためカウンタは 0 で足りるが、こちらは「まだ修復していない・できない」時点の判定であり `SubscriptionState` がまだ生きている。`temporarilyUnavailable` のように修復へ進まない状態が継続しうるため保守的に倒す）。

##### 鍵を供給できない場合の分類

**「一時的に取れない」と「恒久的に無い」を観測から分ける**（どちらも `CryptoKeyStore` が鍵を供給できない状態だが分類を誤ると正反対の事故が起きる）。

| 観測 | 分類 | 根拠 |
| --- | --- | --- |
| **`errSecInteractionNotAllowed`**（端末ロック中に `AfterFirstUnlock` の項目を読んだ等）・`errSecNotAvailable` | **`temporarilyUnavailable`** | 解錠すれば読める。ここで修復すると正常な利用者の枠を消す |
| **`errSecItemNotFound`**（項目が存在しない） | **`integrityFailure`** | 鍵が無ければ既存 blob を検証できない。恒久的な状態 |
| その他の `OSStatus` | **`temporarilyUnavailable`** ＋ 再試行 | 未知の失敗を懲罰側へ倒さない |

どちらか一方へ倒すことはできない（すべて `temporarilyUnavailable` にすると恒久的鍵喪失時に修復も `transact` も走らずアプリが永久停止する。すべて `integrityFailure` にすると端末ロック中の読み取り失敗で正常な利用者の台帳が `lockedUntilReinstall` つきで消える）。**`errSecItemNotFound` は改ざんと区別できない**（攻撃者が Keychain の項目を消しても同じ観測になる）。**その場合の扱いを `integrityFailure`（封鎖つき修復）とするのは意図した設計**（鍵を消すことで封鎖を回避できてはいけない）。

##### 再インストール後に鍵だけが残る場合

**`ThisDeviceOnly` が保証するのは「別端末へ移行しないこと」でありアンインストール時の削除ではなく、実際に再インストール後 Keychain の項目が残る事例が知られている。**

| `ProtectedBlobStore` | `CryptoKeyStore` | 利用痕跡 | 扱い |
| --- | --- | --- | --- |
| `missing` | `missing` | 無し | 通常の新規台帳を作る |
| `missing` | **`existing`** | **無し** | **同じく通常の新規台帳を作る。** 鍵はそのまま再利用してよい |
| `missing` | いずれでも | **有り** | **保守的台帳へ修復**（上記） |
| `valid` | `existing` | — | 通常経路 |
| `integrityFailure` | `existing` | — | 保守的台帳へ修復（6.3） |

**「データが無いのに鍵がある」をそれだけで異常として扱わない**（再インストール直後の正常な状態でありえ、復旧エラーにすると再インストールした利用者がアプリを使えない。鍵を再利用するか新規生成するかで安全性は変わらないため再利用する。削除自体が失敗しうる経路を増やさないため）。**判断を分けるのは鍵ではなく利用痕跡**（再インストールでは `protected/` と `app.db` の両方が消え痕跡が無く、台帳 blob だけを削除した場合は同じ `protected/` に他の blob が残る）。

##### 鍵と署名のポート

**`Domain` は鍵の生バイト列を受け取らない**（受け取れる形だと鍵がログや診断へ流れる経路ができる）。**署名と HMAC の計算そのものをポートの内側へ置く。**

```swift
// Domain — 鍵の生成・保持と、それを使う演算
protocol CryptoKeyStore: Sendable {
    /// マスター鍵の有無。無ければ生成する。鍵そのものは返さない
    func ensureMasterKey() async throws -> KeyPresence

    /// payload-signing-v1 の派生鍵で HMAC-SHA256 を計算する
    func signPayload(_ signedBytes: Data) async throws -> Data

    /// 定数時間比較で検証する
    func verifyPayload(_ signedBytes: Data, signature: Data) async throws -> Bool

    /// source-provider-key-v1 の派生鍵で HMAC-SHA256 を計算し、
    /// 小文字 16 進 64 文字へ変換して返す（正準スキーマ 1.1）
    func providerAssetKeyHash(_ localIdentifier: String) async throws -> String
}

enum KeyPresence: Sendable, Equatable {
    case created        // 今回生成した
    case existing       // 既にあった
}
```

**`providerAssetKeyHash` の計算もここへ置く**（別ポートにすると同じ鍵を 2 か所から扱うことになり鍵の取り出し口が増える）。

```swift
// Domain — クラッシュ報告。送信前フィルタは実装側の責務（9.2）
protocol CrashReporter: Sendable {
    /// 起動時に 1 回だけ。診断送信が無効なら何もしない
    func start(enabled: Bool)

    /// 利用者が診断送信の可否を変更した
    func setEnabled(_ enabled: Bool)

    /// 復旧エラーなど、クラッシュを伴わない異常
    func recordHandledError(_ code: AppErrorCode, context: CrashContext)

    /// パンくず。自由文字列を受け取らない
    func addBreadcrumb(_ event: AnalyticsEvent)
}

/// クラッシュ報告に添える文脈。識別子と自由文字列を持たない
struct CrashContext: Sendable, Equatable {
    let commitState: ExportCommitState?
    let queueDepth: Int
    let recoveryStep: Int?
}
```

**`CrashContext` に `ProjectID` などを入れない**（識別子をログ経路へ渡せない規約〈9.2〉を型で守る）。

### 7.3 ManagedFileStore

**ファイル生成を 1 か所へ集約する**（バックアップ除外と保護クラスを生成のたびに確実に設定するため）。`Domain` がプロトコルを定義し `Persistence` が実装する。

```swift
enum ManagedFileKind: UInt32, Sendable, Hashable {
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

**`ManagedFileStore` は `ManagedFileRef` だけを受け取り呼び出し元へパスを返さない**（パス解決は `kind` からディレクトリを決め `fileID` を連結する形に閉じ、削除・属性設定・孤児 GC・バックアップ判定のすべてが同じ型で処理できる）。**`kind` を含めるのは ID だけでは削除先を識別できないため**（`PendingFileDeletion` は出力・履歴サムネイル・`StampAsset` すべてに使われ、同じ ID が別ディレクトリに存在すれば誤ったファイルを削除する）。**`fileID` を `String` にしない**（`String` では `"../protected/…"` 等も型として作れ、DB 改変や外部由来文字列でパス連結結果が専用ディレクトリを脱出しうる。`UUID` を内部表現にすれば `/` も `.` も含まない値しか存在せず構造的に脱出できない）。

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

`UUID` を通した時点で 3 が失敗することは起こらないが、将来 `ManagedFileID` の内部表現を変えた場合にこの検査だけが残る。

##### 保存の順序

**属性の設定を rename の後だけに置けない**（書き込み中や rename 前に終了すると一時ファイルが無保護のまま残る。未加工の顔画像や未受け渡し出力を扱う以上、完成ファイルだけの保護では足りない）。

| 順 | 操作 |
| --- | --- |
| 1 | **最終ファイルと同じディレクトリ内に**一時ファイルを作る |
| 2 | **書き込み前に** `isExcludedFromBackup` と `FileProtectionType` を設定し、読み返して確認する |
| 3 | データを書き、ファイルと親ディレクトリを同期する |
| 4 | atomic rename / `replaceItemAt` で最終 URL へ移す |
| 5 | **最終 URL へ属性を再設定する** |
| 6 | 属性を**読み返して検証する** |
| 7 | 失敗したら `ManagedFileRef` を返さず、即時削除するか孤児 GC の対象にする |

**手順 1 で同じディレクトリを使うのはディレクトリの既定保護クラスを最初から効かせるため**（別ディレクトリで作ってから移すとその間だけ保護レベルが下がる）。**手順 2 と 5 の両方で設定する**（`replaceItemAt` は置換先の属性を引き継ぐとは限らないため rename 後の再設定が要り、rename 前の設定は中断時保護のために要る。どちらも省けない）。**手順 6 の読み返しも省かない**（設定が反映されなければ次回起動まで気づけない）。

対象は処理中の一時ファイル・未受け渡し出力・ラスタスタンプ一時ファイル・カスタムスタンプ実体・履歴サムネイル・`ProtectedBlobStore` の blob すべて（**個別に `FileManager` を呼ぶ実装は許さない**）。SQLite のファイル群は GRDB が生成するため `ManagedFileStore` を通せず、ディレクトリの既定保護クラスで覆い起動時に DB ファイルの属性を検証する。

##### スコープ付きアクセス

**「パスを返さない」だけでは `MediaKit` と `Rendering` がファイルを開けない**（Image I/O、Core Image、`CGDataProvider(url:)` はいずれも `URL` を要求する）。**永続的な `URL` は公開せず、処理中だけ有効なスコープを渡す。**

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

`ManagedFileRef` を汎用のまま各所へ渡すと **`kind` の取り違えをコンパイラが検出できない。**

```swift
struct OutputFileRef: Sendable, Hashable { let ref: ManagedFileRef }        // .output
struct WorkingSourceFileRef: Sendable, Hashable { let ref: ManagedFileRef } // .processingTemporary
struct RasterFileRef: Sendable, Hashable { let ref: ManagedFileRef }        // .rasterTemporary
struct StampAssetFileRef: Sendable, Hashable { let ref: ManagedFileRef }    // .stampAsset
```

各 initializer は `kind` を検証し一致しなければ `nil` を返す（デコード時も同じ検証を通し `kind` 不一致の行は不正として扱う）。`OutputRecord.outputFile` は `OutputFileRef`、`WorkingSourceRecord.sourceFile` は `WorkingSourceFileRef` を持つ。

### 7.4 ファイル保護とバックアップ

##### 配置

**SQLite の rollback journal を確実に除外するため DB を専用ディレクトリへ置く**（journal は DB と同じディレクトリに作られるため DB ファイルだけの指定では覆えない）。

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

**処理中ファイルを `tmp/` に置かない**（OS がいつでも削除でき再起動のたびにキュー復元が失敗する。[画像処理](image-pipeline.md)）。`raster/` は `tmp/` のまま（1 回の `render` 呼び出し内でのみ有効で消えて困る状況が無い）。

##### バックアップ

**アプリが所有する DB・画像・保護 blob を対象外とする**（ADR 0003。下表が対象の全体であり `UserDefaults` や第三者 SDK の保存領域は含まない。それらに保護すべきデータを置かないことは 9.2 で担保する）。

| パス | 根拠 |
| --- | --- |
| `db/`（`app.db` と journal） | 復元しても整合しない（7.1） |
| `working/` | 処理中の元素材。復元しても意味がない |
| `tmp/raster/` | `render` 呼び出し内でのみ有効 |
| `Library/Caches/stamp-thumbnails/` | 実体から再生成できるキャッシュ |
| `outputs/` | 24 時間で消えるもの。復元しても期限切れ |
| `protected/` | HMAC 鍵と寿命を揃えるため |
| **`stamps/` / `thumbnails/`** | 商品説明との整合、復元の同時点性、参照の失効、復旧 Saga の増加 |

設定画面と初回起動時に、履歴とマイスタンプが端末内にのみ保存されアプリの削除や端末変更では引き継がれないことを明示する（黙って失われる状態を作らない）。

除外の指定は各パスへ `isExcludedFromBackup = true` を設定する。**ディレクトリへ一度設定すれば足りるとは考えない**（Apple は一般的なファイル操作で値が `false` へ戻りうるためファイルを保存するたびに設定するよう明記している）。**すべてのファイル生成を `ManagedFileStore` へ通す**（7.3。ディレクトリ単位の設定は保険であり保証ではない）。

##### データ保護クラス

バックアップ対象外にしても、端末が盗まれてロック画面の状態で解析されれば保護クラスが低いファイルは読める。**アプリが置くファイルはすべて `.complete` とする。**

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

**アプリ全体の既定を `.complete` にする**（設定漏れが「保護が弱い」方向へ倒れないため。rollback journal と一時 DB ファイルは自動生成されるためディレクトリの既定保護クラスで覆う）。**DB を下げる理由はない**（起動時復旧の最初の手順は「保護データが利用可能になるまで待つ」でありその後に DB を開く。[書き出し Saga](export-saga.md) の起動時復旧。v1 は `BGProcessingTask` を使わずフォアグラウンド継続前提のためロック中に DB を開く必要が無い）。`app.db` には写真ライブラリの平文 `localIdentifier`・顔領域・編集内容が入り、これらを `.completeUntilFirstUserAuthentication` に置く理由は実行モデル上残っていない。**ロック中の復旧を要件にする場合は手順 −4 より前に DB を開く別設計が必要**（両立不可。実行時状態のみ別 DB へ切り出す案もあるが v1 では採らない）。

##### ロック中のアクセス

**`.complete` のファイルへロック中にアクセスできないことを破損や欠損として扱わない**（ファイルは存在し読めないだけ）。

| 誤った扱い | 正しい扱い |
| --- | --- |
| ファイル欠損としてロールバック | **「保護データ利用不可」として処理を一時停止する** |
| 復旧エラーにする | ロック解除後に再試行する |
| `verifiedOutput` との不一致として扱う | 照合を行わず、判断を保留する |

欠損と誤認すると**ロールバックが走って会計を戻す**（実際には出力は無事なため、消費だけ取り消されて出力が残るか無事な出力が削除される）。**エラーコードだけで判断しない**（`NSFileReadNoPermissionError` / `EPERM` は他の原因でも返りうる）。

| 手段 | 用途 |
| --- | --- |
| `UIApplication.isProtectedDataAvailable` | **アクセス前に**利用可否を確認する |
| `protectedDataDidBecomeAvailableNotification` | ロック解除後に**処理を再開する** |
| `protectedDataWillBecomeUnavailableNotification` | 進行中の処理を安全な位置で止める |
| `NSFileReadNoPermissionError` / `EPERM` | 上記で捕捉できなかった場合の**補助的な**判定 |

`AppError` に保護データ利用不可の専用コードを設け**再試行可能**として分類する。

##### 利用可否を取得する契約

上の 3 つはいずれも `UIKit` の API であり `Application` は `UIKit` を `import` できないため（4.3）、`Domain` にプロトコルを置く。

```swift
// Domain — Foundation のみ
enum ProtectedDataState: Sendable, Equatable {
    case available
    case unavailable        // 端末がロックされている
}

protocol ProtectedDataAvailability: Sendable {
    func currentState() async -> ProtectedDataState

    /// available になるまで待つ。すでに available なら即座に戻る。
    /// キャンセル時は CancellationError を throw する
    func waitUntilAvailable() async throws

    /// unavailable へ遷移したことを購読する。進行中処理を安全な位置で止めるために使う
    var willBecomeUnavailable: AsyncStream<Void> { get }
}
```

| 層 | 役割 |
| --- | --- |
| `Domain` | プロトコルの定義のみ |
| `App`（または専用アダプタ） | `UIApplication.isProtectedDataAvailable` と 2 つの通知で実装する |
| `Application` | このプロトコルだけを呼ぶ。`UIKit` を知らない |

**`waitUntilAvailable()` は `async throws`**（キャンセル時に単に戻ると呼び出し側が「利用可能になった」と誤認し `.complete` のファイルを読みにいくため、`withTaskCancellationHandler` でキャンセルを受け `CancellationError` を throw する。正常に戻ったことが `available` の保証になる）。`willBecomeUnavailable` を購読するのは `.complete` のファイル読み書き中にロックへ入る場合があるため（書き出し手順 3〜7 の途中でこれを受けた場合は次のジャーナル保存点まで進めてから停止し `waitUntilAvailable()` で再開する。処理途中でエラーにしてロールバックしない）。

### 7.5 履歴・出力・スタンプの寿命

##### 履歴とプライバシー

プライバシー保護を目的とするアプリが内部に未加工の顔画像を蓄積することは避ける。

- **履歴のサムネイルには加工後の画像のみを使用する**（隠す前の顔が一覧に並ばないように）
- **アプリ専用領域へ元画像の完全コピーを永続保存しない**（保持するのは写真ライブラリへの参照と編集設定のみ。処理用コピーは書き出し完了後に削除する）

元素材が削除・権限喪失した場合、過去の設定情報は表示できるが再編集はできない（仕様 18.3）。**再編集には素材の再接続が要る**（処理用ファイルは 24 時間で消えるため履歴から開いた `Project` はほぼ常に素材を持たず、利用者が写真を選び直し署名済み `ProjectSourceSnapshot.identity` と一致した場合にのみ再接続する。[画像処理](image-pipeline.md)。一致しない写真を結び直せると設定はそのままで中身の違う写真が「同じプロジェクト」になってしまう）。

##### 保存期間と容量

**仕様 18.4 の 100 プロジェクト件数上限は採用しない**（Pro は 1 バッチ 50 枚で 2 バッチで上限に達するため）。代わりに保存期間と使用容量で管理する。

| 設定 | 選択肢 | 初期値 |
| --- | --- | --- |
| 保存期間 | 履歴を保存しない / 7 日間 / 30 日間 / **保存期限なし** | **30 日間** |
| 履歴の使用容量上限 | — | **200MB** |

**「制限なし」ではなく「保存期限なし」と表記する**（容量上限は別に存在し「制限なし」では容量も無制限と誤解される）。設定画面には保存期限なしでも容量上限超過で古い履歴から削除される旨を併記する。容量上限超過時は古いプロジェクトから順に削除する（サムネイルだけ削除して設定を残す中間状態は設けない）。

**「履歴を保存しない」を選んだ場合、本当に保存しない。** 完了画面を離れた時点で次をすべて削除する。

- プロジェクト設定、検出結果、サムネイル、加工用の中間ファイル
- `ProjectSourceLocator`（`Project` と同じ行なので同時に消える）
- `WorkingSourceRecord` と処理用ファイル
- `ExportRecord`、完了済みの `ExportQueueItem`

例外は 6 つです。

- **未受け渡しの出力ファイル。** 利用者がまだ受け取っていない成果物であり、履歴とは性質が異なる。保存・共有・破棄のいずれかで解消する
- **保存結果不明の注記（`UnknownLibrarySave`）が付いた `delivered` 出力。** 利用者の確認・再試行・破棄、または 24 時間で解消する（下記）
- **`UsageLedger` の `SourceRecord` と初回成功時刻。** 無料枠の判定に必要な最小限であり、画像の内容を復元できる情報を含まない
- **一括処理トライアルの消費済み素材識別値。** 5 枚分のトライアル対象を判定するために `SourceRecord` を**期限なく**保持する
- **未完了の `ExportCommit` と、それが参照する検証済み出力ファイル。** 中断した処理の後始末であり、履歴ではない
- **`AppLifecycle` の 1 行。** 利用痕跡（7.2）であり、履歴でも成果物でもない。**この設定・手動の履歴全削除・容量超過・期限削除のいずれの対象にもしない**

3 つ目と 6 つ目は保持期間が無期限である点が他と異なる（プライバシーポリシーの記載と整合させる必要がある。12.2）。この設定ではやり直しができない（24 時間以内なら grant により無料枠は追加消費されないが編集内容は復元されない。設定画面に明記する）。

##### やり直しのための保持保証

**履歴を保存する設定では、保存期間の長短にかかわらず直近の作業を 24 時間保持する。**

| 処理 | 保持対象 |
| --- | --- |
| 単体処理 | 直近 1 プロジェクト |
| 一括処理 | 直近 1 バッチと、そのバッチに属する全プロジェクト（最大 50 件） |

一括処理で「直近 1 プロジェクト」だけを保持すると、バッチ内の残り 49 枚が失われ再編集が成立しない。保持の目的は無料枠の再書き出しだけではなく編集のやり直し全般であるため**プランを問わず同一の扱いとする**（期間は仕様 14.3 の無償再書き出しの窓と一致させる）。

##### 未受け渡し出力の状態

消費は手順 7 の完了で確定するため（[書き出し Saga](export-saga.md)）、生成直後の失敗や異常終了で利用者が成果物を失う経路は作らない。ただし保持は無期限ではなく **24 時間で削除する。**

```swift
enum OutputState: Sendable, Equatable { case generated, deliveryUnknown, delivered, discarded }

extension OutputRecord {
    /// 受け取れていない可能性がある。判定はすべてこの述語を使う
    var isUndelivered: Bool {
        state == .generated || state == .deliveryUnknown
    }
}
```

| 状態 | DB 列値 | 意味 | 保持する期間 |
| --- | --- | --- | --- |
| `generated` | 1 | 生成済み。受け渡しは未成功 | 明示的に破棄するまで、または 24 時間経過するまで |
| `deliveryUnknown` | 2 | 写真ライブラリ保存の結果が不明（[書き出し Saga](export-saga.md) の 8.0） | 同上 |
| `delivered` | 3 | 保存または共有が 1 回以上成功した | **完了画面を離れるまで** |
| `discarded` | 4 | 利用者が明示的に破棄した | 直ちに削除する |

**列値を固定するのは `case` の宣言順に依存させないため**（`OutputState` は署名対象外だが DB 列としてスキーマ移行をまたぐ）。**`delivered` は後退させない**（受け渡しは複数回・任意順序で行え、一度成立した事実を `deliveryUnknown` で打ち消すと共有成功済みの出力が未受け渡しへ戻ってしまう。[書き出し Saga](export-saga.md) の 8.0）。**`isUndelivered` を次のすべてで使う**（個別に `state == .generated` と書くと `deliveryUnknown` だけが残った状態で判定を素通りする）。

- 完了画面の離脱確認と未保存件数の集計
- 起動時復旧の案内
- 強制更新前の受け渡し導線（[運用](operations.md)）
- 任意更新の表示禁止
- 新しい加工の開始禁止
- 24 時間の保持

**保存や共有が 1 回成功しても、その場では削除しない**（何度実行しても追加消費しないため、1 回目でファイルを消すと共有後に写真ライブラリへも保存する操作が成立しなくなる）。**状態は写真ごとの出力レコードに保持し、バッチ単位では持たない**（一括処理は部分成功が起こり、32 枚中 20 枚保存・12 枚容量不足という状態は 1 つの状態では表現できない。バッチの状態は各 `OutputRecord` から集計導出する）。一括保存が部分的に成功した場合、既に `delivered` の写真は再保存せず `isUndelivered` の写真だけを再試行する（`deliveryUnknown` は自動再試行の対象外。[書き出し Saga](export-saga.md) の 8.0）。

**`isUndelivered` の出力が 1 枚以上残った状態で完了画面を離れようとした場合、確認を表示する**（判定はその残数で行い文言にも枚数を含める）。

| 履歴の設定 | 提示する選択肢 |
| --- | --- |
| 保存する | あとで保存 / 破棄 / 戻る。あとで保存は履歴に未保存として残り、24 時間以内は再開できる |
| 保存しない | 破棄 / 戻る |

異常終了後の起動時も、写真ごとの状態で分けます。

| 状態 | 起動時の動作 |
| --- | --- |
| `generated` / `deliveryUnknown` | **復旧案内の対象に含める**（枚数は `isUndelivered` の数。バッチ総枚数ではない） |
| **`delivered` かつ `UnknownLibrarySave` あり** | **削除しない。** 「写真ライブラリへの保存結果が不明」として提示する |
| `delivered`（注記なし） | 一時ファイルを削除し、**復旧案内の対象に含めない** |
| `discarded` | 残存ファイルを削除する |

`DeliveryAttempt` が残っている出力は、この判定の前に `previousState` に従って解決する（[書き出し Saga](export-saga.md) の 8.0。`previousState` が `delivered` なら `delivered` を維持し `UnknownLibrarySave` を記録する）。**注記のある `delivered` 出力は削除しない**（削除すると再試行ファイルが消え `OutputRecord` の CASCADE で注記も消え、追加した仕組みが 1 回の起動で無効になる）。**`UnknownLibrarySave` は別テーブル**（`OutputRecord` にフラグを持たせず集約型で結合する）。

```swift
/// OutputRecord と UnknownLibrarySave を結合した読み取り用の値
struct OutputDeliverySnapshot: Sendable {
    let output: OutputRecord
    let hasUnknownLibrarySave: Bool

    /// 利用者の対応が要る。isUndelivered とは別の軸
    var requiresDeliveryAttention: Bool {
        output.isUndelivered || hasUnknownLibrarySave
    }
}
```

| 述語 | 置き場所 | 用途 |
| --- | --- | --- |
| `isUndelivered` | `OutputRecord` | 未受け渡しの件数。離脱確認・24 時間保持・更新誘導・新規加工の禁止 |
| **`requiresDeliveryAttention`** | **`OutputDeliverySnapshot`** | **ファイルを保持する条件。** 起動時の削除対象から外す |

**起動時の削除判定・24 時間の保持判定・案内表示はいずれもこの集約型を入力にする**（`OutputRecord` 単体では注記の有無が分からず判定が成立しない）。**2 つを分ける**（注記付きの `delivered` は「受け取れている」ため未受け渡し件数には数えないが、再試行の余地を残すためファイルは保持する。利用者が「保存済みを確認」「再試行」「破棄」のいずれかを選ぶまで保持し、選んだ時点で注記を消して通常の `delivered` として扱う）。保持期間は他の出力と同じ 24 時間（無期限だと加工済み画像が端末へ蓄積する。期限到達時は注記ごと削除し利用者へは通知しない）。これは履歴の復元ではなく未完了の受け渡し処理の復旧として扱うため、「履歴を保存しない」利用者にも表示する。

##### 未保存出力の容量制限と排他

Pro は 1 バッチ 50 枚のため完成物が数百 MB〜1GB を超えることがある。**一括処理の開始前に推定出力容量・一時処理容量・未保存出力保持容量・現在の空き容量を確認する**（開始条件は推定必要容量の 1.2 倍以上の空き容量。仕様 24.4）。

- 保持できる未保存バッチは**最大 1 件**、保持期間は最大 24 時間
- 空き容量が一定値を下回った場合、保存または破棄を促す
- **未保存出力は、単体・一括を問わず一度に 1 つの処理単位まで**とする。残っている状態で新しい加工を始めようとした場合、先に解消を求める

組み合わせごとに規則は分けない。

##### 削除の可否判定

**除外条件を文章で列挙すると参照元が増えるたびに書き漏らすため、判定を 1 か所へ集約する。**

```swift
enum HistoryUnit: Sendable, Equatable {
    case project(ProjectID)
    case batch(BatchID)
}

enum DeletionTrigger: Sendable {
    case storagePressure      // 容量超過による自動削除
    case retentionExpiry      // 保存期間による期限削除
    /// 利用者による手動削除。confirmedOverrides に明示確認済みの参照が入る
    case userInitiated(confirmedOverrides: Set<OverridableProtection>)
}

/// 利用者の明示確認で上書きできる保護
enum OverridableProtection: Sendable, Hashable {
    case favorite
    case beingEdited
    case workingSource
    case reexportWindow
}

/// 同一 DB トランザクション内で読み取った参照状況
struct DeletionContext: Sendable {
    let trigger: DeletionTrigger
    let isFavorite: Bool
    let isBeingEdited: Bool
    let hasNonTerminalQueueItem: Bool
    let hasUndeliveredOutputRecord: Bool   // isUndelivered のみ。delivered は保護しない
    let hasExportCommit: Bool          // published を含む
    let hasWorkingSourceRecord: Bool
    let isWithinReexportWindow: Bool   // 24 時間のやり直し保証
}

func canDeleteHistoryUnit(
    _ unit: HistoryUnit,          // Project または Batch
    context: DeletionContext
) -> Bool
```

**参照元は 2 種類に分かれます。**

| 分類 | 参照元 | 巻き込んだ場合に起こること |
| --- | --- | --- |
| **絶対保護**（どの契機でも削除しない） | **非終端のキュー項目**（`isTerminal == false`。6.5） | 処理中のバッチが消える |
| 同上 | **`ExportCommit` の行**（`published` を含む。[書き出し Saga](export-saga.md) の 2） | 復旧の手がかりを失い、会計を戻せない／設定エントリを昇格できない |
| 同上 | **`isUndelivered` の `OutputRecord`**（`hasUndeliveredOutputRecord`） | 利用者が受け取っていない成果物が消える |
| **利用者が上書きできる** | お気に入り | 利用者が明示的に保護した履歴が消える |
| 同上 | 編集中のプロジェクト | 編集画面が参照先を失う |
| 同上 | `WorkingSourceRecord`（[画像処理](image-pipeline.md)） | 処理用の元素材が消え、キューを復元できない |
| 同上 | 24 時間のやり直し保証 | やり直しができなくなる |

**絶対保護は 3 つだけ**（いずれも「消すと復旧できない」か「利用者がまだ受け取っていない」ため確認を出しても意味がない）。残りは利用者の明示操作で上書きできる。**契機ごとに扱いを変える**（「閲覧と削除は常に可能」という原則〈6.2〉と自動削除の安全性を両立させるため）。

| 契機 | 絶対保護 | 上書き可能な参照 |
| --- | --- | --- |
| 容量超過による自動削除 | 次の候補へ進む | **保護する。** 次の候補へ進む |
| 保存期間による期限削除 | 保留する | **保護する。** 参照が消えた時点で削除対象へ戻る |
| **利用者による手動削除** | **理由を提示して拒否する** | **明示確認のうえ削除する** |

**手動削除を無条件に拒否しない**（拒否すると「完了直後の履歴を消せない」等、商品原則に反する状態が生まれる）。確認文言には失われるものを具体的に示す。

| 上書きする参照 | 提示する内容 |
| --- | --- |
| お気に入り | 保護した履歴であること |
| 編集中 | 編集内容が失われること |
| `WorkingSourceRecord` | 処理用の素材も削除されること |
| 24 時間のやり直し保証 | **無料のやり直しができなくなり、次回は枠を消費すること** |

**判定と削除は同一トランザクション内で行う**（別にすると判定と削除の間に新しい参照が生まれる。外部キーの `RESTRICT`〈7.1〉が二重防御として働く）。写真ライブラリへ保存済みの加工済み画像は削除されない（設定画面と削除確認の両方に明示する）。

##### `Project` 削除 Saga

**`Project` の削除は DB と署名済み台帳の両方に及ぶ**（`app.db` と `ProtectedBlobStore` は同一トランザクションにできないため順序と復旧を固定する）。

| 順 | 操作 | 保存先 |
| --- | --- | --- |
| 1 | `canDeleteHistoryUnit` が真であることを確認する | DB |
| 2 | **同一 DB トランザクション**で `Project` と関連行（`ExportRecord` / `OutputRecord` / キュー項目 / `WorkingSourceRecord` / 検出・レビュー結果 / `ProjectStampAsset` / 履歴サムネイル）を削除し、実体を `PendingFileDeletion` へ積む | DB |
| 3 | DB の確定後、**台帳トランザクション**で `ExportedSettingsEntry`（pending と確定の両方）/ `ProjectSourceSnapshot` / `WorkingSourceBinding` を削除する。他から参照されない `SourceRecord` も同じトランザクションで削除する | ProtectedBlobStore |
| 4 | `PendingFileDeletion` に従って実体を削除する | ファイルシステム |

**DB を先に確定させる**（逆順だと台帳を消した後に DB 削除が失敗した場合、存在する `Project` から認可情報だけが失われ素材同一性を解決できなくなる。DB が先なら余るのは「`Project` が無い台帳要素」だけで起動時に回収できる）。

| 中断位置 | 起動時の扱い |
| --- | --- |
| 手順 2 の途中 | DB トランザクションが巻き戻る。削除は成立していない |
| 手順 2 と 3 の間 | **`Project` が存在しない台帳要素（4 集合）と、未参照になった `SourceRecord` を台帳トランザクションで削除する** |
| 手順 3 と 4 の間 | `PendingFileDeletion` の GC が実体を回収する |

この照合には全 `projectID` が要る（起動時復旧は `PostCommitRecoverySnapshot.projectIDs` を使い、同じ 1 回の台帳トランザクションで次を削除する。[書き出し Saga](export-saga.md) の 5）。

> `pendingExportedSettingsEntries` / `exportedSettingsEntries` / `projectSourceSnapshots` / `workingSourceBindings` の 4 集合から `Project` の無い要素を消し、**その結果どこからも参照されなくなった `SourceRecord`** も同じトランザクションで消す。

**`SourceRecord` の GC を同じトランザクションに含める**（別にすると snapshot だけが消えて alias レコードが残る区間ができ、繰り返すと台帳が単調に増える）。

##### `Batch` 削除と編集中 `Project` の破棄

**`HistoryUnit` は `Project` と `Batch` の 2 つ**（`Batch` 削除は所属する全 `Project` を巻き込むため別の手順になる）。

| Saga | 対象 | 手順 |
| --- | --- | --- |
| `Project` 削除 | 単体の `Project` | 上記 |
| **`Batch` 削除** | `Batch` と所属する全 `Project` | 判定を**バッチ全体で 1 回**行い、手順 2 の DB トランザクションで `Batch`・全 `Project`・全キュー項目・全 `ExportRecord` を削除する。手順 3 で**全 `projectID` 分**の台帳要素を削除する |
| **編集中 `Project` の破棄** | 書き出し前の `Project` | `Project` 削除 Saga と同じ。`beingEdited` の上書き確認を伴う |

**`Batch` の判定は写真ごとに行わない**（一部だけ削除できると参照の切れた `Project`/`Batch` が残る。1 枚でも絶対保護に触れていればバッチ全体を削除しない）。台帳側の削除も 1 トランザクション（50 件を個別 `transact` すると途中で落ちたとき一部だけ消えた台帳が残る）。

##### 実装の所在

**これらは DB・台帳・ファイルの 3 者を跨ぐため `Application` の Coordinator が所有する**（`HistoryDeletionCoordinator` の宣言は 4.3、排他の規則は 4.2 が正本）。

```swift
// Domain — 永続化ポート
protocol HistoryDeletionStore: Sendable {
    /// 確認画面の表示用。ここで得た値を削除の根拠にしない
    func inspectDeletion(
        _ unit: HistoryUnit,
        trigger: DeletionTrigger
    ) async throws -> DeletionInspection

    /// DB トランザクション内で DeletionContext を再取得し、
    /// canDeleteHistoryUnit を再評価してから削除する
    func deleteHistoryUnit(
        _ unit: HistoryUnit,
        trigger: DeletionTrigger
    ) async throws -> Set<ProjectID>
}

/// 確認画面へ出す情報。削除の可否そのものは保証しない
struct DeletionInspection: Sendable {
    let blockedByAbsoluteProtection: Set<AbsoluteProtection>
    let overridableProtections: Set<OverridableProtection>
    let affectedProjectCount: Int
    let reclaimableBytes: Int64
}

enum AbsoluteProtection: Sendable, Hashable {
    case nonTerminalQueueItem
    case exportCommitPresent
    case undeliveredOutput
}
```

**`DeletionContext` を呼び出し側から渡さない**（渡せる形だと context 読み取り後に新しい `ExportCommit`/キュー項目が作られ古い context で削除が通る競合が残る）。**`deleteHistoryUnit` は `trigger` だけを受け取り `DeletionContext` を DB トランザクションの内側で読み直す**（`inspectDeletion` の結果は確認文言のためだけに使い削除の根拠にしない。再評価で不可になった場合は throw し理由を提示する）。**`DeletionInspection` と `DeletionContext` は別の型**（同じ型だと表示用に読んだ値を削除へ渡す実装が書けてしまう）。

##### 出力の削除経路

**「ファイルを消す」だけでは `OutputRecord` が孤児になるため、すべての出力削除を単一の経路へ統一する。**

| 順 | 操作 |
| --- | --- |
| 1 | DB トランザクションで `OutputRecord` を削除する |
| 2 | **同じトランザクション内で** `PendingFileDeletion` を追加する |
| 3 | DB のコミット後にファイルを削除する |
| 4 | 成功したら `PendingFileDeletion` の行を削除する |
| 5 | 失敗したら起動時 GC で再試行する |

対象は `delivered` での完了画面離脱、利用者による破棄、`isUndelivered` の 24 時間経過、壊れた出力の復元不能（[書き出し Saga](export-saga.md)）のすべて（**入口ごとに別の順序を実装しない**）。**失っても復旧できないほうを避ける**（ファイルを先に消して DB が失敗するとレコードだけが残り実体を指せない。DB を先に更新すれば残るのは孤児ファイルだけで GC が回収する）。

##### `ExportRecord` と履歴の削除

`ExportRecord` は「いつ何を書き出したか」の履歴であり 24 時間では消えないため**履歴設定の対象になる。**

| 保存期間の設定 | `ExportRecord` の扱い |
| --- | --- |
| 履歴を保存しない | **完了画面を離れた時点で削除する** |
| 7 日 / 30 日 | 期限で削除する |
| 保存期限なし | 容量上限に達したら古いものから削除する |

**`ExportRecord` は対応する `Project` または `Batch` と同じトランザクションで削除する**（別々だと記録の食い違いが生じる）。完了済みキュー項目も同じ扱い、未完了は削除しない。一括処理した写真は履歴へ 50 件並べず**バッチ単位で 1 件に集約する**（開くと個別写真を確認でき、エラーのみの再試行へ遷移できる）。

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

`CustomStamp` の一覧サムネイルは `StampAsset` の実体から再生成できるキャッシュとして扱う（欠損時は実体から作り直す）。

##### カスタムスタンプの実体

| 項目 | 仕様 |
| --- | --- |
| 取り込み元 | 写真ライブラリ、およびファイルアプリ（`fileImporter`） |
| 対応形式 | PNG、JPEG、HEIF / HEIC |
| 透過 PNG | 透過状態を維持する |
| 非透過画像 | 円形または角丸マスクで切り抜く |
| 自動背景除去 | **v1 では行わない**（前景マスク生成の品質が素材に依存し、失敗時の説明が難しい） |
| 登録上限 | **Standard・Pro ともに 100 個**（仕様 12.7 から変更。12.1） |
| 登録時の縮小 | 長辺 1,024px を上限とする |
| 保存形式 | 透過を維持できる圧縮形式（PNG または HEIC） |

ファイルアプリからの取り込みを含めるのは写真ライブラリ経由では透過が失われる経路があるため。

**スタンプ一覧の項目と、プロジェクトが参照する画像実体を別々に管理する。**

| 概念 | テーブル | 役割 |
| --- | --- | --- |
| スタンプ一覧の項目 | `CustomStamp` | 名前、並び順、サムネイル。新規適用の選択肢 |
| 画像実体 | `StampAsset` | 内容ハッシュを主キーとする不変のコピー。参照カウントを持つ |

```
StampAsset.referenceCount
    = CustomStamp.assetHash の行数
    + ProjectStampAsset の行数
```

**「プロジェクトの数」では単位が決まらない**（1 プロジェクト内で同じスタンプを複数の顔領域へ使えるため、`EffectSetting` 1 件につき 1 参照か・重複を畳むか・一部の顔から外したときにいつ減算するかが定まらない）。**中間表を置き、参照の単位を「プロジェクトと実体の組」に固定する。**

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

**同じプロジェクト内の重複は `UNIQUE` 制約が畳む**（1 枚の写真に同じスタンプを 10 個置いても参照は 1。最後の 1 個を外した時点で行が消える）。`StampAsset.referenceCount` を保存値としても持つ場合は同じ DB トランザクションで更新し起動時に導出値との一致を検査する（不一致は導出値を正とし保存値を書き直す）。**この構成なら一覧削除で過去プロジェクトの実体が消えない**（プロジェクト側参照が残る限り参照数は 0 にならない。削除確認では引き続き使用される旨を示す）。

**内容ハッシュの対象は最終保存バイト列の SHA-256 とする。**

| 候補 | 問題 |
| --- | --- |
| 入力ファイルそのもののバイト列 | 同じ画像を PNG と HEIC で取り込むと別実体になる |
| 正規化済みピクセル | デコードの実装差（色空間変換の丸め）で値が揺れる |
| **最終保存バイト列** | — |

計算時点は `ManagedFileStore` へ書く直前（保存の手順 1 と 2 の間）。同じハッシュの `StampAsset` があれば書いたファイルを破棄し既存を再利用する。保存バイト列を対象にするのは、それが実際にディスク上にある唯一の表現であり、デコード実装が将来変わっても既存のハッシュが変わらないため。アプリ提供の基本・追加スタンプはベクターとしてコードに持つため実体消失は起きず、`StampAsset` の対象はカスタムスタンプのみ。

##### DB とファイルの更新順序

**失っても復旧できないほうを避け DB を先に更新する**（ファイルを先に消すと DB 失敗で参照中のスタンプを復旧不能に失うが、DB を先に更新すればファイル削除失敗は孤児ファイルが残るだけ）。

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

`PendingFileDeletion` だけでは作成手順 3 で失敗したファイルを回収できない（記録前に落ちるため）。起動時に専用ディレクトリの実体と DB 上の参照一覧を突き合わせ、どちらにも属さないファイルを削除する（対象: `StampAsset` の実体、ラスタスタンプ一時ファイル、書き出しの一時ファイル、処理用ファイル、履歴サムネイル）。**履歴削除・`CustomStamp` 削除・容量超過削除もすべてこの経路を通す**（入口ごとに別順序だと片方だけ孤児が残る）。

##### 使用容量の表示

一覧削除後も過去プロジェクトが参照する `StampAsset` は残るため、使用容量を 1 数値で示すと「削除したのにゼロにならない」という説明不能な状態が生まれる。**内訳を分けて表示する**（登録中のマイスタンプ / 過去の加工履歴で使用中 / 合計）。一括削除は `CustomStamp` の一覧のみを対象とし参照中の `StampAsset` は削除しない（履歴使用分も消したい場合は対象の履歴を削除する必要がある旨を併記する。**参照中の `StampAsset` を強制削除する機能は提供しない**）。

##### メタデータ

撮影日時には**ファイル内の EXIF** と**写真ライブラリの登録日時**の 2 層があり、写真アプリの並び順は後者が決める。EXIF の撮影日時を一律削除すると加工後の写真がすべて当日撮影として並び、一括処理時に元の時系列が失われる。

| 設定 | 初期値 | 利用者による変更 |
| --- | --- | --- |
| 位置情報を削除 | ON | 可 |
| 撮影機器情報を削除 | ON | 可 |
| コメント・編集ソフト情報を削除 | ON | 可 |
| EXIF の撮影日時を保持 | ON | 可（OFF にすると日時も削除） |
| **写真ライブラリの登録日時を元画像から引き継ぐ** | **取得できる場合に引き継ぐ** | **不可** |

`PHAssetCreationRequest.creationDate` は保存時に明示指定できるため、EXIF から日時を消してもライブラリ側の日時を引き継げば並び順は保たれる。

##### 出力メタデータは許可リストで構築する

**元のメタデータ辞書をコピーして既知キーだけ削除する実装は許さない**（未知の EXIF タグ、XMP、IPTC、MakerNote が残ってしまう。削除リストは知らないキーを取りこぼす方向へ倒れる）。**出力メタデータ辞書を空から構築する。**

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
    let iccProfile: Data?                    // 色が変わる場合のみ埋める
    let capture: OriginalCaptureMetadata?    // 設定で保持を選んだ場合のみ（6.4）
    // 向きは常に通常値（1）として書くため、フィールドを持たない
}
```

**`ImageEncoder` はこの型だけを受け取る**（[画像処理](image-pipeline.md)。元のメタデータ辞書を渡せる形だとコピー削除実装が可能になってしまう）。**保存後に読み返し、許可されていない namespace とキーが 1 つも無いことを検査する**（失敗した出力は完成扱いにせず [書き出し Saga](export-saga.md) の手順 1 の検証失敗として扱う）。**カスタムスタンプも同じ方針で再エンコードする**（取り込み時の縮小・変換で元のメタデータを捨てる。実体がアプリ内に残る以上、位置情報を保持する理由が無い）。

**`PHAsset.creationDate` は `Optional`。** 優先順位を定める。

| 順 | 取得元 | 条件 |
| --- | --- | --- |
| 1 | `PHAsset.creationDate` | **読み取り権限が既にある場合のみ**（[画像処理](image-pipeline.md)） |
| 2 | EXIF の `DateTimeOriginal` | 常に試みる |
| 3 | **`creationDate` を設定しない**（OS が保存日時を使う） | どちらも無い場合 |

**3 の場合に現在時刻を明示指定しない**（設定しないのと同じ結果になるが、「日時を引き継いだ」と記録が残ると不具合調査時に誤解の元になる。取得できなかったことを区分値として記録する。9.2）。**この優先順位表は `contentFingerprint` に流用しない**（fingerprint の撮影日時は EXIF のみ。6.4。`PHAsset.creationDate` 優先は写真属性としての正確さのためであり同一性判定には使えない）。

画像方向とピクセルサイズは常に保持する。

---

---

## 8. 書き出し Saga

**正本は [書き出し Saga](export-saga.md) です。** 状態遷移表、手順 −2〜9、ロールバック順序、起動時復旧順序をここへ複製しません。

書き出しの完了で確定する事柄は、ファイルシステム・DB・`ProtectedBlobStore` の 3 か所に分かれており、**単一トランザクションで更新できません。** 異常終了の位置によって「出力だけ残り枠が消費されない」「枠だけ消費され出力が残らない」が起こります。**永続的なコミットジャーナル（`ExportCommit`）を置きます。**

本書の他の章が依存する不変条件だけを示します。

| 不変条件 | 内容 |
| --- | --- |
| **確定点** | 会計の最終確定は **`published` への到達（手順 7）**ただ 1 点。それ以前は成果物を公開しない。手順 8・9 は前進のみ |
| **公開の観測可能性** | `OutputRecord` の insert とコミットの `published` 更新は同一トランザクション。「コミットあり・`OutputRecord` あり」は `published` のときだけ存在する |
| **会計時刻** | `finalizedAt` は `finalizing` の保存時点の `usageNow`。`generatedAt` / `expiresAt` / grant の起点はすべてここから導出する |
| **所有者** | ロールバックの根拠は台帳側の `ownerExportID` のみ。`AccountingApplied` は単独の根拠にならない |
| **`SourceLease`** | 認可時に**勘定を問わず**追加し、手順 4 またはロールバックで削除する |
| **直列化** | 同一素材の非終端コミットは同時 1 件。台帳では「同一 `sourceID` の `SourceLease` は最大 1 件」として現れる |
| **復旧の開始条件** | 起動時復旧を終えるまで新しい書き出しを開始しない |

`ExportAuthorization` / `ExportAccountingMode` / `GrantAction` / `ExportCommit` / `OutputRecord` の型定義も [書き出し Saga](export-saga.md) が正本です。

---

## 9. セキュリティとプライバシー

### 9.1 HMAC と正準化

**バイト表現の正本は [正準スキーマ](canonical-schema.md)**（型ごとのフィールド順、`enum` の固定番号、`PayloadType` と署名バイト列の式を含む payload 定義はここへ複製しない）。

| 規則 | 内容 |
| --- | --- |
| 署名対象 | `signature` 自身を除く全永続フィールド |
| 正準形 | **専用のバイナリエンコーダ**で作る |
| 含めるもの | `payloadType` と `schemaVersion` を署名対象へ含める |
| 再署名 | `ExportCommit` の insert / update のたび、`transact` の保存のたびに行う |
| 検証 | バイト列の**定数時間比較** |
| 移行 | 旧形式で検証してから新形式で再署名する |

**`payloadType` を含めないと種別をまたいだ付け替えを検出できない**（5 種のデータが同じ鍵で署名されるため、有効な `SubscriptionState` の blob を `UsageLedger` の保存先へ置いても検証を通ってしまう。復号でなく検証のみのため構造が偶然パースできれば通過する）。**`JSONEncoder` や binary plist は正準形として使わない**（集合・配列の順序、`Date` 表現、辞書キー順が実装・バージョン依存であり、同じ意味の値から別の署名が出れば正規の起動が `integrityFailure` になる）。

##### 鍵と派生

**アルゴリズム・鍵長・派生ラベル・出力形式の正本は [正準スキーマ](canonical-schema.md) の 1.1。** 要点のみ示す。

| 項目 | 値 |
| --- | --- |
| 署名 | HMAC-SHA256（32 バイト固定） |
| 鍵導出 | HKDF-SHA256。マスター鍵 256 bit、派生鍵 32 バイト、`salt` は空 |
| 用途の分離 | 署名（`payload-signing-v1`）と `providerAssetKeyHash` の HMAC（`source-provider-key-v1`）を別の派生鍵にする |

**2 つを分けるのは性質が違うため**（一方は値の秘匿、他方は完全性の保証が目的であり、同じ鍵だと片方の運用〈ローテーション等〉がもう片方へ波及する）。

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
    let errorCode: AppErrorCode
    let retryCount: Int
    let sourceRepresentation: SourceRepresentation
}

enum AnalyticsEvent: Sendable {
    case appLaunched(LaunchFields)
    case photoSelected(PhotoSelectedFields)
    case detectionCompleted(DetectionFields)
    case reviewCompleted(ReviewFields)
    case exportStarted(ExportStartedFields)
    case exportCompleted(ExportCompletedFields)
    case exportFailed(ExportFailedFields)
    case deliveryCompleted(DeliveryFields)
    case batchStarted(BatchFields)
    case batchCompleted(BatchFields)
    case paywallShown(PaywallFields)
    case purchaseCompleted(PurchaseFields)
    case recoveryPerformed(RecoveryFields)
}

func log(_ event: AnalyticsEvent)   // log(String) も log(code:fields:) も存在しない
```

列挙が閉じていなければ実装時に文字列イベントが混ざるため、上記が v1 の全 `case` であり追加はこの列挙の変更として行う。フィールド型も同じ理由で閉じ、**`String` と `Date` を 1 つも持たない。**

```swift
struct LaunchFields: Sendable {
    let planKind: PlanKind
    let recoveryPerformed: Bool
    let coldStart: Bool
}

struct PhotoSelectedFields: Sendable {
    let sourceRepresentation: SourceRepresentation
    let resolutionBucket: ResolutionBucket
    let hasProviderIdentifier: Bool
    let isBatch: Bool
}

struct DetectionFields: Sendable {
    let faceCountBucket: FaceCountBucket
    let resolutionBucket: ResolutionBucket
    let issueReasons: Set<ReviewReason>
    let isRedetection: Bool
}

struct ReviewFields: Sendable {
    let faceCountBucket: FaceCountBucket
    let issueReasons: Set<ReviewReason>
    let usedBulkResolution: Bool
}

struct ExportStartedFields: Sendable {
    let accountingMode: ExportAccountingMode
    let planKind: PlanKind
    let isBatch: Bool
}

struct DeliveryFields: Sendable {
    let planKind: PlanKind
    let viaPhotoLibrary: Bool        // false なら OS 共有
    let wasRetry: Bool
}

struct BatchFields: Sendable {
    let sizeBucket: BatchSizeBucket
    let planKind: PlanKind
    let failureCountBucket: FaceCountBucket   // 件数区分を共用する
}

enum BatchSizeBucket: Int32, Sendable, Hashable {
    case upTo5 = 0, upTo10 = 1, upTo25 = 2, upTo50 = 3
}

struct PaywallFields: Sendable {
    let reason: UpgradeReason        // 商品判断の分類
    let planKind: PlanKind
}

struct PurchaseFields: Sendable {
    let purchasedPlan: PurchasedPlan   // 購入した等級。Plan をそのまま送らない
    let isRestore: Bool
}

/// 購入イベント専用の区分値。有料 2 種のみで、free を表現できない
enum PurchasedPlan: Int32, Sendable, Hashable {
    case standard = 0
    case pro = 1
}

struct RecoveryFields: Sendable {
    let commitState: ExportCommitState?
    let outcome: RecoveryOutcome
    let ledgerRepaired: Bool
}

enum RecoveryOutcome: Int32, Sendable, Hashable {
    case completed = 0, rolledBack = 1, blocked = 2, noop = 3
}
```

**`UpgradeReason` は [商品判断](product-decisions.md) の分類をそのまま使う**（分析専用の別分類だと Paywall の表示理由と集計が食い違う）。

区分値と誤り分類。**いずれも `Int32` の wire 値を固定し `/v1/diagnostics` と共有する。**

```swift
enum FaceCountBucket: Int32, Sendable, Hashable {
    case zero = 0, one = 1, twoToThree = 2, fourToTen = 3, elevenOrMore = 4
}

enum ResolutionBucket: Int32, Sendable, Hashable {
    case upTo2MP = 0, upTo8MP = 1, upTo16MP = 2, upTo32MP = 3, above32MP = 4
}

/// 課金区分。Plan と status を潰した分析用の値。Plan をそのまま送らない
enum PlanKind: Int32, Sendable, Hashable {
    case free = 0, standardActive = 1, standardPending = 2
    case sandbox = 6
    case proActive = 3, proPending = 4, expired = 5
}

enum OsKind: Int32, Sendable, Hashable {
    case ios = 0
}

/// 仕様 26.1 の誤り分類。自由文字列を使わない
enum AppErrorCode: Int32, Sendable, Hashable {
    case unknown = 0
    case photoLoadFailed = 1
    case unsupportedFormat = 2
    case detectionFailed = 3
    case renderFailed = 4
    case encodeFailed = 5
    case storageInsufficient = 6
    case fileWriteFailed = 7
    case fileVerificationFailed = 8
    case databaseFailure = 9
    case ledgerIntegrityFailure = 10
    case commitSignatureInvalid = 11
    case ledgerRepaired = 12
    case protectedDataUnavailable = 13
    case keychainFailure = 14
    case photoLibrarySaveFailed = 15
    case photoLibraryPermissionDenied = 16
    case shareFailed = 17
    case entitlementVerificationFailed = 18
    case purchaseFailed = 19
    case remoteConfigRejected = 20
    case sourceMissing = 21
    case sourceMismatch = 22
    case capabilityRequired = 23      // 設定内容が現在の能力で許されない（書き出し Saga 1.1.1）
}
```

**`AppErrorCode` を `Domain` に置く**（`ExportQueueFailure` と診断の両方が使うため一方の層に置くと依存が逆流する）。**全 24 case（0〜23）がこの列挙の全体。**

| 要素 | 表現 |
| --- | --- |
| イベント名 | **`enum` の `case`。** 文字列ではない |
| フィールド名 | **`struct` のプロパティ名。** 辞書のキーではない |
| フィールド値 | 列挙値・区分値・数値のみ |
| 送信時の文字列化 | **アダプタ層で `case` から固定文字列へ写す。** 呼び出し側は文字列に触れない |

**値だけを制約しても不十分**（イベント名を `String`、フィールドを `[String: 値]` の辞書にすると、機密情報の置き場所が値からイベント名や辞書キーへ移るだけ。モジュール境界で自由な辞書を受け取らない。1 か所でも通せばそこが全制約の抜け道になる）。これにより仕様 22.5 が禁じるファイル名・パス・顔座標・EXIF・ユーザー入力文字列が型として渡せなくなる（6.6 のドメイン識別子と `ProjectSourceLocator` も `CustomStringConvertible` に適合させず文字列補間としても入らない）。顔数や解像度は仕様 22.3 の粗い区分値としてのみフィールドになる。新しいイベント追加は `case` 追加と `struct` 定義を伴い、**この手間が任意文字列を追加しにくくする仕組みそのもの。**

##### エラー型と握りつぶしの禁止

`AppErrorCode`（上記の 24 case）を持つ `AppError` を定義し、各要素は**再試行可否と診断フィールド**を持つ（仕様 26.2 の再試行可否は型の上で表現し実行時判断に委ねない）。

```swift
struct AppError: Error, Sendable, Equatable {
    let code: AppErrorCode
    let isRetryable: Bool
    let context: CrashContext?      // 診断へ渡す文脈（識別子と自由文字列を含まない）
}
```

**利用者向けメッセージは `AppError` が持たない**（文言は `App` 層が `code` から解決する。`Domain` に文言を持たせるとローカライズ・文言変更のたびにドメイン層が変わる）。すべての `catch` 節で `AppError` へ変換のうえ `log` を通すことを規約とし、`try?` による握りつぶしは lint で禁止する（`do / catch` または `Result` で明示的に扱う）。

##### クラッシュ解析

Sentry へ送信するのは**クラッシュと未分類例外（`UNKNOWN_ERROR`）のみ**（想定内のエラーは Sentry へ送らず分析イベントの区分値として計測する。Sentry 無料枠超過を防ぎプライバシー面でも正しい。スパイク保護とサンプリングを有効化する）。Sentry Cocoa SDK は `Domain` が定義する `CrashReporter` プロトコルの背後に配置し送信前フィルタをこの実装へ集約する。

**型付き分析イベントによる制約が効くのはアプリ自身が書くログだけ**（Sentry や診断 SDK は `Logger` を通らず、例外メッセージ・スタックトレース中のファイルパス・breadcrumbs・HTTP リクエスト URL とヘッダ・UI 階層やセッション記録・端末情報を独自に収集する）。`CrashReporter` の実装契約として制約を明記する。

| 制約 | 内容 |
| --- | --- |
| 送信前フック | `beforeSend` で**許可フィールドだけを残す**。既定は除去 |
| 例外メッセージ | **任意文字列をそのまま送らない。** 例外の型名と `AppError` のコードへ置き換える |
| パスと URL | ファイルパス、写真ライブラリ ID、URL を除去する |
| 利用者入力 | カスタムスタンプ名などの入力値を送らない |
| 添付 | 画像、添付ファイル、画面キャプチャを**送らない** |
| セッション記録 | UI 階層の収集とセッションリプレイを**有効化しない** |
| breadcrumbs | SDK の自動記録を無効化し、**列挙済みのイベントだけ**を手動で記録する |

例外メッセージを型名とコードへ置き換えるのは、メッセージが最も混入しやすい経路のため（ファイル入出力の例外は既定でパスを本文に含む）。

##### 送信経路ごとの保証

仕様 28.3 の禁止項目（元ファイル名、ファイルパス、写真ライブラリ ID、正確な顔座標、画像ハッシュ、SNS アカウント名、カスタムスタンプ画像、写真・動画の内容、音声内容）は、経路ごとに保証の根拠が異なる。

| 送信経路 | 保証 |
| --- | --- |
| **アプリが明示的に送る分析イベント** | 型付き `AnalyticsEvent` により、禁止データを**型として渡せない** |
| **クラッシュ解析（Sentry）** | `CrashReporter` の送信前フィルタと許可リストを**別途適用する** |
| **診断送信（`/v1/diagnostics`）** | 型付きリクエストモデルと、サーバー側の未知フィールド拒否（10 章） |

**型付き分析イベントだけでは後 2 者を防げません。**

### 9.3 脅威モデル

##### HMAC が守る範囲

**HMAC が防ぐのは改変であってリプレイではない。** 過去の正しい署名済み台帳を丸ごと保存し後で書き戻す攻撃は署名が正当なため検出できず、完全に防ぐにはサーバー照合か端末外カウンタが要るが、仕様 14.5 が不正利用防止目的の端末識別子収集を禁じている。

| 分類 | 内容 | 対応・受容の根拠 |
| --- | --- | --- |
| **対象とする** | 署名対象 payload（`UsageLedger` / `SubscriptionState` / `RemoteConfigState` / `TrustedTimeState`）と `ExportCommit` 行の値改変、5 種の相互付け替え | HMAC 検証で検出する |
| **対象としない** | Jailbreak 端末での過去の正規 blob 丸ごと復元によるリプレイ | サーバー照合なしには技術的に防げず、仕様 14.5 が端末識別子収集を禁じる |
| **対象としない** | `outputs/` 実体の手順 7 完了前の読み取り（会計なしで加工済み出力を得る） | 防ぐには手順 7 まで暗号化が要り、複雑さに対し得られる利益（自分の写真を無料で早く得るだけ）が見合わない。`.complete` 保護〈7.4〉はロック中の解析は防ぐが利用中の読み取りは防がない |
| **対象としない（受容）** | `protected/` 全消去＋`app.db` の `AppLifecycle` 行 `DELETE` による利用痕跡の消去（無料枠 5 枚・一括トライアル 5 クレジットを任意頻度で回復。Jailbreak または再署名ビルドを要する） | 痕跡はコンテナ内にしか置けないが、コンテナ内は差し替え対象そのものであり完全に防ぐ構成が存在しない（7.2 の不可能性） |

**受容の根拠**: 狙われる層（Free・履歴非保存・マイスタンプ不所持）への実害はゼロで、同じ利得は仕様 14.5 が許容する再インストールでも得られる。失効した元有料利用者（Standard 期にマイスタンプ登録後 Free へ降格）はコンテナ書き込みの方が再インストールよりスタンプを保てる分利得が大きいが、既に支払い済みの層であり塞ぐ手段がないため判断は変えない。**`PriorUseEvidence` の目的はこの経路を塞ぐことではなく、「ファイル削除のみ」から「DB 直接書き込みも要する」水準へ引き上げることに限る**（7.2）。

**ファイルの「差し替え」は対象とし「読み取り」は対象外とする**（差し替えは他人の権利・別素材混入につながり検出手段〈`WorkingSourceBinding` 照合・`verifiedOutput` 突き合わせ〉があるが、読み取りは自分の成果物を早く得るだけで取り返しのつかない損失も他者への影響も無い。対象外の根拠は攻撃に必要な手間〈rootfs アクセスとblob退避〉に対し得られる利益が無料枠 5 枚・トライアル 5 クレジットに限られること）。

`lastObservedAt` の単調性は端末時刻の巻き戻しには有効だが、台帳ごと差し替えられれば一緒に戻るためリプレイには効かない。

##### 端末時計の変更

`max(now, lastObservedAt)` が防ぐのは過去への巻き戻しのみで、未来への前進には無力。

| 影響 | 内容 |
| --- | --- |
| 月間枠 | 先の月へリセットされ、**枠を前倒しで取得できる** |
| 履歴・未受け渡し出力 | **即座に期限切れになる** |
| リモート設定 | 即座に失効する |

| 分類 | 内容 | 根拠 |
| --- | --- | --- |
| **対象としない** | 端末時計を進めることによる月間枠の前倒し取得 | 検出手段がサーバー照合なしには存在せず、対策コストが見合わない |
| **対象とする** | 時計操作による破壊的削除の誘発 | `retentionNow` が `nil` の間は削除を保留する（6.3） |
| **対象とする** | 時計操作による整合性封鎖の解除 | `MonthlyIntegrityLock` は信頼できる時刻から導出した年月でのみ解除する（6.3） |

**取り返しのつかない方向（削除）にだけ保守的に倒す**（枠の前倒しは利用者に有利で成果物を失わないが、削除は取り返しがつかない）。

##### サーバー側の署名

**端末上の改変は `ProtectedBlobStore` の HMAC で防ぐが CDN やバックエンドの侵害には対応しない**（対応にはサーバー署名〈Ed25519〉と公開鍵埋め込みが要る。v1 では実装せず脅威モデルの範囲外とする。設定内容は枠数と表示に限られ金銭・個人情報に直結しないため）。

##### 画面スナップショット

**履歴サムネイルを加工後にしても OS のタスクスイッチャには編集中の未加工画面が残るため、対策を必須とする**（編集画面がフォアグラウンドから外れる際にプライバシーオーバーレイを表示する。`scenePhase` が `.inactive` へ遷移した時点）。スクリーンショットの全面禁止は採らない（利用者自身の記録手段を塞ぐため）。

---

## 10. リモート設定とバックエンド

自前サーバーは 2 本のエンドポイントのみとします（ADR 0004）。

| エンドポイント | 内容 |
| --- | --- |
| `GET /v1/config` | Free 月間書き出し数、一括処理上限、トライアルクレジット数、トリアージ閾値、履歴の容量上限、カスタムスタンプの保存解像度、有効なスタンプパック、広告表示頻度、**更新誘導**（`minimumSupportedVersion` / `recommendedVersion` / `appStoreID`。6.7）、障害中の機能停止フラグ |
| `POST /v1/diagnostics` | 利用者が明示的に同意した場合のみ受信 |

実装は Rust + Axum。**`/v1/config` の配信方式**: 設定 envelope はサーバー内の静的 JSON から読み、応答は現在の `serverTime` を付けて動的に生成する。**HTTP キャッシュと ETag は使わず `Cache-Control: no-store`** とし last-known-good はアプリ側で保持する（10.2。毎回変わる `serverTime` を含む応答はキャッシュ可能にできない）。

### 10.1 診断エンドポイント

仕様 21.3 の送信禁止データは**送信経路を持たせないこと**で担保する。

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

**`serde(deny_unknown_fields)` を必須とする**（既定の serde は未知フィールドを黙って捨てるため、クライアント不具合で自由文字列が送られても気づけない。拒否すれば実装ミスが 400 として即座に露見する）。`String` を許すのは `app_version` と `os_version` だけで、いずれも形式を正規表現で検証する（9.2 のクライアント側フィルタとこの型定義の両方で防ぐ）。運用面の上限（サイズ、レート制限、保存期間、同意撤回後の扱い、サーバーログ）は [運用](operations.md) が正本。

### 10.2 リモート設定の検証とキャッシュ

`/v1/config` は無料枠、トライアル枚数、一括処理上限、並列数、トリアージ閾値、広告頻度、最低バージョン、機能停止フラグを変更できる。**壊れた値や古い値をそのまま適用すると、アプリ更新なしで全利用者を壊せる。**

```swift
/// /v1/config のレスポンス全体。serverTime は envelope の外に置く
struct RemoteConfigResponse: Sendable, Decodable {
    let serverTime: Date          // UTC epoch ms。信頼できる時刻の主取得元（6.3）
    let envelope: RemoteConfigEnvelope
}

struct RemoteConfigEnvelope: Sendable, Decodable {
    let schemaVersion: Int32
    let configVersion: Int64
    let issuedAt: Date
    let expiresAt: Date
    let payload: RemoteConfig
}

struct RemoteConfig: Sendable, Decodable, Equatable {
    let freeMonthlyExportLimit: Int32
    let proBatchSizeLimit: Int32
    let trialBatchSizeLimit: Int32
    let trialCreditCount: Int32
    let batchConcurrencyLimit: Int32
    let lowConfidenceThreshold: Double
    let extremePoseYawDegrees: Double
    let extremePosePitchDegrees: Double
    let historyStorageLimitBytes: Int64
    let customStampLimit: Int32
    let customStampMaxEdgePixels: Int32
    let enabledStampPacks: Set<String>
    let interstitialAdExportInterval: Int32
    let update: UpdateConfig
    let killSwitches: KillSwitches
}

struct UpdateConfig: Sendable, Decodable, Equatable {
    let minimumSupportedVersion: AppVersion
    let recommendedVersion: AppVersion
    let appStoreID: String
}

struct AppVersion: Sendable, Comparable, Decodable {
    let major: Int32
    let minor: Int32
    let patch: Int32
}

/// 障害時に個別機能を止めるフラグ。安全性の中核に対応するキーは持たない
struct KillSwitches: Sendable, Decodable, Equatable {
    let disableBatchProcessing: Bool
    let disableCustomStampImport: Bool
    let disableDiagnosticsUpload: Bool
}
```

**フィールドを追加する場合は末尾へ足し `schemaVersion` を上げる**（符号化順は [正準スキーマ](canonical-schema.md) の 4.5 が正本）。**`serverTime` を `RemoteConfigEnvelope` の外へ置く**（中に入れると取得のたびに payload が変わり、同一 `configVersion` での内容差し替え拒否規則〈下記〉が正常な再取得で発火してしまう。`RemoteConfigState` として保存するのは `envelope` のみで `serverTime` は信頼時刻として別保存する。6.3）。

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

**部分的に採用しない**（一部だけ既定値で埋めるとテストされていない組み合わせが動く。全体拒否なら「配信された設定」か「既定値」のどちらかだけが動く）。**期限切れで機能停止フラグだけを残すのは障害対応の手段だから**（サーバー障害中に機能停止を解除すると止めたかった機能が動く。上限値・閾値は古い値より既定値の方が安全）。**同一 `configVersion` での内容差し替えを拒否する**（配信事故と意図的差し替え〈CDN/バックエンド侵害〉はどちらも「バージョン同一・内容相違」の形で現れ、正常な配信では起こりえない）。判定には canonical payload を使う（[正準スキーマ](canonical-schema.md)。JSON 文字列比較はキー順や空白差で誤検知する）。運用側は内容変更時に必ず `configVersion` を増加させる。

##### 時刻の表現形式

**`Date` を `JSONDecoder` の既定に任せない**（既定 `.deferredToDate` は Rust 側の出力形式と一致せず、誤デコードで設定が即座に期限切れになるか永久に期限切れにならないかのどちらかになる）。

| 項目 | 規約 |
| --- | --- |
| 形式 | **UTC epoch milliseconds の `Int64`** |
| Swift 側 | `JSONDecoder.dateDecodingStrategy = .millisecondsSince1970` を明示指定する |
| Rust 側 | `i64` として出力する（`serde` の既定表現に任せない） |
| タイムゾーン | UTC 固定。オフセット付き文字列を使わない |

`/v1/diagnostics` の `occurred_at` と同じ形式とし、アプリとサーバー間で時刻表現を 1 つに統一する（RFC 3339 UTC 文字列はパーサの差〈小数秒桁数、`Z` と `+00:00`〉が残るため採らない）。

##### キャッシュを保護する

リモート設定は無料枠・トライアル枚数・一括上限・スタンプ上限・広告頻度・強制更新・機能停止を変更できるため、**キャッシュを `UserDefaults` や平文ファイルへ置けば利用者が値を書き換えて無料枠を増やせてしまう**（`UsageLedger` を HMAC で保護しても判定に使う上限値自体が改変可能なら意味がない）。

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

**最後の行が重要**（キャッシュ書き換えで `minimumSupportedVersion` を上げれば他人の端末でアプリを止められるが、HMAC 不一致を既定値へ倒すことで改変は「更新なし」にしかならない）。**設定の期限判定に `retentionNow` は使わない**（時計を過去へ戻すことを許容する時刻〈6.3〉であり、使うと古い設定〈無料枠やトライアル枚数を高く設定していた時期のもの〉を時計を戻すだけで延命できてしまう）。

| 条件 | 使う時刻 |
| --- | --- |
| 信頼できる時刻がある | **その値** |
| 無い | **`usageNow`**（単調。過去へ戻せない） |

**時刻だけでは足りない**（`usageNow` も信頼時刻も後退しないことしか保証せず前進は保証しない。6.2。通信を遮断して端末時計を据え置けば `expiresAt` は永久に到来しない）。購入状態と同じ道具で、時刻に依存しない上限を併せて課す。

| 条件 | 判定 |
| --- | --- |
| `expiresAt` を過ぎている | **失効** |
| **`UsageLedger.ledgerWritesSinceConfigFetch` >= 4000**（6.2） | **失効** |
| 上記以外 | 有効 |

**失効すると機能停止フラグ以外がバンドル既定値へ戻る**（上限到達は「取得できないまま台帳を 4000 回書いた」状態であり、last-known-good として信頼し続ける根拠がない）。失効の方向は利用者に不利だが、設定はバンドル既定値へ戻るだけで成果物を失わない（削除と違い取り返しがつくため保守的に倒す方向が逆になる）。

### 10.3 リモート設定で変更できないこと

**次はリモート設定から無効化できない**（安全性の中核であり、サーバー側の事故や侵害で外せる状態にしない）。

- 6.5 の確認画面（`reviewRequired` の解消なしに書き出せない）
- 6.1 の全顔初期マスク
- [書き出し Saga](export-saga.md) のファイル検証（サイズ・SHA-256・デコード）
- [書き出し Saga](export-saga.md) のコミットジャーナルと最終確定境界
- [画像処理](image-pipeline.md) の未解決 `bitmapID` によるエラー
- [運用](operations.md) の「未受け渡し出力があるときは受け渡し導線を先に出す」

**これらに対応する設定キー自体を `RemoteConfig` に持たせない**（「フラグはあるが既定で有効」ではなく、フラグを存在させない形にする）。**更新誘導は逆方向の扱い**（`minimumSupportedVersion` はリモートから変更できるが、取得失敗時の既定は「更新なし」。バンドル既定値にも強制更新は含めない）。**一括処理の同時並列数はアプリが対応を宣言した最大値を超えない**（リモートで 8 を指定されてもアプリ側の上限〈v1 は 1〉でクランプする。並列数は実装のメモリ使用量と直結するためサーバーから引き上げられる形にしない）。

### 10.4 障害時

リモート設定の取得に失敗した場合はアプリ内の安全な既定値を使用する。**バックエンド障害で編集処理を停止させない**（仕様 21.6）。

---

---

## 11. テスト戦略

**「純粋な判定」「実ストレージの原子性」「プロセス強制終了後の状態」は同じ層では検証できない**（前 2 者を混ぜると判定テストにシミュレータが要り実行が遅くなって回されなくなる）。

四層へ分ける。フレームワークは **Swift Testing**（`@Test`）を使い、UI テストのみ XCTest とする。

| 層 | 実行環境 | 保証する内容 |
| --- | --- | --- |
| **domain unit test** | `swift test`（数秒。シミュレータ不要） | 純粋関数と状態機械。クォータ、トリアージ、座標変換、`compileRenderDraft`、正準化 |
| **application saga test** | `swift test`（数十秒） | 偽 DB・偽 `ProtectedBlobStore`・偽ファイルによる**各中断点**の挙動 |
| **adapter integration test** | シミュレータ / 実機 | 実 GRDB、実 保護ファイル、実 Keychain、Vision、Core Image |
| **process-death fault injection test** | **実機** | **各手順の直後に強制終了**し、再起動後の状態を検証 |

各項目は検証が成立する最も低い層へ置く（個別のテスト項目は `docs/test-plan.md` が正本）。

### 11.1 必須とする保証

##### コミット Saga への障害注入（実機）

**偽ストアの saga テストは「順序どおりに書けば整合する」ことしか示さない**（GRDB トランザクションの実際の原子性、`replaceItemAt` の中断耐性、同期のタイミングは実装と OS の性質であり偽物では検証できない）。**シミュレータではなく実機を使う**（シミュレータの FS は macOS のものであり iOS のストレージスタックと一致せず、強制終了の再現もプロセス kill にしかならず jetsam の挙動と異なる）。

| 手段 | 用途 |
| --- | --- |
| テスト用フックによる **`_exit(1)`** | 各手順の直後で決定的に落とす。`exit(0)` は正常終了であり `atexit` ハンドラやバッファのフラッシュが走るため、クラッシュ境界の検証にならない |
| 外部プロセスからの `SIGKILL` | シグナルハンドラを経由しない終了 |
| メモリ圧迫によるジェッツァム | 実運用に最も近い経路。一括処理 50 枚で再現する |

**強制終了フックはテスト専用ビルドにのみ含める**（コンパイル条件 `#if DEBUG_FAULT_INJECTION` で分離し、リリースビルド非混入を CI で確認する）。

##### HMAC canonical bytes のゴールデンテスト

各 `schemaVersion` について固定の canonical bytes と HMAC 値をテストへ埋め込む（リファクタリングで正準形が変わると既存利用者の台帳が全て `integrityFailure` になり、単体テストで気づけなければリリース後に発覚する）。

##### Core Image 出力のゴールデン画像テスト

同じ `RenderSpec` から生成したプレビュー用と原寸用の出力が一致することを検証する（**素材には上端のみ・下端のみに顔があるものを含める**。上下非対称性は Y 軸反転の誤りが最も現れやすく、中央に顔がある素材では反転しても差が出ない）。

##### 実ストレージを使う integration test

**プロトコル適合テスト**として、各プロトコルに対し実装と偽実装の**両方へ同じスイート**を実行する（偽実装が本物と違う挙動をすると saga テストが無意味になるため）。

### 11.2 検出品質

仕様 30.2 の検出条件は**合否判定ではなく検出率の回帰監視**として計測する（仕様 34.5 が「完全自動を約束しない」と定めるため閾値でビルドを落とすのは不適切）。同じ素材セットで要確認率も計測する（高すぎると Pro の価値が失われ低すぎると見落としが増える。`extremePose` の角度閾値と `lowConfidence` の信頼度閾値はこの計測から決める。[画像処理](image-pipeline.md) の受入条件）。**iOS のバージョン更新で Vision の検出特性が変わることがあり**、前リリースとの差が一定以上に開いた場合は閾値を見直す。

### 11.3 プライバシーとアクセシビリティ

プライバシーの受入テストとして、履歴一覧に未加工の顔が現れないこと、タスクスイッチャに未加工画面が残らないこと、アプリ専用領域に元画像の永続コピーが残らないこと、出力ファイルからメタデータが除去されていることを明示的に検証する。

アクセシビリティは仕様 29 章を受入条件とする（SwiftUI の `Canvas` は既定でアクセシビリティ要素を持たないため `accessibilityLabel` / `accessibilityValue` / `accessibilityRepresentation` の明示的付与が必須）。実機マトリクスは仕様 30.8 に従う。

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
| 基本スタンプの意匠 | ベクターで自作する 12〜20 種の具体的な図案 | v1 実装中 |
| 履歴の使用容量上限 | 初期値 200MB は暫定。加工後サムネイルの実サイズを計測して確定 | v1 実装中 |
| カスタムスタンプの保存解像度 | 長辺 1,024px は暫定。顔が大きく写る素材での見え方を実機で確認（7.5） | v1 実機検証時 |
| トライアルのクレジット数 | 5 枚は暫定。転換率を見て調整可能な設定値とする | リリース後 |
| 一括処理の同時並列数を 2 へ引き上げるか | v1 は 1 固定。引き上げには二段階ゲートの実装と実機計測が要る | v2 検討時 |
| ファイル同期の方式 | `F_FULLFSYNC` と通常の `fsync` の所要時間差を実機計測し、耐久性とのつり合いで決定（7.1） | v1 実機検証時 |
| 手順 7-b の再確認しきい値 | `usageNow - finalizedAt` の許容差 5 分は暫定。手順 3〜7 の実測時間から確定（[書き出し Saga](export-saga.md)） | v1 実機検証時 |
