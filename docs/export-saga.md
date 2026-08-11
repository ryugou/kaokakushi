# 書き出し Saga

| 項目 | 内容 |
| --- | --- |
| 目的 | 書き出しの認可、状態遷移、処理順、中断時の後始末、起動時復旧を一意に定める |
| 読者 | `Application` 層の実装者 |
| 正本の範囲 | `ExportJob` / `OutputRecord` の型、手順、中断・やり直し・破棄の後始末、起動時復旧、受け渡し |
| 関連 | [アーキテクチャ設計](architecture.md)、[ADR 0005](adr/0005-drop-tamper-resistance-backend-and-heavy-fault-tolerance.md)（改ざん対抗・耐障害機構の簡素化）、[ADR 0006](adr/0006-accounting-per-delivered-output.md)（会計境界＝完了操作） |

`UsageLedger`・書き出しジョブ・`OutputRecord` はすべて `app.db` の平文行である（[ADR 0005](adr/0005-drop-tamper-resistance-backend-and-heavy-fault-tolerance.md)）。会計・出力の公開・ジョブの完了は**単一の SQLite トランザクション**で原子的に確定する。書き出しは直列実行キュー1本（並列数1）で処理し、**手順1〜3を処理中のジョブは常に0件か1件**。生成済み・確認待ち（`OutputRecord.settledAt == nil`）の `ExportJob` は、バッチでは複数同時に存在しうる（結果一覧の完了操作までは全件が確認待ちのまま）。

**生成と完了は別の操作である**（[ADR 0006](adr/0006-accounting-per-delivered-output.md)）。生成は出力ファイルと確認用の `OutputRecord` を作るだけで、枠・クレジットは一切消費しない。消費が起こるのは、利用者が出力確認画面で明示的に完了操作を行った時点（`settleExport` / `settleBatch`）だけである。

---

## 0. Application が使う永続化ポート

`Application` は `Domain` のプロトコルだけを使う（[アーキテクチャ設計](architecture.md) の 4.3）。

