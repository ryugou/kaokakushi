# 書き出し Saga

| 項目 | 内容 |
| --- | --- |
| 目的 | 書き出しの認可、状態遷移、処理順、ロールバック、起動時復旧を一意に定める |
| 読者 | `Application` 層の実装者、障害注入テストの作成者 |
| 正本の範囲 | `ExportCommit` の型と状態、手順 0〜7、ロールバック順序、起動時復旧順序、署名不正コミットの扱い、実体喪失時の扱い、受け渡し |
| 関連 | [アーキテクチャ設計](architecture.md)（`UsageLedger`、`ResolvedCapabilities`、`ManagedFileRef`）、[正準スキーマ](canonical-schema.md)（署名バイト表現）、[テスト計画](test-plan.md) |

書き出しの完了で確定する事柄は、**保存先が 3 つに分かれています。**

| 更新対象 | 保存先 |
| --- | --- |
| 完成済みファイルの公開 | ファイルシステム |
| `OutputRecord` = `generated` | DB |
| Free 枠の消費、`ExportGrant` の作成、トライアル台帳への素材追加 | ProtectedBlobStore |

**単一トランザクションで更新できません。** 異常終了の位置によって「出力だけ残り枠が消費されない」「枠だけ消費され出力が残らない」が起こります。2 つ目は「消費したのに成果物を受け取れない」そのものです。**永続的なコミットジャーナルを置きます。**

---

## 0. Application が使う永続化ポート

`Application` は `Domain` のプロトコルだけを使います（[アーキテクチャ設計](architecture.md) の 4.3）。Saga が必要とする操作を、**トランザクション境界ごと**に切ります。

```swift
// Domain — Foundation のみ

protocol UsageLedgerStore: Sendable {
    func transact<R: Sendable>(
        _ transform: @Sendable (UsageLedger) throws -> LedgerTransaction<R>
    ) async throws -> R
}

protocol ExportSagaStore: Sendable {
    /// 手順 0。expectedProjectRevision と一致しなければ throw（1.1）
    func insertPrepared(
        _ commit: ExportCommit,
        expectedProjectRevision: Int64
    ) async throws

    /// 手順 2 / 3 / 5 / 6。同じ exportID の行を置き換える
    func updateCommit(_ commit: ExportCommit) async throws

    /// 手順 7。単一 DB トランザクションで実行する
    func finalizeExport(_ input: FinalizeExportInput) async throws

    /// 起動時復旧の入力（5 章）。復旧の開始前に一度だけ読む
    func loadRecoverySnapshot() async throws -> RecoverySnapshot

    /// 復旧の完了後に実行する（5 章の手順 5）
    func checkForeignKeys() async throws -> [ForeignKeyViolation]

    /// ロールバックの手順 3〜5 を 1 トランザクションで実行する
    func rollbackCommit(_ exportID: ExportID) async throws

    /// 署名不正行を DB 内部の行 ID で削除する（6 章）
    func deleteCommitByRowID(_ rowID: Int64) async throws
}
```

**手順 7 を複数の Repository 呼び出しとして `Application` 側で組み立てません。** そうすると単一 DB トランザクションを保証できず、「出力は公開済みだがキューは `exporting`」が残ります。

```swift
struct ExportQueueItemID: Sendable, Hashable { let rawValue: UUID }

struct FinalizeExportInput: Sendable {
    let exportID: ExportID
    let outputRecord: OutputRecord
    let exportRecord: ExportRecord
    let queueItemID: ExportQueueItemID?
    let projectUpdatedAt: Date
}

/// 台帳の更新結果と、同じ排他区間で取り出す値を 1 つにまとめる
struct LedgerTransaction<R: Sendable>: Sendable {
    let ledger: UsageLedger      // 保存する新しい台帳
    let result: R                // 認可結果など、呼び出し元が必要とする値
}

/// 署名検証前の行を含む、起動時の一括読み取り
struct RecoverySnapshot: Sendable {
    let commits: [SignedCommitRow]
    let outputRecords: [OutputRecord]
    let deliveryAttempts: [DeliveryAttempt]            // 8.0
    let nonTerminalQueueItems: [ExportQueueItemSnapshot]
    let workingSources: [WorkingSourceRecord]
}

/// 署名検証はまだ通っていない。rowID は破棄のためだけに使う（6 章）
struct SignedCommitRow: Sendable {
    let rowID: Int64
    let rawColumns: ExportCommitColumns
    let signature: Data
}

/// 検証前の生の列。ExportCommit へデコードしない
struct ExportCommitColumns: Sendable {
    let exportID: Data          // 16 バイトとして読めなければ不正
    let projectID: Data
    let batchID: Data?
    let sourceID: Data
    let outputFileKind: UInt32?
    let outputFileID: Data?
    let authorization: Data     // 正準バイト列のまま
    let verifiedOutput: Data?
    let finalizedAtMillis: Int64?
    let finalizedPeriod: Data?
    let intent: Data?
    let applied: Data?
    let state: UInt32
}

struct ExportQueueItemSnapshot: Sendable {
    let id: ExportQueueItemID
    let batchID: BatchID
    let projectID: ProjectID
    let state: ExportQueueState
}

struct ForeignKeyViolation: Sendable {
    let table: String
    let rowID: Int64
    let parentTable: String
}
```

`finalizeExport` の実装が、`OutputRecord` の insert・`ExportRecord` の insert・キュー項目の `completed` 更新・`Project` の最終更新時刻・`ExportCommit` の delete を **1 回の DB トランザクション**で行います。**この境界が手順 7 の正本です。**

**`RecoverySnapshot` は起動時に一度だけ読みます。** 復旧中に個別クエリを繰り返さないのは、手順の途中で DB が変化しないことを保証するためです。

**`SignedCommitRow` は検証前の生の列を持ちます。** `ExportCommit` としてデコードしてしまうと、署名不正行のフィールドを使う経路ができます（6 章）。検証を通った行だけが `ExportCommit` になります。

**`ExportCommitColumns` は「まだ信用できない値」を表す型です。** すべて生のバイト列か固定幅の整数であり、`ProjectID` や `ExportID` へデコードしません。デコードできる型にすると、署名検証を通す前にフィールドを使う経路ができます（6 章）。

