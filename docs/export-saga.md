# 書き出し Saga

| 項目 | 内容 |
| --- | --- |
| 目的 | 書き出しの認可、状態遷移、処理順、ロールバック、起動時復旧を一意に定める |
| 読者 | `Application` 層の実装者、障害注入テストの作成者 |
| 正本の範囲 | `ExportCommit` の型と状態、手順 −2〜9、ロールバック順序、起動時復旧順序、署名不正コミットの扱い、実体喪失時の扱い、受け渡し |
| 関連 | [アーキテクチャ設計](architecture.md)（`UsageLedger`、`ResolvedCapabilities`、`ManagedFileRef`）、[正準スキーマ](canonical-schema.md)（署名バイト表現）、[テスト計画](test-plan.md) |

書き出しの完了で確定する事柄は、保存先が3つに分かれる。

| 更新対象 | 保存先 |
| --- | --- |
| 完成済みファイルの公開 | ファイルシステム |
| `OutputRecord` = `generated` | DB |
| Free 枠の消費、`ExportGrant` の作成、トライアル台帳への素材追加 | ProtectedBlobStore |

単一トランザクションで更新できないため、永続的なコミットジャーナル（`ExportCommit`）を置く。

---

## 0. Application が使う永続化ポート

`Application` は `Domain` のプロトコルだけを使う（[アーキテクチャ設計](architecture.md) の 4.3）。Saga が必要とする操作を、トランザクション境界ごとに切る。

```swift
// Domain — Foundation のみ

protocol UsageLedgerStore: Sendable {
    /// 変換関数が触れるのは LedgerMutableView（検証カウンタ 2 つを除いた射影）。
    /// 保存直前に unverifiedLedgerWrites と ledgerWritesSinceConfigFetch を +1 する
    /// （アーキテクチャ設計 4.2 / 6.2）
    func transact<R: Sendable>(
        _ transform: @Sendable (LedgerMutableView) throws -> LedgerTransaction<R>
    ) async throws -> R

    /// CustomerInfo.requestDate が前回より新しく、SubscriptionState の保存も
    /// 成功した後だけ呼ぶ。unverifiedLedgerWrites を 0 へ（アーキテクチャ設計 6.2）
    func recordEntitlementRefresh() async throws

    /// /v1/config の HTTP レスポンスを新規に受信したら呼ぶ。
    /// 同一 configVersion で保存が起きなかった場合も呼ぶ（同 6.2 / 10.2）
    func recordConfigRefresh() async throws

    /// integrityFailure / missing かつ痕跡ありのときの保守的修復。
    /// transact と同じ排他区間を取るが、変換関数は通さない。
    /// 排他区間の内側で読み直して判定する（同 6.3）
    func repairLedger(evidence: PriorUseEvidence) async throws
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

    /// 手順 2 の入力。署名検証と手順 2.5 の破棄判定だけに使う（5 章）
    func loadSignedCommitRows() async throws -> [SignedCommitRow]

    /// 手順 2.5。台帳修復時に、行 ID を指定して非終端コミットを破棄する（5.2）
    func discardCommitsForLedgerRepair(rowIDs: [Int64]) async throws

    /// 起動時復旧の入力（5 章）。手順 2.8 で 1 回だけ読む
    func loadRecoverySnapshot() async throws -> RecoverySnapshot

    /// 復旧の完了後に実行する（5 章の手順 5）
    func checkForeignKeys() async throws -> [ForeignKeyViolation]

    /// ロールバックの手順 0。state を rollingBack へ更新する（4 章）。
    /// HMAC と「state が prepared〜readyToPublish のいずれか」を再検査する。
    /// published / rollingBack なら throw する
    func markRollingBack(_ exportID: ExportID) async throws

    /// ロールバックの手順 4。state == rollingBack と HMAC を再検査して削除する
    func deleteRolledBack(_ exportID: ExportID) async throws

    /// 署名不正行を DB 内部の行 ID で削除する（6 章）
    func deleteCommitByRowID(_ rowID: Int64) async throws

    /// 手順 9。HMAC と state == published を再検査して削除する。
    /// 手順 8 の pending が解消（昇格または削除）したあとにのみ呼ぶ（3 章）
    func deletePublished(_ exportID: ExportID) async throws

    /// 手順 4 の完了後に、変化した DB 状態を読み直す（5 章）
    func loadPostCommitRecoverySnapshot() async throws -> PostCommitRecoverySnapshot
}

/// 受け渡し（8 章）。ExportSagaStore とは寿命が異なるため分ける
protocol OutputDeliveryStore: Sendable {
    /// 現在の状態を previousState として記録する
    func beginDeliveryAttempt(_ exportID: ExportID) async throws

    /// 写真ライブラリ保存の成功。delivered への更新と attempt の削除を単一トランザクションで
    func completeLibrarySave(_ exportID: ExportID) async throws

    /// 共有の成功。attempt は関与しない
    func completeShare(_ exportID: ExportID) async throws

    /// 失敗。previousState へ戻し attempt を消す（現在が delivered なら維持）
    func abandonDeliveryAttempt(_ exportID: ExportID) async throws

    /// 起動時。残存 attempt を previousState に応じて解決し、
    /// 解決後の全出力の受け渡し状態を返す（単一トランザクション）
    func resolveOrphanedAttempts() async throws -> [OutputDeliverySnapshot]

    /// 起動時と画面表示で、残っている注記を読む
    func loadUnknownLibrarySaves() async throws -> [UnknownLibrarySave]

    /// 「保存結果不明」の案内を利用者が確認した
    func clearUnknownLibrarySave(_ exportID: ExportID) async throws

    /// 利用者の明示操作のみ
    func markDiscarded(_ exportID: ExportID) async throws
}

// OutputDeliverySnapshot の定義はアーキテクチャ設計 7.5
```

`resolveOrphanedAttempts` は解決後の全件を返す。戻り値がその時点の受け渡し状態の正であり、起動時復旧の手順 7.5 と 8 はこれを入力にする（5 章）。

手順 7 は複数の Repository 呼び出しとして `Application` 側で組み立てない。単一 DB トランザクションを保証できないと「出力は公開済みだがキューは `exporting`」が残る。

```swift
struct ExportQueueItemID: Sendable, Hashable { let rawValue: UUID }

/// 手順 7 の入力。レコードの中身は保存済みコミットから導出する
struct FinalizeExportInput: Sendable {
    let exportID: ExportID
    let queueItemID: ExportQueueItemID?   // 単体書き出しでは nil
}

/// 変換関数が読み書きできる台帳の射影。
/// UsageLedger の 18 フィールドから、検証カウンタ 2 つ
/// （unverifiedLedgerWrites / ledgerWritesSinceConfigFetch）を除いた 16 フィールド。
/// 加算は transact の内側、リセットは専用メソッドだけが行う
/// （アーキテクチャ設計 6.2）
struct LedgerMutableView: Sendable, Equatable {
    // UsageLedger の 1〜16 番目と同じ（正準スキーマ 4.1）
}

/// 台帳の更新結果と、同じ排他区間で取り出す値を 1 つにまとめる
struct LedgerTransaction<R: Sendable>: Sendable {
    let ledger: LedgerMutableView   // 保存する新しい台帳（射影）
    let result: R                   // 認可結果など、呼び出し元が必要とする値
}

/// 署名検証前の行を含む、起動時の一括読み取り
struct RecoverySnapshot: Sendable {
    let commits: [SignedCommitRow]
    let nonTerminalQueueItems: [ExportQueueItemSnapshot]
    let workingSources: [WorkingSourceRecord]

    /// 手順 3 の孤児回収を保留するかの判定に使う（6.2）
    let hasSignatureInvalidCommit: Bool
}

/// 署名検証はまだ通っていない。rowID は破棄のためだけに使う（6 章）
struct SignedCommitRow: Sendable {
    let rowID: Int64
    let schemaVersion: UInt32   // 正準バイト列の再構築とデコーダ選択に使う
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
    let delivery: Data          // 署名対象の 13 番目
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

`finalizeExport` の実装が、`OutputRecord` の insert・`ExportRecord` の insert・キュー項目の `completed` 更新・`Project` の最終更新時刻・`WorkingSourceRecord` の delete・`ExportCommit` の `published` への更新を **1 回の DB トランザクション**で行う。この境界が手順 7 の正本。コミット行の削除は手順 9（`deletePublished`）。

読み取りは3回に分かれる。それぞれ入力を必要とする手順が違い、その間に DB が変わるため。

| 呼び出し | 手順 | 返す値 | 使う手順 |
| --- | --- | --- | --- |
| `loadSignedCommitRows()` | **2** | `[SignedCommitRow]`（検証前の生の行） | 手順 2（署名検証）と手順 2.5（破棄対象の行 ID の決定） |
| `loadRecoverySnapshot()` | **2.8** | `RecoverySnapshot` | 手順 3・4 |
| `loadPostCommitRecoverySnapshot()` | **4.2** | `PostCommitRecoverySnapshot` | 手順 4.5・5・5.5・6・7 |

手順 2 の読み取りを `RecoverySnapshot` で兼ねない。手順 2.5（台帳修復時の破棄。5.2）は非終端 `ExportCommit` を全削除するため、手順 2 の時点で `RecoverySnapshot` を読むと、手順 4 が「2.5 が破棄したはずのコミット」を復活させる。手順 2 が必要とするのはコミット行だけ（署名検証と非終端判定に `OutputRecord` や `WorkingSourceRecord` は要らない）。

`RecoverySnapshot` はコミット復旧（手順 3・4）の入力。手順 2.8 で一度だけ読み、個別クエリを繰り返さない。`hasSignatureInvalidCommit`（手順 3 の保留判定に使う）は `RecoverySnapshot` にも持たせる。

| 手順 | DB を変えるか | snapshot の扱い |
| --- | --- | --- |
| 1 | 台帳のみ | — |
| 2 | 変えない | `loadSignedCommitRows()` で行だけを読む |
| **2.5** | **変える**（コミット・`WorkingSourceRecord`・キュー） | この後に `loadRecoverySnapshot()` を呼ぶ |
| 3 | 台帳のみ | 影響なし |
| **4** | **変える**（下表） | この後に `loadPostCommitRecoverySnapshot()` を呼ぶ |
| 4.5 | 変えうる（無効化） | 手順 5.5 は下記のとおり再判定する |
| 5・5.5・6 | 5.5 と 6 は変える | それぞれ自分の走査で読む |
| **7** | **変える**（受け渡し状態） | 戻り値を 7.5 と 8 が使う |

手順 4 は DB を変えるため、その後の手順は同じ snapshot を使えない。

| 手順 4 で起こる変化 | 影響を受ける後続手順 |
| --- | --- |
| `readyToPublish` の復旧で新しい `OutputRecord` ができる | 手順 7.5（未受け渡し出力の復元）、手順 8（更新判定の件数） |
| 手順 7 の完了で `WorkingSourceRecord` が消える | 手順 4.5（binding の照合） |
| `published` の手順 8・9 が進み pending と `published` コミットが消える | 手順 5.5（孤児の回収） |

手順 4.5 の無効化が起こす変化は、手順 5.5 の内側で読み直す。4.5 は照合失敗時に `WorkingSourceRecord` を破棄するが、その台帳側（binding 削除）だけが失敗する可能性がある。手順 5.5 は「`WorkingSourceRecord` が無い孤児 binding」を、4.2 の snapshot ではなくその時点の DB から判定する（孤児回収は自分が消す対象を自分で読む、が原則）。

```swift
/// コミット復旧の後に読み直す。手順 4.5〜7 の入力（7.5 以降は手順 7 の戻り値）
struct PostCommitRecoverySnapshot: Sendable {
    let outputRecords: [OutputRecord]
    let deliveryAttempts: [DeliveryAttempt]
    let unknownLibrarySaves: [UnknownLibrarySave]
    let workingSources: [WorkingSourceRecord]
    let nonTerminalQueueItems: [ExportQueueItemSnapshot]
    let projectIDs: Set<ProjectID>
    let publishedCommitExportIDs: Set<ExportID>   // 手順 8・9 が残っているもの
    let allCommitExportIDs: Set<ExportID>         // 署名不正行も含む、行として存在する全件
    let hasSignatureInvalidCommit: Bool           // 孤児回収の保留判定に使う（5.5 / 6.2）
}
```

`loadPostCommitRecoverySnapshot()` は手順 4 の完了直後に 1 回だけ呼ぶ。手順 7 も DB を変える（`OutputRecord.state` の更新、`DeliveryAttempt` の削除、`UnknownLibrarySave` の追加）ため、手順 7.5 と 8 はこの snapshot ではなく `resolveOrphanedAttempts()` の戻り値（解決後の全 `OutputDeliverySnapshot`）を使う（0 章）。

`SignedCommitRow` は検証前の生の列を持つ。`ExportCommit` としてデコードすると署名不正行のフィールドを使う経路ができるため、検証を通った行だけが `ExportCommit` になる。`ExportCommitColumns` はすべて生のバイト列か固定幅の整数であり、デコードできる型にすると署名検証前にフィールドを使う経路ができる。署名対象の全フィールドを列として持つ（`delivery` を含む。1 つでも欠けると正準バイト列を再構築できない）。`schemaVersion` も行として持つ（署名対象に含まれ、[正準スキーマ](canonical-schema.md) の 1、旧デコーダ選択の起点となる）。

外部キーの検査は `RecoverySnapshot` に含めない（検査は未完了コミットの復旧後、5 章の手順 5 に行うため）。単一 `app.db` では外部キーが実制約として効くため違反は通常発生しない。検出した場合は復旧エラーとし、自動修復しない。

##### `finalizeExport` は入力を信用しない

`FinalizeExportInput` は `OutputRecord` も `ExportRecord` も受け取らない。渡すのは、コミットから導出できない 2 つだけ。

| フィールド | コミットから導出できない理由 |
| --- | --- |
| `exportID` | 対象の指定そのもの |
| `queueItemID` | キュー項目はコミットが持たない（単体書き出しでは `nil`） |

`projectUpdatedAt` も渡さない（`commit.finalizedAt` から導出できる。別の時刻を渡せると `Project` の更新時刻だけを任意に操作できてしまう）。

実装はトランザクション内で、同じ `exportID` の保存済みコミットについて次を確認する。

| 確認 | 不成立なら |
| --- | --- |
| `state == readyToPublish` | throw。手順 7 を実行しない |
| HMAC 検証を通る | throw |
| `verifiedOutput` と `outputFile` が存在する | throw |
| `finalizedAt` / `finalizedPeriod` が存在する | throw |
| 同じ `projectID` の `OutputRecord` が存在しない | throw（下記） |

`OutputRecord.projectID` の UNIQUE 制約を事前検査する（[アーキテクチャ設計](architecture.md) の 7.1）。未削除の `delivered` 出力が残る `Project` を再書き出しすると、手順 4（台帳への暫定適用）まで進んだ後に手順 7 が制約違反で失敗するため、検査で弾く。通常は未受け渡し出力がある状態で新しい加工を開始できず（同 7.5）、`delivered` は完了画面を離れた時点で削除されるため先に解消される。この検査はその規則が破れた場合の最後の防御。

キュー項目も同じトランザクション内で検査する（`queueItemID` は呼び出し側が指定する値であり、検査しなければ無関係な `Project` のキュー項目を `completed` へ更新できる）。

| 確認 | 不成立なら |
| --- | --- |
| `commit.batchID == nil` なら `queueItemID == nil` | throw |
| `commit.batchID != nil` なら該当キュー項目が存在する | throw |
| `queueItem.projectID == commit.projectID` | throw |
| `queueItem.batchID == commit.batchID` | throw |
| `queueItem.state == .exporting` | throw |

確認を通ったら、保存済みコミットの値だけから `OutputRecord` と `ExportRecord` を導出する。

| 導出先 | 導出元 |
| --- | --- |
| `OutputRecord.outputFile` / `outputByteSize` / `outputSHA256` | `outputFile` と `verifiedOutput` |
| `OutputRecord.generatedAt` / `expiresAt` | `finalizedAt` と `finalizedAt + 24h` |
| `OutputRecord.format` / `suggestedCreationDate` | `delivery`（`OutputDeliveryDescriptor`） |
| `ExportRecord.exportedAt` | `finalizedAt` |
| `ExportRecord.accountingMode` | `authorization` |
| `ExportRecord.format` / `outputByteSize` | `delivery` と `verifiedOutput` |

そのほかのポート（`ManagedFileStore` / `CryptoKeyStore` / `ProtectedBlobStore` / `CrashReporter` / 履歴削除の原子的操作）は [アーキテクチャ設計](architecture.md) が正本。

---

## 1. 認可

認可は4つの独立した検査を通る。

| 検査 | 対象 | 失敗時 |
| --- | --- | --- |
| **確認の一致**（1.1） | 利用者が確認したプレビューが、いま書き出そうとしている設定と同じか | 開始しない。台帳へ触れない |
| **確認の再導出**（1.1.2） | `triage` を再実行した結果に対して、判断が実際に記録されているか | 開始しない。台帳へ触れない |
| **設定内容の能力**（1.1.1） | `RenderSpec` が使うスタンプが現在の能力で許されるか | 開始しない。台帳へ触れない |
| **権限とクォータ**（1.2 以降） | 能力・月間枠・トライアル | `.blocked`。lease と予約を補償して終了 |

順序は台帳を触らない検査が先（前 3 つで弾けば補償が不要になる）。

### 1.1.2 確認の成立を認可で再導出する

開始条件が保存された `reviewed` を根拠にできない。`DetectionStatus` と `ReviewStatus` は未署名の `app.db` 行であり、書き換えれば確認を経ずに通る（[アーキテクチャ設計](architecture.md) の 6.1）。

| 順 | 操作 |
| --- | --- |
| 1 | 保存済みの `FaceTrack` と `detectionPixelSize` から `DetectionResult` を組み立てる |
| 2 | `triage` を再実行して `[ReviewIssue]` を再導出する（保存された `DetectionStatus` を使わない） |
| 3 | 再導出した全 `ReviewIssueID` について `ReviewDecision` に `ReviewResolution` が記録されていることを確認する |
| 4 | 1 件でも未記録なら開始しない |

| 処理 | 追加の条件 |
| --- | --- |
| 単体 | 上記のみ |
| バッチ（おまかせ一括） | 上記に加えて `BatchReviewState.overviewConfirmed == true` |
| バッチ（1 枚ずつ確認） | 上記に加えて全写真について上記が成立している |

保存された `reviewed` は使わない（表示の高速化のためのキャッシュ）。`triage` は純粋関数であり再実行は顔数に比例するだけ（Vision の呼び出しを伴わない。50 枚のバッチでも無視できる費用）。再導出の入力自体（`FaceTrack`）も未署名であり、その限界と再導出する理由は [アーキテクチャ設計](architecture.md) の 6.1 にある。

### 1.1.1 設定内容の能力を認可で再検査する

編集画面の `canEdit` だけでは有料スタンプの利用を防げない。`EffectSetting` は未署名の DB 行であり、`op` を有料パックのスタンプへ書き換えて `projectRevision` を手で増やせば、UI を通らずに有料スタンプを含む `RenderSpec` ができ、書き出しは `freeMonthlyConsume` として成立する。

```swift
/// RenderSpec から必要能力を抽出する。UI の canEdit と同じ入力を作る
func capabilityRequirement(
    of spec: RenderSpec,
    stampCatalog: StampCatalog        // 組み込み code → 必要能力
) -> ProjectCapabilityRequirement     // アーキテクチャ設計 6.2