```swift
// Domain — Foundation のみ

protocol ExportSagaStore: Sendable {
    /// 認可を評価し ExportJob を挿入する（1 章）。expectedProjectRevision と不一致なら throw
    func startExport(_ input: StartExportInput, expectedProjectRevision: Int64) async throws -> ExportStartDecision
    /// 確認用の OutputRecord(settledAt: nil) を作成する（3 章）。同じ projectID の未確定 OutputRecord が
    /// 既に存在すれば throw（部分 UNIQUE 制約。詳細は 3 章）。台帳・ExportRecord・キュー・WorkingSourceRecord には触れない
    func recordGeneratedOutput(_ input: RecordOutputInput) async throws
    /// 完了（単体専用。ExportJob.batchID == nil でなければ throw）。単一トランザクションで、台帳の加算または
    /// トライアルクレジットの消費・settledAt の確定・ExportRecord の作成・confirmed 設定エントリの更新・
    /// キュー項目の completed 更新・WorkingSourceRecord の削除を行う（3 章）。ここが唯一の確定境界。
    /// 削除する WorkingSourceRecord の WorkingSourceFileRef は同一トランザクションで PendingFileDeletion へ
    /// 登録する（実削除はコミット後、失敗時は起動時再試行。削除経路の正本はアーキテクチャ設計 7.5）。最後に ExportJob を削除する
    func settleExport(_ exportID: ExportID) async throws
    /// 完了（バッチ）。対象 batchID の未確定 OutputRecord をすべて対象に、settleExport と同じ内容
    /// （WorkingSourceRecord 削除に伴う PendingFileDeletion 登録を含む）を単一トランザクションで一括確定する。
    /// settledAt は呼び出し側が渡した時刻で全件に統一する。事前条件は 3 章
    func settleBatch(_ batchID: BatchID, settledAt: Date) async throws
    /// 失敗・キャンセル・やり直し・中断。ExportJob 行を削除する。対応する OutputRecord が存在すれば
    /// 同一トランザクションで削除し、その出力ファイル（存在すれば）と temporaryFiles（手順 1〜3 で
    /// 生成した一時ファイル。呼び出し元の生成パイプラインが保持する参照を渡す）を
    /// PendingFileDeletion へ登録する（実削除はコミット後。削除経路の正本はアーキテクチャ設計 7.5）。
    /// WorkingSourceRecord は削除しない（4 章）。台帳は未確定のため触れない。
    /// ExportJob 行が無ければ何もしない（temporaryFiles の登録も行わない。冪等）
    func discardExport(_ exportID: ExportID, temporaryFiles: [ManagedFileRef]) async throws
    /// 起動時復旧の入力（5 章）
    func loadRunningJobs() async throws -> [ExportJob]
    /// 起動時復旧。ExportJob 行と、対応する未確定（settledAt IS NULL）OutputRecord をまとめて削除する（5 章）
    func deleteRunningJobs(_ exportIDs: [ExportID]) async throws
}

/// 受け渡し（7 章）。ExportSagaStore とは寿命が異なるため分ける
protocol OutputDeliveryStore: Sendable {
    /// previousState を記録する。事前条件: settledAt != nil（nil なら throw）
    func beginDeliveryAttempt(_ exportID: ExportID) async throws
    /// delivered への更新と attempt 削除を単一トランザクションで
    func completeLibrarySave(_ exportID: ExportID) async throws
    /// 事前条件: settledAt != nil（nil なら throw）、かつ対象の DeliveryAttempt が
    /// 存在しないこと（7.0。試行中の共有は拒否する）
    func completeShare(_ exportID: ExportID) async throws
    /// previousState へ戻す（現在が delivered なら維持）
    func abandonDeliveryAttempt(_ exportID: ExportID) async throws
    /// 起動時。残存 attempt を previousState に応じて解決し、解決後の全出力の受け渡し状態を返す（単一トランザクション）
    func resolveOrphanedAttempts() async throws -> [OutputDeliverySnapshot]
    func loadUnknownLibrarySaves() async throws -> [UnknownLibrarySave]
    func clearUnknownLibrarySave(_ exportID: ExportID) async throws
    /// 完了後の出力を利用者が明示的に破棄する（状態遷移ではない）。DB トランザクションで OutputRecord を
    /// 削除し、同一トランザクションで実体ファイルを PendingFileDeletion へ登録する。実削除はコミット後、
    /// 失敗時は起動時再試行する（削除経路の正本はアーキテクチャ設計 7.5）。UnknownLibrarySave があれば
    /// FK CASCADE で消える。事前条件: settledAt != nil（完了前のやり直しは discardExport を使う）、
    /// かつ対象の DeliveryAttempt が存在しないこと（7.0。試行中の破棄は拒否する）
    func deleteOutput(_ exportID: ExportID) async throws
}

/// 「変更せず再書き出し」免除の判定に使う確定記録の読み取り（1.2）。書き込みは
/// settleExport / settleBatch が単一トランザクション内で直接行うためこのポートには含めない。
/// `ExportedSettingsEntry` の定義はアーキテクチャ設計 6.3
protocol ExportedSettingsEntryStore: Sendable {
    /// 当該 projectID の確定記録を返す（無ければ nil）
    func loadEntry(for projectID: ProjectID) async throws -> ExportedSettingsEntry?
}

/// 出力ファイルの健全性を確認し、記録用の測定値を返す（3 章 手順3・6 章）。存在確認・
/// サイズ 0 でないこと・簡易デコード成功の3検査を1回の走査で賄う
protocol OutputFileVerifier: Sendable {
    func verify(_ file: OutputFileRef) async throws(OutputFileVerificationError) -> VerifiedOutputMeasurement
}
/// `.ioFailure` は一時的な障害であり健全性の否定ではない。6 章の削除判定の根拠にしない
enum OutputFileVerificationError: Error, Sendable, Equatable {
    case missing, emptyFile, undecodable, ioFailure
}
struct VerifiedOutputMeasurement: Sendable {
    let byteSize: Int64
    let sha256: Data
}

struct ExportQueueItemID: Sendable, Hashable { let rawValue: UUID }
/// 出力の縦横比（仕様の 元比率 / 1:1 / 4:5 / 9:16）
enum OutputAspect: Sendable, Hashable {
    case original, square, fourFive, nineSixteen
}
/// 出力メタデータの扱い
struct MetadataPolicy: Sendable, Equatable {
    let removeLocation: Bool
    let removeDeviceInfo: Bool
    let removeSoftwareInfo: Bool
    let keepCaptureDate: Bool
}
/// 出力形式・画質・メタデータ設定。フィールドは `ProjectSettingsHash` の 5〜8 と一致する
/// （正準バイト表現と enum の固定番号は [正準スキーマ](canonical-schema.md) の 5.2 が正本）
struct ExportSetting: Sendable, Equatable {
    let outputAspect: OutputAspect
    let outputFormat: ImageFormat         // 宣言は [画像処理](image-pipeline.md)
    let compressionQuality: Double
    let metadataPolicy: MetadataPolicy
}
/// 手順 0 の入力
struct StartExportInput: Sendable {
    let projectID: ProjectID
    let batchID: BatchID?
    let queueItemID: ExportQueueItemID?   // 単体書き出しでは nil
    let renderSpec: RenderSpec
    let exportSetting: ExportSetting
    let previewConfirmation: PreviewConfirmation   // 1.1
}
/// 手順4（生成）の入力。ExportJob から導出できない値だけを渡す
struct RecordOutputInput: Sendable {
    let exportID: ExportID
    let outputFile: OutputFileRef
    let outputByteSize: Int64
    let outputSHA256: Data
}
enum ExportStartDecision: Sendable {
    case blocked(ExportStartBlock)
    case authorized(ExportJob)
}
// OutputDeliverySnapshot の定義はアーキテクチャ設計 7.5
```

`recordGeneratedOutput` と `settleExport` / `settleBatch` は `ExportJob` に保存済みの `authorization`・`delivery`・`settingsHash`（`startExport` 時点の値を `ExportJob` が保持する。[アーキテクチャ設計](architecture.md) の 7.1 が正本）から必要な値を導出する。呼び出し側から渡すのは `ExportJob` から導出できない値（`exportID` と生成結果）だけ。

そのほかのポート（`ManagedFileStore` / `CrashReporter` / 履歴削除の原子的操作）は [アーキテクチャ設計](architecture.md) が正本。

---

## 1. 認可

