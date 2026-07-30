# 書き出し Saga

| 項目 | 内容 |
| --- | --- |
| 目的 | 書き出しの認可、状態遷移、処理順、中断時の後始末、起動時復旧を一意に定める |
| 読者 | `Application` 層の実装者 |
| 正本の範囲 | `ExportJob` の型と状態、手順、中断・キャンセル時の後始末、起動時復旧、受け渡し |
| 関連 | [アーキテクチャ設計](architecture.md)、[ADR 0005](adr/0005-drop-tamper-resistance-backend-and-heavy-fault-tolerance.md)（改ざん対抗・耐障害機構の簡素化の決定） |

[ADR 0005](adr/0005-drop-tamper-resistance-backend-and-heavy-fault-tolerance.md) により、`UsageLedger`・書き出しジョブ・`OutputRecord` はすべて `app.db` の平文行になった。複数保存先を跨ぐ補償はもう要らない。会計・出力の公開・ジョブの完了は**単一の SQLite トランザクション**で原子的に確定する。書き出しは直列実行キュー1本（並列数1）で処理し、実行中のジョブは常に0件か1件。

---

## 0. Application が使う永続化ポート

`Application` は `Domain` のプロトコルだけを使う（[アーキテクチャ設計](architecture.md) の 4.3）。