/// 抽出した必要能力が現在の能力で許されるかを判定する純粋関数
func authorizeRenderSpec(
    _ requirement: ProjectCapabilityRequirement,
    capabilities: ResolvedCapabilities
) -> RenderSpecAuthorization

enum RenderSpecAuthorization: Sendable, Equatable {
    case authorized
    case blocked(RenderSpecBlockReason)
}

enum RenderSpecBlockReason: Sendable, Equatable {
    case premiumStampNotAvailable      // canUsePremiumStamps == false
    case customStampNotAvailable       // canUseCustomStamps == false
    case unknownBuiltInStampCode       // カタログに無い code
}

/// 組み込みスタンプの分類。アプリにハードコードし、リモート設定から変更できない
protocol StampCatalog: Sendable {
    /// 未知の code は nil。nil は blocked へ倒す
    func requirement(forBuiltIn code: String) -> StampRequirement?
}

enum StampRequirement: Sendable, Hashable {
    case free                      // 基本スタンプ
    case premium(packID: String)   // 追加スタンプ
    case custom                    // カスタムスタンプ（canUseCustomStamps）
    case unknownBuiltIn            // カタログに無い code。常に blocked
}
```

`capabilityRequirement(of:)` は `nil` を返さない。カタログに無い `code` は `.unknownBuiltIn` として `Set` へ入れる（`Optional` を返すと呼び出し側が「制約なし」と解釈する経路ができるため）。

| `RenderSpec` に含まれる値 | 必要な能力 |
| --- | --- |
| `RenderOpSpec.mosaic` / `.blur` / `.solid` | なし |
| `RenderOpSpec.stamp(.builtIn(code))` で `requirement == .free` | なし |
| `RenderOpSpec.stamp(.builtIn(code))` で `requirement == .premium` | **`canUsePremiumStamps`**（`enabledStampPacks` は見ない。下記） |
| `RenderOpSpec.stamp(.custom(assetHash))` | **`canUseCustomStamps`** |
| `BackgroundSpec` の全 case | なし |

| 項目 | 内容 |
| --- | --- |
| **検査の位置（1）** | 手順 −2 の開始ゲートの内側。`transact` の前に評価する。`blocked` なら台帳へ触れずに終了する |
| **検査の位置（2）** | 手順 1 の直前。もう一度評価する（下記） |
| 認可に使う能力 | `authorization.entitlementSnapshot` から解決した `ResolvedCapabilities`（`verificationRequired` なら開始しない。[アーキテクチャ設計](architecture.md) の 6.2） |
| `UpgradeReason` への写像 | `premiumStampNotAvailable` → `premium-stamp`、`customStampNotAvailable` → `custom-stamp`（[商品判断](product-decisions.md)）。`unknownBuiltInStampCode` には写像を作らない（下記） |
| 未知の `code` | `blocked`。カタログに無い値を「無料扱い」へ倒さない |

##### 手順1の直前にもう一度評価する

手順 −2 の 1 回だけでは、`prepared` で停止させて設定を差し替えられる（`paused(.userPaused)` は時間制限がなく、`Project.projectRevision` を据え置けば `expectedProjectRevision` も `ExportCommit` も検出できない）。

| 規則 | 内容 |
| --- | --- |
| 評価の位置 | 手順 1 で `RenderSpec` を組み立てた直後、レンダリングの前 |
| 入力（1） | その `RenderSpec` から抽出した `ProjectCapabilityRequirement`（描画に使う値そのもの） |
| 入力（2） | その `RenderSpec` と、手順 1 が同じ DB 読み取りで得た `ExportSetting` から計算した `ProjectSettingsHash`（入力は 8 フィールド。[正準スキーマ](canonical-schema.md) の 5.2） |
| 検査（1） | `authorizeRenderSpec` が `authorized` を返すこと |
| 検査（2） | ハッシュが `ExportInputSnapshot.projectSettingsHash` と一致すること（上記 1.1.1） |
| いずれかが不成立なら | 生成せずロールバックへ入る（`rollingBack`）。台帳は手順 4 の前なので lease と予約の取り消しだけで済む |
| 能力 | 手順 −2 と同じ `authorization.entitlementSnapshot` から解決した値を使う（開始後の権限変化は 1.4 に従う） |

「認可した spec」と「描画した spec」を同一にするのがこの検査の目的。検査（2）を加えたことで能力要件に影響しない設定変更も検出される（検査（1）だけでは、領域の縮小・`cellRatio` の最小化・`isMasked` の解除など脅威モデル対象外の改変が `settingsEntryToApply` 経由で台帳の確定記録を汚染する経路を塞げない）。`RenderSpec` へ署名する案は領域数に比例してコミット行の再署名コストが増えるため、描画の直前に純粋関数を 2 回呼ぶ方式を採る。

##### `blocked` になったキュー項目の遷移先

| 処理 | 遷移先 |
| --- | --- |
| 単体書き出し（写像がある 2 case） | キュー項目が無い。`UpgradeReason` に対応する Paywall を提示する |
| 単体書き出し（写像が無い 2 case） | キュー項目が無い。`capabilityRequired` のエラーを提示し、該当スタンプの差し替えを促す（下記） |
| バッチの 1 項目 | `failed(ExportQueueFailure(errorCode: .capabilityRequired, isRetryable: false, occurredAt:))` |

`unknownBuiltInStampCode` に `UpgradeReason` を作らない（カタログに無い `code` は課金しても `authorized` にならないため）。

| `RenderSpecBlockReason` | 提示 |
| --- | --- |
| `premiumStampNotAvailable` | Paywall（`premium-stamp`） |
| `customStampNotAvailable` | Paywall（`custom-stamp`） |
| `unknownBuiltInStampCode` | エラー。「使えないスタンプが含まれています」＋該当領域への誘導 |

エラーからの復帰は設定の変更だけ。プレビューの再確認が必要になるため（`detectionRevision` は変わらないが `previewRenderHash` が変わる）、1.1 の確認からやり直す。

##### `enabledStampPacks` を認可の判定に使わない

パックの無効化は認可では課さない。[運用](operations.md) の 2.2 は「新規選択だけ禁止、既存プロジェクトは再描画・再書き出しできる」と定めており、認可で課すと既存作品の再書き出しが止まる。

| 判定の位置 | `enabledStampPacks` の扱い |
| --- | --- |
| スタンプ選択 UI | 見る。無効なパックのスタンプを新規に選べない |
| `authorizeRenderSpec`（手順 −2 / 手順 1） | 見ない。既存の `RenderSpec` は無効化に影響されない |

「変更せず再書き出し」の免除では解決できない（免除は `exportedSettingsEntries` の確定記録を必要とし、一度も書き出していないプロジェクトは対象外）。無効化パックが Free で使えるわけではない（有料パックのスタンプには `canUsePremiumStamps` が別に要る）。`RemoteConfigState` の削除で全パックを有効へ戻しても、認可が `enabledStampPacks` を見ないため書き出しの可否は変わらない（新規選択の制約だけが解除され、[運用](operations.md) の 2.1 がその受容を記録している）。

`AppErrorCode.capabilityRequired` を追加する（[アーキテクチャ設計](architecture.md) の 9.2）。`isRetryable` は `false`（同じ設定のまま再試行しても必ず同じ結果になるため）。遷移先を定めないと、その項目が `exporting` にも終端にも入らずバッチの完了判定が成立しない。

##### 「変更せず再書き出し」の免除

[アーキテクチャ設計](architecture.md) の 6.2 は、有料スタンプを含むプロジェクトの「変更せず再書き出し」を降格後も可としている。一方 `authorizeRenderSpec` は `requirement == .premium` に対して `canUsePremiumStamps` を無条件に要求する。

| 読み方 | 結果 |
| --- | --- |
| 例外を作らない | 降格した利用者が自分の既存作品を再書き出しできない。6.2 に反する |
| 確定記録があれば免除する | 6.2 を満たす。ただし確定記録が偽造できるなら有料機能の迂回になる |

後者を採る。免除の条件は次のすべてに限定する。

| 条件 | 内容 |
| --- | --- |
| 確定記録の存在 | `exportedSettingsEntries` に当該 `projectID` の項目がある（`pendingExportedSettingsEntries` は不可） |
| 設定の一致 | その項目の `settingsHash` が、手順 1 で組み立てた `RenderSpec` と `ExportSetting` から計算した `ProjectSettingsHash` と一致する |
| 素材の一致 | `ProjectSourceSnapshot.identity` が現在の素材と同じ alias 連結成分へ解決される（6.4） |
| 適用範囲 | 有料スタンプの能力要件のみ。クォータと開始ゲート（1.2）は免除しない |

偽造できないことが前提。`exportedSettingsEntries` は署名済み台帳にあり、`settingsHash` は手順 −2 の認可時に計算した値を持ち回る（下記）。手順 3 で再計算する実装だと、停止窓で書き換えた設定のハッシュが確定記録になり、この免除がそのまま有料機能の利用権になる。`pendingExportedSettingsEntries` は根拠にしない（pending は手順 4 の暫定適用であり手順 8 の昇格前はロールバックで取り消されるため）。

`canEdit` と重複しても両方を課す（書き出しは DB の内容を直接の入力とするため、認可の側でも同じ規則を評価しなければ DB 改変が素通りする）。`StampCatalog` をリモート設定から変更できない（サーバー側で有料スタンプを無料へ再分類できる形にすると [アーキテクチャ設計](architecture.md) の 10.3 に反する）。`ProjectSettingsHash` では代用できない（ハッシュは「前回と同じか」しか答えず、内容が現在の能力で許されるかは答えない）。

##### `settingsHash` は認可時の値を持ち回る

`settingsEntryToApply.settingsHash` を手順 3 で計算し直さない。バックグラウンド停止に時間制限が無く、手順 2 の直後にアプリを背面へ送れば `fileVerified` で無期限に止まる。その間に `EffectSetting.op` を有料スタンプへ書き換え `Project.projectRevision` を据え置けば、`expectedProjectRevision` も `ExportCommit` も検出しない。手順 3 で再計算すると、Free 利用者の署名済み台帳へ「有料スタンプ構成を最後に正常書き出しした」という偽の確定記録が入る。

| 規則 | 内容 |
| --- | --- |
| 値の出所 | 手順 −2 の認可で計算した `ExportInputSnapshot.projectSettingsHash` |
| 手順 3 での再計算 | 禁止。`ExportInputSnapshot` から写すだけ |
| 手順 1 の再評価での検査 | 組み立てた `RenderSpec` と `ExportSetting` から計算した `ProjectSettingsHash` が、認可時の値と一致すること（上記） |

認可・描画・台帳確定の 3 者を 1 つの値で束ねる。手順 −2 で計算し、手順 1 で描画する `RenderSpec` に対して再検査し、手順 3 でその値をそのまま台帳へ運ぶ。

### 1.1 確認済みの設定でのみ書き出す

検出漏れはアプリ側で判定できないため、利用者が加工後プレビューを確認したことが安全性の前提（[アーキテクチャ設計](architecture.md) の 6.1）。確認の対象を型で固定する。

```swift
/// 書き出そうとしている入力の同一性
struct ExportInputSnapshot: Sendable, Equatable {
    let projectID: ProjectID
    let projectRevision: Int64        // 手順 0 の競合検査だけに使う
    let detectionRevision: Int64      // 再検出ごとに増える
    let projectSettingsHash: ProjectSettingsHash   // 認可用
    let previewRenderHash: PreviewRenderHash       // 確認用
}

