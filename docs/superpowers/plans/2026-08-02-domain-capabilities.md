# Domain 能力系純粋関数の残実装 Implementation Plan (Issue #20)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Domain 層の未実装純粋関数（resolve / requiredPlan / canEdit / canEnterBatch）とトリアージ閾値の引数注入、およびレビュー持ち越しの Minor 5 件を実装し、Domain 層（サブプロジェクト 2）を完結させる。

**Architecture:** Domain は Foundation のみに依存する純粋 Swift。型・関数シグネチャは正本 docs（コミット dddc18d で正本化済み）の Swift コードブロックを一字一句転記し、導出規則・判定規則は正本本文の記述を TDD で満たす。正本に無い判断が必要になったら実装せず差し戻す。

**Tech Stack:** Swift 6（strict concurrency complete）、Swift Testing（`import Testing`）、SwiftPM。

## Global Constraints

- `packages/Domain/Sources` の import は **Foundation のみ**（architecture.md 3.3。CI の check-imports と SwiftLint が強制）
- 裸の `Date()`（現在時刻取得）禁止。時刻は引数 `usageNow` 等で注入する
- 型・プロトコル・関数シグネチャ・enum 固定値は正本 docs のコードブロックと**一字一句一致**させる（`public` 付与と明示的 `public init` のみ許容）。乖離が必要なら差し戻し
- 外部依存の追加禁止
- テストは Swift Testing で書く。テスト実行はホストへ委譲（コンテナに toolchain 無し）
- lint 制約: 変数名 3 文字以上（id 可）、ファイル先頭説明コメントは `//`（`///` 禁止）、1 行 120 文字以内、末尾カンマ禁止、テスト関数 50 行以内、ファイル 400 行以内、`Data` 等の長い `+` 連鎖禁止、連続空行禁止
- コミットは Conventional Commits、末尾に `(#20)`

---

### Task 1: resolve（CustomerInfoSnapshot → Entitlement）

**Files:**
- Create: `packages/Domain/Sources/Domain/Billing/Resolve.swift`
- Test: `packages/Domain/Tests/DomainTests/Billing/ResolveTests.swift`

**Interfaces:**
- Consumes: `CustomerInfoSnapshot` / `Entitlement` / `Plan` / `PlanStatus`（Billing/SubscriptionState.swift、実装済み）
- Produces: `public func resolve(snapshot: CustomerInfoSnapshot, usageNow: Date, standardEntitlementID: String, proEntitlementID: String) -> Entitlement`

**正本:** architecture.md 6.2 のシグネチャコードブロックと「`resolve` の導出規則」節（コミット dddc18d）。

- [ ] **Step 1: 失敗するテストを書く。** 導出規則の全分岐を `@Test(arguments:)` で固定する:
  - pro ID あり → `plan == .pro`（standard ID も同時にあっても pro 優先）
  - standard ID のみ → `.standard`、どちらも無し → `.free`
  - free は常に `status == .active`、`expiresAt == nil`
  - 有料 + `isInBillingRetry == true` → `.pending`、false → `.active`
  - `expiresAt` が該当 ID の `expirationDates` の値になる（無ければ nil）
  - `lastVerifiedAt == usageNow`、`isSandbox` が写る
  - `grace` / `expired` / `revoked` を生成しない（全分岐の status が active / pending のいずれかであることを網羅的 switch で固定）
- [ ] **Step 2: 実装する。** 正本シグネチャを一字一句転記し、導出規則 1〜4 を素直に実装する
- [ ] **Step 3: `bash scripts/check-imports.sh` を実行して OK を確認する**
- [ ] **Step 4: reviewer の一次レビュー → PASS / CONDITIONAL PASS でコミット** `feat: Domain の resolve（購読状態の畳み込み） (#20)`

### Task 2: ProjectCapabilityRequirement / requiredPlan / canEdit / canEnterBatch

**Files:**
- Create: `packages/Domain/Sources/Domain/Capabilities/ProjectCapability.swift`
- Create: `packages/Domain/Sources/Domain/Capabilities/BatchEntry.swift`
- Test: `packages/Domain/Tests/DomainTests/Capabilities/ProjectCapabilityTests.swift`
- Test: `packages/Domain/Tests/DomainTests/Capabilities/BatchEntryTests.swift`

**Interfaces:**
- Consumes: `StampRequirement`（Accounting/ExportAuthorization.swift、実装済み）、`ResolvedCapabilities` / `Plan`（実装済み）
- Produces:
  - `public struct ProjectCapabilityRequirement: Sendable, Equatable { public let stampRequirements: Set<StampRequirement> }`
  - `public func requiredPlan(_ requirement: ProjectCapabilityRequirement) -> Plan`
  - `public func canEdit(_ requirement: ProjectCapabilityRequirement, capabilities: ResolvedCapabilities) -> Bool`
  - `public func canEnterBatch(capabilities: ResolvedCapabilities, remainingCredits: Int) -> Bool`

**正本:** architecture.md 6.2「解約・降格後の既存データ」のコードブロックと本文、6.4 の `canEnterBatch` コードブロック（dddc18d で関数化済み）、export-saga.md 1.2（StampRequirement の意味）。