**外部キーの検査は `RecoverySnapshot` に含めません。** 検査は未完了コミットの復旧後に行うため（5 章の手順 5）、復旧前に読んだ snapshot へ結果を入れられません。`checkForeignKeys()` を別に呼びます。**単一 `app.db` では外部キーが実制約として効くため、違反は通常発生しません。** 検出した場合は復旧エラーとし、自動修復しません。

##### `finalizeExport` は入力を信用しない

`FinalizeExportInput` は完成済みのレコードを呼び出し側から受け取りますが、**実装はそれをそのまま書きません。** トランザクション内で、同じ `exportID` の保存済みコミットについて次を再確認します。

| 確認 | 不成立なら |
| --- | --- |
| `state == readyToPublish` | throw。手順 7 を実行しない |
| HMAC 検証を通る | throw |
| `projectID` / `batchID` / `outputFile` が入力と一致する | throw |
| `verifiedOutput` が入力の `outputByteSize` / `outputSHA256` と一致する | throw |

**確認を通ったら、保存済みコミットの値から `OutputRecord` を導出します。** 入力の値をそのまま採用しません。入力を信用すると、`Application` 側のバグや改変が DB の最終状態へ直接反映されます。

そのほかのポート（`ManagedFileStore` / `CryptoKeyStore` / `ProtectedBlobStore` / `CrashReporter` / 履歴削除の原子的操作）は [アーキテクチャ設計](architecture.md) が正本です。

---

## 1. 認可

**認可は 2 つの独立した検査を通ります。**

| 検査 | 対象 | 失敗時 |
| --- | --- | --- |
| **確認の一致**（1.1） | 利用者が確認したプレビューが、いま書き出そうとしている設定と同じか | 開始しない。台帳へ触れない |
| **権限とクォータ**（1.2 以降） | 能力・月間枠・トライアル | `.blocked`。lease と予約を補償して終了 |

**順序は確認の一致が先です。** 台帳を触る前に弾けば、補償が不要になります。

### 1.1 確認済みの設定でのみ書き出す

検出漏れはアプリ側で判定できないため、**利用者が加工後プレビューを確認したことが安全性の前提です**（[アーキテクチャ設計](architecture.md) の 6.1）。しかし「確認した」という事実だけでは、**確認後に設定を変えて古いプレビューのまま書き出す経路**を塞げません。

**確認の対象を型で固定します。**

```swift
/// 書き出そうとしている入力の同一性
struct ExportInputSnapshot: Sendable, Equatable {
    let projectID: ProjectID
    let projectRevision: Int64        // Project の変更ごとに増える
    let detectionRevision: Int64      // 再検出ごとに増える
    let settingsHash: ProjectSettingsHash
}

/// 利用者が確認したプレビューの同一性
struct PreviewConfirmation: Sendable, Equatable {
    let projectRevision: Int64
    let detectionRevision: Int64
    let settingsHash: ProjectSettingsHash
}
```

`ProjectSettingsHash` は出力へ影響する全設定の正準ハッシュです（[正準スキーマ](canonical-schema.md)）。

| 処理 | 開始条件 |
| --- | --- |
| 単体 | 現在の `ExportInputSnapshot` の 3 値が `PreviewConfirmation` と**すべて一致する** |
| バッチ | 各写真について上記が一致し、かつモードごとの確認条件（`reviewed` / `overviewConfirmed`）を満たす |

**`settingsHash` だけでは足りません。** 再検出すると顔の集合が変わりますが、設定が同じなら `settingsHash` は変化しません。`detectionRevision` を含めることで、**確認したプレビューと違う顔集合で書き出す経路**を塞ぎます。`projectRevision` は、手動領域の追加・削除など `settingsHash` の対象外の変更を捕まえます。

##### 開始後に設定を変えられないようにする

一致を確認しただけでは、**確認から `prepared` の保存までの間に設定を変更**できます。

| 順 | 操作 |
| --- | --- |
| 1 | 確認の一致を検査する |
| 2 | 権限とクォータを認可する（1.3 のゲート内） |
| 3 | **手順 0 で `Project` の revision を再取得し、`ExportCommit` の insert と同一 DB トランザクションで固定する**（`insertPrepared(_:expectedProjectRevision:)`） |
| 4 | revision が変わっていれば insert が失敗する。**台帳の lease・予約を補償して終了する** |

**非終端の `ExportCommit` が存在する間、対象 `Project` を変更できません。** 編集操作は拒否し、書き出しの完了またはキャンセルを求めます。これにより手順 1〜7 の途中で設定が変わる経路が消えます。

### 1.2 権限とクォータ

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
    case monthlyLimitReached
    case ledgerIntegrityFailure
    case trialCreditsUnavailable
    case trialIntegrityLocked
    case capabilityVerificationRequired
}

struct ExportStartBlock: Sendable, Equatable {
    let reason: ExportStartBlockReason
    let limit: Int?                 // 上限値。提示に使う。該当しなければ nil
}

enum ExportStartDecision: Sendable {
    case blocked(ExportStartBlock)
    case authorized(AuthorizedExportStart)
}

