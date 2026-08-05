# 書き出しフロー（Application 層 Coordinator）Implementation Plan (Issue #7)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** packages/Application に ExportCoordinator / StartupRecoveryCoordinator / OutputDeliveryCoordinator とグローバル直列実行キューを実装し、偽ストアによる状態機械テスト（test-plan.md 3章）を通してサブプロジェクト4を完了する。

**Architecture:** Application は Domain のプロトコルのみに依存する（architecture.md 4.3。実装は App 組み立て時に注入）。書き出しの認可・手順・中断後始末・起動時復旧の正本は export-saga.md。変更を伴う全操作は単一のグローバル直列キュー1本（並列数1）を経由し、actor の排他を根拠にしない（architecture.md 4.2）。Coordinator が消費する画像処理・受け渡しのプロトコル（ImageEffectRenderer / ImageEncoder / MediaSaver / SharePresenter 等）は Domain へ宣言を追加する（実装はサブプロジェクト5の MediaKit）。

**Tech Stack:** Swift 6（strict concurrency complete）、Foundation のみ（外部依存なし）、Swift Testing。

## Global Constraints

- 依存方向: Application は Foundation と Domain のみ import（check-imports.sh の許可リストは変更しない）。Domain への追加は Foundation のみ
- Domain へのプロトコル・型追加は正本（image-pipeline.md「プロトコルのシグネチャ」「@MainActor のプロトコル」、export-saga.md 7章の ShareResult）を一字一句転記する。正本に無いシグネチャが必要になったら実装せず差し戻す
- 裸の `Date()` 禁止。時刻は `@Sendable () -> Date` のクロック注入で受ける
- **actor であることを排他の根拠にしない**（architecture.md 4.2）。変更系操作はすべて Task 2 の SerialTaskQueue を経由する。exportID 別・projectID 別の個別キューは作らない
- `triage` の再導出を行わない。保存済みの確認状態をそのまま信頼する（ADR 0005）
- エラーの握りつぶし禁止。ストアの throw は利用者へのエラー提示まで伝播する
- テストは Swift Testing。偽ストア（FakeExportSagaStore 等）は ApplicationTests 内に置き、実 Persistence には依存しない（test-plan 3章冒頭）
- lint 制約: 変数名3文字以上（id 可）、ファイル先頭説明コメントは `//`、1行120文字以内、末尾カンマ禁止、テスト関数50行以内、ファイル400行以内、型本体250行以内、関数50行以内、引数5個以内、連続空行禁止。docs への参照は節名・見出し名で書く（行番号引用禁止）
- コミットは Conventional Commits、末尾に `(#7)`

---

### Task 1: Domain へ画像処理・受け渡しポートの宣言を追加

**Files:**
- Create: `packages/Domain/Sources/Domain/Ports/ImagePipeline.swift`（`ImageEffectRenderer` / `ImageEncoder` / `OutputMetadata`）
- Create: `packages/Domain/Sources/Domain/Ports/OutputPresentation.swift`（`MediaSaver` / `SharePresenter` / `ShareResult`）
- Create: `packages/Domain/Sources/Domain/Ports/OutputFileVerifier.swift`
- Test: `packages/Domain/Tests/DomainTests/Ports/ImagePipelinePortsTests.swift`

**正本:** image-pipeline.md「プロトコルのシグネチャ」（ImageEffectRenderer / ImageEncoder / MediaSaver）・「@MainActor のプロトコル」（SharePresenter）、export-saga.md 7章（ShareResult の4ケースと写像）、architecture.md 7.5（OutputMetadata は許可リスト構築。ICC 有無・ピクセル寸法・保持する場合の OriginalCaptureMetadata のみ）。

**Interfaces:**
- Produces: 上記プロトコル群。`OutputFileVerifier` は本計画の新設ポート:
  `func verify(_ file: OutputFileRef) async throws -> VerifiedOutputMeasurement`（存在・サイズ0でない・簡易デコード成功を検証し、`byteSize: Int64` と `sha256: Data` を返す。不成立は throw。export-saga.md 3章の手順3と `RecordOutputInput` の入力を1回の走査で賄う）
- `PickedPhotoLoader` / `FaceDetector` は追加しない（インポートフローはサブプロジェクト5。YAGNI）

- [ ] 正本のシグネチャを転記して宣言（doc コメントに正本の節名を明記）。構築可能性のテスト（各型が Sendable で構築でき、ShareResult の4ケースが Equatable であること）
- [ ] reviewer 一次レビュー → コミット `feat: Domainへ画像処理・受け渡しポートを宣言 (#7)`

