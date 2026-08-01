# Domain 層（契約と純粋関数）実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: このリポジトリでは CLAUDE.md の定めにより、各タスクを vibepod（kaneko 実装 → reviewer → code-review スキル）で実行する。Steps は checkbox（`- [ ]`）で追跡する。

**Goal:** docs（architecture / export-saga / image-pipeline / canonical-schema / test-plan）に確定済みの Domain 契約と純粋関数を `packages/Domain` の Swift として実装する（Issue #5）。

**Architecture:** Domain は Foundation のみに依存する純粋 Swift。型・ポート宣言は正本 docs の Swift コードブロックを一字一句転記し（ドキュメントが正本）、純粋関数は test-plan の期待値を TDD で満たす。正本に無い判断が必要になったら実装せず差し戻す。

**Tech Stack:** Swift 6（strict concurrency complete）、Swift Testing（`import Testing`）、SwiftPM。

## Global Constraints

- `packages/Domain/Sources` の import は **Foundation のみ**（CI の import-scan と SwiftLint が強制。architecture.md 3.3）
- Domain 内で裸の `Date()`（現在時刻取得）禁止。時刻は引数 `now: Date` で注入（SwiftLint が強制）
- 型・プロトコル・enum 固定値は正本 docs のコードブロックと**一字一句一致**させる。改名・フィールド追加・省略は禁止（乖離が必要なら差し戻し）
- 各タスク完了時: `swift test --package-path packages/Domain` 全通過＋`bash scripts/check-imports.sh` OK＋コミット（`(#5)` を含める）
- 外部依存の追加は一切禁止

## タスクと正本の対応

| Task | 内容 | 転記元（正本） | テスト要求 |
| --- | --- | --- | --- |
| 1 | 識別子と共通値型 | architecture.md 6.5（ID 型）、6.3（YearMonth）、7.3（ManagedFileRef と種別つき参照）、7.5（StampAssetHash まわりの型） | 型が Sendable/Hashable でコンパイルできること、種別つき参照の kind 固定値 |
| 2 | レンダリング境界の型 | image-pipeline.md 1章（DetectedFace）、2章（RenderSpec 系・検証済み値型群・RenderDraft/RenderPlan 系・座標型）、5章（境界型: ImageSource/LoadedPhoto/DetectionResult/RawBitmapDescriptor/RenderedImage/OutputFile ほか） | test-plan 2.4: 検証済み値型の throws 初期化子（範囲外で throw、境界値で成功） |
| 3 | 会計・課金・キュー・更新の型 | architecture.md 6.2（SubscriptionState 系・ResolvedCapabilities）、6.3（UsageLedger・ExportedSettingsEntry・MonthlyQuotaDecision）、6.4（ExportQueueState・BatchPolicySnapshot）、6.6（AppVersion・UpdateDecision）、export-saga.md 0〜2章（ExportJob・ExportRecord・OutputRecord・OutputState・ExportAuthorization・ExportAccountingMode・ExportSetting・OutputAspect・MetadataPolicy・PreviewConfirmation・BatchReviewState・StampCatalog/StampRequirement） | enum 固定値（OutputState の列値等）がドキュメントと一致すること |
| 4 | 永続化ポート群 | export-saga.md 0章（ExportSagaStore・OutputDeliveryStore と入力型）、image-pipeline.md 5章（WorkingSourceStore と入力型・WorkingSourceRecord）、architecture.md 7.3（ManagedFileStore）、7.5（HistoryDeletionStore・MaintenanceStore・StampStore・OutputDeliverySnapshot・PendingFileDeletion 系） | プロトコルがコンパイルでき、doc コメントの事前条件（settledAt != nil 等）が転記されていること |
| 5 | 設定ハッシュの正準エンコーダ | canonical-schema.md 2章（基本型の符号化）、5章（ProjectSettingsHash / PreviewRenderHash / StampAssetHash、含めるフィールドと順序、最終式） | test-plan 2.5: ゴールデンテスト（固定入力 → 固定ハッシュ値をテストに焼き込む）、順序・Optional・-0.0 正規化・ドメイン分離子 |
| 6 | クォータ・能力・トリアージの純粋関数 | architecture.md 6.3（evaluateMonthlyQuota・rollPeriod）、6.2（resolveCapabilities）、6.1（triage・ReviewIssue・ReviewDecision 系） | test-plan 2.1（月間枠・ローカル年月切替・reissue 前提の判定）、2.2（トリアージ）、2.3（能力） |
| 7 | レンダリングのコンパイル純粋関数 | image-pipeline.md 2章（compileRenderDraft・bindRasterAssets）、1章（expand）、4章（丸め・適用順） | test-plan 2.4（丸め規則・stampKeys 重複排除・欠落 assets で throw・座標変換） |
| 8 | キュー状態機械と更新判定・認可 | architecture.md 6.4（ExportQueue 遷移）、6.6（evaluateUpdate）、export-saga.md 1章（authorizeRenderSpec・免除規則の型面） | test-plan 2.6（更新誘導）、3.2 の純粋部分（認可判定） |