struct AuthorizedExportStart: Sendable {
    let sourceID: SourceID          // このトランザクションで確定した
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

**`ExportStartBlock` は開始を止める理由だけを持ちます。** `QuotaDecision` を連想値にすると `.blocked(.unlimited)` のような無意味な値が構築でき、型で分けた目的を果たしません。`QuotaPolicy.evaluate` が `.blocked(reason:limit:)` を返した場合に開始トランザクションが写し、`unlimited` / `freeReexport` / `consume` はいずれも `ExportAccountingMode` へ写ります。

### 1.3 勘定の使い分け

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

単一フィールドでは preserve を表現できず、通常処理と起動時復旧が同じ `AccountingIntent` を読む以上、復旧側が ensure してしまう経路が残ります。型で分ければ `switch` の網羅で強制されます。

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

### 1.4 開始後の権限変化

開始後に有料契約の失効・月間上限への到達・リモート設定の変更が起きても、その書き出しは開始時の権限で完了させます。**認可の粒度は写真ごとの `exportID` です。**

| Pro 失効時点の状態 | 扱い |
| --- | --- |
| `prepared` 以降へ進んでいる写真 | 開始時の認可で**完了させる** |
| まだ認可されていない `waiting` の写真 | 開始しない。バッチを `paused` にする |

契約期間の終了時に未完了のバッチが残っている場合はキューを `paused` にし、完了済みの写真と履歴は保持します。

### 1.5 開始ゲート

**「同時 1 件」という規則だけでは競合を防げません。** 認可を通ってから `prepared` を書くまでの間に、別の書き出しが同じ認可を通過できます。**認可の前にゲートを取ります。**

**`sourceID` をゲートのキーにできません。** 正規 `sourceID` は `UsageLedger` 内の alias を検索・統合して確定するため、`sourceID` を得るには `transact` が必要で、`transact` はゲートの内側にあります。**ゲート取得に必要な値が、ゲート取得後にしか分かりません。** 台帳をゲートの外で先読みして解決すると、統合処理そのものが競合対象なので意味がありません。

同時並列数の初期値が 1 である以上、素材単位の粒度は実質使われません。**ゲートを全体で 1 件にします。**

```swift
// Domain — プロトコル。実装はアーキテクチャ設計 4.2 の待機キュー規則に従う
protocol ExportStartGate: Sendable {
    func withExclusivePermit<R: Sendable>(
        operation: @Sendable () async throws -> R
    ) async throws -> R
}
```

**その内側の 1 回の `UsageLedgerStore.transact` で、次をすべて行います。**

1. alias を解決・統合し、**`sourceID` を確定する**
2. 時刻を正規化し、月次更新と期限切れ grant の整理を行う
3. クォータまたはトライアルを認可する
4. **`SourceLease` を追加する**（勘定を問わない）。`batchTrial(true)` のときだけ追加で `TrialReservation` を作る
5. 更新済み台帳と `ExportStartDecision` を返す

**1 回の `transact` にまとめるのが要点です。** 解決と認可を別々のトランザクションに分けると、その間に別の処理が同じ alias を解決できます。

開始の順序です。

1. 復旧完了ゲートを確認する（5 章）
2. **確認の一致を検査する**（1.1）。不一致なら台帳へ触れずに終える
3. **`withExclusivePermit` を取得する**
4. **その内側で** `transact` を 1 回実行し、`ExportStartDecision` を得る
5. `.blocked` なら生成せずに終える。ゲートは解放する
6. `ExportCommit(prepared)` を保存する（`expectedProjectRevision` つき）
7. 処理を開始する
8. 手順 7 の完了またはロールバック完了で**ゲートを解放する**

**ゲートは認可の完了では解放しません。コミット行の削除またはロールバックの完了まで保持します。** ロールバックの途中で次の認可が走ると、戻す前の台帳を根拠に判定してしまいます。

### 1.6 同一素材の直列化

**同じ素材の非終端 `ExportCommit` は同時に 1 件だけとします。** この不変条件がないと所有者方式が壊れます。Export A が grant を作り所有者になる → 同じ素材の Export B も正常完了する（既存 grant を使うので所有者にならない）→ A のファイル異常でロールバックし A 所有の grant を削除する → **B は成功しているのに grant が消える。**

- 並列処理は異なる素材の間だけ許可する
- 同一素材は直列化する。バッチ内に重複があっても同様
- **コミット行の削除またはロールバック完了まで**、その素材をロックする

ロックを `readyToPublish` で解放してはいけません。その保存後、コミット行の削除前にも復旧対象となる区間が残っています。

この不変条件は台帳側では **「同一 `sourceID` の `SourceLease` は最大 1 件」** として現れます。v1 は全体ゲートによりこれを自動的に満たします。

### 1.7 並列数を 2 へ上げるときの移行

| 段 | ゲート | 内容 |
| --- | --- | --- |
| 1 | **alias 単位の解決ゲート** | alias から `sourceID` を確定するまでを排他する |
| 2 | `sourceID` 単位のゲート | 確定した `sourceID` で以降を排他する |

第 1 段が短時間で終わるため、実質的な並列度は保たれます。あわせて、月間枠を消費する単体書き出しを同時 1 件に制限するゲートを第 2 段で復活させます（消費するかどうかは認可の結果でありゲート取得時点では未確定なので、条件式ではなく粒度で担保します）。v1 では実装しません。

---

## 2. `ExportCommit` の状態

```swift
struct ExportCommit: Sendable {
    let exportID: ExportID
    let projectID: ProjectID
    let batchID: BatchID?
    let sourceID: SourceID
    let outputFile: OutputFileRef?          // prepared では nil。手順 1 で生成する
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
| `fileVerified` | 上記 ＋ **`outputFile`** ＋ `verifiedOutput` |
| `finalizing` | 上記 ＋ `finalizedAt` / `finalizedPeriod` / `intent` |
| `accountingCommitted` | 上記 ＋ `applied` |
| `readyToPublish` | 上記 ＋ ファイル再検証済み |

**`readyToPublish` は成果物がまだ非公開で、コミット行も残っている状態です。**

**`outputFile` は `prepared` では `nil` です。** `ManagedFileStore.createFile` はファイルの作成が完了してからでないと `ref` を返さないため（[アーキテクチャ設計](architecture.md) の 7.3）、手順 0 の時点で参照を作れません。手順 1 で生成し、手順 2 で `verifiedOutput` と同時に保存します。

**`prepared` で落ちた場合、削除すべき出力ファイルは存在しません。** 手順 1 の途中で作られた一時ファイルは、どのコミット行からも参照されないため起動時の孤児 GC が回収します。

**「適用しようとする内容」と「実際に適用された結果」を分けます。** 台帳を更新する前に「実際に新規追加した値」を確定することはできません。ただし `AccountingApplied` を DB へ書く前に落ちる可能性があるため、**これだけを根拠にロールバックできません。** 台帳側の `ownerExportID` が最終的な判断材料です。

### 2.1 検証結果をジャーナルへ持つ

`fileVerified` で落ちた場合、`OutputRecord` はまだ存在しません（作られるのは手順 7）。検証済みファイルと同じ内容かを起動時に確認する材料が、コミット側になければ復旧できません。

- 復旧時は実体のサイズ・SHA-256・デコードを再確認し、`verifiedOutput` と突き合わせる
- 手順 7 の `OutputRecord` 作成時は、`verifiedOutput` から値を**コピーする（再計算しない）**

再計算ではなくコピーにするのは、手順 1 と手順 7 の間にファイルが差し替えられた場合に検出するためです。再計算すると差し替え後の内容を「正しい記録値」として固定してしまいます。

**アルゴリズムを名前で固定します。** 抽象名にすると実装ごとに別のアルゴリズムを選ぶ余地が残ります。**サイズも記録します。** ダイジェストだけでは手順 6 のサイズ照合ができず、サイズ比較はダイジェスト計算より安く途中書き込みを先に弾けます。

### 2.2 会計時刻は最終確定処理から導出する

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

---

## 3. 手順 0〜7

**この表が手順番号と状態遷移の唯一の正本です。** 他の文書はこの表を参照します。

| 順 | 操作 | 保存先 | 遷移後の状態 |
| --- | --- | --- | --- |
| −2 | `transact` 内で時刻正規化・月次更新・期限切れ grant の整理を**永続化**する。**`SourceLease` を追加する**（勘定を問わない）。`batchTrial(true)` なら**同じトランザクション内で**追加の `TrialReservation` を作る | ProtectedBlobStore | — |
| −1 | `transact` の結果として `ExportStartDecision` を得る。`.blocked` なら以降へ進まない | — | — |
| 0 | `ExportCommit` を保存（`verifiedOutput` / `intent` / `finalizedAt` はすべて `nil`）。**保存に失敗したら補償トランザクションで予約・lease・未参照 `SourceRecord` を削除し、ゲートを解放する** | DB | **`prepared`** |
| 1 | 一時ファイルを生成し、サイズ・SHA-256・デコードを検証して `VerifiedOutput` を得る | ファイルシステム | — |
| 2 | **`outputFile` と** `verifiedOutput` を確定して保存（`finalizedAt` はまだ `nil`） | DB | **`fileVerified`** |
| 3 | **`finalizedAt` を決め、`intent` を確定して**保存 | DB | **`finalizing`** |
| 4 | `UsageLedger` を冪等に**暫定適用**する。**予約の `trialEntries` への移動と `SourceLease` の削除も同じ台帳トランザクション内** | ProtectedBlobStore | — |
| 5 | `applied` を埋めて保存 | DB | **`accountingCommitted`** |
| 6 | `verifiedOutput` と出力ファイルの**健全性**を確認して保存 | ファイルシステム / DB | **`readyToPublish`** |
| 7 | **単一トランザクション**（3.4）。`OutputRecord` を作り、コミット行を削除する。**ここが会計の最終確定境界** | DB | （行が消える） |

```
prepared → fileVerified → finalizing → accountingCommitted → readyToPublish
                                                                   ↓
                                              手順 7 の単一トランザクションで削除
```

**手順 −2 の `SourceLease` は勘定の種類を問いません。** `paidUnlimited` の通常の単体書き出しには grant も予約もないため、lease が無ければ認可から正常生成までの間その素材を参照するものが台帳に存在せず、**処理中の素材が GC されます。**

**手順 4 と 5 を逆にしてはいけません。** 先に `accountingCommitted` を書くと、台帳が未反映のまま「反映済み」として復旧されます。この順なら 4 と 5 の間で落ちても状態は `finalizing` のままなので、台帳更新を冪等に再適用できます。

**手順 0 で `prepared` を先に書くのは、生成中に落ちたときに孤児となる一時ファイルを起動時に特定するため**です。ジャーナルに記録のない一時ファイルは掃除対象になります。

**台帳の更新は手順 4 です。手順 7 ではありません。** 手順 7 は DB だけのトランザクションであり、`ProtectedBlobStore` を同時に更新できません。

**手順 7 を省くと、書き出しのたびにコミット行が永久に蓄積します。** ジャーナルは中断からの復旧のためだけに存在するので、役目を終えたら消します。

冪等性の鍵は 2 種類です。**クォータ消費は `exportID`、トライアル消費は素材の同一性。**

### 3.1 確定点は 1 つだけ

> **検証済みファイルは、手順 7 が完了するまで UI・`MediaSaver`・`SharePresenter` へ公開しません。**
>
> 手順 4 で台帳へ会計を暫定適用し、**手順 7 のコミット行削除で最終確定します。**
>
> 本設計における「利用可能な出力の生成が正常に完了した時点」とは、**手順 7 まで完了した時点**を指します。

| 区間 | 性質 |
| --- | --- |
| 手順 7 より前 | 復旧またはロールバックが可能。成果物は非公開 |
| 手順 7 以降 | 成果物を利用者へ公開する。会計は戻さない |

これは仕様 14.2 の「保存処理または共有可能な状態になった」と一致します。手順 7 の完了が、まさに保存・共有が可能になる時点だからです。

以下では消費しません。検出のみ、プレビューのみ、キャンセル、生成の失敗、生成前の空き容量不足、**生成中の**異常終了、対応外形式。

**生成が完了したあとの異常終了では消費が確定したままです。** 出力は残り再起動後に受け取れるため、ここで消費を戻すと二重取りになります。**写真ライブラリへの保存は消費の条件に含みません。** 保存せず OS 共有だけで完結する経路が成立するためです。

### 3.2 非公開を構造で保証する

**「公開しない」と文章で書くだけでは防げません。** `OutputRecord` を会計直後に作ると、GRDB の `ValueObservation` はその時点から `generated` を観測でき、UI の購読先が `OutputRecord` である以上、最終確定より前に画面へ現れます。

**`OutputRecord` の作成を手順 7 へ移し、コミット行の削除と同一の DB トランザクションで実行します。**

| DB の状態 | 意味 |
| --- | --- |
| コミットあり・`OutputRecord` なし | **非公開**（処理中または復旧対象） |
| コミットなし・`OutputRecord` あり | **公開済み**（会計確定済み） |
| 両方あり | **起こらない**（トランザクションが保証する） |

手順 6 の健全性確認が `OutputRecord` ではなく `verifiedOutput` を参照するのは、この順序変更のためです。

### 3.3 手順 6 の確認内容

**存在確認だけでは不足です。** 0 バイトのファイル、途中まで書かれたファイル、デコードできないファイルも「存在する」ため、その状態でコミット行を削除できてしまいます。削除後は会計を戻すためのジャーナルが失われ、消費だけが残ります。

| 確認項目 | 目的 |
| --- | --- |
| `outputFile` から解決したファイルが存在する | 実体がある |
| ファイルサイズが 0 でなく、`verifiedOutput.byteSize` と一致する | 途中書き込みでない |
| SHA-256 が `verifiedOutput.sha256` と一致する | 内容が入れ替わっていない |
| 簡易デコードが成功する | 画像として開ける |

いずれかが不成立なら削除せず、そのコミットをロールバック対象として扱います。

### 3.4 手順 7 の直前に時刻を再確認する

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

あわせて、**バックグラウンド移行時に手順 3〜7 を進めません。** シーンの非活性化を受けたら次の保存点で停止し、復帰時に上記の再確認から再開します。停止位置は必ずいずれかの `ExportCommitState` であり、中間状態で止まりません。

### 3.5 手順 7 の内容

**DB に保存する状態は `OutputRecord` だけではありません。** `ExportRecord` と写真ごとのキュー状態も同じ DB にあり、`OutputRecord` の insert とコミットの delete だけでは「出力は公開済みだがキューは `exporting`」「キューは `completed` だが `ExportRecord` が無い」が残ります。

| 操作 | 対象 |
| --- | --- |
| `OutputRecord(generated)` を insert | `OutputRecord` |
| 成功記録を insert | `ExportRecord` |
| 対象キュー項目を `completed` へ更新 | キュー状態 |
| プロジェクトの最終更新時刻を更新 | `Project` |
| `ExportCommit` を delete | `ExportCommit` |

バッチの成功件数・失敗件数は、**キュー項目からの導出値**とします。

```swift
struct OutputRecord: Sendable {
    let exportID: ExportID
    let projectID: ProjectID
    let batchID: BatchID?
    let outputFile: OutputFileRef
    let outputByteSize: Int64               // verifiedOutput からコピー
    let outputSHA256: Data                  // verifiedOutput からコピー
    let state: OutputState
    let generatedAt: Date                   // ExportCommit.finalizedAt からコピー
    let expiresAt: Date                     // finalizedAt + 24h