認可は 1.1（確認の一致）と 1.2（能力）の検査、および 1.3（権限・クォータ）の評価を、開始時に一度だけ行う。いずれか不成立なら開始しない。`ExportJob` が存在する間、対象 `Project` の編集を禁止する（2 章）ため、開始後に設定が変わる経路は無い。

### 1.1 確認済みの設定でのみ書き出す

検出漏れはアプリ側で判定できないため、利用者が加工後プレビューを確認したことが安全性の前提（[アーキテクチャ設計](architecture.md) の 6.1）。確認の対象を型で固定する。

```swift
/// 利用者が確認したプレビューの同一性
struct PreviewConfirmation: Sendable, Equatable {
    let projectID: ProjectID
    let detectionRevision: Int64      // 再検出ごとに増える
    let previewRenderHash: PreviewRenderHash
}
/// バッチ一覧の確認状態を batchID と結び付けて保持する
struct BatchReviewState: Sendable, Equatable {
    let batchID: BatchID
    let overviewConfirmed: Bool
}
```

| 処理 | 開始条件 |
| --- | --- |
| 単体 | 現在の `projectID` / `detectionRevision` / `previewRenderHash` が `PreviewConfirmation` とすべて一致し、保存済みの `ReviewDecision` が検出済みの全 `ReviewIssue` を確定していること |
| バッチ | 各写真について上記が一致し、`BatchReviewState.batchID` が対象バッチと一致し、かつモードごとの条件（おまかせ一括は `overviewConfirmed == true`、1 枚ずつ確認は全写真で `ReviewDecision` が確定済みであること）を満たす |

保存済みの `ReviewDecision` をそのまま信頼し、`triage` を再実行して独立に再検証することはしない（利用者自身による端末内データの改変には対抗しない。[ADR 0005](adr/0005-drop-tamper-resistance-backend-and-heavy-fault-tolerance.md)）。

`projectID` を含めるのは `PreviewRenderHash` が `Project` を特定しないため。`detectionRevision` を含めるのは再検出後の顔集合差し替えを検出するため。`Project.projectRevision` は別途、手順 0 で `ExportJob` の insert と同一トランザクションで比較する（変わっていれば insert が失敗し、開始しない）。

### 1.2 設定内容の能力

編集画面の `canEdit` は UI 側の制約でしかなく、書き出しは DB の内容を直接の入力とするため、認可の側でも同じ規則を評価する。

```swift
/// RenderSpec が使う能力を抽出し、現在の能力で許されるかを判定する純粋関数
func authorizeRenderSpec(_ spec: RenderSpec, stampCatalog: StampCatalog, capabilities: ResolvedCapabilities) -> RenderSpecAuthorization

enum RenderSpecAuthorization: Sendable, Equatable {
    case authorized
    case blocked(RenderSpecBlockReason)
}
enum RenderSpecBlockReason: Sendable, Equatable {
    case premiumStampNotAvailable      // canUsePremiumStamps == false
    case customStampNotAvailable       // canUseCustomStamps == false
    case unknownBuiltInStampCode       // カタログに無い code
}
/// 組み込みスタンプの分類。アプリにハードコードし、リモート設定から変更できない（ADR 0005）
protocol StampCatalog: Sendable {
    func requirement(forBuiltIn code: String) -> StampRequirement?
}
enum StampRequirement: Sendable, Hashable {
    case free, premium(packID: String), custom, unknownBuiltIn
}
```

| `RenderSpec` に含まれる値 | 必要な能力 |
| --- | --- |
| `RenderOpSpec.mosaic` / `.blur` / `.solid` | なし |
| `RenderOpSpec.stamp(.builtIn(code))` で `requirement == .free` | なし |
| `RenderOpSpec.stamp(.builtIn(code))` で `requirement == .premium` | `canUsePremiumStamps`（`enabledStampPacks` は見ない。下記） |
| `RenderOpSpec.stamp(.custom(assetHash))` | `canUseCustomStamps` |

`enabledStampPacks` は認可の判定に使わない（同梱パックの構成変更はアプリ更新で行い、既存プロジェクトの再書き出しを妨げない。UI のスタンプ選択では見るが `authorizeRenderSpec` では見ない）。

`blocked` の遷移先: `premiumStampNotAvailable` / `customStampNotAvailable` は対応する `UpgradeReason` の Paywall を提示する。`unknownBuiltInStampCode` は Paywall を提示せず、「使えないスタンプが含まれています」のエラーで差し替えを促す（課金しても解消しないため）。

##### 「変更せず再書き出し」の免除

これは**有料スタンプの能力要件だけを免除する規則であり、月間枠やトライアルクレジットの消費は免除しない**。降格後も、次のすべてを満たす場合に `authorizeRenderSpec` の能力判定だけを免除する（[アーキテクチャ設計](architecture.md) の 6.2）。

| 条件 | 内容 |
| --- | --- |
| 確定記録の存在 | `ExportedSettingsEntry` に当該 `projectID` の項目がある |
| 設定の一致 | その項目の `settingsHash` が、いま組み立てた `RenderSpec` と `ExportSetting` から計算した値と一致する |
| 対象 | 同一 `Project` であること（素材の同一性は照合しない） |
| 適用範囲 | 有料スタンプの能力要件のみ。月間枠・トライアルクレジットの消費は通常どおり発生する |