### Task 2: SerialTaskQueue（グローバル直列実行キュー）

**Files:**
- Create: `packages/Application/Sources/Application/SerialTaskQueue.swift`
- Test: `packages/Application/Tests/ApplicationTests/SerialTaskQueueTests.swift`

**正本:** architecture.md 4.2（単一のグローバル直列キュー1本・並列数1・FIFO・読み取りは経由しない）。

**Interfaces:**
- Produces: `public actor SerialTaskQueue { public func run<T: Sendable>(_ op: @Sendable @escaping () async throws -> T) async throws -> T }`。enqueue は actor 内で同期的に tail を差し替えて FIFO を保証する（`await` を挟まず tail を読んで更新する。前のタスクの完了を待ってから op を実行する連結方式）

- [ ] 実装: `private var tail: Task<Void, Never>?` への連結。キャンセルされた op が後続を巻き込まないこと（tail は失敗を握らず完了だけを伝える。op のエラーは呼び出し元へそのまま throw）
- [ ] テスト: 並列に投入した操作が投入順に1件ずつ実行されること（同時実行数が常に1であることをカウンタで検証）、途中の throw が後続の実行を妨げないこと
- [ ] reviewer 一次レビュー → コミット `feat: グローバル直列実行キュー (#7)`

### Task 3: 偽ストア・偽パイプラインのテスト支援

**Files:**
- Create: `packages/Application/Tests/ApplicationTests/Fakes/FakeExportSagaStore.swift` / `FakeOutputDeliveryStore.swift` / `FakeWorkingSourceStore.swift` / `FakeManagedFileStore.swift`
- Create: `packages/Application/Tests/ApplicationTests/Fakes/FakeImagePipeline.swift`（FakeImageEffectRenderer / FakeImageEncoder / FakeOutputFileVerifier / FakeStampRasterizer / FakeMediaSaver / FakeSharePresenter / FakeStampCatalog）

**正本:** Domain の各ポート宣言の doc コメント（事前条件・冪等性・トランザクション境界）。偽実装はその契約を in-memory で忠実に再現する（例: FakeExportSagaStore は settleExport の事前条件検査・二重確定拒否・discardExport の冪等を再現し、呼び出し履歴を記録する）。

- [ ] 各偽実装は「呼び出し記録」「注入可能な失敗」「in-memory 状態」を持つ。ExportSagaStore の偽実装は台帳カウンタを持ち、消費が起きたか検証できる形にする
- [ ] reviewer 一次レビュー → コミット `test: Application の偽ストア群 (#7)`

### Task 4: ExportCoordinator — 認可と開始（export-saga.md 1章）

**Files:**
- Create: `packages/Application/Sources/Application/ExportRequest.swift`（開始入力の型）
- Create: `packages/Application/Sources/Application/ExportCoordinator.swift`（actor 本体と開始経路）
- Test: `packages/Application/Tests/ApplicationTests/ExportCoordinatorStartTests.swift`

**正本:** export-saga.md 1.1〜1.6（検査の順序・1.1 の一致条件・authorizeRenderSpec・WorkingSourceRecord の実体確認・blocked で ExportJob を作らない・expectedProjectRevision）、test-plan.md 3.1。

**Interfaces:**
- Produces: `public struct SingleExportRequest: Sendable`（projectID / renderSpec / exportSetting / previewConfirmation / 現在の detectionRevision・previewRenderHash / 保存済み確認状態の要約（全 ReviewIssue が確定済みか）/ expectedProjectRevision）。バッチ用は Task 7 で拡張
- Produces: `public enum ExportStartOutcome: Sendable`（blocked(ExportStartBlock) / renderSpecBlocked(RenderSpecBlockReason) / confirmationMismatch / workingSourceMissing / started(ExportJob)）
- Consumes: SerialTaskQueue（Task 2）、Domain の resolveCapabilities / authorizeRenderSpec / StampCatalog

- [ ] 1.6 の順序で実装: 1.1 一致検査 → 1.2 能力（authorizeRenderSpec。免除条件は startExport 内の評価に委ねる）→ 実体確認（ManagedFileStore.withReadAccess での存在確認）→ 1.3 は startExport が評価（ExportStartDecision.blocked を outcome へ写像）
- [ ] テスト（test-plan 3.1）: 検査順序、各不成立で startExport が呼ばれない・ExportJob が作られないこと、triage 再導出をしないこと、実体欠損で invalidateWorkingSource が呼ばれ再選択導線 outcome になること、revision 不一致の throw が伝播すること
- [ ] reviewer 一次レビュー → コミット `feat: ExportCoordinator の認可と開始 (#7)`