    // 再起動後の受け渡しに必要。手順 7 で確定値をコピーする
    let format: ImageFormat
    let suggestedCreationDate: Date?
}
```

**パスを DB へ直接持ちません。** パス文字列を保存すると、DB を書き換えるだけで `../` を含む値を注入でき、期限切れ削除の処理に別のアプリ内部ファイルを消させる経路ができます。

**受け渡しに必要な値も `OutputRecord` が持ちます。** 起動時復旧は未受け渡し出力を復元し、その後 `MediaSaver` または `SharePresenter` へ `OutputFile` を渡します（[画像処理](image-pipeline.md)）。`format` と `suggestedCreationDate` が無ければ `OutputFile` を組み立てられません。

**`Project` の現在値や出力ファイルの再解析から復元しません。**

| 復元しようとする値 | 復元できない理由 |
| --- | --- |
| `format` | `Project` の `ExportSetting` は書き出し後に変更されうる |
| `suggestedCreationDate` | メタデータ設定が「日時を保持しない」なら出力ファイルに残っていない |
| 同上 | 写真ライブラリの登録日時はそもそも出力ファイルへ書かれない |

**期限を `OutputRecord` 自身が持ちます。** `ExportCommit` は完了後に削除するため、**コミットが消えたあとも単独で期限を判定できる**必要があります。判定規則は 6.2 にあります。

---

## 4. ロールバック

| 順 | 操作 | 保存先 |
| --- | --- | --- |
| 1 | `transact` で、この `exportID` が所有する会計要素（消費・grant・トライアル台帳・トライアル予約・**`SourceLease`**）を**冪等に**取り消す | ProtectedBlobStore |
| 2 | 台帳の保存が成功したことを確認する | ProtectedBlobStore |
| 3 | `OutputRecord` を削除する（存在する場合のみ） | DB |
| 4 | `outputFile` のファイルを削除する | ファイルシステム |
| 5 | `ExportCommit` を削除する | DB |
| 6 | 開始ゲートを解放する | メモリ |

- **手順 1 が失敗した場合、2 以降を実行しません。** コミットとファイルを残したまま復旧エラーとします。台帳を戻せていないのにジャーナルを消すと、消費だけが残って根拠が失われます
- **手順 1 の完了後に落ちても、再起動時に同じロールバックを冪等に再実行できます**
- **`ExportCommit` の削除後にのみゲートを解放します。** 解放が早いと、ロールバック途中の台帳を次の認可が読みます
- 取り消してよいのは、台帳の `ownerExportID` がこの `exportID` と一致する要素だけです

取り消しの判断材料は台帳側の `ownerExportID` です。`AccountingApplied` は DB へ書く前に落ちうるため、単独では根拠になりません。

```
consumedExportIDs に対象 exportID があれば削除
grants            のうち ownerExportID == 対象 exportID の要素を削除
trialEntries      のうち ownerExportID == 対象 exportID の要素を削除
trialReservations のうち exportID == 対象 exportID の要素を削除
sourceLeases      のうち exportID == 対象 exportID の要素を削除
別の exportID が作った要素は削除しない
```

既存の grant を再利用しただけの書き出しは `ownerExportID` が一致しないため、以前から存在した権利を巻き添えで消しません。

| 状態 | 台帳への適用 | ロールバック経路 |
| --- | --- | --- |
| `prepared` | **`SourceLease`**、トライアル時のみ予約 | 手順 1〜6。lease・予約・未参照 `SourceRecord` の取り消しは必要。`OutputRecord` は未作成 |
| `fileVerified` | 同上。`finalizedAt` は未確定 | 手順 1〜6 |
| `finalizing` | 上記 ＋ **暫定会計が存在しうる** | 手順 1〜6。`intent` の内容を `ownerExportID` と突き合わせて取り消す |
| `accountingCommitted` | 適用済み | 手順 1〜6。`applied` ではなく台帳の `ownerExportID` を根拠にする |
| `readyToPublish` | 適用済み | **同一プロセス内なら**手順 7 を実行して完了。**起動時に発見した場合は**暫定会計を取り消して手順 3 から再開 |

### 4.1 会計の最終確定境界

**コミット行の削除をもって会計を最終確定とします。ジャーナルが残っている間だけ、会計をロールバックできます。**

理由は 2 つです。

**1. 消費の確定点が曖昧になる。** 生成完了後の異常終了では消費を戻さず、利用者が破棄しても戻さず、トライアルは初回の正常生成で消費します。コミット削除まで完了した出力は正常生成が確定済みであり、その後のストレージ障害だけを払い戻し対象にすると「異常終了では戻さないがストレージ障害では戻す」という区別が必要になります。

**2. 所有者モデルが破綻する。** Export A が grant を作り所有者になる → A のコミットを正常に削除する → 同じ素材を Export B で正常に再書き出しする（B は既存 grant を利用するため所有者は A のまま）→ 後から A の出力ファイルが失われる → `ownerExportID` を根拠に grant を削除する → **B も正常成功しているのに grant が消える。** 非終端コミットの直列化は非終端の間しか効かず、A のコミットは既に削除済みなので B の開始を止められません。

### 4.2 キャンセルの境界

| 時点 | 扱い |
| --- | --- |
| 手順 4 より前 | ロールバック。消費なし |
| 手順 4 以降・手順 7 より前 | 暫定会計を取り消してロールバック |
| 手順 7 の完了後 | **キャンセルではなく破棄として扱う。** 枠は戻さない |

手順 7 が完了した時点で成果物は公開されており、正常生成が確定しています。UI 上も、手順 7 の完了後は取り消せるかのような文言にしません。

---

## 5. 起動時復旧

**復旧を終えるまで、新しい書き出しを開始させません。** 先に許可すると、あとから古いコミットをロールバックした際に、すでに進んだ現在の台帳まで壊しかねません。

**各手順が前の手順の結果に依存します。**

| 順 | 操作 | 依存 |
| --- | --- | --- |
| −4 | **保護データが利用可能になるまで待つ** | — |
| −3 | `app.db` を開く | −4 の完了 |
| −2 | `journal_mode` / `synchronous` / `foreign_keys` を設定・検証する | −3 の完了 |
| −1 | **DB のスキーマ移行を実行する**（5.1） | −2 の完了 |
| 0 | **`ProtectedBlobStore` のスキーマ移行を実行する** | −1 の完了 |
| 1 | `UsageLedger` を読み込み、検証し、必要なら修復する | 0 の完了 |
| 2 | `ExportCommit` を読み込み、行ごとの署名を検証する | 0 の完了 |
| 2.5 | **手順 1 で台帳を修復した場合、全非終端コミットを破棄する**（5.2） | 1・2 の完了 |
| 3 | **有効なコミットに対応しない `trialReservations` と `sourceLeases` を削除する** | 1・2 の完了 |
| 4 | 有効な未完了コミットを復旧する（5.3） | 1・2・3・2.5 の完了 |
| 5 | `PRAGMA foreign_key_check` で外部キー違反が無いことを確認する | 4 の完了 |
| 6 | `PendingFileDeletion` と孤児ファイルを回収する | 5 の完了 |
| 7 | 未受け渡し出力を復元する | 5 の完了 |
| 8 | **`evaluateUpdate` を実行する** | 7 の完了。`generated` の件数が必要 |
| 9 | `.required` なら更新画面、それ以外は通常画面を表示し、**新しい書き出しを許可する** | 全手順の完了 |

- **手順 −4 を最初に置くのは、`.complete` のファイルがロック中に読めないためです。** DB を開く前に待ちます
- **手順 3 を手順 4 より前に置きます。** 孤児予約はクレジットを占有したままなので、回収前に新しい認可を許可すると、実際には空いているクレジットを「使用中」と判定します
- **手順 5 を手順 4 の後に置きます。** ロールバックが `OutputRecord` を削除するため、先に検査すると存在しない違反を検出します
- **手順 6 を手順 5 の後に置きます。** ロールバックと孤児削除が `PendingFileDeletion` へ行を追加しうるため、先に GC を走らせるとその回で回収できません
- **署名検証に失敗したコミットに対応する予約と lease は、手順 3 で自動削除しません**（6 章）

### 5.1 スキーマ移行

`app.db` は 1 つなので `DatabaseMigrator` も 1 系列です。各移行ステップは単一トランザクションで確定し、途中適用が観測されません。



##### 署名付き行の移行

**手順 −1（スキーマ移行）は手順 2（署名検証）より前にあります。** `ExportCommit` の署名対象カラムを通常の SQL migration で先に変換すると、**旧 canonical bytes を再現できなくなり、正規の行がすべて検証失敗します。**

署名付き行の移行は、通常の SQL migration とは別の経路で行います。

| 順 | 操作 |
| --- | --- |
| 1 | **旧 schema のまま**、旧 canonical 形式で署名を検証する |
| 2 | 検証を通った行だけ、値を新しい型へ変換する |
| 3 | **新 canonical 形式で再署名する** |
| 4 | 行の更新と schema version の更新を**同一 DB トランザクション**で確定する |
| 5 | 検証できなかった行は**変換せず**、復旧エラーとして残す（6 章） |

**検証不能な行を自動変換しません。** 変換すれば新しい署名が付き、改ざんされた内容が正規の行として通ります。

この規則は `ProtectedBlobStore` の payload（手順 0）にも同じく適用します。

### 5.2 台帳を修復した起動では再開しない

**`UsageLedger` の HMAC 不一致で修復が走った起動では、署名が正常な未完了コミットも再開できません。**

修復済み台帳は `sourceRecords` / `sourceLeases` / `grants` / `trialEntries` / `trialReservations` をすべて空にします（[アーキテクチャ設計](architecture.md) の 6.3）。一方 `ExportCommit` が持つのは `sourceID` だけで、**元の alias を持ちません。** 手順 4 で grant や `TrialEntry` を再追加すると、次の不変条件を満たせません。

> `grants` / `trialEntries` / `trialReservations` / `sourceLeases` の `sourceID` は `sourceRecords` に存在する。

**修復が走った起動では、全非終端コミットを破棄します。**

| 対象 | 操作 |
| --- | --- |
| 非終端の `ExportCommit` | **すべて削除する**（署名の有効・無効を問わない） |
| 出力ファイル | 参照が消えるため、起動時の孤児 GC が回収する |
| `UsageLedger` | **触らない。** 既に修復済みで、整合性封鎖が掛かっている |
| キュー項目 | `failed`（`isRetryable == true`）へ遷移させる |
| 月間枠・トライアル | **整合性封鎖のまま。** 復元も払い戻しもしない |

**`ExportCommit` へ alias のスナップショットを持たせて `SourceRecord` を再構築する案は採りません。** コミット行に素材識別値を持たせると、署名不正行の扱い（6 章）が「フィールドを一切使わない」と両立しなくなります。修復はそもそも改ざんの疑いがある状態であり、**進行中の書き出しを完了させる利得より、台帳の一貫性を優先します。**

この分岐は手順 2 の直後（手順 4 の復旧より前）に置きます。障害注入テストの対象です。

### 5.3 状態別の復旧

| 中断位置 | 復旧 |
| --- | --- |
| `prepared` | 一時ファイルを削除し、**トライアル予約・`SourceLease`・未参照になった `SourceRecord`** を取り消してコミットを破棄する。生成未完了なので消費しない |
| `fileVerified` | ファイルが健在なら**手順 3 からやり直す**（新しい `finalizedAt` を決める）。失われていればロールバック |
| `finalizing` | 暫定適用があれば冪等に取り消し、**手順 3 からやり直す** |
| `accountingCommitted` | **出力ファイルを再検証**する（5.4）。正常なら暫定適用を取り消し、**手順 3 からやり直す** |
| `readyToPublish` | 出力ファイルを `verifiedOutput` と照合する。正常なら暫定適用を取り消し、**手順 3 からやり直す**。不一致ならロールバック |
| 署名検証に失敗 | 復旧エラー。自動破棄しない（6 章） |

**`finalizing` 以降からの復旧は、`readyToPublish` を含めて必ず手順 3 へ戻ります。例外はありません。** `readyToPublish` で異常終了し数日後に再起動した場合、`finalizedAt` は数日前で `expiresAt = finalizedAt + 24h` はすでに過ぎており、**公開した瞬間に期限切れの出力ができます。** ファイル検証が済んでいることと、時刻が妥当であることは別の話です。

**`readyToPublish` を無条件に削除しません。** 手順 6 と 7 の間で落ちた可能性があり、**コミット行だけが復旧の手がかり**だからです。この時点では `OutputRecord` がまだ無いため、コミットを消すと出力が孤児ファイルになります。

### 5.4 `accountingCommitted` からの復旧

台帳は暫定適用済みなので、**ファイルが失われていれば「消費したのに受け取れない出力」になります。**

| 再検証の結果 | 対応 |
| --- | --- |
| 正常 | 暫定適用を取り消し、手順 3 からやり直す（`OutputRecord` は手順 7 で作る） |
| 欠損・破損 | **このコミットが実際に追加した会計要素だけ**を取り消す（4 章） |
| 取り消し不能 | 復旧エラーとして新規書き出しをブロックする。自動削除しない |

---

## 6. 署名不正コミット

`ExportCommit` は DB にありますが、その内容が ProtectedBlobStore の台帳更新を駆動します。**DB を書き換えれば台帳を任意に操作できてしまう**ため、コミット行にも HMAC を付けます。

**署名検証に失敗した行を自動破棄しません。** 破棄すると、すでに反映済みの `UsageLedger` だけが残る可能性があります。会計済みかどうかを判断できない以上、**復旧エラーとして扱い**、新規書き出しをブロックしたうえで利用者へ提示します。ファイルも自動削除しません。

### 6.1 復旧エラーの解消

**ブロックしたまま解除手段がないと、破損したコミット 1 件でアプリが永久に書き出し不能になります。** 利用者には「もう一度試す」と「破損した処理を破棄して続ける」を提示します。

「破棄して続ける」の挙動です。

- クォータやトライアルクレジットを払い戻さない
- **台帳側の予約を先に確定させる**（6.2）
- 該当の `ExportCommit` を**行 ID で**削除する。**出力ファイルと `OutputRecord` には触れない**
- 復旧エラーを解除し、新規書き出しを許可する

払い戻さないため利用者に不利になりえますが、**破損した DB の情報を根拠に権利を増やす方が危険**です。改ざんによる枠の水増しに直結します。

### 6.2 署名不正行のフィールドを一切使わない

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
| **1 件** | その `exportID` の `TrialReservation` があれば同じ `sourceID` の `TrialEntry` へ変換し、`SourceLease` を削除する。台帳の保存成功を確認してから、署名不正行を行 ID で削除する |
| **2 件以上** | 対応を一意に決められない。**復旧エラーを維持し、台帳へ触れない** |

**0 件は正常な状態です。** `SourceLease` は手順 4 の台帳トランザクションで削除されるため、`accountingCommitted` / `readyToPublish` / 手順 4 完了後・手順 5 保存前にコミット行だけが壊れた場合、孤立 lease は 0 件になります。0 件は「台帳側にこの書き出しの痕跡が残っていない」ことを意味し、**台帳へ何もしないことが正しい対応**です。会計は既に確定しており、払い戻しは行いません。

2 件以上は全体ゲートが 1 件しか許さないはずの状態と矛盾するため、自動で決めず復旧エラーを維持します。

**1 件の場合に台帳の保存が失敗したら、コミットを削除せず復旧エラーを維持します。** 台帳を確定できていないのにコミットを消すと、次回起動で孤児予約として払い戻されます。

**署名不正行が存在する間は、孤児 `TrialReservation` と孤児 `SourceLease` の自動回収を全件保留します**（5 章の手順 3）。どの孤児が破損行に対応するかを識別できないためです。

### 6.3 ファイルには触れない

署名不正行の `outputFile` と `projectID` は信用できません。`ManagedFileRef` により専用ディレクトリの外へは出られませんが、**同じディレクトリ内の別の正常な出力を指すことは可能です。**

行を削除したあと、その出力ファイルはどこからも参照されなくなります。**起動時の孤児ファイル GC が回収します。** 参照の有無だけを根拠にするため、改ざんされたフィールドの影響を受けません。

`TrialEntry` の `ownerExportID` には対象の `exportID` をそのまま入れます。**その書き出しは成功していませんが、クレジットは消費されたものとして扱います。** 同じ素材を再度処理する場合は `batchTrial(false)` となり追加のクレジットは消費しないため、利用者から見れば「1 枚分の試用機会を使ったが、その素材はまた試せる」状態になります。

---

## 7. コミット確定後に出力実体が失われた場合

ジャーナルを消したあとで `OutputRecord` と実体が食い違うことは、外部要因（OS によるキャッシュ削除、ストレージ障害）で起こりえます。

**v1 では自動再生成を行いません。**

| 状況 | 扱い |
| --- | --- |
| 実体が無い、または `outputByteSize` / `outputSHA256` と一致しない | **`OutputRecord` を削除する**（4 章のロールバックではなく、7.5 の出力削除経路） |
| `UsageLedger` | **変更しない。** 月間枠・grant・トライアルクレジットのいずれも戻さない |
| 利用者への提示 | 出力を復元できないこと、および**新しい書き出しになる**ことを示す |
| 24 時間以内の同一素材 | grant により `freeMonthlyReexport` が成立するため、追加消費なしでやり直せる |

`retentionNow == nil` の間は削除も判定も保留します（時計異常中に破壊的削除を行わないため）。

### 7.1 自動再生成を持たない理由

**現在保持しているデータでは再生成できません。**

| 必要なもの | 現状 |
| --- | --- |
| 元画像 | `WorkingSourceRecord` は書き出し完了時に削除される（[画像処理](image-pipeline.md)） |
| `RenderSpec` | `OutputRecord` は保持しない。`Project` 側は編集で変化しうる |
| `ExportSetting`（形式・品質・メタデータ） | `OutputRecord` は保持しない |
| `OutputFile.format` / `suggestedCreationDate` | `OutputRecord` が持つようになった（3.5）。ただし他が揃わない |

再生成を成立させるには、**出力の期限まで不変のスナップショット**（正確な `RenderSpec` と `ExportSetting`、元画像の再取得手段または処理用コピー、出力形式と登録日時、再取得権限が無い場合の利用者操作）を保持する必要があります。

これは未加工の顔画像を最大 24 時間追加で保持することを意味し、**プライバシーと容量の複雑性が v1 の利得に釣り合いません。** 同じ素材の再書き出しは grant により追加消費なしで行えるため、利用者の損失は「もう一度操作する手間」に限られます。

v2 で保持コストを許容できる場合は、不変のスナップショットと専用の復旧ジャーナルを導入する設計へ拡張します。v1 の文書には契約を置きません。
---

## 8. 利用者への受け渡し

- 写真ライブラリへ保存する（`MediaSaver`）
- OS 共有へ渡す（`SharePresenter`）

いずれも任意であり、何度実行しても追加消費しません。失敗した場合は生成済み出力を保持したまま再試行でき、**再書き出しは不要です。**

### 8.0 写真ライブラリ保存の結果不明

**PhotoKit と `app.db` は同一トランザクションにできません。** 次の中断点が残ります。

```
PhotoKit への保存が成功
  → OutputRecord を delivered へ更新する前にプロセスが終了
  → 再起動後は generated に見える
  → 再保存すると写真ライブラリに重複する
```

**exactly-once は保証できません。** 保証できないことを明示し、**自動再試行で重複を作らない**設計にします。

```swift
/// 保存の試行中を表す。runtime 側のテーブル
struct DeliveryAttempt: Sendable {
    let exportID: ExportID
    let startedAt: Date
}
```

| 順 | 操作 | 保存先 |
| --- | --- | --- |
| 1 | `DeliveryAttempt` を記録する | DB |
| 2 | `MediaSaver.saveToPhotoLibrary` を実行する | PhotoKit |
| 3 | 成功したら、`OutputRecord` を `delivered` へ更新し `DeliveryAttempt` を削除する（**同一トランザクション**） | DB |
| 4 | 失敗したら `DeliveryAttempt` を削除する。`generated` のまま再試行できる | DB |

**起動時に `DeliveryAttempt` が残っていれば、手順 2 と 3 の間で終了しています。**

| 状態 | 扱い |
| --- | --- |
| `DeliveryAttempt` が残っている | **`deliveryUnknown`**。`generated` でも `delivered` でもない |
| 自動再保存 | **行わない**（重複を作りうる） |
| 自動削除 | 行わない。出力は保持する |
| 利用者への提示 | 写真ライブラリを確認したうえで、保存済みなら破棄、未保存なら再試行を選ばせる |

```swift
enum OutputState: Sendable { case generated, deliveryUnknown, delivered, discarded }
```

`deliveryUnknown` は**未受け渡しとして扱います。** 24 時間の保持対象であり、完了画面の離脱確認にも数えます。**受け取れていない可能性がある側へ倒します**（`.unknown` の共有結果と同じ方針）。

OS 共有（`SharePresenter`）にはこの経路がありません。結果が同期的に返るためです。

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

### 8.1 `ShareLink` では実装できない

**`SharePresenter` は `UIActivityViewController` だけで実装します。** `ShareLink` は共有 UI を提示する `View` であり、**完了結果を返す API を持ちません。** 上の 4 値を返せない以上、`delivered` への遷移条件を判定できません。

`completionWithItemsHandler` からの写像です。

| 条件 | 結果 |
| --- | --- |
| `activityError != nil` | **`.failed`** |
| `completed == true` | **`.completed`** |
| `completed == false` かつ `activityType == nil` | **`.canceled`**（シートを閉じた） |
| それ以外 | **`.unknown`** |

最後の行が要点です。`completed == false` でも `activityType` が入っている場合は、**共有先アプリが結果を返さなかった**ことを意味します。取りやめとは区別できないため `.unknown` とします。

`UIViewControllerRepresentable` で包み、`CheckedContinuation` で `async` 関数として公開します。