/// 利用者が確認したプレビューの同一性
struct PreviewConfirmation: Sendable, Equatable {
    let projectID: ProjectID
    let detectionRevision: Int64
    let previewRenderHash: PreviewRenderHash
}

/// バッチ一覧の確認状態。Bool 単独では持たない
struct BatchReviewState: Sendable, Equatable {
    let batchID: BatchID
    let overviewConfirmed: Bool
}
```

確認の一致には `previewRenderHash` だけを使う（`ProjectSettingsHash` には圧縮品質とメタデータ設定が含まれ、それらの変更で確認状態を維持する規則 [アーキテクチャ設計](architecture.md) の 6.5 と矛盾するため）。`projectSettingsHash` は「変更せず再書き出し」の認可判定に使う（同 6.2）。2 種類の定義は [正準スキーマ](canonical-schema.md) の 5.2。

| 処理 | 開始条件 |
| --- | --- |
| 単体 | 現在の `projectID` / `detectionRevision` / `previewRenderHash` が `PreviewConfirmation` とすべて一致する |
| バッチ | 各写真について上記が一致し、`BatchReviewState.batchID` が対象バッチと一致し、かつモードごとの確認条件を 1.1.2 の再導出で満たす |

`projectID` を含めるのは `PreviewRenderHash` が `Project` を特定しないため（ハッシュの入力は `RenderSpec` と `ExportSetting` だけであり、同じ設定・同じ領域の別プロジェクトは同じ値になる）。`overviewConfirmed` を裸の `Bool` で持たないのは、別バッチの確認状態を流用させないため。`previewRenderHash` だけでは足りず `detectionRevision` を含めるのは、再検出後の顔集合差し替えを検出するため。`PreviewConfirmation` に `projectRevision` は含めない（`ExportSetting` の変更でも増えるため、含めると圧縮品質を変えただけで確認が無効になる。手動領域の追加・削除は `previewRenderHash` の `regions` に含まれるため `projectRevision` なしでも捕まる）。

`ExportInputSnapshot.projectRevision` は残す。用途は確認の一致ではなく、手順 0 で `ExportCommit` の insert と同一トランザクションで競合を検出することだけ（下記）。

##### 開始後に設定を変えられないようにする

一致を確認しただけでは、確認から `prepared` の保存までの間に設定を変更できる。

| 順 | 操作 |
| --- | --- |
| 1 | 確認の一致を検査する |
| 2 | 権限とクォータを認可する（1.3 のゲート内） |
| 3 | 手順 0 で `Project` の revision を再取得し、`ExportCommit` の insert と同一 DB トランザクションで固定する（`insertPrepared(_:expectedProjectRevision:)`） |
| 4 | revision が変わっていれば insert が失敗する。台帳の lease・予約を補償して終了する |

`ExportCommit` の行が存在する間、対象 `Project` を変更できない（`published` を含む。2 章）。編集操作は拒否し、書き出しの完了またはキャンセルを求める。

### 1.2 権限とクォータ

`blocked` になりうる評価を、生成が終わったあとに行わない。

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
enum ExportAccountingMode: Sendable, Equatable {
    case paidUnlimited                          // 月間枠の対象外
    case freeMonthlyConsume                     // 月間枠を 1 消費
    case freeMonthlyReexport                    // 24 時間以内の再書き出し
    case batchTrial(consumesTrialCredit: Bool)
}
```

書き出し開始時点で利用権限と勘定を確定し、その書き出しについて固定する。`blocked` なら `ExportCommit` を作らず、生成も開始しない。型に `blocked` を含めないことで、検証済みファイルを抱えたまま上限超過で破棄する経路を表現できなくする。`ExportStartBlock` は開始を止める理由だけを持つ（連想値にすると `.blocked(.unlimited)` のような無意味な値が構築できるため）。`evaluate` が `.blocked(reason:limit:)` を返した場合に開始トランザクションが写し、`unlimited` / `freeReexport` / `consume` はいずれも `ExportAccountingMode` へ写る。

### 1.3 勘定の使い分け

| 勘定 | 月間枠 | トライアル台帳 | grant |
| --- | --- | --- | --- |
| `paidUnlimited` | 使わない | 使わない | ensure |
| `freeMonthlyConsume` | 1 消費 | 使わない | ensure |
| `freeMonthlyReexport` | 使わない | 使わない | preserve |
| `batchTrial(true)` | 使わない | 1 消費 | ensure |
| `batchTrial(false)` | 使わない | 使わない | ensure |

月間クォータを使うのは Free の単体処理だけ。したがって Free 利用者が月 5 枚を使い切っていても、クレジットが残っていれば一括トライアルを実行できる。

```swift
/// grant の操作。ensure と preserve を型で分ける
enum GrantAction: Sendable, Equatable {
    /// 有効な grant がなければ firstSuccessAt で新規作成してよい
    case ensure(sourceID: SourceID, firstSuccessAt: Date)

    /// 認可時の grant を維持するだけ。新規作成は禁止
    case preserveAuthorized(sourceID: SourceID, firstSuccessAt: Date)
}
```

単一フィールドでは preserve を表現できず、型で分ければ `switch` の網羅で強制される。

**ensure**（`paidUnlimited` / `freeMonthlyConsume` / `batchTrial` の両方）

> 正常生成時に有効な grant が存在すれば、既存の `firstSuccessAt` を維持する。存在しなければ、`finalizedAt` を `firstSuccessAt` とする新しい grant を作る。

`batchTrial(false)` が意味するのは「その写真のトライアルクレジットを過去に消費済み」であって「いま有効な 24 時間 grant が存在する」ではない。混同すると再処理直後の再書き出しが有料になる。

**preserve**（`freeMonthlyReexport`）

認可と会計の間に時間差があるため、ensure を適用すると無料の再書き出しを繰り返すだけで窓を無期限に更新できてしまう。

> 認可時に保存した `authorizedGrant.firstSuccessAt` をそのまま維持する。会計時点で新しい `firstSuccessAt` を作らない。

同じ `firstSuccessAt` の grant がまだ存在すれば変更しない。期限切れとして既に削除されていれば再追加しない。別の `firstSuccessAt` へは差し替えない。会計時点で認可時の grant が既に期限切れになっていた場合は、再登録せずそのまま落とす（無料で開始したその 1 回は完了させるが、次回の再書き出し権は与えない）。

### 1.4 開始後の権限変化

開始後に有料契約の失効・月間上限への到達・リモート設定の変更が起きても、その書き出しは開始時の権限で完了させる。認可の粒度は写真ごとの `exportID`。

| Pro 失効時点の状態 | 扱い |
| --- | --- |
| `prepared` 以降へ進んでいる写真 | 開始時の認可で完了させる |
| まだ認可されていない `waiting` の写真 | 開始しない。バッチを `paused` にする |

契約期間の終了時に未完了のバッチが残っている場合はキューを `paused` にし、完了済みの写真と履歴は保持する。

### 1.5 開始ゲート

「同時 1 件」という規則だけでは競合を防げない（認可を通ってから `prepared` を書くまでの間に、別の書き出しが同じ認可を通過できる）。`sourceID` をゲートのキーにできない（正規 `sourceID` は `UsageLedger` 内の alias を検索・統合して確定するため、確定には `transact` が必要で、`transact` はゲートの内側にある）。同時並列数の初期値が 1 である以上、素材単位の粒度は実質使われないため、ゲートを全体で 1 件にする。

```swift
// Domain — プロトコル。実装はアーキテクチャ設計 4.2 の待機キュー規則に従う
protocol ExportStartGate: Sendable {
    func withExclusivePermit<R: Sendable>(
        operation: @Sendable () async throws -> R
    ) async throws -> R
}
```

その内側の 1 回の `UsageLedgerStore.transact` で、次をすべて行う。

0. `WorkingSourceBinding` と実体を照合する（`transact` の前。失敗したら台帳へ触れず終了する）
1. alias を解決・統合し、`sourceID` を確定する
2. 時刻を正規化し、月次更新と期限切れ grant の整理を行う
3. クォータまたはトライアルを認可する
4. `SourceLease` を追加する（勘定を問わない）。`batchTrial(true)` のときだけ追加で `TrialReservation` を作る
5. 更新済み台帳と `ExportStartDecision` を返す

1 回の `transact` にまとめるのが要点（解決と認可を別々のトランザクションに分けると、その間に別の処理が同じ alias を解決できる）。`WorkingSourceBinding` の照合は `transact` の外側・permit の内側で行う（照合はファイル I/O を伴い排他区間を延ばすため。permit の内側であれば割り込みは起きない）。

開始の順序。

1. 復旧完了ゲートを確認する（5 章）
2. 確認の一致を検査する（1.1）。不一致なら台帳へ触れずに終える
3. `withExclusivePermit` を取得する
4. 確認の成立を再導出する（1.1.2）。不成立なら台帳へ触れずに終える
5. 設定内容の能力を検査する（1.1.1）。`blocked` なら台帳へ触れずに終える
6. `WorkingSourceBinding` と実体を照合する（[画像処理](image-pipeline.md)）。不一致なら台帳へ触れず、`invalidateWorkingSource(projectID:)` を呼んで終える
7. その内側で `transact` を 1 回実行し、`ExportStartDecision` を得る
8. `.blocked` なら生成せずに終える。ゲートは解放する
9. `ExportCommit(prepared)` を保存する（`expectedProjectRevision` つき）
10. 処理を開始する
11. 手順 9（コミット行の削除）またはロールバック完了でゲートを解放する

ゲートは認可の完了では解放しない。コミット行の削除またはロールバックの完了まで保持する（ロールバックの途中で次の認可が走ると、戻す前の台帳を根拠に判定してしまう）。

### 1.6 同一素材の直列化

同じ素材の非終端 `ExportCommit` は同時に 1 件だけとする。この不変条件がないと所有者方式が壊れる。Export A が grant を作り所有者になる → 同じ素材の Export B も正常完了する（既存 grant を使うので所有者にならない）→ A のファイル異常でロールバックし A 所有の grant を削除する → B は成功しているのに grant が消える。

- 並列処理は異なる素材の間だけ許可する
- 同一素材は直列化する。バッチ内に重複があっても同様
- コミット行の削除またはロールバック完了まで、その素材をロックする（`readyToPublish` で解放してはいけない。保存後、コミット行の削除前にも復旧対象となる区間が残っている）