確定記録の書き込みは完了操作（`settleExport` / `settleBatch`。3 章）が単一トランザクション内で直接行う。読み取りは `ExportedSettingsEntryStore.loadEntry`（0 章）を使う。免除の判定自体は **Application 層**が `loadEntry` の結果と、いま組み立てた `RenderSpec` / `ExportSetting` から計算した `settingsHash` を比較して行う（`authorizeRenderSpec` 自体は免除を評価しない）。

### 1.3 権限とクォータ

```swift
struct ExportAuthorization: Sendable {
    let entitlementSnapshot: Entitlement
    let accountingMode: ExportAccountingMode
    let authorizedAt: Date
}
enum ExportStartBlockReason: Sendable, Equatable {
    case monthlyLimitReached, trialCreditsUnavailable
    case capabilityVerificationRequired   // entitlementSnapshot.verificationRequired、
                                          // または開始時点の能力が勘定の前提（proBatch の
                                          // canUseProBatch）を満たさない（1.5 の store 側ゲート）。
                                          // batchTrial は能力ゲートでブロックしない（作成時の
                                          // 可否は canEnterBatch が担う）。ただし開始時点で
                                          // canUseProBatch を持つ（Pro 加入済み）なら
                                          // クレジットを消費せず paidUnlimited で認可する
                                          // （architecture.md 6.3「Pro へ加入済みの場合は
                                          // 消費しない」。アップグレード後もバッチを中断させない）
}
struct ExportStartBlock: Sendable, Equatable {
    let reason: ExportStartBlockReason
    let limit: Int?
}
/// ADR 0006: 勘定の単位は「受け渡した成果物」。素材の同一性は使わない
enum ExportAccountingMode: Sendable, Equatable {
    case paidUnlimited
    case freeMonthlyConsume
    case batchTrial
}
```

書き出し開始時点で利用権限と勘定を確定し、`ExportJob.authorization` に固定する。`blocked` なら `ExportJob` を作らず、生成も開始しない。**この時点では何も消費しない。** 消費は完了操作（3 章の手順5）で初めて発生する。

### 1.4 勘定の使い分け

| 勘定 | 月間枠 | トライアル台帳 |
| --- | --- | --- |
| `paidUnlimited` | 使わない | 使わない |
| `freeMonthlyConsume` | 1 消費 | 使わない |
| `batchTrial` | 使わない | 1 消費 |

**トライアルバッチ（`kind == .trial`）でも、開始時点で `canUseProBatch` を持つ場合は `batchTrial` ではなく `paidUnlimited` として認可する**（クレジットを消費しない。Pro へアップグレード後もバッチを中断させないため。1.3 の `ExportStartBlockReason` の注記が正本）。

月間クォータを使うのは Free の単体処理だけ（Free 利用者が月 5 枚を使い切っていても、クレジットが残っていれば一括トライアルを実行できる）。`batchTrial` は選択した写真ごとに毎回 1 クレジットを消費する。素材が過去に処理済みかどうかによる例外は無い（[ADR 0006](adr/0006-accounting-per-delivered-output.md)。同じ写真を選び直しても新しい加工として扱う）。

消費は完了操作でのみ発生するため、完了前のやり直し（4 章）に免除や返還という概念は存在しない。まだ何も消費していないものを免除する対象が無いからである。

### 1.5 開始後の権限変化

開始後に有料契約の失効・月間上限への到達が起きても、その書き出しは開始時の権限（`ExportJob.authorization`）で完了させる。開始済みの写真は開始時の認可のまま完了させる。まだ認可されていない写真は開始せず、バッチを `paused` にする。

### 1.6 開始の順序

直列実行キュー1本（並列数1）が同時実行を構造的に防ぐため、専用の排他ゲートや素材単位のロックは不要。

1. 確認の一致を検査する（1.1）。不一致なら終える
2. 設定内容の能力を検査する（1.2）。`blocked` なら終える
3. `WorkingSourceRecord` の実体（ファイルの存在）を確認する（[画像処理](image-pipeline.md)）。無ければ無効化して再選択導線へ倒し、終える。素材参照は `projectID` を介した `WorkingSourceRecord` を使う（素材の同一性照合は行わない。ADR 0006）
4. 権限とクォータを評価する（1.3）。`.blocked` ならここで終える
5. `startExport` で `ExportJob` を挿入する（`expectedProjectRevision` つき）。revision が変わっていれば失敗し、終える
6. 処理を開始する（3 章）

---

## 2. `ExportJob` と `OutputRecord`

```swift
struct ExportJob: Sendable {
    let exportID: ExportID
    let projectID: ProjectID
    let batchID: BatchID?
    let queueItemID: ExportQueueItemID?      // 単体書き出しでは nil。手順 0 で固定する
    let authorization: ExportAuthorization   // 開始時に固定する（1.5）
    let delivery: OutputDeliveryDescriptor   // 認可時に確定。生成時に OutputRecord へコピーする
}
struct OutputDeliveryDescriptor: Sendable {
    let format: ImageFormat
    let suggestedCreationDate: Date?
}
```

