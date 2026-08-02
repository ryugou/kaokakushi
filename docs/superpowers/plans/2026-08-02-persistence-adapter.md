# 永続化アダプタ（GRDB・app.db・Store 実装）Implementation Plan (Issue #6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** packages/Persistence に GRDB による app.db（スキーマ・制約・PRAGMA 検証）と Domain の永続化ポート7種の実装、実 GRDB での integration test を作り、サブプロジェクト3を完了する。

**Architecture:** Domain がプロトコル（ポート）を定義済み（packages/Domain/Sources/Domain/Ports/）。Persistence は GRDB の `DatabaseQueue` 1本でそれらを実装する。スキーマ・制約・接続規約の正本は architecture.md 7章、Saga 系トランザクションの正本は export-saga.md、テスト期待は test-plan.md 4.1〜4.4（インポート Saga 固有の項目はサブプロジェクト5の担当で本計画の対象外）。

**Tech Stack:** Swift 6（strict concurrency complete）、GRDB.swift 7.x（本プロジェクト初の外部依存。Persistence の Package.swift のみに追加）、Swift Testing。

## Global Constraints

- 依存方向: Persistence は Domain と GRDB にのみ依存する。**Domain / Application の import 許可リストは変更しない**（check-imports.sh の対象は従来どおり）
- 型・プロトコルのシグネチャは Domain のポート宣言（正本転記済み）へ準拠する。ポート側の変更が必要になったら実装せず差し戻す
- 接続規約（architecture.md 7.1「接続と journal」）: `DatabaseQueue` 1本、`journal_mode = DELETE`、`synchronous = EXTRA`、`foreign_keys = ON`、起動時に読み返して検証
- 裸の `Date()` 禁止（時刻は引数注入。ポートのシグネチャに従う）
- エラーの握りつぶし禁止。復旧エラーは運用者が次のアクションを判断できる形で throw する
- テストは Swift Testing。実行はホストへ委譲（コンテナに toolchain 無し）。実機でしか検証できないもの（iOS の FileProtectionType 実効性）は `#if os(iOS)` で分離し、macOS ではスキップされる形にする（実機検証はサブプロジェクト11）
- lint 制約: 変数名3文字以上（id 可）、ファイル先頭説明コメントは `//`、1行120文字以内、末尾カンマ禁止、テスト関数50行以内、ファイル400行以内、連続空行禁止
- コミットは Conventional Commits、末尾に `(#6)`

---

### Task 1: GRDB 導入と AppDatabase（接続・PRAGMA 検証）+ CI 更新

**Files:**
- Modify: `packages/Persistence/Package.swift`（GRDB.swift 依存を `from: "7.0.0"` で追加）
- Create: `packages/Persistence/Sources/Persistence/AppDatabase.swift`
- Test: `packages/Persistence/Tests/PersistenceTests/AppDatabaseTests.swift`
- Modify: `.github/workflows/ci.yml`（package-tests ジョブへ Package.resolved ベースの SwiftPM キャッシュを導入。既存コメントの方針どおり。**github-actions-optimize スキルの規約に従う**）

**Interfaces:**
- Produces: `public struct AppDatabase`（`static func open(at: URL) throws -> AppDatabase`、内部に `DatabaseQueue`。一時ディレクトリ上の DB でテストできる `openInMemory` 相当は使わず、ファイル DB のみ — journal_mode 検証のため）

- [ ] 接続規約（DELETE / EXTRA / ON）を設定し、**読み返して検証**する。検証失敗・`PRAGMA foreign_key_check` 違反は復旧エラーとして throw（test-plan 4.2）
- [ ] テスト: 開いた DB の3 PRAGMA が期待値であること、journal_mode を WAL に書き換えた DB を開くと復旧エラーになること
- [ ] reviewer 一次レビュー → コミット `feat: Persistence の AppDatabase と GRDB 導入 (#6)`

### Task 2: スキーマ v1 マイグレーションと制約の integration test

**Files:**
- Create: `packages/Persistence/Sources/Persistence/Schema.swift`（`DatabaseMigrator` v1）
- Test: `packages/Persistence/Tests/PersistenceTests/SchemaTests.swift`

**正本:** architecture.md 7.1 の全テーブル表・一意制約表・外部キー表（完全転記。宣言していない参照を作らない）。enum 列は Domain の raw value（UInt32）で保存。

- [ ] v1 マイグレーションで全テーブル・PRIMARY KEY・UNIQUE・部分 UNIQUE（`OutputRecord.projectID WHERE settledAt IS NULL`）・外部キー（RESTRICT / SET NULL / CASCADE を表どおり）を宣言
- [ ] テスト（test-plan 4.2）: Project 削除が非終端 OutputRecord / ExportJob で RESTRICT されること、Batch 削除で各 batchID が SET NULL になること、部分 UNIQUE が未確定出力を1件に制限すること、CASCADE 連鎖、マイグレーションが単一トランザクションであること
- [ ] reviewer 一次レビュー → コミット `feat: app.db スキーマv1と制約 (#6)`

### Task 3: ManagedFileStore 実装

**Files:**
- Create: `packages/Persistence/Sources/Persistence/ManagedFileStoreLive.swift`
- Test: `packages/Persistence/Tests/PersistenceTests/ManagedFileStoreTests.swift`

**正本:** architecture.md 7.3（パス解決の封鎖・保存手順1〜7・スコープ付きアクセス・属性の読み返し検証）、7.4（バックアップ除外）。Domain の `ManagedFileStore` プロトコルが契約。