---

### Task 1: 識別子と共通値型

**Files:**
- Create: `packages/Domain/Sources/Domain/Identifiers.swift` / `CommonValues.swift` / `ManagedFileRef.swift`
- Test: `packages/Domain/Tests/DomainTests/IdentifiersTests.swift` / `ManagedFileRefTests.swift`
- Delete: `DomainPackageMarker.swift` 系は残す（他パッケージが参照）

**Interfaces（Produces）:** `ProjectID` / `BatchID` / `ExportID` / `RegionID` / `FaceTrackID` / `ManagedFileID` / `ExportQueueItemID` / `CustomStampID`（いずれも `rawValue: UUID` の struct、Sendable+Hashable）、`YearMonth`、`ManagedFileKind` と `ManagedFileRef`・種別つき参照（`OutputFileRef` / `WorkingSourceFileRef` / `StampAssetFileRef` / `ThumbnailFileRef` 等、architecture 7.3 の列挙どおり）、`StampAssetHash`（32バイト固定。不正長で throw）

- [ ] Step 1: 正本節（architecture 6.5 / 6.3 / 7.3）を Read し、宣言を転記したソースを作成
- [ ] Step 2: 失敗するテストを書く（例: `#expect(throws:)` で `StampAssetHash(data: Data(count: 31))` が throw、`YearMonth(year: 2026, month: 13)` の扱いは正本の定義どおり）
- [ ] Step 3: `swift test --package-path packages/Domain` で失敗を確認
- [ ] Step 4: 実装を完成させテスト通過を確認
- [ ] Step 5: `bash scripts/check-imports.sh` OK を確認しコミット（`feat: Domain の識別子と共通値型 (#5)`）

### Task 2: レンダリング境界の型

**Files:**
- Create: `packages/Domain/Sources/Domain/Rendering/`（RenderSpec.swift / ValidatedValues.swift / RenderPlan.swift / Boundary.swift / DetectedFace.swift）
- Test: `packages/Domain/Tests/DomainTests/Rendering/ValidatedValuesTests.swift` ほか

**Interfaces（Consumes）:** Task 1 の ID 型・`StampAssetHash`。**（Produces）:** image-pipeline 2章・5章の全型（`RenderSpec` / `RenderRegionSpec` / `StampSource` / `RenderOpSpec` / `BackgroundSpec` / `EffectOpacity` / `MosaicRatio` / `BlurRatio` / `FeatherRatio` / `ExpansionRatio(s)` / `RotationDegrees` / `SigmaPx` / `FeatherPx` / `CellSizePx` / `NormalizedRect` / `PixelSize` / `PixelRect` / `SourcePlacement` / `RenderDraft` 系 / `RenderPlan` 系 / `MaskShape` / `CornerRatio` / `RegionOrigin` / `RenderValidationError` / `EffectSetting` / `VisibleColor` / `SrgbArgb8888` / `ImageFormat` / 境界型一式）

- [ ] Step 1: image-pipeline 1・2・4・5章の型コードブロックを転記
- [ ] Step 2: 失敗するテスト（test-plan 2.4 の値型検証: 範囲外 throw・境界値成功・`RotationDegrees` の [-180,180) 正規化・`CellSizePx` の floor+下限2）
- [ ] Step 3〜5: 失敗確認 → 実装 → 通過確認 → check-imports → コミット

### Task 3: 会計・課金・キュー・更新の型

**Files:**
- Create: `packages/Domain/Sources/Domain/Accounting/`・`Billing/`・`Queue/`・`Update/`
- Test: enum 固定値・必須フィールドの存在をコンパイルとテストで固定

**Interfaces（Consumes）:** Task 1・2 の型。**（Produces）:** 上表 Task 3 列の全型（正本のコードブロックどおり）

- [ ] Step 1〜5: Task 1 と同型の TDD サイクル（テスト例: `OutputState` の固定列値が docs の表と一致、`ExportAccountingMode` が 4 ケースであること）