`ExportJob` は状態を表すフィールドを持たない。**行の存在そのものが「生成中、または生成済みで完了操作の確認待ち」を表す。** 完了操作（`settleExport` / `settleBatch`）または破棄（`discardExport`）のどちらかで行が削除され、以降は存在しない。`ExportJob` が存在する間、対象 `Project` の編集を禁止する。

ライフサイクルの実体は `OutputRecord.settledAt` が担う。`nil` の間は未確定（`ExportJob` もまだ存在する）。完了操作で `nil` でなくなると同時に `ExportJob` が削除され、以降は `OutputRecord` だけが残る。`OutputRecord` の完全な定義は 3 章にある。

| `ExportJob` | `OutputRecord.settledAt` | 意味 |
| --- | --- | --- |
| 存在する | まだ存在しない | レンダリング中（手順 1〜3） |
| 存在する | `nil` | 生成済み。出力確認画面で完了操作またはやり直し待ち |
| 存在しない | 非 `nil` | 完了済み |

---

## 3. 手順

| 順 | 操作 | 保存先 | 結果 |
| --- | --- | --- | --- |
| 0 | 認可を評価し、`ExportJob` を保存する（1 章） | DB | `ExportJob` 作成 |
| 1 | レンダリングし、一時ファイルへ出力する | ファイルシステム | — |
| 2 | 一時ファイルを出力ディレクトリへ移動する | ファイルシステム | — |
| 3 | 出力ファイルの健全性を確認する（下記） | ファイルシステム | — |
| 4 | `recordGeneratedOutput` で確認用の `OutputRecord`（`settledAt: nil`）を作成する。台帳・`ExportRecord`・キュー・`WorkingSourceRecord` には触れない | DB | 確認用 `OutputRecord` 作成 |
| 5（settle） | **単一トランザクション**。`ExportJob.authorization.accountingMode` に従って台帳を加算またはトライアルクレジットを消費、`settledAt` の確定、`ExportRecord` の作成、confirmed 設定エントリの更新、キュー項目の `completed` 更新、`WorkingSourceRecord` の削除、`ExportJob` の削除を行う。ここが唯一の確定境界 | DB | 完了 |

```
ExportJob 作成 → レンダリング・移動・健全性確認（DB 上の状態変化なし）
  → 手順4: 確認用 OutputRecord 作成（未確定。出力確認画面へ）
  → 完了操作（手順5・settle）→ ExportJob 削除、OutputRecord が確定して残る
```

手順4と手順5の間、成果物は非公開の確認用出力である。検証済みファイルは、手順5が完了するまで UI・`MediaSaver`・`SharePresenter` へ公開しない（7 章）。

手順5で削除する `WorkingSourceRecord` の実体ファイルは、同一トランザクション内で `PendingFileDeletion` へ登録する。実際のファイル削除はトランザクションのコミット後に行い、失敗すれば起動時の GC で再試行する（削除経路の正本は [アーキテクチャ設計](architecture.md) の 7.5。「出力の削除経路」と同じ単一経路を使う）。

**手順3（健全性確認）**: 存在確認だけでは不足する（0 バイトのファイル、途中まで書かれたファイル、デコードできないファイルも「存在する」ため）。`OutputFileVerifier.verify`（0 章）を1回呼び、ファイルが存在すること・サイズが 0 でないこと・簡易デコードが成功することを確認し、成功時は手順4が使う `outputByteSize` / `outputSHA256` を得る。3検査のいずれかが不成立の場合、または一時的な I/O 障害（`.ioFailure`）で確認そのものに失敗した場合のいずれでも、手順 4 へ進まず中断として扱う（4 章）。ただし `.ioFailure` は健全性の否定ではないため、6 章（確定後の実体喪失判定）では削除の根拠にしない。

**手順4（生成）の内容**:

```swift
struct OutputRecord: Sendable {
    let exportID: ExportID
    let projectID: ProjectID
    let batchID: BatchID?
    let outputFile: OutputFileRef
    let outputByteSize: Int64
    let outputSHA256: Data
    let state: OutputState
    let generatedAt: Date             // 生成完了時刻。settle の前後で不変
    let settledAt: Date?              // settle（手順5）で確定する。nil の間は無期限に保護されない
    let expiresAt: Date?              // settledAt + 24h。settle 時に確定する。settledAt が nil の間は nil
    let format: ImageFormat
    let suggestedCreationDate: Date?
}
```

実装は `recordGeneratedOutput` の中で次を確認する（不成立なら throw し、手順 4 を実行しない）。同じ `projectID` の**未確定**（`settledAt IS NULL`）の `OutputRecord` が存在しない（部分 UNIQUE 制約。[アーキテクチャ設計](architecture.md) の 7.1）。`state` は `generated` で作成し、`format` / `suggestedCreationDate` は `ExportJob.delivery` からコピーする。`settledAt` / `expiresAt` はまだ `nil`。

**手順5（settle）の内容**:

```swift
struct ExportRecord: Sendable {
    let exportID: ExportID
    let projectID: ProjectID
    let batchID: BatchID?
    let exportedAt: Date              // settledAt と同じ
    let accountingMode: ExportAccountingMode
    let format: ImageFormat
    let outputByteSize: Int64
}
```