この不変条件は台帳側では「同一 `sourceID` の `SourceLease` は最大 1 件」として現れる。v1 は全体ゲートによりこれを自動的に満たす。

### 1.7 並列数を2へ上げるときの移行

| 段 | ゲート | 内容 |
| --- | --- | --- |
| 1 | alias 単位の解決ゲート | alias から `sourceID` を確定するまでを排他する |
| 2 | `sourceID` 単位のゲート | 確定した `sourceID` で以降を排他する |

第 1 段が短時間で終わるため、実質的な並列度は保たれる。あわせて、月間枠を消費する単体書き出しを同時 1 件に制限するゲートを第 2 段で復活させる（消費するかどうかは認可の結果でありゲート取得時点では未確定なので、条件式ではなく粒度で担保する）。v1 では実装しない。

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
    let delivery: OutputDeliveryDescriptor  // 認可時に確定。手順 7 で OutputRecord へ
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

    /// 「変更せず再書き出し」の比較対象（アーキテクチャ設計 6.2）
    /// 手順 4 で pendingExportedSettingsEntries へ入れる値。手順 8 で確定側へ昇格する。
    /// settingsHash は手順 −2 の ExportInputSnapshot.projectSettingsHash を持ち回る（下記）
    let settingsEntryToApply: ExportedSettingsEntry

}

/// 台帳へ実際に適用された結果
struct AccountingApplied: Sendable {
    let consumedInserted: Bool
    let grantInsertedByThisExport: Bool
    let trialInsertedByThisExport: Bool
    let pendingSettingsEntryInserted: Bool
}

/// 受け渡しに必要な不変値。手順 7 で OutputRecord へコピーする
struct OutputDeliveryDescriptor: Sendable {
    let format: ImageFormat
    let suggestedCreationDate: Date?
}

enum ExportCommitState: Sendable, Equatable {
    case prepared
    case fileVerified          // finalizedAt はまだ nil
    case finalizing            // finalizedAt を確定した。台帳へ適用する直前
    case accountingCommitted
    case readyToPublish        // 手順 7 の直前。まだ非公開
    case rollingBack           // ロールバック確定。前進させない（4 章）
    case published             // 手順 7 完了。設定エントリの昇格待ち
}
```

| 状態 | 必須フィールド |
| --- | --- |
| `prepared` | `authorization` のみ |
| `fileVerified` | 上記 ＋ `outputFile` ＋ `verifiedOutput` |
| `finalizing` | 上記 ＋ `finalizedAt` / `finalizedPeriod` / `intent` |
| `accountingCommitted` | 上記 ＋ `applied` |
| `readyToPublish` | 上記 ＋ ファイル再検証済み |
| `rollingBack` | 遷移前の必須フィールドを保持する。追加要求なし |
| `published` | 上記。`OutputRecord` と `ExportRecord` が存在する |

`readyToPublish` は成果物がまだ非公開で、コミット行も残っている状態。`published` は公開済みで、残る仕事は台帳側の昇格（手順 8）だけ。

##### 「非終端」の定義

`published` を非終端に含めない（会計は確定しており、ロールバックの対象ではないため）。

```swift
extension ExportCommitState {
    /// ロールバックしうる状態。published は含まない
    var isNonTerminal: Bool { self != .published }
}
```

| 判定 | `prepared` 〜 `readyToPublish` | `published` |
| --- | --- | --- |
| ロールバックの対象 | 対象（`rollingBack` は再実行の対象） | 対象外（前進のみ） |
| 台帳修復時の破棄（5.2） | 破棄する | 破棄しない。手順 8（台帳が空なので no-op）と手順 9 を実行して完了させる |
| 同一素材の直列化（1.6） | 数える | 数えない。ゲートは手順 9 で解放する |
| `Project` の編集禁止（1.1） | 禁止する | 禁止する（下記） |
| 履歴削除の絶対保護（[アーキテクチャ設計](architecture.md) の 7.5） | 保護する | 保護する（下記） |

編集禁止と削除保護には `published` も含める（どちらも「コミット行が存在する間」を条件とする。`Project` が削除されると昇格先の `Project` が消えるため）。通常の経路では手順 7 から 9 までが連続するため、この区間は一瞬。

台帳修復では `published` を破棄しない（出力は既に `OutputRecord` として存在し、利用者へ渡せる状態のため。破棄するとファイルが孤児になる）。修復で `pendingExportedSettingsEntries` は空になるため、手順 8 は何もせず手順 9 が行を消す。

`outputFile` は `prepared` では `nil`（`ManagedFileStore.createFile` はファイルの作成が完了してからでないと `ref` を返さないため。[アーキテクチャ設計](architecture.md) の 7.3）。手順 1 で生成し、手順 2 で `verifiedOutput` と同時に保存する。`prepared` で落ちた場合、削除すべき出力ファイルは存在しない（手順 1 の途中で作られた一時ファイルはどのコミット行からも参照されないため、起動時の孤児 GC が回収する）。

「適用しようとする内容」と「実際に適用された結果」を分ける（台帳を更新する前に「実際に新規追加した値」を確定することはできないため）。ただし `AccountingApplied` を DB へ書く前に落ちる可能性があるため、これだけを根拠にロールバックできない。台帳側の `ownerExportID` が最終的な判断材料。

### 2.1 検証結果をジャーナルへ持つ

`fileVerified` で落ちた場合、`OutputRecord` はまだ存在しない（作られるのは手順 7）。検証済みファイルと同じ内容かを起動時に確認する材料が、コミット側になければ復旧できない。

- 復旧時は実体のサイズ・SHA-256・デコードを再確認し、`verifiedOutput` と突き合わせる
- 手順 7 の `OutputRecord` 作成時は、`verifiedOutput` から値をコピーする（再計算しない）

再計算ではなくコピーにするのは、手順 1 と手順 7 の間にファイルが差し替えられた場合に検出するため（再計算すると差し替え後の内容を「正しい記録値」として固定してしまう）。アルゴリズムを名前で固定する（抽象名にすると実装ごとに別のアルゴリズムを選ぶ余地が残る）。サイズも記録する（ダイジェストだけでは手順 6 のサイズ照合ができず、サイズ比較はダイジェスト計算より安く途中書き込みを先に弾ける）。

### 2.2 会計時刻は最終確定処理から導出する

会計時刻を `fileVerified` で確定すると成功時点と食い違う。7 月 31 日に `fileVerified` となり 8 月 1 日に復旧して公開された場合、利用者が受け取るのは 8 月なのに消費は 7 月扱いになり、grant の 24 時間も 7 月から開始する。月をまたぐ場合だけでなく、2 時間後の復旧でも窓と期限が 2 時間ずれる。そこで `fileVerified` では `finalizedAt` を確定しない。最終確定を試みる直前に `finalizing` を保存し、そこで初めて時刻を決める。

| 値 | 導出元 |
| --- | --- |
| `finalizedAt` | `finalizing` を保存する時点の `usageNow` |
| `finalizedPeriod` | `finalizedAt` の年月 |
| grant の `firstSuccessAt` | `finalizedAt`（ensure の場合） |
| `OutputRecord.generatedAt` | `finalizedAt` |
| `OutputRecord.expiresAt` | `finalizedAt + 24h` |

これにより「利用者が受け取った時刻」と「消費を計上した時刻」が必ず一致する。`authorization` は開始時に固定したまま（長時間の中断後に復旧しても、権限は開始時のもの、時刻は確定時のものを使う）。

---

## 3. 手順 −2〜9

この表が手順番号と状態遷移の唯一の正本。他の文書はこの表を参照する。

| 順 | 操作 | 保存先 | 遷移後の状態 |
| --- | --- | --- | --- |
| −2 | 確認の再導出（1.1.2）・設定内容の能力（1.1.1）・`WorkingSourceBinding` の照合（[画像処理](image-pipeline.md)）を行う。いずれか不成立なら開始しない。続いて `transact` 内で時刻正規化・月次更新・期限切れ grant の整理を永続化する。`SourceLease` を追加する（勘定を問わない）。`batchTrial(true)` なら同じトランザクション内で追加の `TrialReservation` を作る | ファイルシステム / ProtectedBlobStore | — |
| −1 | `transact` の結果として `ExportStartDecision` を得る。`.blocked` なら以降へ進まない | — | — |
| 0 | `ExportCommit` を保存（`verifiedOutput` / `intent` / `finalizedAt` はすべて `nil`）。保存に失敗したら補償トランザクションで予約・lease・未参照 `SourceRecord` を削除し、ゲートを解放する | DB | **`prepared`** |
| 1 | 一時ファイルを生成し、サイズ・SHA-256・デコードを検証して `VerifiedOutput` を得る | ファイルシステム | — |
| 2 | `outputFile` と `verifiedOutput` を確定して保存（`finalizedAt` はまだ `nil`） | DB | **`fileVerified`** |
| 3 | `finalizedAt` を決め、`intent` を確定して保存 | DB | **`finalizing`** |
| 4 | `UsageLedger` を冪等に暫定適用する。予約の `trialEntries` への移動と `SourceLease` の削除も同じ台帳トランザクション内 | ProtectedBlobStore | — |
| 5 | `applied` を埋めて保存 | DB | **`accountingCommitted`** |
| 6 | `verifiedOutput` と出力ファイルの健全性を確認して保存 | ファイルシステム / DB | **`readyToPublish`** |
| 7 | 単一トランザクション（3.5）。`OutputRecord` と `ExportRecord` を作り、キュー項目を `completed` にし、`WorkingSourceRecord` を削除する。ここが会計の最終確定境界 | DB | **`published`** |
| 8 | 台帳トランザクションで `pendingExportedSettingsEntries` の該当要素を `exportedSettingsEntries` へ昇格する（[アーキテクチャ設計](architecture.md) の 6.2） | ProtectedBlobStore | — |
| 9 | コミット行を削除する | DB | （行が消える） |

```
prepared → fileVerified → finalizing → accountingCommitted → readyToPublish
    → published → （手順 8 の台帳昇格）→ 手順 9 でコミット行を削除