- [ ] **Step 1: 失敗するテストを書く。**
  - `requiredPlan`: stampRequirements が空 → `.free`、`.premiumStamp` を含む → `.standard` 以上、`.customStamp` を含む → 対応プラン（正本 6.2 本文と export-saga 1.2 から要求能力→最小プランの対応を確認して固定。**対応が正本から一意に導けない場合は実装せず差し戻す**）
  - `canEdit`: `.premiumStamp` 要求 × `canUsePremiumStamps == false` → false、要求空 → 常に true、`.customStamp` 要求 × `canUseCustomStamps == true` → true。**requiredPlan の戻り値比較を使わず能力で判定していること**（`plan = pro` かつ制限つき能力で false になるケースを固定）
  - `canEnterBatch`: `canUseProBatch` → 常に true、`canUseBatchTrial && remainingCredits > 0` → true、`remainingCredits == 0` → false、両能力なし → false（test-plan 2.3 の期待）
- [ ] **Step 2: 実装する**（canEnterBatch は正本の式を一字一句転記）
- [ ] **Step 3: `bash scripts/check-imports.sh` を実行して OK を確認する**
- [ ] **Step 4: reviewer の一次レビュー → コミット** `feat: Domain の編集可否・一括開始判定 (#20)`

### Task 3: トリアージ閾値の注入と Minor 5 件

**Files:**
- Modify: `packages/Domain/Sources/Domain/Review/Triage.swift`（閾値 private 定数 → 引数）
- Modify: `packages/Domain/Tests/DomainTests/Review/TriageTests.swift`（全呼び出しへ閾値引数を追加）
- Modify: `packages/Domain/Sources/Domain/Rendering/ValidatedValues.swift`（emptyRegion コメント）
- Modify: `packages/Domain/Sources/Domain/Review/Triage.swift`（FaceTrackID バイト比較）
- Modify: `packages/Domain/Sources/Domain/Update/EvaluateUpdate.swift`（時計巻き戻しコメント）
- Test: `packages/Domain/Tests/DomainTests/Canonical/SettingsHashGoldenTests.swift`（16 進リテラル固定テスト追加）

**Interfaces:**
- Produces: `triage(_ result:projectID:detectionRevision:extremePoseYawDegrees:extremePosePitchDegrees:)`（正本 architecture.md 6.1 の新シグネチャ）

- [ ] **Step 1: triage の閾値注入。** private 定数 `extremePoseYawDegrees` / `extremePosePitchDegrees` を削除し引数へ（既定値は付けない。呼び出し側が設定定数を渡す）。既存テストは 45.0 を渡す形へ追従。非有限の安全側判定（`!isFinite → true`）は維持
- [ ] **Step 2: Minor 対応。**
  - `RenderValidationError.emptyRegion` に「`NormalizedRect` が幅 0 を拒否するため現在は到達不能（正本転記のため残す）」コメントを追加
  - `overlappingFacesIssues` の UUID 文字列ソートを 16 バイトのバイト列辞書順比較へ（canonical-schema.md 2.1 の規則。`uuid` タプルから `[UInt8]` を作り `lexicographicallyPrecedes` で比較するヘルパを Triage.swift 内に置く）
  - `evaluateUpdate` へ「`usageNow < lastPromptedAt`（時計巻き戻し）では 24h 制限が続くが、端末時計をそのまま信頼する ADR 0005 の帰結として受容する」コメントを追加
  - `SettingsHashGoldenTests.swift` へ、既知の固定入力 1 件について `canonicalProjectSettingsBytes` 全体を 1 本の 16 進文字列リテラルと比較するテストを追加（バイト列は既存のプリミティブ組み立てヘルパの出力から生成してリテラル化する。`Data` → 16 進文字列のヘルパはテスト内に置く）
- [ ] **Step 3: `.swiftlint.yml` の `identifier_name.excluded: [id, op]` を確認し、`op` を Domain 限定へ絞れるか検討。SwiftLint の `identifier_name` にパス限定機能が無い場合は現状維持とし、その旨をコメントで補強する（設定ファイルの変更は最小限に）**
- [ ] **Step 4: `bash scripts/check-imports.sh` を実行して OK を確認する**
- [ ] **Step 5: reviewer の一次レビュー → コミット** `refactor: トリアージ閾値の注入とレビュー持ち越しMinorの解消 (#20)`

---

## Self-Review 済み事項

- Issue #20 の全項目とタスクの対応: resolve → T1、requiredPlan/canEdit/canEnterBatch/ProjectCapabilityRequirement → T2、閾値注入＋Minor 5 件 → T3。`canDeleteHistoryUnit` は正本の削除可否判定がサブプロジェクト 10（履歴）の文脈でしか検証できないため対象外のまま（Issue #20 に明記済み）
- 型整合: `StampRequirement` は実装済みの `Accounting/ExportAuthorization.swift` を参照（新規定義しない）。`ResolvedCapabilities` / `Plan` / `CustomerInfoSnapshot` / `Entitlement` も実装済み
- T2 の requiredPlan は正本の対応表が薄い可能性がある。**一意に導けなければ差し戻す**ことを Step 1 に明記済み