`settleExport` は単体書き出し専用であり、実装はトランザクション内で次を確認する（不成立なら throw し、手順 5 を実行しない）。`ExportJob` が存在する（二重確定の防止）、`ExportJob.batchID == nil`（バッチの成果物は `settleBatch` でのみ確定する。個別に確定させると「結果一覧画面での完了操作 1 回」という単位が壊れる）、対応する `OutputRecord` が存在し `settledAt IS NULL` である、`queueItemID` が指定されていれば対応するキュー項目が存在し `projectID` / `batchID` が一致し `state == .exporting`（無関係なキュー項目を `completed` にしない）。`settleBatch` も同様に、対象 `batchID` に一致し `settledAt IS NULL` である全 `OutputRecord` それぞれについて同じキュー項目チェックを行う。加えて、確定対象の集合（`settledAt IS NULL` の `OutputRecord`）に含めない項目（生成前・処理中・`failed`・`paused` のいずれかで `OutputRecord` を持たない）が残っていてもバッチ全体を止めない（一枚の失敗でバッチ全体を停止しない。[アーキテクチャ設計](architecture.md) の 6.4）。ただし消費するクレジット・枠の枚数は、同一トランザクション内で実際に `settledAt` を設定する `OutputRecord` の件数と必ず一致することを検査する（数え間違いによる過不足消費を防ぐ）。**確定対象が 0 件（不明な `batchID`・確定済みバッチを含む）なら throw する**（`settleExport` の二重確定防止と対称。静かな成功は誤 `batchID` や二重呼び出しを隠す）。

確認を通ったら、`settledAt` に確定時刻（単体は現在時刻、バッチは呼び出し側が渡した時刻）を設定し、`expiresAt` を `settledAt + 24h` に設定する。`ExportJob` の値だけから `ExportRecord` を導出する。

| 導出先 | 導出元 |
| --- | --- |
| `ExportRecord.exportedAt` | 確定した `settledAt` |
| `ExportRecord.accountingMode` | `ExportJob.authorization` |
| `ExportRecord.format` / `outputByteSize` | 既存の `OutputRecord` |

`outputFile` は不透明な参照であり、パス文字列ではない（[アーキテクチャ設計](architecture.md) の 7.1。パス文字列だと `../` を含む値を注入できる経路ができる）。

---

## 4. 中断・やり直し・破棄

会計は手順5（settle。3 章）でしか確定しない。それより前で終わる中断・やり直しは、すべて次の一律の後始末で足りる。

| 契機 | 後始末 |
| --- | --- |
| 生成の失敗（手順 1〜3） | `discardExport` で `ExportJob` 行を削除する。`OutputRecord` はまだ存在しないため対象外。手順 1〜3 の一時ファイルは同一トランザクションで `PendingFileDeletion` へ登録する（実削除はコミット後。削除経路の正本は [アーキテクチャ設計](architecture.md) の 7.5） |
| 手順 3 の健全性確認が不成立 | 同上 |
| 出力確認画面での「やり直す」 | `discardExport` で `ExportJob` 行と `OutputRecord` 行を同一トランザクションで削除する。出力ファイルも同一トランザクションで `PendingFileDeletion` へ登録する（実削除はコミット後。削除経路の正本は [アーキテクチャ設計](architecture.md) の 7.5） |
| 利用者によるキャンセル | 上記のどちらか（キャンセルした時点に応じる） |
| プロセスの異常終了 | 起動時復旧が `running` の `ExportJob` 行と対応する未確定 `OutputRecord` を削除する（5 章） |

会計要素（月間枠・トライアル）はまだ何も書き込まれていないため、返還処理は不要。**免除・返還という概念自体が存在しない**（何も消費していないものを免除・返還する対象が無い。[ADR 0006](adr/0006-accounting-per-delivered-output.md)）。`WorkingSourceRecord` は削除しない。素材は完了まで保持され、やり直しは再レンダリングできる。`discardExport` は冪等（行が無ければ何もしない）。

完了前の出力は永続保護しない。アプリの再起動やフローからの離脱でも破棄してよい（消費していないため、利用者が失うのは操作の手間だけである）。

手順5（settle）が完了した後は前進のみで取り消せない（成果物は公開済みで正常生成が確定している）。UI 上も、完了後はキャンセル・やり直しを提示しない。完了後の破棄は 7 章の扱いに従い、次の書き出しは新規消費になる。

---

## 5. 起動時復旧

1. `loadRunningJobs()` で `ExportJob` の全行を読み、`deleteRunningJobs` で行と対応する未確定（`settledAt IS NULL`）`OutputRecord` をまとめて削除する
2. 出力先・一時ディレクトリの孤児ファイル（どの `OutputRecord` からも参照されないファイル）を GC で回収する
3. `resolveOrphanedAttempts()` を実行し、残存 `DeliveryAttempt` を `previousState` に応じて解決する（7 章）
4. `loadUnknownLibrarySaves()` で残っている注記を読み、未受け渡し出力（`settledAt != nil` かつ未受け渡し）の復旧案内を提示する
5. 更新誘導を判定する（[アーキテクチャ設計](architecture.md) が正本）

完了済み（`settledAt != nil`）の `OutputRecord` には手順1で何もしない。復旧が完了するまで新しい書き出しを開始させない。

---

## 6. 確定後に出力実体が失われた場合