```

手順 7 でコミット行を消さない（消すと手順 8 の台帳昇格が中断した場合に根拠が失われる。`published` を挟むことで「出力は公開済みだが設定エントリが未昇格」を復旧可能な状態として表現する）。

手順 7 が会計の最終確定境界（`published` へ到達した時点で消費は確定し、以降のロールバックはない。手順 8 と 9 は前進のみ）。

手順 9 は手順 8 の台帳保存が成功したあとにのみ呼ぶ。`ExportSagaStore` は DB ポートであり `ProtectedBlobStore` 内の昇格完了を検査できないため、順序は `ExportCoordinator` が保証し、`deletePublished` は HMAC と `state == published` だけを再検査する。手順 8 の前に手順 9 を呼ぶ実装は、起動時復旧で「pending はあるが `published` コミットが無い」として手順 5.5 の削除対象になり、昇格が永久に行われない。

##### 手順8が繰り返し失敗する場合

手順 8 は `ProtectedBlobStore` への書き込みであり、`temporarilyUnavailable` などで継続的に失敗しうる。失敗している間、コミットは `published` のまま残り、(1) 開始ゲートが解放されず（1.5）、(2) 対象 `Project` は編集禁止かつ履歴削除の絶対保護（2 章）、(3) 起動時復旧の手順 4 が完了しないため新しい書き出しも許可されない（5 章）。アプリ全体が止まる。

昇格は「変更せず再書き出し」の比較対象を確定する処理であり、成果物にも会計にも影響しない。アプリを止め続ける根拠としては弱い。

| 試行 | 扱い |
| --- | --- |
| 保護データ利用不可 | 諦めない。`waitUntilAvailable()` で待って再試行する（[アーキテクチャ設計](architecture.md) の 7.4） |
| 同一プロセス内の 1〜3 回目 | 指数バックオフで再試行する |
| 同一プロセス内の 4 回目以降 | 昇格を諦め、pending を削除して手順 9 へ進む（下記） |
| 起動時復旧での再実行 | 回数を引き継がない。その起動で改めて 1〜3 回試す |

保護データ利用不可を「諦める」条件に含めない（書き出し直後に画面を消すという自然な操作で発火し、利用者が無言で無料の再書き出し権を失うため。再試行可能なエラーとして分類されている。同 7.4）。

試行回数はプロセス内カウンタで持つ（`ExportCommit` は署名対象なので回数を持たせると再署名が要り、費用が釣り合わないため）。起動をまたいでリセットされる結果、恒久的な障害では「起動ごとに 3 回試す」ことになるが、いずれも安価な台帳トランザクション。

| 諦めた場合の帰結 | 内容 |
| --- | --- |
| 成果物 | 影響なし。`OutputRecord` は既に存在し、受け渡しできる |
| 会計 | 影響なし。消費は手順 7 で確定済み |
| 「変更せず再書き出し」 | 成立しない。次回は通常の消費として扱われる |
| 利用者への提示 | 行わない。成果物は渡っており、失われるのは無料の再書き出し権だけ |

pending を残して手順 9 へ進まない（「昇格」と「削除」はどちらも 1 回の台帳トランザクションであり、昇格が失敗する原因は削除にも同じく効くため）。削除も失敗する場合は手順 9 へ進まず、コミットを `published` のまま残す。次回起動の手順 4 が再実行する。

##### 台帳が書けない間も成果物へ到達させる

上の帰結表（「成果物 | 影響なし」）が成立するのは、成果物への導線が実際に開く場合だけ。起動時復旧の手順 4 が完了しないと手順 4.2〜9 に到達せず、手順 7.5（未受け渡し出力の復元）も手順 9（通常画面の表示）も実行されない。台帳への書き込み不能が続く間、公開済みの出力へ到達する手段がない。

| 規則 | 内容 |
| --- | --- |
| 手順 4 の扱い | `published` のコミットについて、手順 8 の昇格が失敗しても手順 4 は「完了」とする |
| 根拠 | 昇格は「変更せず再書き出し」の比較対象を確定する処理であり、成果物にも会計にも影響しない（上記） |
| 手順 4.2 以降 | 通常どおり実行する。手順 7.5 が未受け渡し出力を復元し、手順 9 が通常画面を表示する |
| コミット行 | `published` のまま残す。次回起動の手順 4 が昇格を再試行する |
| 新しい書き出し | 起動時復旧の完了ゲートは通す（手順 9 に到達するため）。`ExportStartGate` の permit は解放しない（下記） |

「開始ゲート」を 2 つの意味で使わない。ここで通すのは起動時復旧の完了ゲート（手順 9 に到達させ、通常画面と受け渡し導線を出すこと）。`ExportStartGate` の permit は 1.5 の規則どおり、手順 9（コミット行の削除）またはロールバック完了まで解放しない。

| ゲート | この状態での扱い |
| --- | --- |
| 起動時復旧の完了ゲート | 通す。手順 4 を「完了」として手順 4.2〜9 を実行する |
| `ExportStartGate` の permit | 解放しない。手順 9 に到達していないため（1.5） |

同一プロセス内では新しい書き出しを開始できないことは受容する（台帳へ書けない状態では手順 −2 の `transact` も失敗するため、permit を解放しても認可は成立しない）。守りたいのは「受け渡し前の出力へ到達できること」であり、そこに permit は要らない。次回起動で昇格が成功すれば手順 9 が走り、permit は新しいプロセスで最初から取得される。

「昇格できない」を「アプリを止める」根拠にしない（止めることで守られるものが無く、利用者は受け渡し前の出力を 24 時間の期限内に取り出せなくなる。失うのは無料の再書き出し権だけであり、成果物より優先しない。[アーキテクチャ設計](architecture.md) の 7.5 の絶対保護と同じ向き）。

手順 5.5 の pending 削除保留とは独立（あちらは署名不正行が残る間の話であり、こちらは台帳が書けない間の話。どちらも「pending を消さない」だが、前進を止めるかどうかが逆になる）。

`deletePublished` の事前条件は「pending が解消していること」（昇格でも削除でもその `ownerExportID` の pending が台帳に無くなっていれば満たされる。「昇格が成功したこと」ではない）。

利用者に不利な側へ倒す判断（「昇格できたことにする」とアプリを止めないために未成功の設定を確定させることになり、権限の迂回になる）。

手順 −2 の `SourceLease` は勘定の種類を問わない（`paidUnlimited` の通常の単体書き出しには grant も予約もないため、lease が無ければ処理中の素材が GC される）。

手順 4 と 5 を逆にしてはいけない（先に `accountingCommitted` を書くと、台帳が未反映のまま「反映済み」として復旧される。この順なら 4 と 5 の間で落ちても状態は `finalizing` のままなので、台帳更新を冪等に再適用できる）。

手順 0 で `prepared` を先に書くのは、生成中に落ちたときに孤児となる一時ファイルを起動時に特定するため。台帳の更新は手順 4（手順 7 ではない。手順 7 は DB だけのトランザクションであり `ProtectedBlobStore` を同時に更新できない）。手順 9 を省くと、書き出しのたびにコミット行が永久に蓄積する（ジャーナルは中断からの復旧と手順 8 の根拠のためだけに存在するので、役目を終えたら消す）。

冪等性の鍵は 2 種類。クォータ消費は `exportID`、トライアル消費は素材の同一性。

### 3.1 確定点は1つだけ

> 検証済みファイルは、手順 7 が完了するまで UI・`MediaSaver`・`SharePresenter` へ公開しない。
>
> 手順 4 で台帳へ会計を暫定適用し、手順 7（`published` への更新）で最終確定する。
>
> 本設計における「利用可能な出力の生成が正常に完了した時点」とは、手順 7 まで完了した時点を指す。

| 区間 | 性質 |
| --- | --- |
| 手順 7 より前 | 復旧またはロールバックが可能。成果物は非公開 |
| 手順 7 以降 | 成果物を利用者へ公開する。会計は戻さない |

これは仕様 14.2 の「保存処理または共有可能な状態になった」と一致する。

以下では消費しない：検出のみ、プレビューのみ、キャンセル、生成の失敗、生成前の空き容量不足、生成中の異常終了、対応外形式。

生成が完了したあとの異常終了では消費が確定したまま（出力は残り再起動後に受け取れるため、消費を戻すと二重取りになる）。写真ライブラリへの保存は消費の条件に含めない（保存せず OS 共有だけで完結する経路が成立するため）。

### 3.2 非公開を構造で保証する

「公開しない」と文章で書くだけでは防げない。`OutputRecord` を会計直後に作ると、GRDB の `ValueObservation` はその時点から `generated` を観測でき、UI の購読先が `OutputRecord` である以上、最終確定より前に画面へ現れる。`OutputRecord` の作成を手順 7 へ移し、コミットの `published` 更新と同一の DB トランザクションで実行する。

| DB の状態 | コミットの `state` | 意味 |
| --- | --- | --- |
| コミットあり・`OutputRecord` なし | `prepared` 〜 `readyToPublish` | 非公開（処理中または復旧対象） |
| コミットあり・`OutputRecord` あり | `published` | 公開済み。手順 8・9 の完了待ち |
| コミットなし・`OutputRecord` あり | — | 全手順が完了している |
| コミットあり・`OutputRecord` あり | `published` 以外 | 起こらない（トランザクションが保証する） |

手順 6 の健全性確認が `OutputRecord` ではなく `verifiedOutput` を参照するのは、この順序変更のため。

### 3.3 手順6の確認内容

存在確認だけでは不足。0 バイトのファイル、途中まで書かれたファイル、デコードできないファイルも「存在する」ため、その状態でコミット行を削除できてしまう。削除後は会計を戻すためのジャーナルが失われ、消費だけが残る。

| 確認項目 | 目的 |
| --- | --- |
| `outputFile` から解決したファイルが存在する | 実体がある |
| ファイルサイズが 0 でなく、`verifiedOutput.byteSize` と一致する | 途中書き込みでない |
| SHA-256 が `verifiedOutput.sha256` と一致する | 内容が入れ替わっていない |
| 簡易デコードが成功する | 画像として開ける |

いずれかが不成立なら手順 7 へ進まず、`rollingBack` へ遷移してロールバックする（4 章）。

### 3.4 手順7の直前に時刻を再確認する

「異常終了したら手順 3 へ戻る」だけでは `finalizedAt` の陳腐化を防げない。同じプロセスが生き続けたまま、手順 3 で `finalizing` を保存 → バックグラウンドへ移行 → 数時間または数日停止 → 同じ Task が再開 → 手順 7 を実行、という経路をたどれる（プロセスは落ちていないため起動時復旧を通らない）。

| 順 | 操作 |
| --- | --- |
| 7-a | 新しい `usageNow` を取得する |
| 7-b | `finalizedAt` との差、および `finalizedPeriod` との一致を確認する |
| 7-c | いずれかが規定を外れていれば、暫定会計を取り消して手順 3 から再確定する |
| 7-d | 規定内なら、そのまま手順 7 の単一トランザクション（3.5）を実行する |

| 条件 | 扱い |
| --- | --- |
| `usageNow` の年月 ≠ `finalizedPeriod` | 再確定する（計上月がずれる） |
| `usageNow - finalizedAt` > 5 分 | 再確定する |
| 上記以外 | そのまま進む |

あわせて、バックグラウンド移行時に手順 3〜7 を進めない。シーンの非活性化を受けたら次の保存点で停止し、復帰時に上記の再確認から再開する。停止位置は必ずいずれかの `ExportCommitState` であり、中間状態で止まらない。

### 3.5 手順7の内容

DB に保存する状態は `OutputRecord` だけではない。`ExportRecord` と写真ごとのキュー状態も同じ DB にあり、`OutputRecord` の insert だけでは「出力は公開済みだがキューは `exporting`」「キューは `completed` だが `ExportRecord` が無い」が残る。

| 操作 | 対象 |
| --- | --- |
| `OutputRecord(generated)` を insert（`delivery` からコピー） | `OutputRecord` |
| 成功記録を insert | `ExportRecord` |
| 対象キュー項目を `completed` へ更新 | キュー状態 |
| プロジェクトの最終更新時刻を更新 | `Project` |
| `WorkingSourceRecord` を delete | `WorkingSourceRecord` |
| その処理用ファイルを `PendingFileDeletion` へ追加 | `PendingFileDeletion` |
| `ExportCommit` を `published` へ更新（削除しない） | `ExportCommit` |

処理用の元画像は書き出しの完了で不要になる（削除を別トランザクションにすると「出力は公開済みだが未加工の元画像が残る」区間ができる）。

台帳側の `WorkingSourceBinding` はここでは消さない（手順 7 は DB 専用トランザクション）。DB を先に消す規則（[画像処理](image-pipeline.md)）に従い、残った binding は孤児として起動時の手順 5.5 が回収する。逆順にすると、手順 7 の直前に落ちた場合に「`WorkingSourceRecord` があり binding が無い」状態となり、正常な書き出しが差し替えとして検出される。

```swift
/// いつ何を書き出したかの記録。24 時間では消えない
struct ExportRecord: Sendable {
    let exportID: ExportID
    let projectID: ProjectID
    let batchID: BatchID?
    let exportedAt: Date            // ExportCommit.finalizedAt
    let accountingMode: ExportAccountingMode
    let format: ImageFormat
    let outputByteSize: Int64
}
```

バッチの成功件数・失敗件数は、キュー項目からの導出値とする。

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

パスを DB へ直接持たない（パス文字列を保存すると、DB を書き換えるだけで `../` を含む値を注入でき、期限切れ削除の処理に別のアプリ内部ファイルを消させる経路ができる）。

受け渡しに必要な値も `OutputRecord` が持つ（起動時復旧は未受け渡し出力を復元し、その後 `MediaSaver` または `SharePresenter` へ `OutputFile` を渡す。[画像処理](image-pipeline.md)。`format` と `suggestedCreationDate` が無ければ `OutputFile` を組み立てられない）。`Project` の現在値や出力ファイルの再解析からは復元しない。

| 復元しようとする値 | 復元できない理由 |
| --- | --- |
| `format` | `Project` の `ExportSetting` は書き出し後に変更されうる |
| `suggestedCreationDate` | メタデータ設定が「日時を保持しない」なら出力ファイルに残っていない |
| 同上 | 写真ライブラリの登録日時はそもそも出力ファイルへ書かれない |

期限を `OutputRecord` 自身が持つ（`ExportCommit` は完了後に削除するため、コミットが消えたあとも単独で期限を判定できる必要がある。判定規則は 6.2）。

---

## 4. ロールバック

| 順 | 操作 | 保存先 |
| --- | --- | --- |
| 0 | `ExportCommit` を `rollingBack` へ更新する（下記） | DB |
| 1 | `transact` で、この `exportID` が所有する会計要素（消費・grant・トライアル台帳・トライアル予約・`SourceLease`・`pendingExportedSettingsEntries`）を冪等に取り消す | ProtectedBlobStore |
| 2 | 台帳の保存が成功したことを確認する | ProtectedBlobStore |
| 3 | `outputFile` のファイルを削除する | ファイルシステム |
| 4 | `ExportCommit` を削除する | DB |
| 5 | 開始ゲートを解放する | メモリ |

- 手順 0 を最初に置く（これが無いと、手順 1 の完了後・手順 4 の前に落ちた場合に、復旧側が「前進」と「補償」を区別できない）
- 手順 1 が失敗した場合、2 以降を実行しない（台帳を戻せていないのにジャーナルを消すと、消費だけが残って根拠が失われる）
- 手順 1 の完了後に落ちても、再起動時に同じロールバックを冪等に再実行できる（`rollingBack` が残っているため）
- `ExportCommit` の削除後にのみゲートを解放する（解放が早いと、ロールバック途中の台帳を次の認可が読む）
- 取り消してよいのは、台帳の `ownerExportID` がこの `exportID` と一致する要素だけ

##### `rollingBack` を状態として持つ

ロールバックの意思を DB へ残さないと、中断で前進する。手順 1（台帳の取り消し）が成功し、手順 4 の前に強制終了すると、コミット行は `accountingCommitted` または `readyToPublish` のまま残り、出力ファイルは健全になる。5.3 は `state` だけを見て「正常なら手順 3 からやり直す」と規定するため、ロールバックは再実行されず、取り消したはずの会計が再適用されて公開・消費される。利用者のキャンセルが無言で覆される。

| 項目 | 規則 |
| --- | --- |
| 遷移元 | `prepared` / `fileVerified` / `finalizing` / `accountingCommitted` / `readyToPublish` |
| 遷移先 | 削除のみ（手順 4）。他の状態へ戻さない |
| 起動時の扱い | 手順 1 から冪等に再実行する。手順 3 へ戻さない（5.3） |
| キャンセル・破棄の受付 | すでに確定しているため無視する |
| `published` からの遷移 | 無い。`published` は前進のみ（2 章の「非終端」の定義） |
| 非終端か | 非終端。編集禁止・削除の絶対保護・同一素材の直列化はすべて継続する |

遷移前の状態を保持する必要はない（ロールバックの操作は「台帳の `ownerExportID` が一致する要素を冪等に取り消す」であり、遷移元によって手順が変わらない）。`rollingBack` は署名対象の `state`（DB を書き換えて `readyToPublish` へ戻し前進させる経路を、行 HMAC が塞ぐ）。

##### `markRollingBack` が事前条件を再検査する

規則を書くだけでは強制点がない。`published` からのロールバックは「無い」と定めているが（2 章）、その禁止を実行時に確かめる場所が無いと、アプリ自身の誤りで払い戻しが走る。手順 8 が失敗して指数バックオフに入っている間、コミットは `published` のまま数秒から数分残り、その区間に利用者がキャンセルや破棄を要求すると `ExportCoordinator` が `markRollingBack` を呼ぶ。検査が無ければ手順 1 が `ownerExportID` 一致の消費・grant・トライアルを取り消し、手順 3 が出力ファイルを削除する。成果物は既に写真ライブラリへ渡っているため、成果物を保ったまま枠が戻ってしまう。

| メソッド | 再検査する事前条件 |
| --- | --- |
| `markRollingBack` | HMAC ＋ `state ∈ {prepared, fileVerified, finalizing, accountingCommitted, readyToPublish}` |
| `deleteRolledBack` | HMAC ＋ `state == rollingBack` |
| `deletePublished` | HMAC ＋ `state == published` |
| `finalizeExport` | HMAC ＋ `state == readyToPublish` ＋ 5 項目（1 章） |

破壊的な操作はすべて、自分が前提とする状態を自分で確かめる（呼び出し側の順序制御に依存しない）。UI 側でも `published` 以降はキャンセルを提示しない（4.2。二重の防御であり、どちらか一方に頼らない）。

取り消しの判断材料は台帳側の `ownerExportID`（`AccountingApplied` は DB へ書く前に落ちうるため単独では根拠にならない）。

```
consumedExportIDs に対象 exportID があれば削除
grants            のうち ownerExportID == 対象 exportID の要素を削除
trialEntries      のうち ownerExportID == 対象 exportID の要素を削除
trialReservations のうち exportID == 対象 exportID の要素を削除
sourceLeases      のうち exportID == 対象 exportID の要素を削除