### Task 5: ExportCoordinator — 生成と中断後始末（export-saga.md 3〜4章）

**Files:**
- Create: `packages/Application/Sources/Application/ExportCoordinator+Generate.swift`
- Test: `packages/Application/Tests/ApplicationTests/ExportCoordinatorGenerateTests.swift` / `ExportCoordinatorDiscardTests.swift`

**正本:** export-saga.md 3章（手順1〜4: レンダリング→出力ファイル作成→健全性確認→recordGeneratedOutput。生成は無消費）、4章（中断・やり直し・破棄は discardExport の一律後始末。temporaryFiles の受け渡し）、test-plan.md 3.1 後半・3.3。

- [ ] 生成: compileRenderDraft / bindRasterAssets → ImageEffectRenderer.render → ImageEncoder.encode → OutputFileVerifier.verify → recordGeneratedOutput（verify の byteSize / sha256 を RecordOutputInput へ）。全工程 SerialTaskQueue 上で実行
- [ ] 中断: 生成失敗・健全性不成立・キャンセル・やり直しの各契機で discardExport（temporaryFiles にラスタ一時ファイル等の参照を渡す）。冪等の再現
- [ ] テスト: 生成完了時点で OutputRecord(settledAt: nil) と出力ファイルのみが作られ、台帳・ExportRecord・キュー・WorkingSourceRecord に触れないこと（偽ストアの記録で検証）。破棄後も台帳が不変で WorkingSourceRecord が残り再レンダリングできること。破棄回数に制限が無いこと
- [ ] reviewer 一次レビュー → コミット `feat: ExportCoordinator の生成と中断後始末 (#7)`

### Task 6: ExportCoordinator — 完了操作と実体喪失（export-saga.md 3章手順5・6章）

**Files:**
- Create: `packages/Application/Sources/Application/ExportCoordinator+Settle.swift`
- Test: `packages/Application/Tests/ApplicationTests/ExportCoordinatorSettleTests.swift`

**正本:** export-saga.md 3章（settleExport / settleBatch は store の単一トランザクションへ委譲。ここが唯一の確定境界）、6章（確定後の実体喪失: verify 不一致で OutputRecord を物理削除、台帳不変、自動再生成なし）、test-plan.md 3.2・3.4。

- [ ] settleExport / settleBatch の呼び出し（SerialTaskQueue 経由。settledAt はバッチのみクロックから渡す）。store の throw（二重確定・0件 throw 等）を伝播
- [ ] 実体喪失の検査経路: 完了済み出力の提示前に OutputFileVerifier で byteSize / sha256 を照合し、不一致なら deleteOutput 相当の削除（OutputDeliveryStore.deleteOutput）＋利用者へ「復元できない・新しい書き出しになる」outcome
- [ ] テスト: 二重 settle で消費が重複しないこと（偽ストアの拒否を伝播）、実体喪失時に UsageLedger が不変であること
- [ ] reviewer 一次レビュー → コミット `feat: ExportCoordinator の完了操作と実体喪失 (#7)`

### Task 7: ExportCoordinator — バッチ進行（1.5 の権限変化・直列1件）

**Files:**
- Create: `packages/Application/Sources/Application/ExportCoordinator+Batch.swift`
- Test: `packages/Application/Tests/ApplicationTests/ExportCoordinatorBatchTests.swift`

**正本:** export-saga.md 1.1（バッチの開始条件: BatchReviewState と モード別条件）・1.5（開始済みは開始時の権限で完了、未認可は開始せず paused）、Domain の QueueMachine / ExportQueueState、test-plan.md 3.1 のバッチ項目。

- [ ] キュー項目の逐次処理（1件ずつ SerialTaskQueue 経由で開始〜生成）。各写真の開始時に 1.1 のバッチ条件を検査。開始時点の認可を ExportJob に固定し、途中の権限変化で waiting を開始せずバッチを paused にする
- [ ] テスト: 同時に処理中の ExportJob が常に1件までであること、権限喪失後に running が完了し waiting が開始されないこと、おまかせ一括（overviewConfirmed）と1枚ずつ確認（全 ReviewDecision 確定）の開始条件
- [ ] reviewer 一次レビュー → コミット `feat: ExportCoordinator のバッチ進行 (#7)`