`OutputRecord` と実体が食い違うことは、外部要因（OS によるキャッシュ削除、ストレージ障害）で起こりうる。v1 では自動再生成を行わない。この章は完了済み（`settledAt != nil`）の出力だけを扱う。未確定の出力は永続保護しないため（4 章）、実体を失えば単に生成のやり直しになる。

実体の健全性は `OutputFileVerifier.verify`（0 章）で確認する。

| 状況 | 扱い |
| --- | --- |
| `verify` が `.missing` / `.emptyFile` / `.undecodable` を返す、または検査に成功したが測定値（`byteSize` / `sha256`）が `OutputRecord.outputByteSize` / `outputSHA256` と一致しない | `OutputRecord` を物理削除する（7 章の `deleteOutput` と同じ、履歴削除の唯一の経路） |
| `verify` が `.ioFailure` を返す（保護データ利用不可・一時的な I/O 障害） | **実体喪失として扱わない。** `OutputRecord` を削除せず、確認できなかった旨を提示するに留める（再試行の余地を残す） |
| 台帳 | いずれの状況でも変更しない。月間枠・トライアルクレジットのいずれも戻さない |
| 利用者への提示 | 物理削除した場合のみ、出力を復元できないこと・新しい書き出しになることを示す。`.ioFailure` の場合は復元不可を示さない |

**自動再生成を行わない理由**: 現在保持しているデータでは再生成できない（元画像は完了時に `WorkingSourceRecord` ごと削除され、`RenderSpec` と `ExportSetting` も `OutputRecord` は保持しない）。再生成には出力の期限まで不変のスナップショットを保持する必要があり、未加工の顔画像を最大24時間追加保持することを意味する。プライバシーと容量の複雑性が v1 の利得に釣り合わない。完了済みの出力を失った場合の再生成は新規消費になる（[ADR 0006](adr/0006-accounting-per-delivered-output.md)。時間窓による免除は無い）ため、利用者の損失は消費した 1 枠と操作の手間の両方である。

---

## 7. 利用者への受け渡し

- 写真ライブラリへ保存する（`MediaSaver`）
- OS 共有へ渡す（`SharePresenter`）

完了後にのみ行える。何度実行しても追加消費しない。失敗しても生成済み出力を保持したまま再試行でき、再書き出しは不要。

**完了の確定**（[ADR 0006](adr/0006-accounting-per-delivered-output.md)）: 生成後の出力確認画面で、利用者が**明示的な完了操作**を行った時点で枠が確定する。単体は `settleExport`、バッチは `settleBatch` を呼ぶ（3 章）。完了操作の付近には「完了すると 1 枚として確定し、以降の作り直しは新しい 1 枚になる」旨を明示する。完了前は「やり直す」で出力を破棄でき、追加消費しない（4 章）。出力確認画面の表示は「公開」ではなく確認のための表示であり、スクリーンショットによる無消費の持ち出しは受容する（ADR 0006 Consequences）。

バッチの完了操作は、結果一覧画面での操作 1 回で対象バッチ内の**未確定な全出力**の `settledAt` を同一トランザクションで設定し、確定した枚数分だけクレジットを消費する（`settleBatch`）。完了前は写真単位のやり直しができ、一括保存・共有は完了後にのみ行える。

**不変条件**: `beginDeliveryAttempt` / `completeLibrarySave` / `completeShare` は `settledAt != nil` を事前条件とする（`nil` なら throw）。完了前の出力は UI 上も保存・共有へ到達できないが、防御として明記する。`completeShare` はさらに、対象の `DeliveryAttempt` が存在しないことも事前条件とする（存在すれば `deliveryAttemptAlreadyInProgress` を throw し、試行中の共有を拒否する。7.0）。`deleteOutput`（完了後の明示的な破棄）にもこの事前条件を課すが、完了前のやり直しは `discardExport`（4 章）を使うため対象外。保存・共有の成否は問わない（失敗しても出力は保持され再試行できる）。

### 7.0 写真ライブラリ保存の結果不明

PhotoKit と `app.db` は同一トランザクションにできない。保存成功後 `OutputRecord` を `delivered` へ更新する前に、プロセスの終了またはタスクのキャンセルで中断すると、再起動後は `generated` に見え、再保存すると重複する。exactly-once は保証できないため、自動再試行で重複を作らない設計にする。

```swift
/// 保存の試行中を表す。runtime 側のテーブル
struct DeliveryAttempt: Sendable {
    let exportID: ExportID
    let startedAt: Date
    let previousState: OutputState   // 試行開始前の状態
}
```

| 順 | 操作 | 保存先 |
| --- | --- | --- |
| 1 | 現在の状態を `previousState` として `DeliveryAttempt` を記録する | DB |
| 2 | `MediaSaver.saveToPhotoLibrary` を実行する | PhotoKit |
| 3 | 成功したら `OutputRecord` を `delivered` へ更新し `DeliveryAttempt` を削除する（同一トランザクション） | DB |
| 4 | 失敗したら `previousState` へ戻し `DeliveryAttempt` を削除する | DB |