- [ ] kind ごとのディレクトリ + fileID(UUID) 連結のみのパス解決。保存手順1〜7（同一ディレクトリの一時ファイル→書き込み前属性→書き込み→atomic rename→再属性→読み返し検証→失敗時は返さない）
- [ ] テスト: 保存後の `isExcludedFromBackup` が true であること（macOS でも検証可能）、rename 前中断で最終ファイルが現れないこと、スコープ付きアクセスの URL がスコープ外へ漏れない設計であること。`FileProtectionType` の実効検証は `#if os(iOS)` で分離
- [ ] reviewer 一次レビュー → コミット `feat: ManagedFileStore 実装 (#6)`

### Task 4: WorkingSourceStore / MaintenanceStore / StampStore 実装

**Files:**
- Create: `packages/Persistence/Sources/Persistence/WorkingSourceStoreLive.swift` / `MaintenanceStoreLive.swift` / `StampStoreLive.swift`
- Test: 対応する 3 テストファイル

**正本:** Domain の各ポート宣言（doc コメント含む）、architecture.md 7.5（StampAsset の内容ハッシュ主キー・参照カウント・PendingFileDeletion）、image-pipeline.md（WorkingSourceRecord の寿命）。

- [ ] 各ポートの全メソッドを実 GRDB + ManagedFileStore で実装（StampStore の importCustomStamp は SHA-256 一致時の既存実体再利用を含む）
- [ ] テスト: 各メソッドの正常系・境界（参照カウント 0 での PendingFileDeletion 積み・重複インポートの同一実体化・孤児 GC の候補列挙）
- [ ] reviewer 一次レビュー → コミット `feat: WorkingSource/Maintenance/StampStore 実装 (#6)`

### Task 5: ExportSagaStore 実装

**Files:**
- Create: `packages/Persistence/Sources/Persistence/ExportSagaStoreLive.swift`
- Test: `packages/Persistence/Tests/PersistenceTests/ExportSagaStoreTests.swift`

**正本:** export-saga.md（startExport の認可と ExportJob 作成、recordGeneratedOutput、settleExport / settleBatch の**単一トランザクション**での消費確定・ExportRecord 作成・WorkingSourceRecord 削除・ExportJob 削除、discardExport の物理削除、loadRunningJobs / deleteRunningJobs の起動時復旧）、architecture.md 6.3（UsageLedger の period 切替と ExportID 集合での消費）。

- [ ] 全メソッド実装。settle 系は 1 つの `DatabaseQueue.write` に閉じる
- [ ] テスト（test-plan 4.2）: settleExport / settleBatch の原子性（途中状態が観測されないこと）、成功後にのみ settledAt が確定すること、同一 exportID の再適用拒否、月跨ぎの period 切替が settle 時に行われること
- [ ] reviewer 一次レビュー → コミット `feat: ExportSagaStore 実装 (#6)`

### Task 6: OutputDeliveryStore / HistoryDeletionStore 実装

**Files:**
- Create: `packages/Persistence/Sources/Persistence/OutputDeliveryStoreLive.swift` / `HistoryDeletionStoreLive.swift`
- Test: 対応する 2 テストファイル

**正本:** export-saga.md 7章（DeliveryAttempt / UnknownLibrarySave / 孤立 attempt の解決・delivered の不可逆）、architecture.md 7.5（削除経路の単一化: DB 行削除 + PendingFileDeletion、HistoryUnit は Project のみ）。

- [ ] 全メソッド実装（deleteOutput は DB 行 + PendingFileDeletion の単一経路。delivered を後退させない）
- [ ] テスト: beginDeliveryAttempt〜complete/abandon の遷移、resolveOrphanedAttempts の復旧、削除の物理経路
- [ ] reviewer 一次レビュー → コミット `feat: OutputDelivery/HistoryDeletionStore 実装 (#6)`

### Task 7: プロトコル適合の共通スイート（test-plan 4.1）

**Files:**
- Create: `packages/Persistence/Tests/PersistenceTests/ConformanceSuites.swift`
- Modify: DomainTests のフェイク（private のまま流用できない場合、必要最小限のフェイクを PersistenceTests 内へ複製せず、共通の検証関数群として実装側スイートに整理する）

- [ ] 実装と（存在する範囲の）偽実装へ同じ検証を実行できる共通スイートを、少なくとも ExportSagaStore / OutputDeliveryStore / StampStore について用意する（フェイクとの完全一致検証が Application 層のフェイク整備後になる場合は、その旨を報告し実装側スイートのみで完了とする）
- [ ] reviewer 一次レビュー → コミット `test: 永続化ポートの適合スイート (#6)`

---

## Self-Review 済み事項

- Issue #6 完了条件との対応: スキーマ → T2、7 Store → T3〜T6、integration test → T2〜T7。CI キャッシュ（外部依存導入に伴う ci.yml の既存方針）→ T1
- test-plan 4.3 のうちインポート Saga 固有項目（手順1〜3 の補償・PickedPhotoInput 所有権）はサブプロジェクト5（SourceImportCoordinator）の担当で本計画対象外。ManagedFileStore 単体の属性・rename・GC 候補は T3 / T4 で扱う
- FileProtectionType の実効性は macOS の swift test で検証不能のため `#if os(iOS)` 分離とし、実機検証をサブプロジェクト11 へ委ねる（Global Constraints に明記）
- GRDB は Persistence の Package.swift のみに追加。Domain の Foundation-only は不変（check-imports / SwiftLint のゲートは既存のまま有効）