pendingExportedSettingsEntries のうち ownerExportID == 対象 exportID の要素を削除
  （確定側の exportedSettingsEntries は触らない）

別の exportID が作った要素は削除しない
```

既存の grant を再利用しただけの書き出しは `ownerExportID` が一致しないため、以前から存在した権利を巻き添えで消さない。

確定側を触らないのは、手順 4 が pending にしか書かないため（[アーキテクチャ設計](architecture.md) の 6.2）。確定側への昇格は手順 8 であり、そこへ到達したコミットはロールバックの対象になりません。「一度も成功していない設定が最後の正常書き出しとして残る」経路は、集合を分けたことで構造的に消えている。

`ProjectSourceSnapshot` はロールバックの対象外（書き出しでは追加も削除もしない。`Project` の寿命まで保持し、削除は `Project` 削除 Saga だけが行う。[アーキテクチャ設計](architecture.md) の 7.5）。

| 状態 | 台帳への適用 | ロールバック経路 |
| --- | --- | --- |
| `prepared` | `SourceLease`、トライアル時のみ予約 | 手順 0〜5。lease・予約・未参照 `SourceRecord` の取り消しは必要 |
| `fileVerified` | 同上。`finalizedAt` は未確定 | 手順 0〜5 |
| `finalizing` | 上記 ＋ 暫定会計が存在しうる | 手順 0〜5。`intent` の内容を `ownerExportID` と突き合わせて取り消す |
| `accountingCommitted` | 適用済み | 手順 0〜5。`applied` ではなく台帳の `ownerExportID` を根拠にする |
| `readyToPublish` | 適用済み | 手順 0〜5（下記） |
| `rollingBack` | 取り消し済みまたは取り消し中 | 手順 1〜5 を冪等に再実行する |

`readyToPublish` でもロールバックが優先する。キャンセル要求または手順 6 の検証失敗を受けた時点で `rollingBack` へ遷移し、前進しない（「同一プロセス内なら手順 7 を実行して完了させる」という扱いは採らない。4.2 のキャンセル境界と矛盾し利用者の意思が無言で覆されるため）。

手順 6 が成功して手順 7 へ進む経路と、ロールバックへ入る経路の分岐点は 1 つ。手順 6 の検証がすべて成立し、かつキャンセル要求が無い場合にだけ手順 7 へ進む。

### 4.1 会計の最終確定境界

`published` への到達をもって会計を最終確定とする。`published` より前の間だけ、会計をロールバックできる。`published` のコミット行は残るが、ロールバックの対象ではない（残す目的は手順 8 の根拠を保持することだけ）。

理由は 2 つ。

1. 消費の確定点が曖昧になる。`published` へ到達した出力は正常生成が確定済みであり、その後のストレージ障害だけを払い戻し対象にすると「異常終了では戻さないがストレージ障害では戻す」という区別が必要になる。
2. 所有者モデルが破綻する（1.6 と同じ理由）。Export A が grant を作り所有者になり `published` に到達 → 同じ素材を Export B で正常に再書き出しする（既存 grant を利用するため所有者は A のまま）→ 後から A の出力ファイルが失われ `ownerExportID` を根拠に grant を削除する → B も正常成功しているのに grant が消える。非終端コミットの直列化は `readyToPublish` までしか効かず、A は既に `published` なので B の開始を止められない。

### 4.2 キャンセルの境界

| 時点 | 扱い |
| --- | --- |
| 手順 4 より前 | ロールバック。消費なし |
| 手順 4 以降・手順 7 より前（`readyToPublish` を含む） | 暫定会計を取り消してロールバック（`rollingBack` へ遷移） |
| 手順 7 の完了後 | キャンセルではなく破棄として扱う。枠は戻さない |

手順 7 が完了した時点で成果物は公開されており、正常生成が確定している。UI 上も、手順 7 の完了後は取り消せるかのような文言にしない。`published` のコミット行が残っていても、キャンセルの根拠にはならない。

---

## 5. 起動時復旧

復旧を終えるまで、新しい書き出しを開始させない（先に許可すると、あとから古いコミットをロールバックした際に、すでに進んだ現在の台帳まで壊しかねない）。各手順が前の手順の結果に依存する。

| 順 | 操作 | 依存 |
| --- | --- | --- |
| −4 | 保護データが利用可能になるまで待つ | — |
| −3 | `app.db` を開く | −4 の完了 |
| −2 | `journal_mode` / `synchronous` / `foreign_keys` を設定・検証する | −3 の完了 |
| −1 | DB のスキーマ移行を実行する（5.1） | −2 の完了 |
| 0 | `ProtectedBlobStore` のスキーマ移行を実行する | −1 の完了 |
| 1 | `UsageLedger` を読み込み、検証し、必要なら修復する | 0 の完了 |
| 2 | `ExportCommit` を読み込み、行ごとの署名を検証する | 0 の完了 |
| 2.5 | 手順 1 で台帳を修復した場合、非終端コミットを破棄する（5.2） | 1・2 の完了 |
| 2.8 | `loadRecoverySnapshot()` を実行する（0 章） | 2.5 の完了 |
| 3 | 有効なコミットに対応しない `trialReservations` と `sourceLeases` を削除する（署名不正行があれば保留） | 2.8 の完了 |
| 4 | 有効な未完了コミットを復旧する（5.3）。`published` のコミットは手順 8・9 を再実行して完了させる | 2.8・3 の完了 |
| 4.2 | `loadPostCommitRecoverySnapshot()` を 1 回だけ実行する（0 章） | 4 の完了 |
| 4.5 | `WorkingSourceBinding` と処理用実体を照合する（[画像処理](image-pipeline.md)） | 4.2 の完了 |
| 5 | `PRAGMA foreign_key_check` で外部キー違反が無いことを確認する | 4.5 の完了 |
| 5.5 | `Project` が存在しない台帳要素、`WorkingSourceRecord` が無い孤児 binding、そして未参照になった `SourceRecord` を削除する（[アーキテクチャ設計](architecture.md) の 7.5）。`pendingExportedSettingsEntries` はいかなる理由でも下記の条件を満たすまで削除しない | 5 の完了。4.2 の `projectIDs` が必要 |
| 6 | `PendingFileDeletion` と孤児ファイルを回収する | 5.5 の完了 |
| 7 | `resolveOrphanedAttempts()` を実行し、残存 `DeliveryAttempt` を `previousState` に従って解決する（8.0）。戻り値が解決後の全 `OutputDeliverySnapshot` | 5 の完了。4.2 の `deliveryAttempts` を使う |
| 7.5 | 未受け渡し出力（`isUndelivered`）を復元する。手順 7 の戻り値を使う（手順 4 で新しく作られた出力も含まれる） | 7 の完了 |
| 8 | `evaluateUpdate` を実行する | 7.5 の完了。手順 7 の戻り値の `isUndelivered` 件数が必要 |
| 9 | `.required` なら更新画面、それ以外は通常画面を表示し、新しい書き出しを許可する。あわせて `AppLifecycle` の行が無ければ挿入する（[アーキテクチャ設計](architecture.md) の 7.2） | 全手順の完了 |

- 手順 −4 を最初に置くのは、`.complete` のファイルがロック中に読めないため（DB を開く前に待つ）
- `AppLifecycle` の挿入を手順 9 に置く（この行は手順 1 の利用痕跡判定の入力。評価より後に書くことで、真の初回起動が「痕跡あり」と誤判定される経路が構造的に消える。手順 9 に到達せずに終了した起動では書かれず、次の起動でもう一度試みられる）
- 手順 3 を手順 4 より前に置く（孤児予約はクレジットを占有したままなので、回収前に新しい認可を許可すると、実際には空いているクレジットを「使用中」と判定する）
- 手順 5 を手順 4 の後に置く（手順 4 が `OutputRecord` と `ExportRecord` を作るため、先に検査すると復旧で解消する違反を検出してしまう）
- 手順 4.5 を手順 4 の後に置く（コミット復旧が手順 7 を完了させると `WorkingSourceRecord` が消えるため、先に照合すると正常に消える予定の行を差し替えとして誤検出する）
- 手順 6 を手順 5.5 の後に置く（ロールバック・孤児削除・台帳側の孤児回収が `PendingFileDeletion` へ行を追加しうるため、先に GC を走らせるとその回で回収できない）
- 手順 7 を 7.5 と 8 より前に置く（`DeliveryAttempt` を解決するまで出力の状態が確定せず、復元対象の件数も更新判定の件数も正しく数えられない）
- 件数は `generated` ではなく `isUndelivered` で数える（`deliveryUnknown` も未受け渡しであり、除外すると復旧案内からも強制更新の猶予からも漏れる）
- 署名検証に失敗した行が 1 件でもある間は、手順 3 の孤児回収（予約・lease）と手順 5.5 の孤児 pending 削除を全件保留する（6 章）
- 保留は「破棄して続ける」の完了後に解除し、その時点で手順 3 と 5.5 の回収を実行する（6.1）

##### 手順5.5で孤児pendingを削除してよい条件

署名不正行が存在する間、孤児 pending を削除できない。6.2 は「孤立 lease と孤立 pending の件数の組み合わせが到達点を一意に表す」ことを前提に自動判断する。手順 5.5 が先に pending を消すと、`(lease 1 / pending 1)` — 6.2 が「一意に決められない → 復旧エラーを維持し台帳へ触れない」と定めた状態が `(1 / 0)` に見え、明示的に禁じた自動判断（消費確定とコミット削除）が発火する。

| 状況 | 孤児 pending の扱い |
| --- | --- |
| 署名検証に失敗した行が 1 件以上ある | 一切削除しない（下記） |
| 署名不正行が無い | `ownerExportID` に対応するコミット行が存在しない pending を削除する |
| 台帳修復が走った起動（2.5） | 台帳ごと空なので対象外 |

保留は「孤児判定による削除」だけでなく、手順 5.5 のあらゆる pending 削除に及ぶ（`Project` が存在しないことを理由とする削除も含む。署名不正行の `projectID` は信用できないため、その pending が指す `Project` は `ExportCommit.projectID` の `RESTRICT`（[アーキテクチャ設計](architecture.md) の 7.1）で守られない場合がある。その `Project` を削除すると「`Project` が無い」経路で pending が消え、保留で防いだはずの自動判断が発火する）。

`Project` が無い pending が残る間、`Project` 削除 Saga の手順 3 も pending だけを残す（他の 3 集合と `SourceRecord` は通常どおり削除し、pending は署名不正行が解消されるまで持ち越す）。

「有効なコミットが無い」ではなく「コミット行が存在しない」で判定する（復旧エラーで残った非 published の有効コミットも、署名不正で残った行も、どちらも行としては存在するため孤児にならない。`PostCommitRecoverySnapshot` は照合のために `allCommitExportIDs` を持つ。0 章）。

### 5.1 スキーマ移行

`app.db` は 1 つなので `DatabaseMigrator` も 1 系列。各移行ステップは単一トランザクションで確定し、途中適用が観測されない。

##### 署名付き行の移行

手順 −1（スキーマ移行）は手順 2（署名検証）より前にある。`ExportCommit` の署名対象カラムを通常の SQL migration で先に変換すると、旧 canonical bytes を再現できなくなり、正規の行がすべて検証失敗する。署名付き行の移行は、通常の SQL migration とは別の経路で行う。

| 順 | 操作 |
| --- | --- |
| 1 | 旧 schema のまま、旧 canonical 形式で署名を検証する |
| 2 | 検証を通った行だけ、値を新しい型へ変換する |
| 3 | 新 canonical 形式で再署名する |
| 4 | 行の更新と schema version の更新を同一 DB トランザクションで確定する |
| 5 | 検証できなかった行は変換せず、復旧エラーとして残す（6 章） |

検証不能な行を自動変換しない（変換すれば新しい署名が付き、改ざんされた内容が正規の行として通る）。この規則は `ProtectedBlobStore` の payload（手順 0）にも同じく適用する。

### 5.2 台帳を修復した起動では再開しない

`UsageLedger` の HMAC 不一致で修復が走った起動では、署名が正常な未完了コミットも再開できない。修復済み台帳は `sourceRecords` / `sourceLeases` / `grants` / `trialEntries` / `trialReservations` をすべて空にする（[アーキテクチャ設計](architecture.md) の 6.3）。一方 `ExportCommit` が持つのは `sourceID` だけで、元の alias を持たない。手順 4 で grant や `TrialEntry` を再追加すると、次の不変条件を満たせない。

> `grants` / `trialEntries` / `trialReservations` / `sourceLeases` の `sourceID` は `sourceRecords` に存在する。

修復が走った起動では、進行中の作業をすべて破棄する。

| 対象 | 操作 |
| --- | --- |
| 非終端の `ExportCommit`（`published` 以外） | すべて削除する（署名の有効・無効を問わない。下記） |
| `published` の `ExportCommit` | 削除しない。手順 8（no-op）と手順 9 を実行して完了させる |
| 出力ファイル | 参照が消えるため、起動時の孤児 GC が回収する |
| すべての `WorkingSourceRecord` | 行を削除し、処理用ファイルを `PendingFileDeletion` へ |
| `UsageLedger` | 触らない。既に修復済みで、整合性封鎖が掛かっている |
| キュー項目 | `failed(ledgerRepaired)` へ遷移させる（下記） |
| 月間枠・トライアル | 整合性封鎖のまま。復元も払い戻しもしない |

`WorkingSourceRecord` も残せない（修復で `projectSourceSnapshots` が空になるため、コミットを持たない編集中プロジェクトも `sourceID` を解決できない。処理用ファイルだけが残る状態を避けるためにも、まとめて破棄する）。

##### `paused(.sourceReselectionRequired)` にしない

再選択・再接続は署名済み `ProjectSourceSnapshot` との照合を必須とする（[画像処理](image-pipeline.md)）。修復で `projectSourceSnapshots` が空になる以上、この経路は必ず失敗する。`paused` にすると復帰手段のない状態を作る。`failed(ledgerRepaired)` は `ExportQueueFailure(errorCode: .ledgerRepaired, isRetryable: false, occurredAt:)` の略記（[アーキテクチャ設計](architecture.md) の 6.5 と 9.2）。

| 対象 | 修復後にできること |
| --- | --- |
| キュー項目 | `failed(ledgerRepaired)`。再開・再試行のいずれもできない |
| バッチ | 履歴として閲覧・削除のみ |
| 既存 `Project` | 閲覧と削除のみ。再編集は新規プロジェクトとしてやり直す |
| 新しい加工 | 新規 `Project` として開始できる（整合性封鎖の範囲でクォータ判定を受ける） |

利用者へは「以前の作業を再開できない」ことを明示する。

##### 履歴側への影響

`projectSourceSnapshots` / `exportedSettingsEntries`（pending 含む）/ `workingSourceBindings` は署名済み台帳の一部であり、HMAC 不一致では内容を信用できないため、修復では 3 つとも空にする。

| 失われるもの | 修復後の扱い |
| --- | --- |
| 既存 `Project` の素材 identity | 再接続できない。閲覧と削除のみ |
| 「変更せず再書き出し」の比較対象 | 無料の再書き出しが成立しない。新規プロジェクトとして通常の消費 |
| 処理用実体との結び付き | `WorkingSourceRecord` ごと破棄されるため、対応する binding も残らない |

どちらも利用者に不利な側へ倒れるが、成果物は失わない（改ざんされた可能性のある identity を信用すると、別の写真を「同じ素材」として無料で処理できてしまう）。`Project` 行そのものは削除しない。

##### 署名不正行の扱いはここだけ例外にする

6 章は「署名検証に失敗した行を自動破棄しない」と定めるが、台帳修復時はこの例外とする（破棄しない根拠は「会計済みか判断できないため台帳と食い違う可能性がある」ことだが、台帳が既に空へ修復されている以上、食い違う相手が存在しない）。ただし、破棄の手順は 6 章と同じ制約に従う。

| 規則 | 内容 |
| --- | --- |
| 削除の指定 | DB 内部の行 ID だけを使う |
| `projectID` / `exportID` / `outputFile` | 一切使わない（改ざんされている可能性がある） |
| 対応キュー項目の特定 | 行わない。上の表のとおり全非終端キュー項目を `failed(ledgerRepaired)` にする |

キュー項目を個別に特定しない（署名不正行の `projectID` は使えないため対応関係を辿れず、修復起動では全非終端キュー項目が一律 `failed(ledgerRepaired)` になるため、特定作業そのものが不要）。

| 遷移前の状態 | 遷移後 |
| --- | --- |
| `waiting` / `analyzing` / `reviewRequired` / `exporting` / `paused` | `failed(ledgerRepaired)` |
| `completed` / `failed` / `canceled`（終端） | 変更しない |

`ExportCommit` へ alias のスナップショットを持たせて `SourceRecord` を再構築する案は採らない（署名不正行の扱いが「フィールドを一切使わない」と両立しなくなる。修復はそもそも改ざんの疑いがある状態であり、進行中の書き出しを完了させる利得より台帳の一貫性を優先する）。

この分岐は手順 2 の直後（手順 4 の復旧より前）に置く。障害注入テストの対象。

### 5.3 状態別の復旧

| 中断位置 | 復旧 |
| --- | --- |
| `prepared` | 一時ファイルを削除し、トライアル予約・`SourceLease`・未参照になった `SourceRecord` を取り消してコミットを破棄する。生成未完了なので消費しない |
| `fileVerified` | ファイルが健在なら手順 3 からやり直す（新しい `finalizedAt` を決める）。失われていればロールバック |
| `finalizing` | 暫定適用があれば冪等に取り消し、手順 3 からやり直す |
| `accountingCommitted` | 出力ファイルを再検証する（5.4）。正常なら暫定適用を取り消し、手順 3 からやり直す |
| `readyToPublish` | 出力ファイルを `verifiedOutput` と照合する。正常なら暫定適用を取り消し、手順 3 からやり直す。不一致ならロールバック |
| `rollingBack` | ロールバックの手順 1 から冪等に再実行する。手順 3 へ戻さない |
| `published` | 前進のみ。手順 8（設定エントリの昇格）と手順 9（コミット行の削除）を冪等に再実行する |
| 署名検証に失敗 | 復旧エラー。自動破棄しない（6 章） |

`published` からはやり直さない（会計は確定済みで `OutputRecord` も存在する。ここで手順 3 へ戻すと、同じ出力に対して 2 つ目の `OutputRecord` ができる）。手順 8 は冪等（昇格対象は `ownerExportID` がこのコミットの `exportID` と一致する pending だけであり、既に昇格済みなら pending が存在せず何も起きない）。

`finalizing` 以降からの復旧は、`readyToPublish` を含めて必ず手順 3 へ戻る。例外はない。`readyToPublish` で異常終了し数日後に再起動した場合、`finalizedAt` は数日前で `expiresAt = finalizedAt + 24h` はすでに過ぎており、公開した瞬間に期限切れの出力ができてしまう（ファイル検証が済んでいることと、時刻が妥当であることは別の話）。

`readyToPublish` を無条件に削除しない（手順 6 と 7 の間で落ちた可能性があり、コミット行だけが復旧の手がかりのため。この時点では `OutputRecord` がまだ無いため、コミットを消すと出力が孤児ファイルになる）。

### 5.4 `accountingCommitted` からの復旧

台帳は暫定適用済みなので、ファイルが失われていれば「消費したのに受け取れない出力」になる。

| 再検証の結果 | 対応 |
| --- | --- |
| 正常 | 暫定適用を取り消し、手順 3 からやり直す（`OutputRecord` は手順 7 で作る） |
| 欠損・破損 | このコミットが実際に追加した会計要素だけを取り消す（4 章） |
| 取り消し不能 | 復旧エラーとして新規書き出しをブロックする。自動削除しない |

---

## 6. 署名不正コミット

`ExportCommit` は DB にあるが、その内容が ProtectedBlobStore の台帳更新を駆動する。DB を書き換えれば台帳を任意に操作できてしまうため、コミット行にも HMAC を付ける。

署名検証に失敗した行を自動破棄しない（破棄すると、すでに反映済みの `UsageLedger` だけが残る可能性がある。会計済みかどうかを判断できない以上、復旧エラーとして扱い、新規書き出しをブロックしたうえで利用者へ提示する。ファイルも自動削除しない）。

### 6.1 復旧エラーの解消

ブロックしたまま解除手段がないと、破損したコミット 1 件でアプリが永久に書き出し不能になる。利用者には「もう一度試す」と「破損した処理を破棄して続ける」を提示する。「破棄して続ける」の挙動。

- クォータやトライアルクレジットを払い戻さない
- 台帳側の会計を先に確定させる（6.2 の lease / pending の分岐）
- 該当の `ExportCommit` を行 ID で削除する。出力ファイルと `OutputRecord` には触れない
- 保留していた孤児回収（手順 3 の予約・lease、手順 5.5 の pending）を実行する
- 復旧エラーを解除し、新規書き出しを許可する

払い戻さないため利用者に不利になりうるが、破損した DB の情報を根拠に権利を増やす方が危険（改ざんによる枠の水増しに直結する）。

### 6.2 署名不正行のフィールドを一切使わない

HMAC 検証に失敗した時点で、その行の全フィールドが信用できない。

| 改ざん先 | 起こること |
| --- | --- |
| `exportID` を別の正規予約のものへ | 無関係なクレジットを消費させられる |
| `outputFile` を別の正常な出力へ | 専用ディレクトリ外へは出られないが、他の正常な出力を削除できる |
| `projectID` を別の履歴へ | 無関係な履歴を巻き込む |

復旧の根拠は署名済み `UsageLedger` 側だけとする。まず、有効な署名済みコミットに対応しない `SourceLease`（孤立 lease）を抽出する。v1 は全体ゲートにより同時 1 件なので、孤立 lease は 0 件か 1 件のはず。同時に、有効な署名済みコミットに対応しない `pendingExportedSettingsEntries`（孤立 pending）も数える。手順 4 で lease が消えて pending が生まれるため、この 2 つの個数の組み合わせが「どこまで進んでいたか」を一意に表す。

| 孤立 lease | 孤立 pending | 到達点 | 処理 |
| --- | --- | --- | --- |
| 1 件 | 0 件 | 手順 4 より前 | `accountingMode` に従って消費を確定し、`SourceLease` を削除する（下表） |
| 0 件 | 1 件 | 手順 4 以降 | pending を削除する。確定側へ昇格しない。消費は既に確定済みなので触らない |
| 0 件 | 0 件 | 手順 8 完了後、または最初から会計要素なし | 台帳を一切変更しない |
| 上記以外 | | 一意に決められない | 復旧エラーを維持し、台帳へ触れない |

いずれの場合も、台帳の保存成功を確認してから署名不正行を DB 内部の行 ID だけで削除する。

孤立 pending を無視すると、未成功の設定が残る（手順 4 で lease は消えるため、lease だけを見る規則では「0 件＝台帳へ触れない」となり、一度も正常書き出ししていない設定が pending に残ったままになる。pending は「変更せず再書き出し」の判定に使われないが、次の書き出しで同じ `projectID` の pending を上書きできず、不変条件 10「`projectID` ごとに 1 件」に抵触する）。署名不正行の `exportID` は使わない（判断材料は「孤立要素の個数」と「台帳自身が持つ `ownerExportID`」だけ。削除対象の pending は、有効なコミットが存在しない `ownerExportID` を持つものとして台帳側から特定する）。

`SourceLease.accountingMode` から消費を確定する。

| `accountingMode` | 台帳への操作 |
| --- | --- |
| `freeMonthlyConsume` | `consumedExportIDs` へ `lease.exportID` を追加する |
| `batchTrial(true)` | その `exportID` の `TrialReservation` を同じ `sourceID` の `TrialEntry` へ変換する |
| `batchTrial(false)` | 追加消費なし（既に `TrialEntry` がある） |
| `freeMonthlyReexport` | 追加消費なし（24 時間以内の再書き出し） |
| `paidUnlimited` | 追加消費なし |

`accountingMode` を lease へ持たせるのは、これが署名済みの唯一の手掛かりのため（コミット行のフィールドは一切使えず、予約の有無だけを見ると手順 4 より前にコミットを壊すことで消費を回避できてしまう）。`consumedExportIDs` への追加も冪等（集合であるため、既に含まれていれば何も起こらない。手順 4 の完了後に壊れた場合と合わせて二重計上は生じない）。

lease 0 件は「手順 4 を通過した」ことを意味する（`SourceLease` は手順 4 の台帳トランザクションで削除されるため。このとき pending が 1 件あれば手順 8 の前、0 件なら手順 8 の後だが、いずれも会計は確定済みであり払い戻しは行わない）。lease と pending がともに 1 件ある、あるいはどちらかが 2 件以上ある状態は、全体ゲートが同時 1 件しか許さない設計と矛盾する。自動で決めず復旧エラーを維持する。

##### 一意に決められない場合の最終手段

自動判断を拒むだけでは、復旧エラーが永久に解除されない。利用者が明示的に選べる最終手段を用意する。

| 選択肢 | 挙動 |
| --- | --- |
| もう一度試す | 再検証する。他の起動要因で解消していれば通常経路へ戻る |
| すべて破棄して続ける（払い戻しなし） | 孤立 lease と孤立 pending をすべて削除する。`accountingMode` が `freeMonthlyConsume` の lease については、その `exportID` を `consumedExportIDs` へ入れて消費を確定させる |

| 規則 | 内容 |
| --- | --- |
| 提示の条件 | `(1 / 1)` または 2 件以上の状態で、利用者が復旧エラー画面から選んだときだけ |
| 消費の扱い | `accountingMode` に従って確定する。`freeMonthlyConsume` の lease は `consumedExportIDs` へ入れる。`paidUnlimited` と `trialCredit` は枠を消費しないため入れない |
| 予約の扱い | `TrialReservation` は削除する（`TrialEntry` へ変換しない） |
| 署名不正行 | 同じ台帳トランザクションの完了後に、行 ID だけで削除する（下記の 4 分岐と同じ扱い） |
| 文言 | 「中断した処理を破棄します。使用した枠は戻りません」を明示する |

`accountingMode` から消費を確定させる（省くと、コミット行を任意に削除して孤立 lease と孤立 pending の個数を作り、この分岐へ意図的に到達すれば同じ回避が成立してしまう。lease 自体は正規の経路で台帳に作られた署名済みの記録であり、対応するコミットが分からなくても「この `exportID` が無料枠を消費するつもりだった」ことは分かる）。

払い戻さない（未計上の消費を残すよりも「身に覚えのない消費が 1 件増える」ほうが害が小さい。前者は繰り返し収穫できるが、後者は 1 回きりで、かつこの分岐に到達するのは全体ゲートの不変条件が既に破れている状態）。トライアルクレジットは戻る（予約を削除すると `trialEntries` へ移していないためクレジットが回復する。回復するのは最大 1 枚であり、正常な利用では到達しない）。

署名不正行そのものも削除する（削除しないと次回起動で同じ復旧エラーへ戻り、最終手段を選んだ意味がない。台帳の保存に成功したことを確認してから、行 ID だけで削除する）。1 件の場合に台帳の保存が失敗したら、コミットを削除せず復旧エラーを維持する（台帳を確定できていないのにコミットを消すと、次回起動で孤児予約として払い戻される）。

署名不正行が存在する間は、孤児 `TrialReservation` / `SourceLease` / `pendingExportedSettingsEntries` の自動回収を全件保留する（5 章の手順 3 と 5.5。どの孤児が破損行に対応するかを識別できないため）。「破棄して続ける」の完了後に、保留していた回収を実行する（実行しないと孤児予約がクレジットを占有したまま新規認可が許可され、実際には空いているクレジットを「使用中」と判定する）。

### 6.3 ファイルには触れない

署名不正行の `outputFile` と `projectID` は信用できない。`ManagedFileRef` により専用ディレクトリの外へは出られないが、同じディレクトリ内の別の正常な出力を指すことは可能。行を削除したあと、その出力ファイルはどこからも参照されなくなり、起動時の孤児ファイル GC が回収する（参照の有無だけを根拠にするため、改ざんされたフィールドの影響を受けない）。

`TrialEntry` の `ownerExportID` には対象の `exportID` をそのまま入れる（その書き出しは成功していないが、クレジットは消費されたものとして扱う。同じ素材を再度処理する場合は `batchTrial(false)` となり追加のクレジットは消費しない。利用者から見れば「1 枚分の試用機会を使ったが、その素材はまた試せる」状態になる）。

---

## 7. コミット確定後に出力実体が失われた場合

ジャーナルを消したあとで `OutputRecord` と実体が食い違うことは、外部要因（OS によるキャッシュ削除、ストレージ障害）で起こりうる。v1 では自動再生成を行わない。

| 状況 | 扱い |
| --- | --- |
| 実体が無い、または `outputByteSize` / `outputSHA256` と一致しない | `OutputRecord` を削除する（4 章のロールバックではなく、7.5 の出力削除経路） |
| `UsageLedger` | 変更しない。月間枠・grant・トライアルクレジットのいずれも戻さない |
| 利用者への提示 | 出力を復元できないこと、および新しい書き出しになることを示す |
| 24 時間以内の同一素材 | grant により `freeMonthlyReexport` が成立するため、追加消費なしでやり直せる |

`retentionNow == nil` の間は削除も判定も保留する（時計異常中に破壊的削除を行わないため）。

### 7.1 自動再生成を持たない理由

現在保持しているデータでは再生成できない。

| 必要なもの | 現状 |
| --- | --- |
| 元画像 | `WorkingSourceRecord` は書き出し完了時に削除される（[画像処理](image-pipeline.md)） |
| `RenderSpec` | `OutputRecord` は保持しない。`Project` 側は編集で変化しうる |
| `ExportSetting`（形式・品質・メタデータ） | `OutputRecord` は保持しない |
| `OutputFile.format` / `suggestedCreationDate` | `OutputRecord` が持つようになった（3.5）。ただし他が揃わない |

再生成を成立させるには、出力の期限まで不変のスナップショット（正確な `RenderSpec` と `ExportSetting`、元画像の再取得手段または処理用コピー、出力形式と登録日時、再取得権限が無い場合の利用者操作）を保持する必要がある。これは未加工の顔画像を最大 24 時間追加で保持することを意味し、プライバシーと容量の複雑性が v1 の利得に釣り合わない。同じ素材の再書き出しは grant により追加消費なしで行えるため、利用者の損失は「もう一度操作する手間」に限られる。

v2 で保持コストを許容できる場合は、不変のスナップショットと専用の復旧ジャーナルを導入する設計へ拡張する。v1 の文書には契約を置かない。

---

## 8. 利用者への受け渡し

- 写真ライブラリへ保存する（`MediaSaver`）
- OS 共有へ渡す（`SharePresenter`）

いずれも任意であり、何度実行しても追加消費しない。失敗した場合は生成済み出力を保持したまま再試行でき、再書き出しは不要。

### 8.0 写真ライブラリ保存の結果不明

PhotoKit と `app.db` は同一トランザクションにできない。PhotoKit への保存が成功したあと `OutputRecord` を `delivered` へ更新する前にプロセスが終了すると、再起動後は `generated` に見え、再保存すると写真ライブラリに重複する。exactly-once は保証できない。保証できないことを明示し、自動再試行で重複を作らない設計にする。

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
| 3 | 成功したら、`OutputRecord` を `delivered` へ更新し `DeliveryAttempt` を削除する（同一トランザクション） | DB |
| 4 | 失敗したら `previousState` へ戻し、`DeliveryAttempt` を削除する | DB |

起動時に `DeliveryAttempt` が残っていれば、手順 2 と 3 の間で終了している。

| `previousState` | 起動時の扱い |
| --- | --- |
| `generated` | `deliveryUnknown` へ更新する |
| `deliveryUnknown` | `deliveryUnknown` のまま |
| `delivered` | `delivered` を維持する。状態は後退させず、「写真ライブラリへの保存結果が不明」を別途提示する |

| 項目 | 扱い |
| --- | --- |
| 自動再保存 | 行わない（重複を作りうる） |
| 自動削除 | 行わない。出力は保持する |
| 利用者への提示 | 写真ライブラリを確認したうえで、保存済みなら破棄、未保存なら再試行を選ばせる |

`OutputState` の定義と DB 列値は [アーキテクチャ設計](architecture.md) の 7.5 が正本。`deliveryUnknown` は未受け渡しとして扱う（24 時間の保持対象であり、完了画面の離脱確認にも数える。受け取れていない可能性がある側へ倒す。`.unknown` の共有結果と同じ方針）。

##### `delivered` を後退させない

受け渡しは複数回・任意の順序で行える（[アーキテクチャ設計](architecture.md) の 7.5）。OS 共有に成功したあと写真ライブラリへも保存する経路があるため、`previousState` が無いと、PhotoKit 完了後 DB 更新前に異常終了した場合に `deliveryUnknown` へ後退し、以前に共有が成功した事実まで失われる。一度成立した `delivered` は取り消さない（利用者はすでに成果物を受け取っており、「受け取れていない可能性がある側へ倒す」判断はその事実を打ち消す理由にならない）。写真ライブラリ側の不明は、状態ではなく個別の案内として提示する。

##### 受け渡しを`exportID`ごとに直列化する

`actor` であることは排他保証にならない（`await` のたびに再入可能であり、`MediaSaver.saveToPhotoLibrary` の待機中に別の受け渡し操作が同じ `exportID` へ入り、写真ライブラリ保存の失敗による `abandonDeliveryAttempt` が、待機中に成立した OS 共有の `delivered` を消してしまう経路がある）。`exportID` ごとの明示的な待ち行列で直列化する（[アーキテクチャ設計](architecture.md) の 4.2 と同じ方式。`actor` の再入性に依存しない）。

| 規則 | 内容 |
| --- | --- |
| 排他の単位 | `exportID` |
| `DeliveryAttempt` が存在する間 | その出力への共有・破棄・別の保存をすべて拒否する |
| `abandonDeliveryAttempt` | `previousState` へ戻す。ただし現在状態が `delivered` なら維持する |
| `resolveOrphanedAttempts` | 同上。`delivered` を `deliveryUnknown` へ下げない |
| メソッドの分離 | 写真ライブラリ用と共有用を分ける（共有は `DeliveryAttempt` を作らない） |

`abandonDeliveryAttempt` にも現在状態の検査を残す（直列化していれば理屈上は起こらないが、規則を 1 か所の排他実装だけに依存させない）。

##### 保存結果不明を永続化する

`previousState == .delivered` の場合、`delivered` を維持したうえで「写真ライブラリへの保存結果が不明」を提示する。この事実は戻り値だけでは次の起動へ残らない。

```swift
/// 写真ライブラリ保存の結果が不明であることの記録。runtime 側のテーブル
struct UnknownLibrarySave: Sendable {
    let exportID: ExportID
    let occurredAt: Date
}
```

| 契機 | 操作 |
| --- | --- |
| `resolveOrphanedAttempts` で `delivered` を維持したとき | upsert する（既存行があれば `occurredAt` を更新する） |
| 利用者が「確認した」を選んだとき | 行を削除する |
| 出力そのものが削除されたとき | `OutputRecord` への FK CASCADE で消える |

追加を upsert にする（`UnknownLibrarySave.exportID` は PRIMARY KEY。[アーキテクチャ設計](architecture.md) の 7.1。注記が残ったまま再び写真ライブラリ保存を試みて中断すると、次回起動の `resolveOrphanedAttempts` が同じ `exportID` を再挿入する。この関数は単一トランザクションで全件を返す契約なので、制約違反は起動時復旧の手順 7 全体を失敗させ、7.5・8・9 へ到達できなくなる）。`occurredAt` を更新するのは、最後に不明になった時刻を示すため。

`OutputState` を増やさない（「共有は成功したが写真ライブラリは不明」は受け渡し状態の一種ではなく `delivered` に付随する注記。状態へ混ぜると `isUndelivered` の定義が曖昧になる）。

##### 状態遷移は用途別メソッドで行う

汎用の `updateOutputState(_:to:)` を置かない（任意の逆遷移を作れるため、`delivered` → `generated` のような呼び出しが型では止まらない）。`OutputDeliveryStore`（0 章）の各メソッドが、それぞれ 1 つの遷移だけを担う。

| メソッド | 遷移 | 呼ばれる場面 |
| --- | --- | --- |
| `completeLibrarySave` | `generated` / `deliveryUnknown` → `delivered`。`DeliveryAttempt` を削除 | 写真ライブラリ保存の成功 |
| `completeShare` | `generated` / `deliveryUnknown` → `delivered` | 共有の `.completed` |
| `abandonDeliveryAttempt` | `previousState` へ戻す（現在が `delivered` なら維持） | 写真ライブラリ保存の失敗 |
| `resolveOrphanedAttempts` | `previousState` が `generated` なら `deliveryUnknown`、`delivered` なら維持 | 起動時（手順 7） |
| `markDiscarded` | 任意の状態 → `discarded` | 利用者の明示的な破棄のみ |

共有には `DeliveryAttempt` を作らない（結果が同期的に返るため中断点が無く、`.completed` のときだけ `completeShare` を呼ぶ。`.canceled` / `.failed` / `.unknown` では現在の状態を変えない）。メソッドを分けるのは、`completeLibrarySave` が `DeliveryAttempt` の削除を伴い、`completeShare` が伴わないため。`delivered` → `deliveryUnknown` を行うメソッドは存在しない（後退させる手段を実装しないことで、規則を型で担保する）。

OS 共有（`SharePresenter`）にはこの経路がない（結果が同期的に返るため）。

```swift
enum ShareResult: Sendable, Equatable { case completed, canceled, unknown, failed }
```

| 結果 | 出力状態 | 扱い |
| --- | --- | --- |
| `.completed` | `generated` / `deliveryUnknown` → `delivered` | 受け渡し成功 |
| `.canceled` | 現在の状態を維持 | 利用者が取りやめた |
| `.failed` | 現在の状態を維持 | 再試行できる |
| `.unknown` | 現在の状態を維持 | 安全側へ倒す |

`.unknown` は、共有先アプリが完了を返さない場合に生じる（ここで `delivered` にすると、実際には渡っていない写真を「保存済み」として一時ファイルを消しかねない。受け取れていない可能性がある側へ倒す）。

### 8.1 `ShareLink` では実装できない

`SharePresenter` は `UIActivityViewController` だけで実装する（`ShareLink` は共有 UI を提示する `View` であり、完了結果を返す API を持たない。上の 4 値を返せない以上、`delivered` への遷移条件を判定できない）。`completionWithItemsHandler` からの写像。

| 条件 | 結果 |
| --- | --- |
| `activityError != nil` | `.failed` |
| `completed == true` | `.completed` |
| `completed == false` かつ `activityType == nil` | `.canceled`（シートを閉じた） |
| それ以外 | `.unknown` |

最後の行が要点。`completed == false` でも `activityType` が入っている場合は、共有先アプリが結果を返さなかったことを意味する。取りやめとは区別できないため `.unknown` とする。

`UIViewControllerRepresentable` で包み、`CheckedContinuation` で `async` 関数として公開する。