起動時に `DeliveryAttempt` が残っていれば、手順 2 と 3 の間でプロセスの終了またはタスクのキャンセルにより中断している。`previousState == generated` なら `deliveryUnknown` へ更新し、`deliveryUnknown` はそのまま、`delivered` は維持したうえで「保存結果が不明」を別途提示する（状態は後退させない）。自動再保存・自動削除は行わない。利用者に写真ライブラリを確認させ、保存済みなら破棄、未保存なら再試行を選ばせる。`OutputState` の定義は [アーキテクチャ設計](architecture.md) の 7.5 が正本。`deliveryUnknown` は未受け渡しとして扱う（受け取れていない可能性がある側へ倒す）。

##### `delivered` を後退させない・直列化・保存結果不明の永続化

受け渡しは複数回・任意の順序で行える（[アーキテクチャ設計](architecture.md) の 7.5）。OS 共有成功後に写真ライブラリ保存を試みて中断しても、`previousState` により直前の共有成功の事実を失わない。一度成立した `delivered` は取り消さない。

`actor` であることは排他保証にならない（`await` のたびに再入可能なため）。個別の待ち行列は作らず、グローバル直列キュー1本（[アーキテクチャ設計](architecture.md) の 4.2。書き出しの手順 1〜3 と共通）で直列化する。`DeliveryAttempt` が存在する間、その出力への共有・破棄・別の保存、および**その出力を含む履歴（`Project`）の削除**はすべて拒否する（削除側の絶対保護としての扱いは [アーキテクチャ設計](architecture.md) の「削除の可否判定」が正本）。

保存（PhotoKit 側）が成立した後、手順 3（`delivered` への更新・`DeliveryAttempt` の削除）をタスクのキャンセルで取りやめてはならない。手順 4（失敗時の `previousState` への復元・`DeliveryAttempt` の削除）も同様に、呼び出し元のタスクキャンセルで取りやめてはならない。実装は、呼び出し元のキャンセルが直列キューの op 内部へ伝播していても、手順 3・4 の DB 反映をキャンセル非伝播のコンテキストで完走させる。

```swift
/// 写真ライブラリ保存の結果が不明であることの記録。runtime 側のテーブル
struct UnknownLibrarySave: Sendable {
    let exportID: ExportID
    let occurredAt: Date
}
```

`resolveOrphanedAttempts` で `delivered` を維持したとき upsert する。利用者が「確認した」を選んだとき行を削除する。出力そのものが削除されたとき（`deleteOutput`、または 6 章の実体喪失時の削除）は `OutputRecord` への FK CASCADE で消える。`OutputState` は増やさない（「共有は成功したが写真ライブラリは不明」は `delivered` に付随する注記であり、状態へ混ぜると `isUndelivered` の定義が曖昧になる）。

##### 状態遷移は用途別メソッドで行う

汎用の `updateOutputState(_:to:)` は置かない（任意の逆遷移を防ぐため）。`OutputState` は `generated` / `deliveryUnknown` / `delivered` の3値であり、破棄は状態ではなく行の物理削除で表す（`discarded` という状態は存在しない）。

| メソッド | 効果 | 呼ばれる場面 |
| --- | --- | --- |
| `completeLibrarySave` | `generated` / `deliveryUnknown` → `delivered`。`DeliveryAttempt` を削除 | 写真ライブラリ保存の成功 |
| `completeShare` | `generated` / `deliveryUnknown` → `delivered` | 共有の `.completed` |
| `abandonDeliveryAttempt` | `previousState` へ戻す（現在が `delivered` なら維持） | 写真ライブラリ保存の失敗 |
| `resolveOrphanedAttempts` | `previousState` が `generated` なら `deliveryUnknown`、`delivered` なら維持 | 起動時 |
| `deleteOutput` | 状態遷移ではない。`OutputRecord` 行を削除し、実体ファイルを同一トランザクションで `PendingFileDeletion` へ登録する（実削除はコミット後。0 章、削除経路の正本は [アーキテクチャ設計](architecture.md) の 7.5） | 完了後の出力を利用者が明示的に破棄したとき |

共有には `DeliveryAttempt` を作らない（結果が同期的に返るため中断点が無い）。共有の開始時点で既に `settledAt` は確定済み（完了後にのみ共有へ進めるため）である。

```swift
enum ShareResult: Sendable, Equatable { case completed, canceled, unknown, failed }
```

`.completed` は `generated` / `deliveryUnknown` → `delivered`。`.canceled` / `.failed` / `.unknown` は現在の状態を維持する（安全側へ倒す）。

### 7.1 `ShareLink` では実装できない

`SharePresenter` は `UIActivityViewController` だけで実装する（`ShareLink` は完了結果を返す API を持たないため）。`completionWithItemsHandler` からの写像。

| 条件 | 結果 |
| --- | --- |
| `activityError != nil` | `.failed` |
| `completed == true` | `.completed` |
| `completed == false` かつ `activityType == nil` | `.canceled`（シートを閉じた） |
| それ以外（`activityType` があるが未完了） | `.unknown`（共有先アプリが結果を返さなかった） |

`UIViewControllerRepresentable` で包み、`CheckedContinuation` で `async` 関数として公開する。

共有中（`completionWithItemsHandler` が呼ばれる前）にプロセスが終了した場合、共有先アプリへは既に渡っていても `app.db` 上は未受け渡しのまま残ることがある。これは受容する。共有は完了後にのみ行え、再共有しても追加消費は起きず、共有先での重複受信を除けば実害がないため（7 章冒頭）。