### Task 4: 永続化ポート群

**Files:**
- Create: `packages/Domain/Sources/Domain/Ports/`（ExportSagaStore.swift / OutputDeliveryStore.swift / WorkingSourceStore.swift / ManagedFileStore.swift / HistoryStores.swift / MaintenanceStore.swift / StampStore.swift）

**Interfaces（Consumes）:** Task 1〜3 の全型。**（Produces）:** 上表 Task 4 列の全プロトコルと入力型

- [ ] Step 1: 正本のプロトコル宣言と doc コメント（事前条件・トランザクション境界）を転記
- [ ] Step 2: コンパイルが通ることと、偽実装（テスト内のミニマルな準拠型）が書けることをテストで固定
- [ ] Step 3〜5: 通常サイクル

### Task 5: 設定ハッシュの正準エンコーダ

**Files:**
- Create: `packages/Domain/Sources/Domain/Canonical/`（CanonicalEncoder.swift / SettingsHash.swift）
- Test: `CanonicalEncoderTests.swift` / `SettingsHashGoldenTests.swift`

**Interfaces（Consumes）:** Task 2 の RenderSpec 系・Task 3 の ExportSetting。**（Produces）:** `ProjectSettingsHash` / `PreviewRenderHash` の計算関数（canonical-schema 5.2 の最終式どおり、SHA-256 はどう実装するか: **Foundation のみ制約下では CryptoKit を使えないため、正本 canonical-schema が要求するのは「SHA-256 であること」まで。ハッシュ計算の実体は Domain にプロトコル `Sha256Digest`（入力バイト列→32バイト）として置き、実装はアダプタ注入とする。ただしこの分離が docs に無い場合は差し戻して確認すること**）

- [ ] Step 1: canonical-schema 2章の符号化規則を関数群として TDD（整数 BE / Optional タグ / -0.0 正規化 / ordered vs unordered / 長さ前置き）
- [ ] Step 2: 5.2 のフィールド順で入力バイト列を構築する関数を TDD
- [ ] Step 3: 固定入力のゴールデンテスト（期待バイト列をテストへ焼き込み。ハッシュはアダプタ注入のため バイト列までを Domain のゴールデンとする）
- [ ] Step 4〜5: 通常サイクル

### Task 6: クォータ・能力・トリアージの純粋関数

**Files:**
- Create: `packages/Domain/Sources/Domain/Quota/`（MonthlyQuota.swift）・`Capabilities/`（ResolveCapabilities.swift）・`Review/`（Triage.swift）
- Test: test-plan 2.1 / 2.2 / 2.3 の項目を1件ずつテスト化

- [ ] Step 1: test-plan 2.1 の期待値からテストを先に書く（ローカル年月・`current != period` 切替・消費可能判定）
- [ ] Step 2〜5: 失敗確認 → 実装（architecture 6.3 の判定手順どおり）→ 通過 → コミット。2.2 / 2.3 も同サイクルで繰り返す

### Task 7: レンダリングのコンパイル純粋関数

**Files:**
- Create: `packages/Domain/Sources/Domain/Rendering/Compile.swift`（compileRenderDraft / bindRasterAssets / expand）
- Test: test-plan 2.4 の座標・丸め・stampKeys・欠落 assets throw

- [ ] Step 1〜5: TDD サイクル（image-pipeline 2章・4章の規則が唯一の正）

### Task 8: キュー状態機械と更新判定・認可

**Files:**
- Create: `packages/Domain/Sources/Domain/Queue/QueueMachine.swift`・`Update/EvaluateUpdate.swift`・`Authorization/AuthorizeRenderSpec.swift`
- Test: test-plan 2.6・3.2 の純粋部分

- [ ] Step 1〜5: TDD サイクル

---

## Self-Review 済み事項

- Spec coverage: implementation-plan「サブプロジェクト2」の列挙（evaluateMonthlyQuota / rollPeriod / resolveCapabilities / triage / compileRenderDraft / ExportQueue 状態機械 / 正準エンコーダ / 値型 / ポート）は Task 1〜8 で全て割り当て済み
- 既知の未決: Task 5 の SHA-256 実装分離（Domain=バイト列構築、ハッシュ=注入）は docs に明文が無いため、**Task 5 実行時に差し戻し確認する**と明記
- 型名整合: 各 Task の Produces は正本 docs の名称のみを使用（転記制約により逸脱不可）