### Task 8: OutputDeliveryCoordinator（export-saga.md 7章）

**Files:**
- Create: `packages/Application/Sources/Application/OutputDeliveryCoordinator.swift`
- Test: `packages/Application/Tests/ApplicationTests/OutputDeliveryCoordinatorTests.swift`

**正本:** export-saga.md 7章（保存手順1〜4の DeliveryAttempt、共有は attempt を作らない、ShareResult の写像、delivered を後退させない、deleteOutput、グローバルキュー共有）、test-plan.md 3.2 の受け渡し項目・3.6 の受け渡し状態項目。

- [ ] 保存: beginDeliveryAttempt → MediaSaver.saveToPhotoLibrary → 成功で completeLibrarySave / 失敗で abandonDeliveryAttempt（全工程 SerialTaskQueue 経由。attempt 存在中の共有・破棄・別保存の拒否は store の throw を伝播）
- [ ] 共有: SharePresenter.share の ShareResult を写像（.completed のみ completeShare。canceled / failed / unknown は状態維持）
- [ ] 破棄: deleteOutput の伝播（事前条件違反の throw を含む）
- [ ] テスト: 保存成否と枠の無関係（追加消費なし・再試行可能）、settledAt == nil への保存・共有が throw すること、delivered の不可逆、保存失敗で previousState へ戻ること
- [ ] reviewer 一次レビュー → コミット `feat: OutputDeliveryCoordinator (#7)`

### Task 9: StartupRecoveryCoordinator（export-saga.md 5章）

**Files:**
- Create: `packages/Application/Sources/Application/StartupRecoveryCoordinator.swift`
- Test: `packages/Application/Tests/ApplicationTests/StartupRecoveryTests.swift`

**正本:** export-saga.md 5章（復旧手順1〜5の順序）、architecture.md 4.3（起動時に1回のみ・完了まで他のすべてを開始させない）、test-plan.md 3.5・3.6 の復旧案内項目。

**Interfaces:**
- Produces: `public struct StartupRecoveryReport: Sendable`（resolveOrphanedAttempts の OutputDeliverySnapshot 配列・UnknownLibrarySave 配列・削除した running ジョブ数。復旧案内 UI の入力）
- Produces: 復旧完了ゲート: `public func awaitRecoveryCompleted() async` を ExportCoordinator の開始経路が待つ（復旧完了まで新規書き出しを開始させない）

- [ ] 手順を順序どおり実装: loadRunningJobs → deleteRunningJobs →（孤児 GC は MaintenanceStore の担当のため呼び出しのみ。実装はサブプロジェクト3で済み）→ resolveOrphanedAttempts → loadUnknownLibrarySaves → report 生成。更新誘導（手順5）はサブプロジェクト10 の対象のため呼び出し点だけ設ける
- [ ] テスト（test-plan 3.5）: 実行順序（偽ストアの呼び出し記録で検証）、完了済み出力に触れないこと、previousState による解決（generated → deliveryUnknown / delivered 維持＋注記）、復旧完了までの開始ゲート、report が snapshot を使うこと
- [ ] reviewer 一次レビュー → コミット `feat: StartupRecoveryCoordinator (#7)`

---

## Self-Review 済み事項

- Issue #7 完了条件との対応: 3 Coordinator → T4〜T9、直列実行キュー → T2、生成無消費〜settle 確定 → T5・T6、偽ストアの状態機械・起動時復旧テスト → T3〜T9
- test-plan 3章の対応: 3.1 → T4・T5・T7、3.2 → T6・T8、3.3 → T5、3.4 → T6、3.5 → T9、3.6 のうち受け渡し状態・復旧案内 → T8・T9
- 対象外（担当サブプロジェクトを明記）: 3.6 の履歴削除系（HistoryDeletionCoordinator はサブプロジェクト10）、3.2「完了操作付近の文言表示」（UI。サブプロジェクト6）、孤児 GC の実装（サブプロジェクト3で完了済み。T9 は呼び出しのみ）、更新誘導の実装（サブプロジェクト10）
- Domain へ追加する宣言は Coordinator が消費するものに限定（PickedPhotoLoader / FaceDetector はサブプロジェクト5 で追加）。check-imports の許可リストは不変
- 型整合: ExportStartOutcome は Domain の ExportStartBlock / RenderSpecBlockReason を包む（再定義しない）。VerifiedOutputMeasurement の byteSize / sha256 は RecordOutputInput の outputByteSize / outputSHA256 と同型