```swift
// Domain — Foundation のみ

protocol ExportSagaStore: Sendable {
    /// 認可を評価し ExportJob(running) を挿入する（1 章）。expectedProjectRevision と不一致なら throw
    func startExport(_ input: StartExportInput, expectedProjectRevision: Int64) async throws -> ExportStartDecision
    /// 確定。単一トランザクションで台帳更新・ExportRecord/OutputRecord(generated) 作成・キュー項目 completed 更新・
    /// WorkingSourceRecord 削除・confirmed 設定エントリ記録・ExportJob completed 更新を行う（3 章）
    func finalizeExport(_ input: FinalizeExportInput) async throws
    /// 失敗・キャンセル・中断。ExportJob 行を削除する（4 章）。台帳は未確定のため触れない
    func deleteJob(_ exportID: ExportID) async throws
    /// 起動時復旧（5 章）
    func loadRunningJobs() async throws -> [ExportJob]
    func deleteRunningJobs(_ exportIDs: [ExportID]) async throws
}

/// 受け渡し（8 章）。ExportSagaStore とは寿命が異なるため分ける
protocol OutputDeliveryStore: Sendable {
    /// previousState を記録する。事前条件: settledAt != nil（nil なら throw。ADR 0006）
    func beginDeliveryAttempt(_ exportID: ExportID) async throws
    /// delivered への更新と attempt 削除を単一トランザクションで
    func completeLibrarySave(_ exportID: ExportID) async throws
    /// 事前条件: settledAt != nil（nil なら throw。ADR 0006）
    func completeShare(_ exportID: ExportID) async throws
    /// previousState へ戻す（現在が delivered なら維持）
    func abandonDeliveryAttempt(_ exportID: ExportID) async throws
    /// 起動時。残存 attempt を previousState に応じて解決し、解決後の全出力の受け渡し状態を返す（単一トランザクション）
    func resolveOrphanedAttempts() async throws -> [OutputDeliverySnapshot]
    func loadUnknownLibrarySaves() async throws -> [UnknownLibrarySave]
    func clearUnknownLibrarySave(_ exportID: ExportID) async throws
    /// 事前条件なし。完了前の出力の破棄にも使う（4 章の reissue 経路）
    func markDiscarded(_ exportID: ExportID) async throws
    /// 出力確認画面での明示的な完了操作で呼ぶ。settledAt が nil なら現在時刻を設定する。一度設定したら変更しない（ADR 0006）
    func markSettled(_ exportID: ExportID) async throws
}

struct ExportQueueItemID: Sendable, Hashable { let rawValue: UUID }
/// 手順 0 の入力
struct StartExportInput: Sendable {
    let projectID: ProjectID
    let batchID: BatchID?
    let renderSpec: RenderSpec
    let exportSetting: ExportSetting
    let previewConfirmation: PreviewConfirmation   // 1.1
}
/// 確定の入力。ExportJob から導出できない値だけを渡す
struct FinalizeExportInput: Sendable {
    let exportID: ExportID
    let queueItemID: ExportQueueItemID?   // 単体書き出しでは nil
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

`finalizeExport` は `ExportJob` に保存済みの `authorization` と `delivery` から会計とレコードを導出する。呼び出し側から渡すのは `exportID` / `queueItemID` と生成結果（出力ファイルの参照・サイズ・ハッシュ）だけ。

そのほかのポート（`ManagedFileStore` / `CrashReporter` / 履歴削除の原子的操作）は [アーキテクチャ設計](architecture.md) が正本。

---

## 1. 認可

認可は 1.1〜1.3 の検査と 1.4 の権限・クォータ評価を順に通る。いずれか不成立なら開始しない。`ExportJob` が存在する間、対象 `Project` の編集を禁止する（2 章）ため、認可は開始前に一度だけ行えばよく、開始後に設定が変わる経路は無い。

### 1.1 確認済みの設定でのみ書き出す

検出漏れはアプリ側で判定できないため、利用者が加工後プレビューを確認したことが安全性の前提（[アーキテクチャ設計](architecture.md) の 6.1）。確認の対象を型で固定する。

```swift
/// 利用者が確認したプレビューの同一性
struct PreviewConfirmation: Sendable, Equatable {
    let projectID: ProjectID
    let detectionRevision: Int64      // 再検出ごとに増える
    let previewRenderHash: PreviewRenderHash
}
/// バッチ一覧の確認状態。Bool 単独では持たない
struct BatchReviewState: Sendable, Equatable {
    let batchID: BatchID
    let overviewConfirmed: Bool
}
```

| 処理 | 開始条件 |
| --- | --- |
| 単体 | 現在の `projectID` / `detectionRevision` / `previewRenderHash` が `PreviewConfirmation` とすべて一致する |
| バッチ | 各写真について上記が一致し、`BatchReviewState.batchID` が対象バッチと一致し、かつモードごとの確認条件を 1.2 の再導出で満たす |

`projectID` を含めるのは `PreviewRenderHash` が `Project` を特定しないため。`detectionRevision` を含めるのは再検出後の顔集合差し替えを検出するため。`Project.projectRevision` は別途、手順 0 で `ExportJob` の insert と同一トランザクションで比較する（変わっていれば insert が失敗し、開始しない）。

### 1.2 確認の再導出

開始条件が保存された `reviewed` を根拠にできない（表示の高速化のためのキャッシュに過ぎず、実際の判断が記録されているとは限らないため）。保存済みの `FaceTrack` と `detectionPixelSize` から `DetectionResult` を組み立て、`triage` を再実行して `[ReviewIssue]` を再導出し、再導出した全 `ReviewIssueID` について `ReviewDecision` に `ReviewResolution` が記録されていることを確認する。1 件でも未記録なら開始しない。バッチ（おまかせ一括）は加えて `BatchReviewState.overviewConfirmed == true`、バッチ（1 枚ずつ確認）は加えて全写真について上記が成立していることを要求する。

`triage` は純粋関数であり再実行は顔数に比例するだけ（Vision の呼び出しを伴わない）。

### 1.3 設定内容の能力

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

有料スタンプを含むプロジェクトは、降格後も「変更せず再書き出し」なら課金なしで書き出せる（[アーキテクチャ設計](architecture.md) の 6.2）。次のすべてを満たす場合に `authorizeRenderSpec` の判定を免除する。

| 条件 | 内容 |
| --- | --- |
| 確定記録の存在 | `exportedSettingsEntries` に当該 `projectID` の項目がある |
| 設定の一致 | その項目の `settingsHash` が、いま組み立てた `RenderSpec` と `ExportSetting` から計算した値と一致する |
| 対象 | 同一 `Project` であること（ADR 0006。素材の同一性は照合しない） |
| 適用範囲 | 有料スタンプの能力要件のみ。クォータは免除しない |

確定記録は手順 4（finalize）で直接書き込む。中間状態を経ないため、以前あった「未確定の記録を根拠にしてしまう」経路は存在しない。

### 1.4 権限とクォータ

```swift
struct ExportAuthorization: Sendable {
    let entitlementSnapshot: Entitlement
    let accountingMode: ExportAccountingMode
    let authorizedAt: Date
}
enum ExportStartBlockReason: Sendable, Equatable {
    case monthlyLimitReached, trialCreditsUnavailable
    case capabilityVerificationRequired   // entitlementSnapshot.verificationRequired
}
struct ExportStartBlock: Sendable, Equatable {
    let reason: ExportStartBlockReason
    let limit: Int?
}
/// ADR 0006: 勘定の単位は「受け渡した成果物」。素材の同一性は使わない
enum ExportAccountingMode: Sendable, Equatable {
    case paidUnlimited, freeMonthlyConsume
    case batchTrial(consumesTrialCredit: Bool)
    case reissue   // 1.5 参照。追加消費なし
}
```

書き出し開始時点で利用権限と勘定を確定し、`ExportJob.authorization` に固定する。`blocked` なら `ExportJob` を作らず、生成も開始しない。

### 1.5 勘定の使い分け

枠が数える単位は「受け渡した成果物」であり、素材の同一性は勘定に使わない（ADR 0006）。生成後の出力確認画面で、利用者が**明示的な完了操作**を行った時点（`OutputRecord.settledAt` が確定する時点。8 章）で「完了」となり、枠が確定する。保存・共有は完了後にのみ行える。

| 勘定 | 月間枠 | トライアル台帳 |
| --- | --- | --- |
| `paidUnlimited` | 使わない | 使わない |
| `freeMonthlyConsume` | 1 消費 | 使わない |
| `batchTrial(true)` | 使わない | 1 消費 |
| `batchTrial(false)` | 使わない | 使わない |
| `reissue` | 使わない | 使わない |

月間クォータを使うのは Free の単体処理だけ（Free 利用者が月 5 枚を使い切っていても、クレジットが残っていれば一括トライアルを実行できる）。

**`reissue` の成立条件**（認可時に判定）: 同一 `projectID` の直近の `OutputRecord` が `state == discarded` かつ `settledAt == nil` であること。破棄（8 章の `markDiscarded`）でも実体喪失（7 章）でも `OutputRecord` は物理削除せず `discarded` へ遷移させ `settledAt` を保持するため、この行を根拠に判定できる。回数・時間の制限は無い。`settledAt` が確定した後に `discarded` になった行は `reissue` の根拠にならず、新規消費となる。

### 1.6 開始後の権限変化

開始後に有料契約の失効・月間上限への到達が起きても、その書き出しは開始時の権限（`ExportJob.authorization`）で完了させる。`running` の写真は開始時の認可のまま完了させる。まだ認可されていない `waiting` の写真は開始せず、バッチを `paused` にする。

### 1.7 開始の順序

直列実行キュー1本（並列数1）が同時実行を構造的に防ぐため、専用の排他ゲートや素材単位のロックは不要。

1. 確認の一致を検査する（1.1）。不一致なら終える
2. `triage` を再実行し確認の成立を再導出する（1.2）。不成立なら終える
3. 設定内容の能力を検査する（1.3）。`blocked` なら終える
4. `WorkingSourceRecord` の実体（ファイルの存在）を確認する（[画像処理](image-pipeline.md)）。無ければ無効化して再選択導線へ倒し、終える。`sourceID` はこの記録の参照をそのまま使う（素材の同一性照合は行わない。ADR 0006）
5. 権限とクォータを評価する（1.4）。`.blocked` ならここで終える
6. `startExport` で `ExportJob(running)` を挿入する（`expectedProjectRevision` つき）。revision が変わっていれば失敗し、終える
7. 処理を開始する（3 章）

---

## 2. `ExportJob` の状態

```swift
struct ExportJob: Sendable {
    let exportID: ExportID
    let projectID: ProjectID
    let batchID: BatchID?
    let sourceID: SourceID
    let authorization: ExportAuthorization   // 開始時に固定する（1.6）
    let delivery: OutputDeliveryDescriptor   // 認可時に確定。finalize で OutputRecord へコピーする
    let state: ExportJobState
}
enum ExportJobState: Sendable, Equatable {
    case running     // 処理中
    case completed   // finalize 完了。OutputRecord・ExportRecord が存在する
}
struct OutputDeliveryDescriptor: Sendable {
    let format: ImageFormat
    let suggestedCreationDate: Date?
}
```

状態は2つだけ。中断は別状態を経ず、行の削除で表す（4 章）。`running` の間、対象 `Project` の編集を禁止する。`completed` は前進のみで、以降の状態は無い。

---

## 3. 手順

| 順 | 操作 | 保存先 | 遷移後の状態 |
| --- | --- | --- | --- |
| 0 | 認可を評価し、`ExportJob` を保存する（1 章） | DB | `running` |
| 1 | レンダリングし、一時ファイルへ出力する | ファイルシステム | — |
| 2 | 一時ファイルを出力ディレクトリへ移動する | ファイルシステム | — |
| 3 | 出力ファイルの健全性を確認する（下記） | ファイルシステム | — |
| 4 | **単一トランザクション**。`ExportJob.authorization.accountingMode` に従って台帳を加算またはトライアルクレジットを消費（`reissue` なら何もしない）、`ExportRecord` と `OutputRecord(generated)` の作成、キュー項目の `completed` 更新、`Project` の最終更新時刻の更新、`WorkingSourceRecord` の削除、confirmed 設定エントリの記録を行う。ここが唯一の確定境界 | DB | `completed` |

```
running → （レンダリング・ファイル移動・健全性確認。DB 上の状態変化なし）→ 手順 4（単一トランザクション）→ completed
```

会計・出力の公開・ジョブの完了が同じトランザクションで確定するため、旧設計にあった「暫定適用してから最終確定する」区間そのものが無い。検証済みファイルは、このトランザクションが完了するまで UI・`MediaSaver`・`SharePresenter` へ公開しない。

**手順3（健全性確認）**: 存在確認だけでは不足する（0 バイトのファイル、途中まで書かれたファイル、デコードできないファイルも「存在する」ため）。ファイルが存在し、サイズが 0 でなく、簡易デコードが成功することを確認する。いずれかが不成立なら手順 4 へ進まず、中断として扱う（4 章）。

**手順4（finalize）の内容**:

```swift
struct ExportRecord: Sendable {
    let exportID: ExportID
    let projectID: ProjectID
    let batchID: BatchID?
    let exportedAt: Date
    let accountingMode: ExportAccountingMode
    let format: ImageFormat
    let outputByteSize: Int64
}
struct OutputRecord: Sendable {
    let exportID: ExportID
    let projectID: ProjectID
    let batchID: BatchID?
    let outputFile: OutputFileRef
    let outputByteSize: Int64
    let outputSHA256: Data
    let state: OutputState
    let generatedAt: Date
    let expiresAt: Date              // generatedAt + 24h
    let settledAt: Date?             // finalize 時は nil。8 章で確定する（ADR 0006）
    let format: ImageFormat
    let suggestedCreationDate: Date?
}
```

実装はトランザクション内で次を確認する（不成立なら throw し、手順 4 を実行しない）。`ExportJob.state == running`（二重確定の防止）、同じ `projectID` の**非終端**（`discarded` 以外の）`OutputRecord` が存在しない（`OutputRecord.projectID` の部分 UNIQUE 制約。[アーキテクチャ設計](architecture.md) の 7.1。未削除の `delivered` 出力が残る `Project` は再書き出し不可、同 7.5）、`queueItemID` が指定されていれば対応するキュー項目が存在し `projectID` / `batchID` が一致し `state == .exporting`（無関係なキュー項目を `completed` にしない）。

確認を通ったら、同じ `projectID` の `discarded` 行があれば同一トランザクションで削除する（`reissue` 判定の根拠は認可時に読み取り済みであり、この行はもう要らない）。続いて `ExportJob` の値だけから `OutputRecord` と `ExportRecord` を導出する。

| 導出先 | 導出元 |
| --- | --- |
| `OutputRecord.outputFile` / `outputByteSize` / `outputSHA256` | `FinalizeExportInput` |
| `OutputRecord.generatedAt` / `expiresAt` | 手順 4 のトランザクション時刻と `+ 24h` |
| `OutputRecord.format` / `suggestedCreationDate` | `ExportJob.delivery` |
| `ExportRecord.accountingMode` | `ExportJob.authorization` |

パスを DB へ直接持たない（[アーキテクチャ設計](architecture.md) の 7.1。パス文字列を保存すると `../` を含む値を注入できる経路ができる）。

---

## 4. 中断とキャンセル

会計は手順 4（3 章）でしか確定しない。それより前で終わる中断は、すべて次の一律の後始末で足りる。

| 契機 | 後始末 |
| --- | --- |
| 生成の失敗（手順 1〜3） | `deleteJob` で `ExportJob` 行を削除する。一時／出力ファイルをベストエフォートで削除する |
| 利用者によるキャンセル | 同上 |
| 手順 3 の健全性確認が不成立 | 同上 |
| プロセスの異常終了 | 起動時復旧が `running` の行を削除する（5 章） |

会計要素（月間枠・トライアル）はまだ何も書き込まれていないため、返還処理は不要。`deleteJob` は冪等（行が無ければ何もしない）。

**手順 4（finalize）が完了した後、出力確認画面での「やり直す」**（ADR 0006）: `OutputRecord` は作られるが `settledAt` はまだ確定していない。この間に利用者が「やり直す」を選んだ場合は `deleteJob` ではなく `markDiscarded` で `OutputRecord` を `discarded` へ遷移させ、編集へ戻す（8 章）。台帳は変更しない（会計は既に確定済み）。次の書き出しは `reissue` として追加消費なしで行える（1.5）。

出力確認画面での**明示的な完了操作**（8 章の `markSettled`）を経たあとは前進のみで取り消せない。UI 上も、完了後はキャンセル・やり直しを提示しない。完了後の破棄は 8 章の扱いに従い、次の書き出しは新規消費になる。

---

## 5. 起動時復旧

1. `loadRunningJobs()` で `running` の全行を読み、`deleteRunningJobs` でまとめて削除する
2. 出力先・一時ディレクトリの孤児ファイル（どの `ExportJob` 行からも参照されないファイル）を GC で回収する

`completed` の行には何もしない（`OutputRecord` と `ExportRecord` は既に確定済み）。復旧が完了するまで新しい書き出しを開始させない。

---

## 6. 署名不正コミット

[ADR 0005](adr/0005-drop-tamper-resistance-backend-and-heavy-fault-tolerance.md) により廃止。台帳が `app.db` の平文行になり、コミット行の署名という概念自体が無くなったため。

---

## 7. 確定後に出力実体が失われた場合

`OutputRecord` と実体が食い違うことは、外部要因（OS によるキャッシュ削除、ストレージ障害）で起こりうる。v1 では自動再生成を行わない。

| 状況 | 扱い |
| --- | --- |
| 実体が無い、または `outputByteSize` / `outputSHA256` と一致しない | `OutputRecord` を `discarded` へ遷移させる（物理削除しない。`settledAt` を保持したまま残す。実体ファイルは削除する） |
| 台帳 | 変更しない。月間枠・トライアルクレジットのいずれも戻さない |
| 利用者への提示 | 出力を復元できないこと、および新しい書き出しになることを示す |
| `settledAt == nil`（未完了）のまま失った場合 | `reissue` でやり直せる（追加消費なし。1.5） |
| `settledAt` が確定済み（完了後）に失った場合 | 新規消費でやり直す。`reissue` は成立しない |

**自動再生成を持たない理由**: 現在保持しているデータでは再生成できない（元画像は書き出し完了時に `WorkingSourceRecord` ごと削除され、`RenderSpec` と `ExportSetting` も `OutputRecord` は保持しない）。再生成には出力の期限まで不変のスナップショットを保持する必要があり、未加工の顔画像を最大24時間追加保持することを意味する。プライバシーと容量の複雑性が v1 の利得に釣り合わない。未完了のまま失った場合は `reissue` により追加消費なしで行えるため、利用者の損失は「もう一度操作する手間」に限られる。

---

## 8. 利用者への受け渡し

- 写真ライブラリへ保存する（`MediaSaver`）
- OS 共有へ渡す（`SharePresenter`）

完了後にのみ行える。何度実行しても追加消費しない。失敗しても生成済み出力を保持したまま再試行でき、再書き出しは不要。

**完了（`settledAt`）の確定**（ADR 0006）: 生成後の出力確認画面で、利用者が**明示的な完了操作**を行った時点で枠が確定する。`markSettled` の呼び出しで、`OutputRecord.settledAt` が `nil` なら現在時刻を設定する（同一トランザクション）。一度設定した `settledAt` は変更しない。完了操作の付近には「完了すると 1 枚として確定し、以降の作り直しは新しい 1 枚になる」旨を明示する。完了前は「やり直す」で出力を破棄でき、追加消費しない（4 章）。

バッチの完了操作は、結果一覧画面での操作 1 回で対象バッチ内の**全出力**の `settledAt` を同一トランザクションで設定する（`markSettled` のバッチ版。個別の出力だけを完了させる操作は持たない）。完了前は写真単位のやり直しができ、一括保存・共有は完了後にのみ行える。

**不変条件**: `beginDeliveryAttempt` / `completeLibrarySave` / `completeShare` は `settledAt != nil` を事前条件とする（`nil` なら throw）。完了前の出力は UI 上も保存・共有へ到達できないが、防御として明記する。`markDiscarded` にはこの事前条件を課さない（完了前のやり直しでも呼ばれるため。4 章）。保存・共有の成否は問わない（失敗しても出力は保持され再試行できる）。

### 8.0 写真ライブラリ保存の結果不明

PhotoKit と `app.db` は同一トランザクションにできない。保存成功後 `OutputRecord` を `delivered` へ更新する前にプロセスが終了すると、再起動後は `generated` に見え、再保存すると重複する。exactly-once は保証できないため、自動再試行で重複を作らない設計にする。

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

起動時に `DeliveryAttempt` が残っていれば、手順 2 と 3 の間で終了している。`previousState == generated` なら `deliveryUnknown` へ更新し、`deliveryUnknown` はそのまま、`delivered` は維持したうえで「保存結果が不明」を別途提示する（状態は後退させない）。自動再保存・自動削除は行わない。利用者に写真ライブラリを確認させ、保存済みなら破棄、未保存なら再試行を選ばせる。`OutputState` の定義は [アーキテクチャ設計](architecture.md) の 7.5 が正本。`deliveryUnknown` は未受け渡しとして扱う（受け取れていない可能性がある側へ倒す）。

##### `delivered` を後退させない・直列化・保存結果不明の永続化

受け渡しは複数回・任意の順序で行える（[アーキテクチャ設計](architecture.md) の 7.5）。OS 共有成功後に写真ライブラリ保存を試みて中断しても、`previousState` により以前の共有成功の事実を失わない。一度成立した `delivered` は取り消さない。

`actor` であることは排他保証にならない（`await` のたびに再入可能なため）。`exportID` ごとの明示的な待ち行列で直列化する（[アーキテクチャ設計](architecture.md) の 4.2 と同じ方式）。`DeliveryAttempt` が存在する間、その出力への共有・破棄・別の保存はすべて拒否する。

```swift
/// 写真ライブラリ保存の結果が不明であることの記録。runtime 側のテーブル
struct UnknownLibrarySave: Sendable {
    let exportID: ExportID
    let occurredAt: Date
}
```

`resolveOrphanedAttempts` で `delivered` を維持したとき upsert する。利用者が「確認した」を選んだとき行を削除する。出力そのものが削除されたときは `OutputRecord` への FK CASCADE で消える。`OutputState` は増やさない（「共有は成功したが写真ライブラリは不明」は `delivered` に付随する注記であり、状態へ混ぜると `isUndelivered` の定義が曖昧になる）。

##### 状態遷移は用途別メソッドで行う

汎用の `updateOutputState(_:to:)` は置かない（任意の逆遷移を防ぐため）。

| メソッド | 遷移 | 呼ばれる場面 |
| --- | --- | --- |
| `completeLibrarySave` | `generated` / `deliveryUnknown` → `delivered`。`DeliveryAttempt` を削除 | 写真ライブラリ保存の成功 |
| `completeShare` | `generated` / `deliveryUnknown` → `delivered` | 共有の `.completed` |
| `abandonDeliveryAttempt` | `previousState` へ戻す（現在が `delivered` なら維持） | 写真ライブラリ保存の失敗 |
| `resolveOrphanedAttempts` | `previousState` が `generated` なら `deliveryUnknown`、`delivered` なら維持 | 起動時 |
| `markDiscarded` | 任意の状態 → `discarded`。行は物理削除せず `settledAt` を保持したまま残す。実体ファイルは削除する | 利用者の明示的な破棄のみ（完了前のやり直しを含む。4 章） |
| `markSettled` | 状態は変えない。`settledAt` のみ確定 | 出力確認画面での明示的な完了操作 |

共有には `DeliveryAttempt` を作らない（結果が同期的に返るため中断点が無い）。共有の開始時点で既に `settledAt` は確定済み（完了後にのみ共有へ進めるため）であり、共有側で `settledAt` を扱う必要はない。

```swift
enum ShareResult: Sendable, Equatable { case completed, canceled, unknown, failed }
```

`.completed` は `generated` / `deliveryUnknown` → `delivered`。`.canceled` / `.failed` / `.unknown` は現在の状態を維持する（安全側へ倒す）。

### 8.1 `ShareLink` では実装できない

`SharePresenter` は `UIActivityViewController` だけで実装する（`ShareLink` は完了結果を返す API を持たないため）。`completionWithItemsHandler` からの写像。

| 条件 | 結果 |
| --- | --- |
| `activityError != nil` | `.failed` |
| `completed == true` | `.completed` |
| `completed == false` かつ `activityType == nil` | `.canceled`（シートを閉じた） |
| それ以外（`activityType` があるが未完了） | `.unknown`（共有先アプリが結果を返さなかった） |

`UIViewControllerRepresentable` で包み、`CheckedContinuation` で `async` 関数として公開する。
