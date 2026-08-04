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
| **本書** | 目的、技術スタック、モジュール構成と依存方向、並行性、ドメインモデル、永続化、セキュリティ境界、設定定数、テスト戦略、逸脱と未決事項 |
| [画像処理アーキテクチャ](image-pipeline.md) | `RenderSpec` / `RenderDraft` / `RenderPlan`、座標・色・合成規約、スタンプラスタライズ、写真選択の境界型 |
| [書き出し Saga](export-saga.md) | 認可、`ExportJob` の状態、処理手順、中断時の後始末、起動時復旧、実体喪失時の扱い、受け渡し |
| [正準スキーマ](canonical-schema.md) | ハッシュ定義（設定ハッシュ・`StampAssetHash`）と基本型の符号化（ADR 0005、ADR 0006） |
| [運用](operations.md) | 更新誘導の運用、審査への配慮、診断と Sentry の運用制約 |
| [商品面の決定](product-decisions.md) | v1 のリリース範囲、動画の扱い、課金訴求の分類、利用者向け表現 |
| [実装計画](implementation-plan.md) | サブプロジェクトへの分解、依存、モジュール割り当て |
| [テスト計画](test-plan.md) | 層ごとの個別テスト項目 |
| [ADR](adr/) | 技術選定とその理由 |

**推奨読書順**

1. 本書の 1〜4 章（目的、技術スタック、モジュール境界、並行性）
2. 本書の 5〜6 章（ドメインモデル、永続化）
3. [画像処理アーキテクチャ](image-pipeline.md)
4. [書き出し Saga](export-saga.md) → [正準スキーマ](canonical-schema.md)
5. 本書の 9〜11 章（セキュリティ、設定定数、テスト戦略）

**文書間の依存**

```
architecture.md（型と境界の正本）
  ├─→ image-pipeline.md   （RenderSpec 系の正本。architecture の ManagedFileRef に依存）
  ├─→ export-saga.md      （手順と状態の正本。architecture の UsageLedger に依存）
  │     └─→ canonical-schema.md（ハッシュ定義の正本）
  ├─→ operations.md       （運用規則。architecture の判定結果に依存）
  └─→ product-decisions.md（商品面の決定。architecture の能力判定に依存）
```

---

## 1. 目的・前提・対象範囲

### 1.1 本書の役割

本書は実装時に参照する現在の設計を定める。型、不変条件、状態遷移、処理順、障害時の挙動を一意に決めることが目的。**挙動の定義は本設計が正であり、`ui-mock/` は本設計に追従する**（モックのコードは実装へ流用しない）。

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

**台帳・購入状態キャッシュは `app.db` の平文テーブルとして保存する**（ADR 0005）。

**ラスタライズは `CGContext` を使う（`ImageRenderer` は不採用）。** `ImageRenderer` は `@MainActor` 隔離のため一括処理 50 枚が直列化される。`CGContext` はバックグラウンド実行でき、ピクセル形式とストライドも明示できる（[画像処理](image-pipeline.md)）。

**`UIViewRepresentable` / `UIViewControllerRepresentable` は広告バナーと共有シートのみに使う。**

---

## 3. モジュール構成と依存方向

### 3.1 パッケージ構成

Swift Package Manager のローカルパッケージとして層を分け、**モジュール境界をコンパイラに強制させます。**

```
kaokakushi/
├── KaoKakushi.xcodeproj
├── App/                     アプリ本体
│   ├── KaoKakushiApp.swift  エントリポイント、DI の組み立て
│   ├── Navigation/          Route と画面解決
│   ├── Screens/             SwiftUI の各画面
│   ├── Selection/           PhotoSelectionBridge / FileSelectionBridge（[画像処理](image-pipeline.md)）
│   └── PrivacyShield/       スクリーンショット対策（9.2）
│
├── packages/
│   ├── Domain/              純粋 Swift。Foundation 以外に依存しない
│   ├── Application/         書き出し Saga、起動時復旧、ロールバック（4.3）
│   ├── Rendering/           StampRasterizer 実装（Core Graphics）
│   ├── Persistence/         GRDB、ファイル管理
│   ├── MediaKit/            Vision / Image I/O / Core Image / PhotoKit
│   ├── Billing/             RevenueCat ラッパと権限解決
│   ├── Ads/                 AdPresenter（Google Mobile Ads）
│   └── Analytics/           `CrashReporter` の実装（Sentry のみへ送る。9.1）
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
| | `GRDB` / `Vision` / `Photos` |

**`CGSize` / `CGRect` も使わない。** 必要な値型は `PixelSize` / `PixelRect` / `NormalizedRect` としてドメイン側で定義する（[画像処理](image-pipeline.md)）。`CoreGraphics` の型は描画系の前提（原点の左上/左下等）を暗黙に持ち込む。

**`Package.swift` の `dependencies` では強制できない**（Apple SDK のシステムモジュールは列挙なしで `import` できるため）。強制手段は次の通り。

| 手段 | 内容 |
| --- | --- |
| SwiftLint の `custom_rules`（禁止 import の正規表現検出） | `Domain/Sources/**` に対し上記の禁止モジュールを検出する |
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
| `ExportSagaStore` / `OutputDeliveryStore`（[書き出し Saga](export-saga.md)） | `Domain` は**プロトコル**。呼び出しは全 Coordinator が共有するグローバル直列キュー 1 本を経由する（4.2。専用の待機キュー・ゲートは持たない） |
| `Application` の Coordinator | `actor` |
| `SharePresenter` / `AdPresenter` | **`@MainActor`**（UIKit を操作する） |
| UI の状態オブジェクト | `@MainActor` |
| `MediaKit` の重い処理 | `nonisolated` な `async` 関数。呼び出し側が並行度を制御する |

### 4.2 排他区間の実装規則

**`actor` は再入可能であり、単独では「読み取りから保存完了まで」の論理的クリティカルセクションを保持できない**（`await` で中断すると同じ actor のメソッドへ別の呼び出しが入り、FIFO も保証されない）。**変更を伴うすべての操作（書き出し・受け渡し状態の更新・素材の選択替え・履歴削除）は、単一のグローバル直列キュー 1 本（v1 は並列数 1）で直列化する**（ADR 0005）。同時に処理する項目は常に 1 件とし、次の項目はキューの前が完了してから着手する。**読み取りとプレビュー描画はキューを経由しない**（変更を伴わないため直列化の対象外）。**`OutputDeliveryCoordinator` の受け渡し操作（`beginDeliveryAttempt` / `completeLibrarySave` / `completeShare` / `abandonDeliveryAttempt` 等）もこの同じグローバルキューを使う**（専用の per-exportID キューは持たない。共有シート表示など利用者操作待ちの間も、他の変更系操作はキューで待機する。v1 は並列数 1 のため許容する）。

**キャンセル**は「キュー投入前」と「キューから取り出して処理を開始する直前」の 2 箇所で `Task.checkCancellation()` を確認する。**生成（書き出し）は何も消費しないため、キャンセルはどの時点でも `ExportJob` 行の削除という一律の後始末で足りる**（ADR 0006）。生成後の出力確認画面での「やり直す」「完了」は明示的な操作であり `CancellationError` としては扱わない（[書き出し Saga](export-saga.md) が正本）。`CancellationError` は業務エラーとして扱わず、Sentry へは送らない（9.1）。

### 4.3 Application 層

次の処理は `Domain`（純粋 Swift）にも `App`（SwiftUI）にも置けません。

- 書き出しの手順、完了操作、中断時の後始末（[書き出し Saga](export-saga.md)）
- 起動時復旧
- DB・台帳・ファイルの協調、ゲートの取得と解放
- 出力の受け渡し

`App` へ置くと UI 状態と永続化 Saga が結合し画面離脱で復旧処理が止まる経路ができ、`Domain` へ置くと副作用と `await` が入り純粋 Swift の制約が壊れる。

```swift
// Application — Domain のプロトコルだけを使う
actor ExportCoordinator { }            // 書き出しの手順、完了操作、中断時の後始末（[書き出し Saga](export-saga.md)）
actor StartupRecoveryCoordinator { }   // 起動時復旧（[書き出し Saga](export-saga.md)）
actor OutputDeliveryCoordinator { }    // MediaSaver / SharePresenter の呼び出しと状態遷移
actor SourceImportCoordinator { }      // インポート / 再選択 / 再接続 / 複製（[画像処理](image-pipeline.md)）
actor HistoryDeletionCoordinator { }   // Project / Batch 削除、編集中の破棄（7.5）
```

##### 排他の単位

**`actor` であることを排他の根拠にしない**（4.2）。**すべての変更系 Coordinator が、単一のグローバル直列キュー（4.2）を共有する。** exportID 別・projectID 別の個別キューや、複数ロックの取得順序規則は持たない（キューが 1 本しかないため、複数キューを跨ぐ取得によるデッドロックはそもそも起こらない。ADR 0005）。

| Coordinator | 役割 |
| --- | --- |
| `ExportCoordinator` | 書き出しの手順、中断時の後始末（[書き出し Saga](export-saga.md)） |
| `OutputDeliveryCoordinator` | `MediaSaver` / `SharePresenter` の呼び出しと状態遷移 |
| `SourceImportCoordinator` | インポート / 再選択 / 再接続 / 複製（[画像処理](image-pipeline.md)） |
| `HistoryDeletionCoordinator` | `Project` / `Batch` 削除、編集中の破棄（7.5） |
| `StartupRecoveryCoordinator` | 起動時に 1 回のみ実行し、**完了まで他のすべてを開始させない** |

**整合は `canDeleteHistoryUnit` が非終端の `ExportJob` および未削除の `OutputRecord` を絶対保護として同一 DB トランザクション内で見ることで成立する**（7.5）。判定と削除を同一 DB トランザクションへ閉じることで整合する。`DatabaseQueue` がトランザクションを直列化するため判定と挿入は交差しない。

**`Application` が直接 `import` してはいけないもの**を明示する。

| 禁止 | 代わりに使う |
| --- | --- |
| `SwiftUI` / `UIKit` | UI は知らない。保護データの利用可否は `Domain` の `ProtectedDataAvailability`（7.4） |
| `GRDB` | `Domain` の永続化プロトコル |
| `Vision` / `CoreImage` / `Photos` | `Domain` の `FaceDetector` / `ImageEffectRenderer` / `MediaSaver` |

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
    let projectID: ProjectID                  // 写真を識別する。6.5
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
    detectionRevision: Int64,
    extremePoseYawDegrees: Double,    // 設定定数（10 章）。Domain は設定定数の型を参照しないため注入する
    extremePosePitchDegrees: Double
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

**非有限（`NaN` / 無限大）の `yawDegrees` / `pitchDegrees` は `extremePose` として扱う**（`NaN` は比較が常に偽になるため、素通しすると破損した検出結果が要確認判定を通過する。安全側へ倒す）。

**`faceAtEdge` は、既定拡張率（上 25% / 下 15% / 左右 15%。[画像処理](image-pipeline.md) 1 章）を顔矩形へ適用した結果が画像境界（0 以下または 1 以上）に接する場合に発生する**（拡張式は `expand` と共有する。利用者が拡張率を変更しても判定は既定拡張率で行う — 要確認判定は「既定でも隠しきれない可能性」の検出であり、設定に追従させると判定が利用者操作で変わる）。

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

##### 書き出し認可での確認

**書き出し認可は、保存済みの `DetectionStatus` / `ReviewStatus` / `ReviewDecision` をそのまま信頼する**（ADR 0005）。認可時に検査するのは、確認済みプレビューが現在の設定と一致すること（`PreviewConfirmation`。[書き出し Saga](export-saga.md) の 1.1）と、`reviewRequired` かつ `unreviewed` の写真が残っていないことの 2 点のみ。不成立なら開始しない。

##### `triage` の入力

`triage` は `DetectionResult` を受け取ります（上記）。その材料を `FaceTrack` が列として持ちます。

| `FaceTrack` の列 | 用途 |
| --- | --- |
| `faceTrackID` / `bounds` / `createdManually` | 描画と `RegionOrigin` の決定 |
| **`confidence`** | `lowConfidence` の判定 |
| **`yawDegrees` / `pitchDegrees` / `rollDegrees`** | `extremePose` の判定と描画の回転 |
| **`isSmallFace`** | `smallFace` の判定 |
| **`detectionPixelSize`**（`Project` の列） | 検出時の寸法。`isSmallFace` の根拠 |

**検出品質の列を `FaceTrack` へ持たせる**（持たせないと `triage` を再実行できず再導出が成立しない）。

##### 要確認への対応

**`reviewRequired` かつ `unreviewed` の写真が 1 枚でも残っている間は一括書き出しを開始できない。**

**警告を消すのではなく、警告に対する利用者の判断を記録する**（検出結果は事実であり、確認したからといって事実は変わらない）。

```swift
enum ReviewResolution: Sendable, Equatable {
    /// 内容を見て、このままでよいと判断した
    case acceptedAsIs

    /// 手動で隠す範囲を追加した。どの領域かを保持する
    case manualRegionAdded(regionID: RegionID)   // 6.5

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

`reviewRequired` の写真が `reviewed` になる条件は、その写真の `[ReviewIssue]` すべてに `ReviewResolution` が記録されていること（1 件でも未記録なら `unreviewed`）。発生単位にすることで「3 人のうち 1 人だけ対応して先へ進む」経路をなくす。`normal` の写真には `ReviewIssue` が無く `ReviewDecision` を作れない（確認の成立はモードで分かれる。6.4）。

**一括対応は理由別のグループ単位でのみ許可する**（個別対応を強いるのは現実的でないため）。

- そのグループのサムネイル一覧を表示した状態からのみ実行できる
- **`noFaceDetected` は一括対応の対象外**（何も加工されないまま通過する最も危険な経路であり個別判断を要する）

`DetectionStatus` と `ReviewIssue` は利用者の判断で変化せず、警告理由は書き出し後も記録として残る。

##### 単体処理で顔が 1 つも検出されない場合

**この節は単体処理に限る**（一括処理の顔 0 件は `noFaceDetected` と勘定の規則に従う。[書き出し Saga](export-saga.md)）。利用不可にはせず、手動で隠す範囲を追加する / 縦横比変更やメタデータ削除だけを行う / 編集を終了する、から選べるようにする。

加工なしの書き出しも仕様 14.2 の定義では消費対象。不意打ちを避けるため完了操作の前に明示する（消費は完了操作で確定するため。6.3）。**`MonthlyQuotaDecision`（6.3）が `unlimited` の場合は無料枠に言及しない。**

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
}

/// 契約の等級。raw value は DB 列値（スキーマ移行をまたぐため固定。下記）
enum Plan: UInt32, Sendable, Hashable, Comparable {
    case free = 1
    case standard = 2
    case pro = 3
}

/// 契約の状態。pending は支払い保留（仕様 5.4）。raw value は DB 列値
enum PlanStatus: UInt32, Sendable, Hashable {
    case active = 1
    case grace = 2
    case pending = 3
    case expired = 4
    case revoked = 5
}

func resolve(
    snapshot: CustomerInfoSnapshot,
    usageNow: Date,
    standardEntitlementID: String,   // 設定定数（10 章）。Domain は設定定数の型を参照しないため注入する
    proEntitlementID: String
) -> Entitlement

struct Entitlement: Sendable, Equatable {
    let plan: Plan               // free / standard / pro
    let status: PlanStatus       // active / grace / pending / expired / revoked
    let expiresAt: Date?
    let lastVerifiedAt: Date     // 取得できた時刻
    let isSandbox: Bool
}

/// app.db の平文テーブルへ保存する購入状態キャッシュ（ADR 0005）
struct SubscriptionState: Sendable, Equatable {
    let entitlement: Entitlement
    let willRenew: Bool
    let fetchedAt: Date            // このキャッシュを書いた時刻
}
```

**購読キャッシュの鮮度管理は RevenueCat SDK の標準キャッシュ挙動にそのまま任せる**（ADR 0005）。`Purchases.getCustomerInfo()` を既定のキャッシュポリシーで呼び、返された `CustomerInfo` をそのまま `resolve` へ渡す。

##### `resolve` の導出規則

1. `plan`: `activeEntitlementIDs` に `proEntitlementID` があれば `pro`、なければ `standardEntitlementID` があれば `standard`、どちらも無ければ `free`
2. `status`: `free` は常に `active`。有料プランは `isInBillingRetry` なら `pending`（支払い保留。仕様 5.4）、それ以外は `active`
3. `expiresAt`: 該当 entitlement ID の `expirationDates` の値（無ければ `nil`）。`free` は `nil`
4. `lastVerifiedAt = usageNow`、`isSandbox` は snapshot の値を写す

**`resolve` は `grace` / `expired` / `revoked` を生成しない。** ストアの猶予期間は RevenueCat が `expirationDates` を猶予終了まで延ばした `active` として現れ、失効・取り消しは `activeEntitlementIDs` から消えることで `free` として現れる。`PlanStatus` の残りのケースは保存済み `Entitlement`（`SubscriptionState`）が失効判定（上記）で使うために存在する。

**`Plan` / `PlanStatus` の列値を固定する**（値は上記コードブロックの raw value が正本。`SubscriptionState` の DB 列としてスキーマ移行をまたぐため、`case` 宣言順に依存させない。`BatchKind`（6.4）/ `OutputState`（7.5）と同じ規則）。

##### `isSandbox` の用途

サンドボックス購読は実費なしで取得でき更新周期も短いため、本番と同じ扱いにすると区別できない。

| 項目 | 規則 |
| --- | --- |
| 能力の付与 | **本番と同じ。** サンドボックスでも `ResolvedCapabilities` を制限しない（TestFlight と審査で有料機能を検証できなくなる） |
| `Entitlement` への伝搬 | **`isSandbox` を `Entitlement` と `SubscriptionState` へ持たせる** |

要件は 3 点。

- **`pending`（支払い保留）では有料機能を付与しない**（仕様 5.4）。権限フラグはすべて `Entitlement` から導出し `plan` から直接導出しない
- **オフライン耐性**（仕様 25.3 / 27.3）。最後に検証成功した `Entitlement` を `app.db` へ保存し、RevenueCat SDK のキャッシュが有効な間はこのキャッシュにより有料機能を維持する
- **バックエンド障害で編集を止めない**（仕様 21.6。v1 はサーバレス。ADR 0005）

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

    /// 有効な追加スタンプパック。設定定数から能力解決時に写す（10 章）
    let enabledStampPacks: Set<String>
    let canUseProBatch: Bool      // 制限なしの一括処理
    let canUseBatchTrial: Bool    // クレジット消費による一括トライアル
    let shouldShowAds: Bool
}

enum CapabilityResolution: Sendable, Equatable {
    case resolved(ResolvedCapabilities)
    case verificationRequired
}

/// 能力解決の入力
enum SubscriptionCacheState: Sendable {
    /// キャッシュがある
    case loaded(SubscriptionState)
    /// キャッシュが存在しない（初回起動・再インストール直後）
    case missing
    /// DB が一時的に読めない
    case temporarilyUnavailable(verified: Entitlement?)
}

func resolveCapabilities(
    _ state: SubscriptionCacheState,
    usageNow: Date,
    enabledStampPacks: Set<String>   // 設定定数（10 章）。Domain は設定定数の型を参照しないため注入する
) -> CapabilityResolution
```

| 状態 | 解決結果 |
| --- | --- |
| `loaded` | `Entitlement` から `ResolvedCapabilities` を導出する |
| `missing` かつオンラインで取得成功 | 取得結果で `loaded` として解決する |
| `missing` かつオフライン | **`verificationRequired`** |
| `temporarilyUnavailable(verified: nil)` | **`verificationRequired`**（コールドスタート） |
| `temporarilyUnavailable(verified: 値)` | その値で解決する |

**`Entitlement.expiresAt` を過ぎたキャッシュは失効として扱う以外の鮮度判定は行わず、RevenueCat SDK が返すキャッシュをそのまま信頼する**（ADR 0005）。

**`verificationRequired` は「Free として動かす」ことではない。** 有料機能を新規に付与せず、書き出しの認可も開始しない（未検証での有料機能付与と、正当な利用者の無言降格の両方を避ける）。

**`enabledStampPacks` を能力解決の内側で `ResolvedCapabilities` へ写す**（`Domain` の判定関数は設定定数の型を参照しないため。3.3）。

##### `Entitlement` → `ResolvedCapabilities` の導出

1. **`expiresAt` を過ぎていれば `status` に関わらず Free 相当**（失効判定を最初に行う）
2. **`status` が `pending` / `expired` / `revoked` なら Free 相当**（`pending` では有料機能を付与しない。仕様 5.4）
3. `status` が `active` / `grace` なら `plan` の行を適用する

| 能力 | `free`（および Free 相当） | `standard` | `pro` |
| --- | --- | --- | --- |
| `singleExportAccess` | `metered` | `unlimited` | `unlimited` |
| `canUsePremiumStamps` | ✕ | ○ | ○ |
| `canUseCustomStamps` | ✕ | ○ | ○ |
| `canUseProBatch` | ✕ | ✕ | ○ |
| `canUseBatchTrial` | ○ | ○ | **✕**（通常一括が使えるため） |
| `shouldShowAds` | ○ | ✕ | ✕ |

`enabledStampPacks` はどの行でも設定定数（10 章）の値をそのまま写す。

**`Plan` を参照してよいのは能力解決の内側だけとする**（クォータ判定・広告頻度・開始ゲート・一括可否・編集可否・UI 活性制御はすべて `ResolvedCapabilities` を見る。`Plan` を渡すと `status = pending` でも `plan != free` が成立し規則を迂回する）。**「確認できない」を型で表す**（`ResolvedCapabilities` を必ず返す関数では `metered` は暗黙降格、`unlimited` は未検証付与になるため `verificationRequired` を独立させる）。

`verificationRequired` の間の挙動。

- **書き出しの認可を開始しない**
- **有料機能を新規に付与しない**
- **Free へ降格したとも表示しない**
- **カスタムスタンプ・履歴・プリセットを削除しない**
- 再試行と購入の復元を提示する

**`verificationRequired` で書き出しを止める範囲は限られる。** この状態へ入るのは、能力をそもそも判定できない場合（`missing` かつオフライン / `temporarilyUnavailable(verified: nil)`）だけであり、オフラインでの初回起動という限られた場面。

##### `missing` を Free として扱ってよい条件

キャッシュの不在だけでは、初回インストールなのか再インストールした有料利用者なのかを区別できない。

| 状況 | 解決結果 |
| --- | --- |
| `missing` かつ RevenueCat への問い合わせが**成功**（購読なし） | `resolved`（Free 相当の能力） |
| `missing` かつ問い合わせが**成功**（購読あり） | `resolved`（該当プランの能力） |
| `missing` かつ**オフライン等で問い合わせ不能** | **`verificationRequired`** |
| `loaded` かつオフライン | `resolved`（キャッシュで維持） |

**キャッシュが無い状態でオフラインなら書き出しを止める**（Free として進めると再インストール直後の有料利用者に無料枠を消費させ、`unlimited` として進めると未検証で有料機能を渡すため、どちらも取れない）。購読の確認は初回起動時に一度行えば済むため、制約はオフラインでの初回起動という限られた場面だけ。

##### 購入状態キャッシュの読み込み失敗

`SubscriptionState` は `app.db` の平文行であり、読み込み結果は 7.2 の分類（`valid` / `missing` / `temporarilyUnavailable`）に従う。

| 結果 | 扱い |
| --- | --- |
| `valid` | このキャッシュで有料機能を維持する |
| `missing` | RevenueCat へ問い合わせる。成功するまでは `verificationRequired` |
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
    /// StampRequirement の定義は [書き出し Saga](export-saga.md) の 1.2
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

**`RenderSpec` を直接受け取らない**（判定に必要なのはスタンプの必要能力だけであり座標や強度は無関係。同じ判定規則〈`premium` は `canUsePremiumStamps`、`custom` は `canUseCustomStamps`、`unknownBuiltIn` は否〉を書き出し認可の `authorizeRenderSpec`〈同 1.3〉と共有し、UI と認可で判定を一致させる。一致は契約テストで固定する）。

判定規則（要求能力の対応は [書き出し Saga](export-saga.md) 1.2 の表、プランごとの能力は 6.2 の能力導出表が正本）。

- `canEdit`: `premium` は `canUsePremiumStamps`、`custom` は `canUseCustomStamps` で判定する。**`unknownBuiltIn` を含む場合は常に否**（どの能力でも解消しない。認可側の `unknownBuiltInStampCode` と同じ安全側）
- `requiredPlan`: `premium` または `custom` を含めば `standard`、いずれも無ければ `free`（スタンプ能力は `standard` と `pro` で同一のため `pro` を要求する組み合わせは存在しない）。`unknownBuiltIn` は課金で解消しないため対象外（Paywall を提示しない。同 1.3）

**`requiredPlan` の戻り値で可否を決めない**（プラン名の比較だと `status = pending` が素通りする）。作成時のプランで判定すると、Standard 時代に作ったプロジェクトが Free で編集できないのに同じ元写真を選び直せば Free の機能で同じものを作れるという説明のつかない差が生まれるため、現在の設定内容で判定する。

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

**新しい `projectID` が付くため、元素材の記録をそのまま共有できない**（`WorkingSourceRecord` は `projectID` ごとの記録であり参照ではなく複製が要る。[画像処理](image-pipeline.md) が正本）。

| 順 | 操作 | 保存先 | 失敗時 |
| --- | --- | --- | --- |
| 1 | 新しい `ProjectID` を発行する | — | — |
| 2 | 元素材の実体がある場合、**存在確認を通したうえでコピー元として取得し**（[画像処理](image-pipeline.md)）、新しい `projectID` を指す `WorkingSourceRecord` を作る | ファイルシステム / DB | 手順 3 へ |
| 3 | DB トランザクションで `Project` と設定を複製し、有料スタンプの領域を選択された方式へ置換する | DB | 手順 4 へ |
| 4 | 手順 3 が失敗したら、作成済みの `WorkingSourceRecord` と実体を補償削除する | DB / ファイルシステム | 起動時 GC へ委ねる |

**処理用ファイルを共有しない**（同じ実体を 2 つの `Project` が指すと一方の書き出し完了/破棄が他方の素材を削除する）。**元素材の実体が無い場合は `WorkingSourceRecord` を作らずに複製する**（利用者の再選択時に通常の再接続〈[画像処理](image-pipeline.md)〉が走る）。**`ExportedSettingsEntry` は複製しない**（複製先はまだ書き出しておらず「変更せず再書き出し」の対象にならない）。この Saga も `SourceImportCoordinator` が所有する。

バッチ**全体**に対する操作は内容によらず能力で決まる。

| 操作 | 必要な能力 |
| --- | --- |
| 加工済み写真（履歴グリッド）の閲覧 | なし |
| バッチ全体への設定反映 / 再実行 / エラー写真のみの再試行 | `canUseProBatch` |

原則は 4 つです。

- **閲覧と削除は常に可能**とする
- **既存の作品をそのまま取り出す権利は残す**
- **有料機能の新規利用にのみ契約が必要**とする
- **データそのものは削除しない**（仕様 12.6）。再契約時にカスタムスタンプと一括設定プリセットをそのまま再利用できる

**「変更せず再書き出し」はアプリ提供の追加スタンプとカスタムスタンプを同一に扱う**（規則を分けると「どちらのスタンプを使ったか」で挙動が変わり説明できなくなる）。有料スタンプを含むプロジェクトでは、エフェクト・強度・領域・出力設定のいずれかを変更した時点で Standard 以上が必要になる（Free 範囲のプロジェクトではこの判定を行わない）。

##### 比較対象を台帳へ持つ

**現在の設定ハッシュと比べる対象「最後に正常書き出しした設定」は、独立テーブル `ExportedSettingsEntry`（6.3）へ持たせる**（完了操作と同じトランザクション境界で更新するため）。**台帳への反映は完了操作（単一トランザクション）で直接行う**（確定前の値を根拠にしてしまう経路が無い。ADR 0005、ADR 0006）。

| 契機 | 操作 |
| --- | --- |
| 完了操作の確定 | **`ExportedSettingsEntry` へ直接書き込む**（[書き出し Saga](export-saga.md)が正本） |
| `Project` の削除 | **`Project` 削除 Saga**（DB 確定後）で削除する（7.5） |

**免除条件（確定記録の存在・設定の一致・対象・適用範囲）の正本は [書き出し Saga](export-saga.md)。** 免除の対象は**降格後の有料スタンプ能力要件のみであり、月間枠は免除しない**（クォータは別途評価する。6.3）。ADR 0006 により、素材の同一性は判定条件に含めない（対象は「同一 `Project`」であることのみ）。要素数は `Project` 数と同じく有界であり、`Project` が消えた entry は削除 Saga が回収する。**降格の事実自体はクォータ判定に影響しない。**

##### 広告表示頻度

仕様 15.3 / 15.4 を純粋関数として実装する。

- 検出中、顔選択中、編集中、書き出し中、書き出しエラー対応中、課金処理中は表示しない
- 初回書き出し完了時には全画面広告を表示しない
- 全画面広告は最大でも 2〜3 回の書き出しにつき 1 回
- 同一セッションで連続表示しない
- 広告取得失敗でアプリ処理を止めない

### 6.3 クォータとトライアル

##### 台帳は 1 つ

**通常クォータとトライアル消費を、1 つの `app.db` テーブル行として原子的に置き換える**（ADR 0005）。**勘定の単位は「受け渡した成果物」であり、素材の同一性は使わない**（ADR 0006）。

```swift
struct YearMonth: Sendable, Hashable, Comparable {
    let year: Int32
    let month: Int32        // 1...12。端末の TimeZone で算出する
}

struct UsageLedger: Sendable, Equatable {
    let period: YearMonth                          // 消費を計上している年月
    let consumedExportIDs: Set<ExportID>            // 月間枠の消費（6.5）
    let trialConsumedExportIDs: Set<ExportID>       // トライアルクレジットの消費
}

extension UsageLedger {
    var consumed: Int { consumedExportIDs.count }
    var trialConsumed: Int { trialConsumedExportIDs.count }
}

/// 正常書き出しで確定した設定。「変更せず再書き出し」の比較対象（6.2）。
/// UsageLedger のフィールドではなく独立テーブル（projectID ごとに 1 行。外部キーは 7.1）で、
/// 完了操作の単一トランザクションで upsert する
struct ExportedSettingsEntry: Sendable, Equatable {
    let projectID: ProjectID
    let settingsHash: ProjectSettingsHash
    let exportedAt: Date
}
```

**消費は件数ではなく書き出し ID の集合で持つ**（`Int` では同一 `exportID` の再適用の拒否も特定書き出しの消費取消も実装できない）。各集合の要素数には上限があるため線形探索で構わない。

| 集合 | 一意条件 | 上限 |
| --- | --- | --- |
| `ExportedSettingsEntry` | `projectID` ごとに 1 件 | 履歴の保存期間内の `Project` 数 |
| `consumedExportIDs` | — | 月間上限（既定 5） |
| `trialConsumedExportIDs` | — | トライアルクレジット数（既定 5。[運用](operations.md) の 2.1） |

##### 判定

**消費は生成時ではなく、完了操作の単一トランザクションで行う**（ADR 0006）。生成（書き出し）は出力ファイルと確認用の `OutputRecord` を作るだけで、枠・クレジットは一切消費しない。認可時に評価するのは「消費できるか」だけであり、この関数自体は台帳を更新しない。

```swift
enum MonthlyQuotaDecision: Sendable, Equatable {
    case unlimited        // Standard / Pro
    case consumable        // Free。残り枠がある
    case blocked(limit: Int)
}

func evaluateMonthlyQuota(
    ledger: UsageLedger,
    access: SingleExportAccess,      // Plan ではない。6.2 が解決した能力
    monthlyLimit: Int,               // 設定定数の freeMonthlyExportLimit（10 章）
    usageNow: Date,                  // 端末の現在時刻
    deviceTimeZone: TimeZone
) -> MonthlyQuotaDecision
```

判定順序。

1. `access == .unlimited` なら `unlimited`
2. 端末の現在の年月が `ledger.period` と異なれば、消費数を 0 とみなして判定する（実際の period 更新と消費の計上は完了操作でまとめて行う。下記）
3. （1.の消費数、または `ledger.consumed`）が `monthlyLimit` 未満なら `consumable`
4. それ以外は `blocked(limit: monthlyLimit)`

**`monthlyLimit` を引数で受け取る**（上限は設定定数で変わるため `Domain` の定数にできない。10 章）。**実際に採用する会計モード（`ExportAccountingMode`）の組み立ては [書き出し Saga](export-saga.md) が正本。** ここで定義するのは月間枠だけを見る `Domain` の純粋関数に限る。

##### 時間の扱い

**すべての時間判定は端末の現在時刻・現在タイムゾーンをそのまま使う**（ADR 0005）。端末時計を操作すれば月間枠を前倒しで得られることを受容する（ADR 0005 Consequences）。

```swift
func rollPeriod(_ ledger: UsageLedger, now: Date, deviceTimeZone: TimeZone) -> UsageLedger {
    let current = YearMonth(from: now, in: deviceTimeZone)
    if current != ledger.period {
        return ledger.with(period: current, consumedExportIDs: [])
    } else {
        return ledger
    }
}
```

**月初にリセットするのは `consumedExportIDs` だけ**（`trialConsumedExportIDs` は月をまたいで保持する。トライアルクレジットに月次の期限は無い）。**`period` は端末の現在の年月と一致しない場合、前進・後退を問わず切り替える**（`current != ledger.period`。ADR 0006）。実際の切り替えと消費の計上は完了操作の単一トランザクションで行う。

##### 一括処理トライアル

Free および Standard の利用者が Pro の中核である一括処理を一度も試さずに判断することを避けるため、**一括処理でのみ使える 5 枚分のクレジット**を付与する。**月間の無料枠とは別勘定とする**（月間枠から引くと一括処理を試しただけでその月の枠を使い切ってしまう。端末内処理のため限界原価はない）。

**回数制ではなくクレジット制とする。**

- **確定した成果物ごとに 1 クレジットを消費する**（素材の同一性は問わない。ADR 0006）。消費は完了操作（単一トランザクション）で行う
- 使い切るまで有効
- Pro へ加入済みの場合は消費しない

**完了前のやり直しは、まだ何も消費していないため免除・返還という概念自体が存在しない**（ADR 0006）。出力ファイルと確認用の `OutputRecord` を削除するだけで、回数の制限は無い。

**残クレジット数は保存せず、台帳から導出する。**

```swift
// policy は BatchPolicySnapshot（6.4）。DB から読んだ直後に hard max へクランプ済み
let remainingCredits = max(0, policy.trialCreditCount - usageLedger.trialConsumedExportIDs.count)
```

**クランプ後の値を使う**（`BatchPolicySnapshot` は `app.db` の平文行であり、読み出し直後に hard max〈5〉と最小値〈0〉へ丸める。6.4）。残数と台帳の両方を保存すると異常終了時に不整合な状態が生じるため導出とし、正を 1 つにする。

**トライアルクレジットに期限は設けない**（使い切るまで有効。端末内処理のため繰り返しても限界原価が発生せず、期限を設けるとその境界の説明が要り試用導線として複雑になる）。**トライアルで解放するのは「一括処理という操作方式」だけ**（エフェクト・スタンプの利用範囲は `ResolvedCapabilities` をそのまま参照し、一括処理へ入ったことで能力を書き換えない。追加スタンプまで一時解放すると Standard の価値が曖昧になる）。

**台帳は `app.db` の平文行であり、利用者が直接書き換えれば無料枠・トライアルを回復できることを受容する**（ADR 0005 Consequences。狙われる規模ではなく、被害上限は無料書き出し数枚）。DB 読み込み自体が失敗した場合の扱いは 7.2 の分類に従う。

### 6.4 バッチ処理

**一括処理の制限なし利用は `canUseProBatch` が必要。** `canUseBatchTrial` だけを持つ利用者は、残クレジットの範囲で一括処理を実行できる。

```swift
func canEnterBatch(capabilities: ResolvedCapabilities, remainingCredits: Int) -> Bool {
    capabilities.canUseProBatch ||
    (capabilities.canUseBatchTrial && remainingCredits > 0)
}
```

**残クレジットが 0 になれば一括処理画面を閉じる**（勘定の単位は「受け渡した成果物」であり素材の同一性を問わないため、消費済みの写真を無料で再処理できる経路は無い。ADR 0006）。**判定に `Plan` を使わない**（料金表や説明文でのプラン名使用は構わないが、実装上の条件式はすべて能力で書く）。

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
| **トライアルの選択枚数** | 残クレジット数 |

| 分類 | 発火条件 | 誘導 |
| --- | --- | --- |
| `batch-credit` | Free / Standard が、**残クレジットを超える枚数**を選ぼうとした | Pro |
| `batch-size` | Free / Standard が**総数 5 枚**を超えて選ぼうとした | Pro |
| `batch-limit` | Pro が**総数 50 枚**を超えて選ぼうとした | 誘導なし。上限の通知のみ |

**「新しい写真かどうか」の判定は存在しない**（ADR 0006。素材の同一性は問わない）。`batch-size` と `batch-limit` を分けるのは、前者がアップグレードで解消できる制限、後者が仕様上の上限のため。`batch-credit` は `batch-size` と独立した条件であり、残クレジットが総枚数上限（5 枚）より少ない場合に `batch-size` より先に発火する。

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
    let errorCode: AppErrorCode      // 9.1 の列挙
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

**処理用ファイルが失われた場合も新しい状態を作らず `paused(.sourceReselectionRequired)` へ遷移させる**（`paused` は「利用者操作を待って再開できる」の意で再選択要求もこれに当てはまる。バッチ全体ではなく該当項目だけが `paused` になる）。**`WorkingSourceRecord` の削除と対象キュー項目の `paused(.sourceReselectionRequired)` への更新は単一 DB トランザクションで原子的に行う**（欠損したファイル参照の `PendingFileDeletion` への登録も同じトランザクション。正本は [画像処理](image-pipeline.md) の `WorkingSourceStore.invalidateWorkingSource`）。**`isTerminal` を各所で書き下さない**（履歴削除可否判定〈7.5〉・バッチ完了判定・復旧対象選定がすべてこの 1 述語を使う。書き下すと状態追加時に一部だけ更新される事故が起こる）。

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

**実行中のバッチは開始時点の設定定数（10 章）のスナップショットで動く**（アプリ更新をまたいで再開しても枚数上限や並列数が変わらない）。

```swift
struct BatchPolicySnapshot: Sendable, Equatable {
    let kind: BatchKind            // クランプ先を決める（下記）
    let batchSizeLimit: Int32
    let trialCreditCount: Int32
    let concurrencyLimit: Int32
}

/// このバッチが Pro の通常一括かトライアルか。作成時に確定する。
/// raw value は DB 列値（スキーマ移行をまたぐため固定。下記）
enum BatchKind: UInt32, Sendable, Hashable {
    case proBatch = 1  // canUseProBatch による通常の一括処理
    case trial = 2     // クレジット消費による一括トライアル
}
```

`Batch` の行が保持し再起動後も同じ値を使う（読み直して適用すると復元したバッチの上限が実行中に変わってしまう）。

**列値を固定する**（値は上記コードブロックの raw value が正本。`Batch` の DB 列としてスキーマ移行をまたぐため、`case` 宣言順に依存させると版によって `trial` のバッチが `proBatch` として上限 50 でクランプされうる。`OutputState` と同じ規則。7.5）。新しいバッチの作成時は、その時点の設定定数（10 章）から作る。

##### 読み出しのたびに hard max へクランプする

**`BatchPolicySnapshot` は `app.db` の平文行であり、`trialCreditCount` を 5→500 へ書き換えれば一括処理を任意枚数の新規写真に無制限に使えてしまう**（クランプは改ざん対抗ではなく実装ミス対策として持つ。DB 行の直接書き換えそのものは ADR 0005 が受容する範囲であり、被害上限は無料書き出し数枚のまま変わらない）。

| フィールド | クランプ先（[運用](operations.md) の 2.1） |
| --- | --- |
| `batchSizeLimit`（`kind == .proBatch`） | `proBatchSizeLimit` の hard max **50** / 最小 1 |
| `batchSizeLimit`（`kind == .trial`） | `trialBatchSizeLimit` の hard max **5** / 最小 1 |
| `trialCreditCount` | hard max **5** / 最小 0 |
| `concurrencyLimit` | `batchConcurrencyLimit` の hard max **1**（v1）/ 最小 1 |
| `kind` | **クランプの対象外**（記録用の値であり上限を持たない） |

| 規則 | 内容 |
| --- | --- |
| 読み出し | **`app.db` から読んだ直後にクランプする** |
| クランプの向き | **hard max を超える値は hard max へ、最小値を下回る値は最小値へ** |
| 適用箇所 | `remainingCredits` の導出、`canEnterBatch`、選択枚数条件、キューの並列数のすべて |
| `kind` の改変 | **`.trial` → `.proBatch` の書き換えは `batchSizeLimit` の上限を 5 → 50 へ緩めるが、選択枚数は `remainingCredits`（≤5）に縛られる**（下記） |

**`kind` を持たせるのは `batchSizeLimit` のクランプ先が 2 つあるため**（`BatchPolicySnapshot` だけでは Pro の 50 とトライアルの 5 のどちらへ丸めるか決まらない）。**`kind` の改変では処理できる枚数は増えない**（トライアルの消費は `trialConsumedExportIDs`〈上限 5。6.3〉が独立して縛るため、`batchSizeLimit` を緩めても選択枚数の実質的な上限は変わらない）。**下限もクランプする**（`batchSizeLimit` を 0 にして「上限 0 だから何枚でも通る」という実装ミスを誘発させないため）。

その他の規則は仕様 16.5 / 16.7 / 16.8 に従う。

- 1 バッチ最大 50 枚
- 同時並列処理は **v1 では 1 固定**（初期値・hard max とも 1）。2 へ引き上げる場合は開始順序と勘定の再設計が要る（v2 検討時）
- 一枚の失敗でバッチ全体を停止しない
- **アプリ再起動後に未完了キューを復元する**（[画像処理](image-pipeline.md) の `WorkingSourceRecord`）
- 元素材へのアクセス権限を失った場合は再選択を求める
- バックグラウンド処理は OS の実行制限に従う。`BGProcessingTask` は使わず、フォアグラウンド継続を前提とする

**バッチの写真集合は実行開始時に固定する**（追加分の検出開始時期・進行中確認との関係・一括設定の適用範囲・50 枚超過時の分割など論点が増える割に利用者価値が低い）。

##### 一括設定と個別修正の優先順位

1. **一括設定は各写真の初期値として適用する**
2. 個別に編集された写真には `hasOverride` を記録する
3. **共通設定を変更しても、`hasOverride` が立った写真は変更しない**
4. 全件を上書きしたい場合のみ、対象件数を提示した確認を経て実行する

`hasOverride` は写真単位のフラグとし `Domain` が管理する。

##### 対応しないこと

顔認識を行わない以上、**複数写真を横断した同一人物の判定はできない**（仕様 16.4）。「全写真で家族だけ残し他人だけ隠す」は実現できず、説明文でこれを誤解させないことを制約とする。

### 6.5 ドメイン識別子

**識別子を `String` と `UUID` で混在させない**（2 つの型で表現されると DB の結合もハッシュ算出時の正準化も一意に決まらない）。

```swift
// Domain — すべて Foundation のみ
struct ProjectID:   Sendable, Hashable { let rawValue: UUID }
struct BatchID:     Sendable, Hashable { let rawValue: UUID }
struct ExportID:    Sendable, Hashable { let rawValue: UUID }
struct RegionID:    Sendable, Hashable { let rawValue: UUID }
struct FaceTrackID: Sendable, Hashable { let rawValue: UUID }
struct CustomStampID: Sendable, Hashable { let rawValue: UUID }   // CustomStamp（一覧の項目）の識別子。7.5

/// 認可用。出力へ影響する全設定の正準ハッシュ（正準スキーマ 5.2）
struct ProjectSettingsHash: Sendable, Hashable { let bytes: Data }   // 32 バイト

/// プレビュー確認用。見た目に影響する値だけ（正準スキーマ 5.2）
struct PreviewRenderHash: Sendable, Hashable { let bytes: Data }     // 32 バイト

struct StampAssetHash: Sendable, Hashable { let bytes: Data }        // 32 バイト（正準スキーマ 5.3）
```

**`FaceTrackID` も `UUID`**（自動検出は `observation.uuid` をそのまま使い手動領域はアプリが採番するため、文字列だと 2 つの出所で表現が揺れる）。

| 理由 | 内容 |
| --- | --- |
| 誤った受け渡しの防止 | `exportID` を期待する引数へ `projectID` を渡せない。**コンパイルで止まる** |
| DB 結合の一意性 | 外部キーと結合の対象が型で決まる（7.1） |
| 正準化の一意性 | ハッシュ算出対象の各 ID を「`UUID` の 16 バイト」として符号化できる（[正準スキーマ](canonical-schema.md) §2） |
| ログ禁止の強制 | 分析イベントのフィールド型にしないことで、送信経路へ入れられない（9.1） |

いずれの型も `CustomStringConvertible` に適合させない（文字列補間で自動的にログや診断へ流れる経路を作らないため）。

### 6.6 アプリ更新の判定

起動時に新しいバージョンがあれば App Store へ誘導する。**判定は純粋関数に閉じる**（提示条件・審査への配慮は [運用](operations.md) が正本）。**更新誘導は常に任意の推奨とする**（ADR 0005）。

```swift
/// メジャー・マイナー・パッチの数値の組で比較する（文字列比較はしない）
struct AppVersion: Sendable, Hashable, Comparable {
    let major: Int32
    let minor: Int32
    let patch: Int32

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

enum UpdateDecision: Sendable, Equatable {
    case none
    case recommended(AppVersion)   // 任意。スキップできる
}

func evaluateUpdate(
    current: AppVersion,
    latestOnStore: AppVersion?,     // iTunes Lookup API から取得。失敗時は nil
    skippedVersion: AppVersion?,    // 利用者が「後で」を選んだバージョン
    lastPromptedAt: Date?,
    usageNow: Date
) -> UpdateDecision
```

1. `latestOnStore == nil` または `current >= latestOnStore` なら **`.none`**
2. `skippedVersion == latestOnStore` なら `.none`
3. `usageNow - lastPromptedAt < 24h` なら `.none`（1 日 1 回まで）
4. それ以外は **`.recommended`**

**取得元は iTunes Lookup API**（`https://itunes.apple.com/lookup?id=...`）。**取得失敗時は `.none`**（App Store 側の一時障害を誘導表示の抑制側へ倒す）。**文字列比較は使わない**（`"1.10.0" < "1.9.0"` が文字列としては真になり新しいバージョンを古いと判定する）。

判定は起動時復旧の完了後に行う（[書き出し Saga](export-saga.md) が正本）。`skippedVersion` と `lastPromptedAt` は `UserDefaults` に置く。

---

## 7. 永続化

### 7.1 app.db

GRDB（SQLite）を使います。採用理由は [ADR 0002](adr/0002-grdb-and-single-database.md) にあります。

**アプリのリレーショナルデータを 1 つの `app.db` へ収めます。**

| テーブル | 備考 |
| --- | --- |
| `Project` | 仕様 19.1。`projectRevision`（下記）、`detectionRevision`、`detectionPixelSize`、再編集用の `ProjectSourceLocator` を持つ（[画像処理](image-pipeline.md)）。**ここにのみ平文の `localIdentifier` が存在する**。素材の撮影日時・取得経路（`OriginalCaptureMetadata` / `SourceRepresentation` / `libraryCreationDate`。7.5）も直接持つ |
| `FaceTrack` | 仕様 19.2。手動領域は `createdManually = true`。**検出品質の列（`confidence` / `yawDegrees` / `pitchDegrees` / `rollDegrees` / `isSmallFace`）も持つ**（6.1 の再導出に要る） |
| `EffectSetting` | 仕様 19.4 |
| `ExportSetting` | 仕様 19.5 |
| `CustomStamp` | 仕様 19.6。スタンプ一覧の項目（7.5） |
| `StampAsset` | プロジェクトが参照する不変の画像実体のメタデータ。内容ハッシュを主キーとする（7.5） |
| `ProjectStampAsset` | プロジェクトと `StampAsset` の対応（7.5） |
| `ExportRecord` | 仕様 19.7。`batchID` を追加 |
| `Batch` | バッチ単位の履歴。`BatchPolicySnapshot` を持つ（6.4） |
| `BatchPreset` | 一括設定プリセット |
| `DeliveryAttempt` | 写真ライブラリ保存の試行中を表す。`previousState` を持つ（[書き出し Saga](export-saga.md) が正本） |
| `UnknownLibrarySave` | 保存結果が不明のまま `delivered` を維持したことの記録 |
| `ExportJob` | 書き出しの進行中を表す（状態列を持たず、行の存在そのものが進行中を示す。完了操作または破棄で削除する。[書き出し Saga](export-saga.md) が正本）。`settingsHash` 列（startExport 時点の `ProjectSettingsHash`。settle で `ExportedSettingsEntry` へコピーする Persistence 内部列）を持つ |
| `OutputRecord` | 写真ごとの出力状態。`exportID` で書き出しと対応づける |
| `ExportedSettingsEntry` | 「変更せず再書き出し」免除の確定記録（6.3）。`projectID` ごとに 1 件 |
| `ExportQueueItem` | 一括処理のキュー状態（6.4） |
| `WorkingSourceRecord` | 処理用にアプリ領域へ複製した元素材（[画像処理](image-pipeline.md)） |
| `PendingFileDeletion` | 参照 0 になった実体の削除候補（7.5） |
| **`UsageLedger`** | **クォータ・トライアル台帳（6.3）。平文行（ADR 0005）** |
| **`SubscriptionState`** | **購入状態キャッシュ（6.2）。平文行（ADR 0005）** |

**`app.db` 全体がバックアップ対象外**（7.4）。復元してはいけない理由（DB を分けても解消しない）:

- `ExportJob` を別端末へ復元しても対応する一時ファイルは存在せず、`UsageLedger`（同じくバックアップ対象外）との整合も失われる
- 写真ライブラリ参照（`ProjectSourceLocator`）は別端末で意味を持たず、履歴を復元しても再編集できない

##### DB を分けない

**実行時状態と利用者データを 1 つの `app.db` へ置く**（判断の経緯は [ADR 0002](adr/0002-grdb-and-single-database.md)）。設計上の帰結は 3 つ。

| 帰結 | 内容 |
| --- | --- |
| **実の外部キー制約** | `OutputRecord.projectID` → `Project`、`ExportQueueItem.batchID` → `Batch` を SQLite が強制する。アプリ側の起動時検査が不要になる |
| 単一トランザクション | [書き出し Saga](export-saga.md) の確定処理が `ATTACH` なしで成立する |
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
| `ExportJob.exportID` | **PRIMARY KEY** |
| `OutputRecord.exportID` | **PRIMARY KEY** |
| `OutputRecord.projectID` | **部分 UNIQUE**（`settledAt IS NULL` の行のみ。未確定の出力は 1 プロジェクトにつき 1 件。7.5） |
| `WorkingSourceRecord.projectID` | **PRIMARY KEY** |
| `PendingFileDeletion(kind, fileID)` | **UNIQUE** |
| `ProjectStampAsset(projectID, assetHash)` | **UNIQUE** |
| `StampAsset.contentHash` | **PRIMARY KEY** |
| `CustomStamp.customStampID` | **PRIMARY KEY** |
| `ExportQueueItem(batchID, projectID)` | **UNIQUE** |
| `DeliveryAttempt.exportID` | **PRIMARY KEY** |
| `UnknownLibrarySave.exportID` | **PRIMARY KEY** |
| `ExportedSettingsEntry.projectID` | **PRIMARY KEY**（免除の確定記録は projectID ごとに 1 件。6.3） |
| `UsageLedger` / `SubscriptionState` | **単一行キー**（`id INTEGER PRIMARY KEY CHECK(id = 1)` 相当。「台帳は 1 つ」「キャッシュは 1 つ」を DB 制約で固定する） |

外部キーは `PRAGMA foreign_keys = ON` で有効化し、次を宣言します。

| 子 | 親 | 削除時 |
| --- | --- | --- |
| `OutputRecord.projectID` | `Project` | **RESTRICT**（未受け渡し出力があるプロジェクトを消さない。7.5） |
| `OutputRecord.batchID` | `Batch` | SET NULL |
| `ExportJob.projectID` | `Project` | **RESTRICT** |
| `ExportJob.batchID` | `Batch` | SET NULL |
| `WorkingSourceRecord.projectID` | `Project` | CASCADE |
| `FaceTrack.projectID` | `Project` | CASCADE |
| `EffectSetting.projectID` | `Project` | CASCADE |
| `EffectSetting.faceTrackID` | `FaceTrack` | CASCADE |
| `ExportSetting.projectID` | `Project` | CASCADE |
| `ExportQueueItem.projectID` | `Project` | CASCADE |
| `ExportQueueItem.batchID` | `Batch` | CASCADE |
| `ExportRecord.projectID` | `Project` | CASCADE |
| `ExportedSettingsEntry.projectID` | `Project` | CASCADE |
| `ExportRecord.batchID` | `Batch` | SET NULL |
| `ProjectStampAsset.projectID` | `Project` | CASCADE |
| `ProjectStampAsset.assetHash` | `StampAsset` | RESTRICT |
| `CustomStamp.assetHash` | `StampAsset` | RESTRICT |
| `UnknownLibrarySave.exportID` | `OutputRecord` | CASCADE |
| `DeliveryAttempt.exportID` | `OutputRecord` | CASCADE |

**`batchID` を `SET NULL` にするのは `Batch` の記録を消しても出力と書き出し記録を残すため**（バッチは処理の単位であり個々の出力の存在条件ではない。閲覧・削除の単位は `Project` のみ。7.5）。宣言していない参照は `PRAGMA foreign_key_check` で検出できないため、上の表が外部キーの全体であり新しい参照は必ずこの表へ加える。**`RESTRICT` は削除可否の判定（7.5）を DB 側でも二重に担保する**（アプリ側判定を通り抜けた削除は制約違反として失敗する）。**「未確定の出力は 1 プロジェクトにつき 1 件」は `OutputRecord.projectID` の部分 UNIQUE インデックス（`WHERE settledAt IS NULL`）で表現できる**（SQLite の部分インデックスを使う。開始ゲートを別途持たない）。中断・失敗は `ExportJob` 行を削除して終わるため再試行という概念は無く、次の開始は常に新しい `exportID` を発行する（[書き出し Saga](export-saga.md) が正本）。

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

**SQLite の標準設定（`synchronous = EXTRA`）にそのまま任せる。** 個別の耐久性保証や電源断対策は追加しない。整合の回復は起動時復旧が担う（未確定の `ExportJob` / `OutputRecord` の削除と孤児ファイルの GC。[書き出し Saga](export-saga.md) が正本）。会計は完了操作でしか確定しないため、それより前に中断した書き出しは会計への影響なくやり直せる。

### 7.2 台帳・購入状態の保存

**`UsageLedger`（6.3）と `SubscriptionState`（6.2）は `app.db` の平文テーブルとして保存する**（ADR 0005）。書き込みは他の `app.db` 更新と同じ DB トランザクションで行える。

##### 読み込み結果の分類

| 結果 | 扱い |
| --- | --- |
| 行が存在する | そのまま使う |
| 行が存在しない | 新規状態として扱う（`UsageLedger` は空の台帳を作る。`SubscriptionState` は `missing` として 6.2 の解決へ委ねる） |
| DB が開けない・クエリが失敗する | 他の `app.db` テーブルと同じくアプリ全体の障害として扱う |

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

**`ManagedFileStore` は `ManagedFileRef` だけを受け取り呼び出し元へパスを返さない**（パス解決は `kind` からディレクトリを決め `fileID` を連結する形に閉じ、削除・属性設定・孤児 GC・バックアップ判定のすべてが同じ型で処理できる）。**`kind` を含めるのは ID だけでは削除先を識別できないため**（`PendingFileDeletion` は出力・履歴サムネイル・`StampAsset` すべてに使われ、同じ ID が別ディレクトリに存在すれば誤ったファイルを削除する）。**`fileID` を `String` にしない**（`String` では `"../"` 等も型として作れ、DB 改変や外部由来文字列でパス連結結果が専用ディレクトリを脱出しうる。`UUID` を内部表現にすれば `/` も `.` も含まない値しか存在せず構造的に脱出できない。これが唯一の防御であり、実行時の経路検査は追加しない）。

| 経路 | 規約 |
| --- | --- |
| 生成 | `ManagedFileStore` が採番する。呼び出し元は値を作らない |
| DB への保存 | `UUID` として保存する（文字列カラムでも `UUID` としてデコードする） |
| デコード失敗 | **その行を不正として扱う。** 文字列へフォールバックしない |

##### 保存の順序

**属性の設定を rename の後だけに置けない**（書き込み中や rename 前に終了すると一時ファイルが無保護のまま残る。未加工の顔画像や未受け渡し出力を扱う以上、完成ファイルだけの保護では足りない）。

| 順 | 操作 |
| --- | --- |
| 1 | **最終ファイルと同じディレクトリ内に**一時ファイルを作る |
| 2 | **書き込み前に** `isExcludedFromBackup` と `FileProtectionType` を設定し、読み返して確認する |
| 3 | データを書く |
| 4 | atomic rename / `replaceItemAt` で最終 URL へ移す |
| 5 | **最終 URL へ属性を再設定する** |
| 6 | 属性を**読み返して検証する** |
| 7 | 失敗したら `ManagedFileRef` を返さず、即時削除するか孤児 GC の対象にする |

**手順 1 で同じディレクトリを使うのはディレクトリの既定保護クラスを最初から効かせるため**（別ディレクトリで作ってから移すとその間だけ保護レベルが下がる）。**手順 2 と 5 の両方で設定する**（`replaceItemAt` は置換先の属性を引き継ぐとは限らないため rename 後の再設定が要り、rename 前の設定は中断時保護のために要る。どちらも省けない）。**手順 6 の読み返しも省かない**（設定が反映されなければ次回起動まで気づけない）。

対象は処理中の一時ファイル・未受け渡し出力・ラスタスタンプ一時ファイル・カスタムスタンプ実体・履歴サムネイルすべて（**個別に `FileManager` を呼ぶ実装は許さない**）。SQLite のファイル群は GRDB が生成するため `ManagedFileStore` を通せず、ディレクトリの既定保護クラスで覆い起動時に DB ファイルの属性を検証する。

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
Library/Caches/stamp-thumbnails/
tmp/raster/
```

**処理中ファイルを `tmp/` に置かない**（OS がいつでも削除でき再起動のたびにキュー復元が失敗する。[画像処理](image-pipeline.md)）。`raster/` は `tmp/` のまま（1 回の `render` 呼び出し内でのみ有効で消えて困る状況が無い）。

##### バックアップ

**アプリが所有する DB・画像を対象外とする**（ADR 0003。下表が対象の全体であり `UserDefaults` や第三者 SDK の保存領域は含まない。それらに保護すべきデータを置かないことは 9.1 で担保する）。

| パス | 根拠 |
| --- | --- |
| `db/`（`app.db` と journal） | 復元しても整合しない（7.1） |
| `working/` | 処理中の元素材。復元しても意味がない |
| `tmp/raster/` | `render` 呼び出し内でのみ有効 |
| `Library/Caches/stamp-thumbnails/` | 実体から再生成できるキャッシュ |
| `outputs/` | 24 時間で消えるもの。復元しても期限切れ |
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

**アプリ全体の既定を `.complete` にする**（設定漏れが「保護が弱い」方向へ倒れないため。rollback journal と一時 DB ファイルは自動生成されるためディレクトリの既定保護クラスで覆う）。**DB を下げる理由はない**（起動時復旧はまず「保護データが利用可能になるまで待つ」、その後に DB を開く。[書き出し Saga](export-saga.md) の起動時復旧。v1 は `BGProcessingTask` を使わずフォアグラウンド継続前提のためロック中に DB を開く必要が無い）。`app.db` には写真ライブラリの平文 `localIdentifier`・顔領域・編集内容が入り、これらを `.completeUntilFirstUserAuthentication` に置く理由は実行モデル上残っていない。**ロック中の復旧を要件にする場合は、起動時復旧より前に DB を開く別設計が必要**（両立不可。実行時状態のみ別 DB へ切り出す案もあるが v1 では採らない）。

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

**`waitUntilAvailable()` は `async throws`**（キャンセル時に単に戻ると呼び出し側が「利用可能になった」と誤認し `.complete` のファイルを読みにいくため、`withTaskCancellationHandler` でキャンセルを受け `CancellationError` を throw する。正常に戻ったことが `available` の保証になる）。`willBecomeUnavailable` を購読するのは `.complete` のファイル読み書き中にロックへ入る場合があるため（書き出しの途中でこれを受けた場合は次のジャーナル保存点まで進めてから停止し `waitUntilAvailable()` で再開する。処理途中でエラーにしてロールバックしない）。

### 7.5 履歴・出力・スタンプの寿命

##### 履歴とプライバシー

プライバシー保護を目的とするアプリが内部に未加工の顔画像を蓄積することは避ける。

- **履歴のサムネイルには加工後の画像のみを使用する**（隠す前の顔が一覧に並ばないように）
- **アプリ専用領域へ元画像の完全コピーを永続保存しない**（保持するのは写真ライブラリへの参照と編集設定のみ。処理用コピーは書き出し完了後に削除する）

元素材が削除・権限喪失した場合、過去の設定情報は表示できるが再編集はできない（仕様 18.3）。**再編集には素材の再接続が要る**（処理用ファイルは 24 時間で消えるため履歴から開いた `Project` はほぼ常に素材を持たず、利用者が写真を選び直すことで再接続する。再接続の判定は [画像処理](image-pipeline.md) の `WorkingSourceRecord` が正本であり、勘定には使わない。ADR 0006）。

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

例外は 4 つです。

- **未受け渡しの出力ファイル。** 利用者がまだ受け取っていない成果物であり、履歴とは性質が異なる。保存・共有・破棄のいずれかで解消する
- **保存結果不明の注記（`UnknownLibrarySave`）が付いた `delivered` 出力。** 利用者の確認・再試行・破棄、または 24 時間で解消する（下記）
- **`UsageLedger` の消費記録（月間枠・トライアルクレジット）。** 無料枠・トライアルクレジットの判定に必要な最小限であり、画像の内容を復元できる情報を含まない
- **未完了の `ExportJob` と、それが参照する検証済み出力ファイル。** 中断した処理の後始末であり、履歴ではない

##### やり直しのための保持保証

**履歴を保存する設定では、保存期間の長短にかかわらず直近の作業を 24 時間保持する。**

| 処理 | 保持対象 |
| --- | --- |
| 単体処理 | 直近 1 プロジェクト |
| 一括処理 | 直近 1 バッチと、そのバッチに属する全プロジェクト（最大 50 件） |

一括処理で「直近 1 プロジェクト」だけを保持すると、バッチ内の残り 49 枚が失われ再編集が成立しない。保持の目的は編集のやり直し全般であるため**プランを問わず同一の扱いとする**（期間は `WorkingSourceRecord` の保持期間と一致させる。処理用ファイル自体が 24 時間で消えるため）。

##### 未受け渡し出力の状態

**消費は完了操作（単一トランザクション）で確定するため、生成そのものは何も消費しない**（ADR 0006）。**完了前（`settledAt == nil`）の出力は永続保護しない。** アプリの再起動やフローからの離脱で破棄する（消費していないため損失は操作の手間だけ。起動時復旧が未確定の `OutputRecord` を削除する）。**24 時間の保持規則は完了済みで未受け渡しの出力にのみ適用する。**

```swift
// raw value は DB 列値（スキーマ移行をまたぐため固定。下表）
enum OutputState: UInt32, Sendable, Equatable { case generated = 1, deliveryUnknown = 2, delivered = 3 }

extension OutputRecord {
    /// 受け取れていない可能性がある。判定はすべてこの述語を使う（settledAt != nil が前提）
    var isUndelivered: Bool {
        state == .generated || state == .deliveryUnknown
    }
}
```

| 状態 | 意味 | 保持する期間 |
| --- | --- | --- |
| `generated` | 生成済み。受け渡しは未成功 | `settledAt == nil` の間は保護しない。完了後は明示的に破棄するまで、または 24 時間経過するまで |
| `deliveryUnknown` | 写真ライブラリ保存の結果が不明（[書き出し Saga](export-saga.md)） | 完了済みの出力のみ到達する。同上 |
| `delivered` | 保存または共有が 1 回以上成功した | **完了画面を離れるまで** |

**`OutputRecord` は `settledAt: Date?` を持つ**（生成直後は `nil`。出力確認画面での明示的な完了操作で、消費・`ExportRecord` 作成などと同一トランザクションで確定する。[書き出し Saga](export-saga.md) が正本）。**保存・共有および 24 時間保持の対象は `settledAt != nil` の行に限る**（未確定の出力は受け渡しへ進めない。8 章）。**`OutputRecord.projectID` の一意性は未確定（`settledAt IS NULL`）の行に限る**（部分 UNIQUE。7.1）。

**列値を固定するのは `case` の宣言順に依存させないため**（`OutputState` は署名対象外だが DB 列としてスキーマ移行をまたぐ）。**`delivered` は後退させない**（受け渡しは複数回・任意順序で行え、一度成立した事実を `deliveryUnknown` で打ち消すと共有成功済みの出力が未受け渡しへ戻ってしまう）。**`isUndelivered` を次のすべてで使う**（個別に `state == .generated` と書くと `deliveryUnknown` だけが残った状態で判定を素通りする）。

- 完了画面の離脱確認と未保存件数の集計
- 起動時復旧の案内
- 更新誘導の表示禁止
- 新しい加工の開始禁止
- 24 時間の保持

**保存や共有が 1 回成功しても、その場では削除しない**（何度実行しても追加消費しないため、1 回目でファイルを消すと共有後に写真ライブラリへも保存する操作が成立しなくなる）。**状態は写真ごとの出力レコードに保持し、バッチ単位では持たない**（一括処理は部分成功が起こり、32 枚中 20 枚保存・12 枚容量不足という状態は 1 つの状態では表現できない。バッチの状態は各 `OutputRecord` から集計導出する）。一括保存が部分的に成功した場合、既に `delivered` の写真は再保存せず `isUndelivered` の写真だけを再試行する（`deliveryUnknown` は自動再試行の対象外）。

**完了済みで未受け渡しの出力が 1 枚以上残った状態で完了画面を離れようとした場合、確認を表示する**（判定はその残数で行い文言にも枚数を含める）。**完了前（`settledAt == nil`）の出力は確認なしで破棄する**（何も消費していないため。ADR 0006）。

| 履歴の設定 | 提示する選択肢（完了済み・未受け渡しのみ） |
| --- | --- |
| 保存する | あとで保存 / 破棄 / 戻る。あとで保存は履歴に未保存として残り、24 時間以内は再開できる |
| 保存しない | 破棄 / 戻る |

異常終了後の起動時も、出力ごとの状態で分けます。

| 状態 | 起動時の動作 |
| --- | --- |
| `settledAt == nil`（未確定） | **行と実体ファイルを削除する**（消費していないため復旧の必要がない。ADR 0006） |
| `settledAt != nil` かつ `generated` / `deliveryUnknown` | **復旧案内の対象に含める**（枚数は `isUndelivered` の数。バッチ総枚数ではない） |
| **`delivered` かつ `UnknownLibrarySave` あり** | **削除しない。** 「写真ライブラリへの保存結果が不明」として提示する |
| `delivered`（注記なし） | 一時ファイルを削除し、**復旧案内の対象に含めない** |

`DeliveryAttempt` が残っている出力は、この判定の前に `previousState` に従って解決する（[書き出し Saga](export-saga.md)。`previousState` が `delivered` なら `delivered` を維持し `UnknownLibrarySave` を記録する）。**注記のある `delivered` 出力は削除しない**（削除すると再試行ファイルが消え `OutputRecord` の CASCADE で注記も消え、追加した仕組みが 1 回の起動で無効になる）。**`UnknownLibrarySave` は別テーブル**（`OutputRecord` にフラグを持たせず集約型で結合する）。

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
}

/// 同一 DB トランザクション内で読み取った参照状況
struct DeletionContext: Sendable {
    let trigger: DeletionTrigger
    let isFavorite: Bool
    let isBeingEdited: Bool
    let hasNonTerminalQueueItem: Bool
    let hasUndeliveredOutputRecord: Bool   // isUndelivered のみ（settledAt != nil の出力が対象）。delivered は保護しない
    let hasRunningExportJob: Bool
    let hasWorkingSourceRecord: Bool
}

func canDeleteHistoryUnit(
    _ unit: HistoryUnit,          // Project
    context: DeletionContext
) -> Bool
```

**履歴は写真アプリ型のフラットな写真グリッドであり、閲覧・削除の単位は `Project` のみとする**（バッチのグルーピングは処理の単位としてのみ存在し、閲覧・削除の単位ではない。[商品面の決定](product-decisions.md)）。`Batch` 行自体は利用者が直接削除する対象ではなく、所属する `Project` がすべて削除されたときに自動的に消える（下記「`Project` 削除 Saga」）。

**参照元は 2 種類に分かれます。**

| 分類 | 参照元 | 巻き込んだ場合に起こること |
| --- | --- | --- |
| **絶対保護**（どの契機でも削除しない） | **非終端のキュー項目**（`isTerminal == false`。6.4） | 処理中のバッチが消える |
| 同上 | **`ExportJob` の行**（[書き出し Saga](export-saga.md) の 2 章） | 進行中の書き出しが宙に浮く |
| 同上 | **`isUndelivered` の `OutputRecord`**（`hasUndeliveredOutputRecord`） | 利用者が受け取っていない成果物が消える |
| **利用者が上書きできる** | お気に入り | 利用者が明示的に保護した履歴が消える |
| 同上 | 編集中のプロジェクト | 編集画面が参照先を失う |
| 同上 | `WorkingSourceRecord`（[画像処理](image-pipeline.md)） | 処理用の元素材が消え、キューを復元できない |

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

**判定と削除は同一トランザクション内で行う**（別にすると判定と削除の間に新しい参照が生まれる。外部キーの `RESTRICT`〈7.1〉が二重防御として働く）。写真ライブラリへ保存済みの加工済み画像は削除されない（設定画面と削除確認の両方に明示する）。

##### `Project` 削除 Saga

**`Project` の削除は `ExportedSettingsEntry`（能力免除の記録。6.2）を含めて 1 つの DB トランザクションで行う**（`UsageLedger` も `app.db` の平文テーブルであり、DB とは別の保存先を持たない。ADR 0005）。**`UsageLedger` の消費カウンタ（`consumedExportIDs` / `trialConsumedExportIDs`）は履歴削除で一切変更しない。** 履歴・バッチを削除しても消費は戻らない（`ExportedSettingsEntry` は降格後の有料スタンプ能力免除の記録であり消費の記録ではないため、削除対象が異なる。6.3）。

| 順 | 操作 |
| --- | --- |
| 1 | `canDeleteHistoryUnit` が真であることを確認する |
| 2 | **同一 DB トランザクション**で `Project` と関連行（`ExportRecord` / `OutputRecord` / キュー項目 / `WorkingSourceRecord` / 検出・レビュー結果 / `ProjectStampAsset` / 履歴サムネイル / `ExportedSettingsEntry`）を削除し、実体を `PendingFileDeletion` へ積む |
| 3 | 削除した `Project` が `Batch` に属しており、そのトランザクション内で数えた **残り所属 `Project` 数が 0** になった場合、**同じトランザクションで `Batch` 行も削除する** |
| 4 | `PendingFileDeletion` に従って実体を削除する |

中断すればトランザクションはロールバックされ削除は成立しない（他の `app.db` 更新と同じ）。手順 3 と 4 の間で中断した場合は、`PendingFileDeletion` の起動時 GC が実体を回収する。**`Batch` 行の削除は利用者操作の対象ではなく、`Project` 削除の副次的な後始末に過ぎない**（`ExportQueueItem.projectID` は `Project` へ `CASCADE` するため、この時点でそのバッチのキュー項目は既に存在しない。7.1）。`ExportRecord` / `OutputRecord` / `ExportJob` が保持する `batchID` は `SET NULL` になる（7.1）。

##### 編集中 `Project` の破棄

書き出し前の `Project` を破棄する場合も `Project` 削除 Saga と同じ手順を使う。`beingEdited` の上書き確認を伴う（削除の可否判定）。

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
    /// canDeleteHistoryUnit を再評価してから削除する（所属 Batch が空になった場合の自動削除を含む）
    func deleteHistoryUnit(
        _ unit: HistoryUnit,
        trigger: DeletionTrigger
    ) async throws
}

/// 確認画面へ出す情報。削除の可否そのものは保証しない
struct DeletionInspection: Sendable {
    let blockedByAbsoluteProtection: Set<AbsoluteProtection>
    let overridableProtections: Set<OverridableProtection>
    let reclaimableBytes: Int64
}

enum AbsoluteProtection: Sendable, Hashable {
    case nonTerminalQueueItem
    case exportJobRunning
    case undeliveredOutput
}
```

**`DeletionContext` を呼び出し側から渡さない**（渡せる形だと context 読み取り後に新しい `ExportJob`/キュー項目が作られ古い context で削除が通る競合が残る）。**`deleteHistoryUnit` は `trigger` だけを受け取り `DeletionContext` を DB トランザクションの内側で読み直す**（`inspectDeletion` の結果は確認文言のためだけに使い削除の根拠にしない。再評価で不可になった場合は throw し理由を提示する）。**`DeletionInspection` と `DeletionContext` は別の型**（同じ型だと表示用に読んだ値を削除へ渡す実装が書けてしまう）。

##### 出力の削除経路

**「ファイルを消す」だけでは `OutputRecord` が孤児になるため、すべての出力削除を単一の経路へ統一する。**

| 順 | 操作 |
| --- | --- |
| 1 | DB トランザクションで `OutputRecord` を削除する |
| 2 | **同じトランザクション内で** `PendingFileDeletion` を追加する |
| 3 | DB のコミット後にファイルを削除する |
| 4 | 成功したら `PendingFileDeletion` の行を削除する |
| 5 | 失敗したら起動時 GC で再試行する |

対象は完了前（`settledAt == nil`）の破棄・起動時復旧、`delivered` での完了画面離脱、`isUndelivered`（完了済み）の 24 時間経過、壊れた出力の復元不能、`Project` / `Batch` の削除のすべて（**入口ごとに別の順序を実装しない**）。**失っても復旧できないほうを避ける**（ファイルを先に消して DB が失敗するとレコードだけが残り実体を指せない。DB を先に更新すれば残るのは孤児ファイルだけで GC が回収する）。

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
| 登録上限 | **Standard・Pro ともに 100 個**（差別化として機能せず Pro の焦点をぼかすため、両プランで揃える） |
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

##### `StampStore`

**`CustomStamp` / `StampAsset` / `ProjectStampAsset` を扱う永続化ポートを 1 つに集約する**（`Application` は `GRDB` を直接扱わないため。4.3）。以下の契約は、本節のこれまでの規則をこのポートの操作として整理したもの。

```swift
/// スタンプ一覧の項目（仕様 19.6）
struct CustomStamp: Sendable, Equatable {
    let customStampID: CustomStampID
    let assetHash: StampAssetHash    // 画像実体への参照
    let name: String
    let sortOrder: Int32
    let thumbnail: ManagedFileRef    // .stampThumbnail。実体から再生成できるキャッシュ
}

// Domain — 永続化ポート
protocol StampStore: Sendable {
    /// 取り込み。body が一時ファイルへ書いた内容の SHA-256 が既存の StampAsset と一致すれば
    /// それを再利用し、新規に書いたファイルは破棄する。一致しなければ新規 StampAsset を作る。
    /// thumbnailBody は一覧サムネイル（.stampThumbnail）を書き込む（ラスタライズは
    /// 呼び出し元が MediaKit で行う。重複取り込みでも CustomStamp 行ごとに作る）。
    /// sortOrder は既存の最大値 + 1 を store が採番する（呼び出し側の競合と採番漏れを防ぐ）
    func importCustomStamp(
        name: String,
        body: @Sendable (URL) async throws -> Void,
        thumbnailBody: @Sendable (URL) async throws -> Void
    ) async throws -> (stamp: CustomStamp, assetHash: StampAssetHash)

    /// スタンプ一覧
    func loadCustomStamps() async throws -> [CustomStamp]

    /// 一覧から削除する（CustomStamp 行のみ。StampAsset の参照カウントは変えない）
    func removeCustomStamp(_ id: CustomStampID) async throws

    /// Project のいずれかの領域が実体を使うようになった。UNIQUE(projectID, assetHash) により冪等
    func attachStampReference(projectID: ProjectID, assetHash: StampAssetHash) async throws
    /// Project からその実体を使う領域がすべて無くなった。同一トランザクションで参照数を導出し、
    /// 0 になった実体は同じトランザクション内で PendingFileDeletion へ登録する
    func releaseStampReference(projectID: ProjectID, assetHash: StampAssetHash) async throws

    /// 使用容量の内訳（登録中のマイスタンプ / 過去の加工履歴で使用中 / 合計）
    func loadStampStorageBreakdown() async throws -> StampStorageBreakdown
}

/// 使用容量の内訳（本節「使用容量の表示」が正本）
struct StampStorageBreakdown: Sendable {
    let registeredBytes: Int64     // 登録中のマイスタンプ（一覧に存在する CustomStamp が指す実体）
    let historyOnlyBytes: Int64    // 一覧から削除済みだが過去の加工履歴で参照中の実体
    let totalBytes: Int64
}
```

**実体欠損時の処理**: `StampAsset` の実体が読み取れない場合、`CustomStamp` / `StampAsset` / `ProjectStampAsset` の DB 行はいずれも変更しない（履歴サムネイルと同じ扱い。本節「履歴サムネイル」）。一覧・プレビューではプレースホルダを表示する。内容ハッシュが主キーであるため、利用者が同じ画像を再度取り込めば同じハッシュへ解決し実体だけが復元される（行の再作成は不要）。

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

##### `MaintenanceStore`

**起動時 GC が使う永続化ポートを 1 つに集約する**（`Application` は `GRDB` を直接扱わないため。4.3）。このポートだけで起動時 GC を実装できる粒度にする。

```swift
// Domain — 永続化ポート。起動時の孤児ファイル GC が使う
protocol MaintenanceStore: Sendable {
    /// 未処理の PendingFileDeletion をすべて読む
    func loadPendingFileDeletions() async throws -> [PendingFileDeletion]
    /// 実体削除に成功した行を消す
    func clearPendingFileDeletion(_ file: ManagedFileRef) async throws

    /// 種別ごとに、管理ディレクトリ内に実在するファイル ID の一覧を返す
    func listExistingFileIDs(kind: ManagedFileKind) async throws -> Set<ManagedFileID>
    /// 種別ごとに、DB 上のテーブルが参照している ID の一覧を返す
    func listReferencedFileIDs(kind: ManagedFileKind) async throws -> Set<ManagedFileID>

    /// 孤児ファイル（listExistingFileIDs にあり listReferencedFileIDs に無いもの）を削除候補として登録する
    func registerOrphan(_ file: ManagedFileRef) async throws
}
```

`listReferencedFileIDs` の参照元は種別ごとに固定する。

| `ManagedFileKind` | 参照元 |
| --- | --- |
| `.output` | `OutputRecord.outputFile` |
| `.stampAsset` | `StampAsset` の行そのもの（内容ハッシュが主キー） |
| `.historyThumbnail` | `Project` が保持する `ManagedFileRef` |
| `.processingTemporary` | `WorkingSourceRecord.sourceFile` |
| `.stampThumbnail` | `CustomStamp.thumbnailFileID`（一覧サムネイルは行が参照を持つ。欠損時は実体から再生成する） |
| `.rasterTemporary` | **常に空集合**（DB 参照を持たない一時ファイル。存在するものはすべて孤児候補として扱う） |

起動時復旧の手順は、(1) `loadPendingFileDeletions` で未処理分の実体削除を再試行し成功したものを `clearPendingFileDeletion` で消す、(2) 種別ごとに `listExistingFileIDs` と `listReferencedFileIDs` の差集合を求め `registerOrphan` で削除候補へ登録する、(3) 登録した候補を（1）と同じ経路で削除する。**`.rasterTemporary` は参照元が無いため、次回起動をまたいで存在するものはすべて孤児として削除してよい**（1 回の `render` 呼び出し内でのみ有効なため）。`.stampThumbnail` は `CustomStamp.thumbnailFileID` を参照元とし、参照されない実体のみを孤児として削除する（欠損時は実体から再生成できるキャッシュだが、行が参照を持つ以上、参照中の実体を削除しない）。

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
enum SourceRepresentation: Sendable, Equatable {
    case original      // プロバイダーが返した原データ
    case transcoded    // OS が変換した派生データしか取得できなかった
}

/// EXIF の撮影日時。ローカル表記とオフセットを分けて保持する（正準スキーマ 5.1）
struct OriginalCaptureMetadata: Sendable, Equatable {
    let dateTimeOriginal: String?      // "YYYY:MM:DD HH:MM:SS"
    let subSecTimeOriginal: String?
    let offsetTimeOriginal: String?    // "+09:00" など
    let utcMillis: Int64?              // offset がある場合のみ算出する
}

/// 出力メタデータ。許可フィールド以外を構造的に持てない
struct OutputMetadata: Sendable, Equatable {
    let pixelSize: PixelSize
    let iccProfile: Data?                    // 色が変わる場合のみ埋める
    let capture: OriginalCaptureMetadata?    // 設定で保持を選んだ場合のみ
    // 向きは常に通常値（1）として書くため、フィールドを持たない
}
```

**`utcMillis` は `offsetTimeOriginal` がある場合にだけ入り、無い場合は `nil`（端末のタイムゾーンで補完しない。正準スキーマ 5.1）。** ローカル表記をそのまま持つのは出力 EXIF へ書き戻すため（UTC 変換後の再構築は往復誤差が出る）。**`representation` が `transcoded`（取得経路が元データを返さなかった）でも取得を拒否しない**（取得できた表現からそのまま処理する。9.1 の診断区分値としてのみ記録する）。

**`Project` は `capture: OriginalCaptureMetadata?` / `sourceRepresentation: SourceRepresentation` / `libraryCreationDate: Date?`（`PHAsset.creationDate` 由来。取得できる場合のみ）を直接フィールドとして持つ**（7.1。素材ごとの中間 snapshot は持たない）。

**`ImageEncoder` はこの型だけを受け取る**（[画像処理](image-pipeline.md)。元のメタデータ辞書を渡せる形だとコピー削除実装が可能になってしまう）。**保存後に読み返し、許可されていない namespace とキーが 1 つも無いことを検査する**（失敗した出力は完成扱いにせず [書き出し Saga](export-saga.md) のファイル検証失敗として扱う）。**カスタムスタンプも同じ方針で再エンコードする**（取り込み時の縮小・変換で元のメタデータを捨てる。実体がアプリ内に残る以上、位置情報を保持する理由が無い）。

**`PHAsset.creationDate` は `Optional`。** 優先順位を定める。

| 順 | 取得元 | 条件 |
| --- | --- | --- |
| 1 | `PHAsset.creationDate` | **読み取り権限が既にある場合のみ**（[画像処理](image-pipeline.md)） |
| 2 | EXIF の `DateTimeOriginal` | 常に試みる |
| 3 | **`creationDate` を設定しない**（OS が保存日時を使う） | どちらも無い場合 |

**3 の場合に現在時刻を明示指定しない**（設定しないのと同じ結果になるが、「日時を引き継いだ」と記録が残ると不具合調査時に誤解の元になる。取得できなかったことを区分値として記録する。9.1）。

画像方向とピクセルサイズは常に保持する。

---

---

## 8. 書き出し Saga

**正本は [書き出し Saga](export-saga.md) です。** 状態遷移、認可、中断時の後始末、起動時復旧の手順をここへ複製しません。書き出しは直列キュー 1 本（v1 は並列数 1）で処理するため、同一素材の並行実行は構造的に起きません（4.2、4.3。ADR 0005）。

**生成（書き出し）は出力ファイルと確認用の `OutputRecord` を作るだけで、枠・クレジットは一切消費しません。** 消費・`settledAt` の確定・`ExportRecord` の作成・確定記録の更新・`WorkingSourceRecord` の削除・書き出しジョブの削除は、出力確認画面での**明示的な完了操作**による単一の DB トランザクションでまとめて行います（ADR 0006）。ファイルシステムと DB を跨ぐ補償や永続的なコミットジャーナルは持ちません。それより前の中断は、完了前の出力を永続保護しない一律の後始末で足ります（[書き出し Saga](export-saga.md)）。

本書の他の章が依存する不変条件だけを示します。

| 不変条件 | 内容 |
| --- | --- |
| **確定境界** | 会計の計上・枠の確定・成果物の公開はすべて完了操作の単一トランザクションただ 1 点。それ以前は何も消費せず、成果物も公開しない |
| **完了前の出力** | 永続保護しない。アプリの再起動・フローからの離脱で破棄する（消費していないため損失は操作の手間だけ。ADR 0006） |
| **未受け渡し出力の保護**（完了済み） | 保存前に消えない。更新誘導より受け渡しを優先する（ADR 0005） |
| **復旧の開始条件** | 起動時復旧（未確定の `ExportJob` / `OutputRecord` の一律削除・孤児ファイル GC）を終えるまで新しい書き出しを開始しない |

`ExportJob` / `ExportAuthorization` / `ExportAccountingMode` / `OutputRecord` の型定義も [書き出し Saga](export-saga.md) が正本です。

---

## 9. セキュリティとプライバシー

### 9.1 ログ・診断

**端末外への送信先は Sentry のみとする**（ADR 0005）。送信するのは**クラッシュと未分類例外（`UNKNOWN_ERROR`）のみ**（Sentry 無料枠超過を防ぎプライバシー面でも正しい。スパイク保護とサンプリングを有効化する）。**独立した分析イベントの送信基盤は持たない**（ADR 0005）。既知のエラーは即座には送らず、**パンくず（breadcrumb）として記録し、後続のクラッシュに付随した場合にのみ送信する。**

```swift
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
    case protectedDataUnavailable = 13
    case photoLibrarySaveFailed = 15
    case photoLibraryPermissionDenied = 16
    case shareFailed = 17
    case entitlementVerificationFailed = 18
    case purchaseFailed = 19
    case sourceMissing = 21
    case sourceMismatch = 22
    case capabilityRequired = 23      // 設定内容が現在の能力で許されない
}
```

**`AppErrorCode` を `Domain` に置く**（`ExportQueueFailure` と診断の両方が使うため一方の層に置くと依存が逆流する）。**この列挙が全体。値の欠番はそのまま維持し詰め直さない**（将来の追加に備える。ADR 0005）。

##### エラー型と握りつぶしの禁止

`AppErrorCode` を持つ `AppError` を定義し、各要素は**再試行可否と診断フィールド**を持つ（仕様 26.2 の再試行可否は型の上で表現し実行時判断に委ねない）。

```swift
struct AppError: Error, Sendable, Equatable {
    let code: AppErrorCode
    let isRetryable: Bool
    let context: CrashContext?      // 診断へ渡す文脈（識別子と自由文字列を含まない）
}
```

**利用者向けメッセージは `AppError` が持たない**（文言は `App` 層が `code` から解決する。`Domain` に文言を持たせるとローカライズ・文言変更のたびにドメイン層が変わる）。すべての `catch` 節で `AppError` へ変換し `CrashReporter.addBreadcrumb` を通すことを規約とし、`try?` による握りつぶしは lint で禁止する（`do / catch` または `Result` で明示的に扱う）。

##### クラッシュ解析

```swift
// Domain — クラッシュ報告。送信前フィルタは実装側の責務
protocol CrashReporter: Sendable {
    /// 起動時に 1 回だけ。診断送信が無効なら何もしない
    func start(enabled: Bool)

    /// 利用者が診断送信の可否を変更した
    func setEnabled(_ enabled: Bool)

    /// 既知エラーの発生をパンくずとして記録する。自由文字列を受け取らない。
    /// 送信されるのは後続でクラッシュが発生した場合のみ
    func addBreadcrumb(_ code: AppErrorCode)
}

/// クラッシュ報告に添える文脈。識別子と自由文字列を持たない
struct CrashContext: Sendable, Equatable {
    let hasActiveExportJob: Bool
    let queueDepth: Int
    let recoveryStep: Int?
}
```

**`CrashContext` に `ProjectID` などを入れない**（識別子をログ経路へ渡せない規約を型で守る）。Sentry Cocoa SDK は `Domain` が定義するこのプロトコルの背後に配置し、送信前フィルタをこの実装へ集約する。**Sentry は `Logger` を通らず、例外メッセージ・スタックトレース中のファイルパス・breadcrumbs・HTTP リクエスト URL とヘッダ・UI 階層やセッション記録・端末情報を独自に収集する**ため、実装契約として制約を明記する。

| 制約 | 内容 |
| --- | --- |
| 送信前フック | `beforeSend` で**許可フィールドだけを残す**。既定は除去 |
| 例外メッセージ | **任意文字列をそのまま送らない。** 例外の型名と `AppError` のコードへ置き換える |
| パスと URL | ファイルパス、写真ライブラリ ID、URL を除去する |
| 利用者入力 | カスタムスタンプ名などの入力値を送らない |
| 添付 | 画像、添付ファイル、画面キャプチャを**送らない** |
| セッション記録 | UI 階層の収集とセッションリプレイを**有効化しない** |
| breadcrumbs | SDK の自動記録を無効化し、**`addBreadcrumb` で記録した `AppErrorCode` だけ**を送信対象にする |

例外メッセージを型名とコードへ置き換えるのは、メッセージが最も混入しやすい経路のため（ファイル入出力の例外は既定でパスを本文に含む）。**仕様 28.3 の禁止項目**（元ファイル名、ファイルパス、写真ライブラリ ID、正確な顔座標、画像ハッシュ、SNS アカウント名、カスタムスタンプ画像、写真・動画の内容、音声内容）は、この送信前フィルタと許可リストで担保する。**端末外への送信経路は Sentry のみ**（ADR 0005）。

### 9.2 脅威モデル

**利用者自身による端末内データの改ざん・時計操作は対象外とする**（ADR 0005）。台帳・購入状態は平文であり、書き換えれば無料枠やトライアルを回復でき、端末時計を操作すれば月間枠を前倒し取得できる。処理用ファイルの実体照合も存在確認のみであり差し替えは検出しない。被害上限は無料書き出し数枚であり、同じ利得は仕様 14.5 が許容する再インストールでも得られるため受容する（ADR 0005 Consequences）。

| 分類 | 内容 | 根拠 |
| --- | --- | --- |
| **対象としない（受容）** | `app.db` の直接書き換えによる無料枠・トライアルの回復 | ADR 0005。防御コストが守る価値（無料書き出し数枚）に見合わない |
| **対象としない（受容）** | 端末時計の操作による月間枠の前倒し取得 | 検出にはサーバー照合が要るが自前バックエンドを持たない |
| **対象としない（受容）** | 処理用ファイルの差し替え（存在確認のみのため検出しない） | 実害は自分の書き出し内容が変わる程度であり他者への影響が無い |
| **対象としない（受容）** | `FaceTrack`（検出品質・顔行）の直接書き換えによる `triage` 結果の操作 | 自分の写真を自分の判断で確認せずに書き出すことに帰着し、露出するのは改変者本人の写真のみ |
| **対象とする** | 未加工出力（`outputs/`）の保護、`.complete` によるロック中解析対策 | 7.4。プライバシー境界として維持する |
| **対象とする** | 未加工の顔画像を端末外へ送信しないこと | 9.1 のクラッシュ解析の送信前フィルタで担保する（端末外への送信経路は Sentry のみ） |
| **対象外** | CDN・自前バックエンドの侵害 | v1 は自前バックエンドを持たない（ADR 0005） |

**画面スナップショット**: OS のタスクスイッチャに編集中の未加工画面が残るため、フォアグラウンドから外れる際にプライバシーオーバーレイを表示する（`scenePhase` が `.inactive` へ遷移した時点）。スクリーンショットの全面禁止は採らない（利用者自身の記録手段を塞ぐため）。**この帰結として、完了前の出力確認画面をスクリーンショットすれば無消費のまま画面解像度の成果物相当を取得できるが、受容する**（原寸出力ではなく、防ぐには透かし・遮蔽の防御機構が必要になるため。[ADR 0006](adr/0006-accounting-per-delivered-output.md)）。

---

## 10. 設定定数

**v1 はサーバレスであるため、運用値をバンドル内の定数として持つ**（ADR 0005）。値を変えるにはアプリ更新が要る。

| 定数 | 値 |
| --- | --- |
| `freeMonthlyExportLimit` | 5 |
| `proBatchSizeLimit` | 50 |
| `trialBatchSizeLimit` | 5 |
| `trialCreditCount` | 5 |
| `batchConcurrencyLimit` | 1 |
| `lowConfidenceThreshold` | 暫定: v1 初期リリースはトリアージ無効（閾値未設定）。実測後に確定（12 章） |
| `extremePoseYawDegrees` / `extremePosePitchDegrees` | 暫定 45°（yaw / pitch とも）。実測後に確定（12 章） |
| `historyStorageLimitBytes` | 200MB |
| `customStampLimit` | 100 |
| `customStampMaxEdgePixels` | 1,024 |
| `interstitialAdExportInterval` | 3 |
| `enabledStampPacks` | 同梱の全パック |
| `standardEntitlementID` / `proEntitlementID` | `"standard"` / `"pro"`（RevenueCat の entitlement 識別子） |

値の根拠・変更履歴は [運用](operations.md) が正本。**障害時は緊急アップデートで対応する**（ADR 0005）。取得失敗という状態が存在しないため、既定値へのフォールバックも不要。

---

## 11. テスト戦略

**「純粋な判定」と「実ストレージの原子性」は同じ層では検証できない**（混ぜると判定テストにシミュレータが要り実行が遅くなって回されなくなる）。

三層へ分ける。フレームワークは **Swift Testing**（`@Test`）を使い、UI テストのみ XCTest とする。

| 層 | 実行環境 | 保証する内容 |
| --- | --- | --- |
| **domain unit test** | `swift test`（数秒。シミュレータ不要） | 純粋関数と状態機械。クォータ、トリアージ、座標変換、`compileRenderDraft`、[書き出し Saga](export-saga.md) の状態遷移（中断時のロールバック規則を含む） |
| **application saga test** | `swift test`（数十秒） | 偽 DB・偽ファイルによる**各中断点**の挙動 |
| **adapter integration test** | シミュレータ / 実機 | 実 GRDB、実ファイル保護、Vision、Core Image |

各項目は検証が成立する最も低い層へ置く（個別のテスト項目は `docs/test-plan.md` が正本）。**中断・再起動後の挙動は状態機械のユニットテストで検証する**（[書き出し Saga](export-saga.md) の状態数を 3〜4 個へ削減したため、実機での障害注入なしに十分検証できる。ADR 0005）。

### 11.1 必須とする保証

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

## 12. 未決事項

v1 のリリース範囲、動画の扱い、課金訴求の分類、利用者向け表現は [商品面の決定](product-decisions.md) が正本です。

| 項目 | 内容 | 決定時期 |
| --- | --- | --- |
| 商品 ID | 仕様 27.1 の商品 ID は暫定 | ストア登録時 |
| App Store ID | 更新誘導のリンク先に必要（[運用](operations.md)） | ストア登録時 |
| `lowConfidence` の閾値 | `FaceObservation.confidence` の下限。実素材の分布を見て決定（[画像処理](image-pipeline.md) / 6.1）。**暫定運用: v1 初期リリースでは `lowConfidence` のトリアージを無効（閾値未設定）で出し、実測後の更新で有効化する** | v1 実機検証時 |
| `extremePose` の角度閾値 | yaw / pitch の絶対値の上限。検出品質テストの結果から決定（6.1）。**暫定運用: 暫定値 yaw / pitch 45° で実装し、実測後に確定する** | v1 実機検証時 |
| プライバシーポリシーの記載 | トライアル消費記録（`UsageLedger.trialConsumedExportIDs`）を期限なく端末内へ保持することを記載し、7.5 の例外と整合させる | ストア申請前 |
| 基本スタンプの意匠 | ベクターで自作する 12〜20 種の具体的な図案 | v1 実装中 |
| 履歴の使用容量上限 | 初期値 200MB は暫定。加工後サムネイルの実サイズを計測して確定 | v1 実装中 |
| カスタムスタンプの保存解像度 | 長辺 1,024px は暫定。顔が大きく写る素材での見え方を実機で確認（7.5） | v1 実機検証時 |
| トライアルのクレジット数 | 5 枚は暫定。転換率を見て調整可能な設定値とする | リリース後 |
| 一括処理の同時並列数を 2 へ引き上げるか | v1 は 1 固定。引き上げには開始順序の再設計と実機計測が要る | v2 検討時 |
