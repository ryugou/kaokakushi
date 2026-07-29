# 正準バイト表現と署名スキーマ

| 項目 | 内容 |
| --- | --- |
| 目的 | HMAC 署名の対象となる全型について、バイト列を一意に定める |
| 読者 | `Persistence` の実装者、署名まわりのテスト作成者 |
| 正本の範囲 | 符号化規則、型ごとのフィールド順、`enum` の固定番号、署名対象 payload の定義 |
| 関連 | [アーキテクチャ設計](architecture.md)（署名の原則）、[書き出し Saga](export-saga.md)（`ExportCommit` の意味論）、[テスト計画](test-plan.md)（ゴールデンテスト） |

**この文書がバイト表現の唯一の正本です。** 他の文書は型の意味を定義し、バイト表現には言及しません。

---

## 1. 原則

`JSONEncoder` や binary plist を正準形として使いません。集合と配列の順序、`Date` の表現、辞書のキー順が実装とバージョンに依存し、**同じ意味の値から別の署名が出れば正規の起動が `integrityFailure` になります。**

```swift
enum PayloadType: UInt32, Sendable {
    case usageLedger = 1
    case subscriptionState = 2
    case exportCommit = 3
    case remoteConfigState = 4
}

struct SignedPayload: Sendable {
    let payloadType: PayloadType
    let schemaVersion: UInt32
    let canonicalBytes: Data
    let signature: Data
}
```

- HMAC の対象は **`signature` 自身を除く全永続フィールド**
- **`schemaVersion` と `payloadType` を署名対象へ含める**
- `ExportCommit` の insert / update の**たびに再署名する**
- `UsageLedgerStore.transact` の保存時にも必ず再署名する
- 検証はバイト列の**定数時間比較**で行う
- マイグレーション時は旧形式で検証してから新形式で再署名する

**`payloadType` を含めないと、種別をまたいだ付け替えを検出できません。** 4 種のデータが同じ鍵で署名されているため、有効な `SubscriptionState` の blob を `UsageLedger` の保存先へ置いても検証を通ります。

**追加は末尾のみ**とし、既存フィールドの順序を変えません。順序を変える必要が生じた場合は `schemaVersion` を上げ、旧バージョンのデコーダを残します。

---

## 1.1 暗号アルゴリズムと鍵

**アルゴリズムを名前とビット長で固定します。** 「HMAC」「HKDF」だけでは実装が一意に定まりません。

| 項目 | 値 |
| --- | --- |
| 署名 | **HMAC-SHA256** |
| 署名長 | **32 バイト固定** |
| 鍵導出 | **HKDF-SHA256**（RFC 5869。extract → expand の両段） |
| マスター鍵 | **256 bit（32 バイト）**。`SecRandomCopyBytes` で生成し Keychain へ保存 |
| 派生鍵の長さ | **32 バイト** |
| HKDF の `salt` | **空（長さ 0）** |
| HKDF の `info` | 用途ごとの派生ラベルの UTF-8 バイト列 |
| 検証 | バイト列の**定数時間比較**（`timingsafe_bcmp` 相当） |

**`salt` を空にするのは、マスター鍵が既に一様乱数だからです。** HKDF の `salt` は入力鍵材料のエントロピーが偏る場合に効きます。`SecRandomCopyBytes` の出力へ salt を足しても強度は上がらず、salt をどこへ保存するかという問題だけが増えます。

派生ラベルです。

| 用途 | `info`（UTF-8） |
| --- | --- |
| 台帳・購入状態・コミット・リモート設定の署名 | `payload-signing-v1` |
| `providerAssetKeyHash` の HMAC 用派生鍵 | `source-provider-key-v1` |

**2 つを分けるのは、性質が違うからです。** 一方は値の秘匿、他方は完全性の保証が目的であり、同じ鍵を使うと片方の運用（ローテーション等）がもう片方へ波及します。

##### `providerAssetKeyHash`

| 項目 | 規約 |
| --- | --- |
| アルゴリズム | **HMAC-SHA256**（鍵は `source-provider-key-v1` の派生鍵） |
| 入力 | `PHAsset.localIdentifier` の UTF-8 バイト列 |
| 出力形式 | **32 バイトを小文字 16 進の 64 文字へ**（`String` として保持する） |

**16 進固定にするのは、`SourceAlias.provider(String)` として台帳へ入り、正準化で UTF-8 バイト列として符号化されるためです。** Base64 や大文字混在を許すと、同じ入力から別の alias ができます。

##### 時刻の丸め

| 項目 | 規約 |
| --- | --- |
| 表現 | UTC epoch milliseconds の `Int64` |
| 丸め | **floor**（ミリ秒未満を切り捨てる） |
| 負の値 | 1970 年より前も floor（`-0.5ms` は `-1`） |

**floor に固定するのは、`Date` の内部表現が `Double` 秒だからです。** 丸め方向が実装依存だと、同じ `Date` から別のバイト列が出ます。`round` は境界で振れるため使いません。

---

## 2. 基本型の符号化

| 型 | 符号化 |
| --- | --- |
| 先頭 | `payloadType`（`UInt32`）＋ `schemaVersion`（`UInt32`） |
| 整数 | **ビッグエンディアン**の固定長 |
| `Bool` | `UInt8`（`0` / `1`） |
| `enum` | **固定の `UInt32`**（`case` の宣言順に依存させない。5 章） |
| 可変長データ | `UInt32` の長さ前置き |
| `Date` | **UTC epoch milliseconds の `Int64`** |
| `Double` | **IEEE 754 の `bitPattern`**（`-0.0` は `+0.0` へ正規化してから） |
| `UUID` | 16 バイト |
| `Optional` | **`0` / `1` のタグ** ＋ 値（`nil` はタグのみ） |
| `String` | **UTF-8** バイト列（長さ前置き） |
| コレクション | **先頭に `UInt32` の要素数**、各要素は長さ前置き |
| **unordered collection** | 各要素を符号化し、**バイト列の辞書順にソート**してから連結 |
| **ordered array** | **元の順序を保持する。ソートしない** |

### 2.1 ordered と unordered の分類

**順序に意味を持つ配列が存在します。** 一律にソートすると `RenderSpec.regions` の描画順を変え、署名のための正準化が意味を持つデータを壊します。

| 分類 | 対象 |
| --- | --- |
| unordered | `consumedExportIDs`、`sourceRecords`、`grants`、`trialEntries`、`trialReservations`、`sourceLeases`、`exportedSettingsEntries`、`projectSourceSnapshots`、`SourceRecord.aliases`、`RemoteConfig.enabledStampPacks` |
| ordered | `RenderSpec.regions`、`ReviewIssueID.affectedFaceTrackIDs` |

`affectedFaceTrackIDs` は「辞書順にソート済み」として構築されますが、それは**構築時の規則**であり、正準化がソートするのではありません。順序は値の一部です。

**`FaceTrackID` は `UUID` なので、文字列化の表現に依存しない順序を定めます。**

> `UUID` の 16 バイトを**符号なしバイト列として辞書順**に比較する。

大文字小文字やハイフンの有無は順序へ影響しません。unordered collection のソートにも同じ規則を使います。

**分類は型に付けます。** unordered な集合は Swift の `Set` として宣言し、`Array` はすべて ordered として扱うのが原則です。`grants` などが `Array` なのは要素が `Hashable` でないためであり、この場合は**エンコーダ側に unordered として明示的に登録します。**

### 2.2 識別子

| 型 | 符号化 |
| --- | --- |
| `ProjectID` / `BatchID` / `ExportID` / `RegionID` / `SourceID` / `ManagedFileID` | `UUID` の 16 バイト |
| `ContentFingerprint` / `StampAssetHash` | **32 バイト固定長**（長さ前置きしない） |
| `FaceTrackID` | `UUID` の 16 バイト |
| `ManagedFileRef` および種別つき参照（`OutputFileRef` ほか） | `kind`（`UInt32`）→ `fileID`（16 バイト） |

---

## 3. `enum` の固定番号

**`case` の宣言順に依存させません。** `case` を追加した時点で既存の全署名が変わるためです。

### `SourceAlias`

| case | 番号 | 連想値 |
| --- | --- | --- |
| `provider` | 1 | `String`（小文字 16 進 64 文字） |
| `content` | 2 | **32 バイト固定長**（`ContentFingerprint`） |

### `SourceRepresentation`

| case | 番号 |
| --- | --- |
| `original` | 1 |
| `transcoded` | 2 |

### `MonthlyIntegrityLock`

| case | 番号 | 連想値 |
| --- | --- | --- |
| `none` | 1 | — |
| `lockedUntilTrustedMonthAfter` | 2 | `TrustedUTCMonth` |
| `lockedUntilReinstall` | 3 | — |

### `ExportCommitState`

| case | 番号 |
| --- | --- |
| `prepared` | 1 |
| `fileVerified` | 2 |
| `finalizing` | 3 |
| `accountingCommitted` | 4 |
| `readyToPublish` | 5 |

### `ExportAccountingMode`

| case | 番号 | 連想値 |
| --- | --- | --- |
| `paidUnlimited` | 1 | — |
| `freeMonthlyConsume` | 2 | — |
| `freeMonthlyReexport` | 3 | — |
| `batchTrial` | 4 | `consumesTrialCredit: Bool` |

### `GrantAction`

| case | 番号 | 連想値 |
| --- | --- | --- |
| `ensure` | 1 | `sourceID` → `firstSuccessAt` |
| `preserveAuthorized` | 2 | `sourceID` → `firstSuccessAt` |

### `Plan`

| case | 番号 |
| --- | --- |
| `free` | 1 |
| `standard` | 2 |
| `pro` | 3 |

### `ImageFormat`

| case | 番号 |
| --- | --- |
| `jpeg` | 1 |
| `heic` | 2 |
| `png` | 3 |

### `PlanStatus`

| case | 番号 |
| --- | --- |
| `active` | 1 |
| `grace` | 2 |
| `pending` | 3 |
| `expired` | 4 |
| `revoked` | 5 |

### `ManagedFileKind`

`UInt32` の生値を型定義そのものが持ちます（`output = 1` 〜 `protectedBlob = 7`）。

### `ProtectedPayload.blobKeyRawValue`

**内部ファイル名の決定に使うため、値を固定します。**

| 型 | 値 |
| --- | --- |
| `UsageLedger` | **1** |
| `SubscriptionState` | **2** |
| `RemoteConfigState` | **3** |

この対応もゴールデンテストの対象です（6 章）。

---

## 4. 署名対象 payload

### 4.1 `UsageLedger`（`schemaVersion` 1）

| 順 | フィールド | 型 |
| --- | --- | --- |
| 1 | `period` | `YearMonth` |
| 2 | `consumedExportIDs` | unordered set of `ExportID` |
| 3 | `sourceRecords` | unordered collection of `SourceRecord` |
| 4 | `grants` | unordered collection of `GrantEntry` |
| 5 | `trialEntries` | unordered collection of `TrialEntry` |
| 6 | `trialReservations` | unordered collection of `TrialReservation` |
| 7 | `sourceLeases` | unordered collection of `SourceLease` |
| 8 | `exportedSettingsEntries` | unordered collection of `ExportedSettingsEntry` |
| 9 | `projectSourceSnapshots` | unordered collection of `ProjectSourceSnapshot` |
| 10 | `lastObservedAt` | `Date` |
| 11 | `monthlyIntegrityLock` | `MonthlyIntegrityLock` |
| 12 | `lastTrustedMonth` | `TrustedUTCMonth?` |
| 13 | `trialIntegrityLocked` | `Bool` |

要素型のフィールド順です。

| 型 | 順 |
| --- | --- |
| `YearMonth` / `TrustedUTCMonth` | `year`（`Int32`）→ `month`（`Int32`）。**実型も `Int32`** |
| `SourceRecord` | `sourceID` → `aliases`（unordered） |
| `GrantEntry` | `sourceID` → `firstSuccessAt` → `ownerExportID` |
| `TrialEntry` | `sourceID` → `ownerExportID` |
| `TrialReservation` | `sourceID` → `exportID` |
| `SourceLease` | `sourceID` → `exportID` |
| `ExportedSettingsEntry` | `projectID` → `settingsHash`（32 バイト固定）→ `exportedAt` → `ownerExportID` |
| `ProjectSourceSnapshot` | `projectID` → `identity` → `representation` → `capture` → `libraryCreationDate` → `registeredAt` |
| `SourceIdentity` | `providerAssetKeyHash`（`String?`）→ `contentFingerprint`（32 バイト固定） |
| `OriginalCaptureMetadata` | `dateTimeOriginal` → `subSecTimeOriginal` → `offsetTimeOriginal` → `utcMillis`（すべて `Optional`） |

`ExportedSettingsEntry` と `ProjectSourceSnapshot` は **`projectID` ごとに 1 件**です。台帳の検証時に重複が無いことを確認します。

台帳修復時は、両方とも**空**にします（[アーキテクチャ設計](architecture.md) の 6.3）。

### 4.2 `SubscriptionState`（`schemaVersion` 1）

型定義は [アーキテクチャ設計](architecture.md) の 6.2 が正本です。ここには順序だけを置きます。

| 順 | フィールド | 型 |
| --- | --- | --- |
| 1 | `entitlement` | `Entitlement`（下記） |
| 2 | `willRenew` | `Bool` |
| 3 | `fetchedAt` | `Date` |

`Entitlement` の順は `plan` → `status` → `expiresAt` → `lastVerifiedAt` です。

**`fetchedAt` と `Entitlement.lastVerifiedAt` は別の値です。** 前者はキャッシュを書いた時刻、後者は権限を検証できた時刻で、オフライン時にキャッシュを読み直しても後者は動きません。

### 4.3 `ExportCommit`（`schemaVersion` 1）

| 順 | フィールド | 型 |
| --- | --- | --- |
| 1 | `exportID` | `ExportID` |
| 2 | `projectID` | `ProjectID` |
| 3 | `batchID` | `BatchID?` |
| 4 | `sourceID` | `SourceID` |
| 5 | `outputFile` | `OutputFileRef?`（`prepared` では `nil`） |
| 6 | `authorization` | `ExportAuthorization` |
| 7 | `verifiedOutput` | `VerifiedOutput?` |
| 8 | `finalizedAt` | `Date?` |
| 9 | `finalizedPeriod` | `YearMonth?` |
| 10 | `intent` | `AccountingIntent?` |
| 11 | `applied` | `AccountingApplied?` |
| 12 | `state` | `ExportCommitState` |
| 13 | `delivery` | `OutputDeliveryDescriptor` |

ネストした型のフィールド順です。

| 型 | 順 |
| --- | --- |
| `ExportAuthorization` | `entitlementSnapshot`（`Entitlement`）→ `accountingMode` → `authorizedAt` → `authorizedGrant` |
| `AuthorizedGrant` | `sourceID` → `firstSuccessAt` |
| `VerifiedOutput` | `byteSize`（`Int64`）→ `sha256`（32 バイト固定長。長さ前置きしない） |
| `AccountingIntent` | `consumeExportID` → `grantAction` → `trialSourceIDToEnsure` → `settingsEntryToApply` → `previousSettingsEntry` |
| `AccountingApplied` | `consumedInserted` → `grantInsertedByThisExport` → `trialInsertedByThisExport` → `settingsEntryReplaced` |
| `OutputDeliveryDescriptor` | `format`（`UInt32`）→ `suggestedCreationDate`（`Date?`） |

`sha256` を固定長にするのは、長さが常に 32 バイトであり前置きが冗長なためです。他の `Data` は長さ前置きを維持します。

### 4.4 `RemoteConfigState`（`schemaVersion` 1）

| 順 | フィールド | 型 |
| --- | --- | --- |
| 1 | `highestAcceptedVersion` | `Int64` |
| 2 | `acceptedPayloadDigest` | 32 バイト固定長 |
| 3 | `lastKnownGood` | `RemoteConfigEnvelope` |

`RemoteConfigEnvelope` の順は `schemaVersion`（`Int32`）→ `configVersion`（`Int64`）→ `issuedAt` → `expiresAt` → `payload` です。

`RemoteConfig` / `UpdateConfig` / `AppVersion` / `KillSwitches` の型宣言は [アーキテクチャ設計](architecture.md) の 10.2 が正本です。ここではその符号化順だけを固定します。**フィールドを追加する場合は末尾へ足し、`schemaVersion` を上げます。**

| 型 | 順 |
| --- | --- |
| `RemoteConfig` | 上の宣言順（`freeMonthlyExportLimit` から `killSwitches` まで） |
| `UpdateConfig` | `minimumSupportedVersion` → `recommendedVersion` → `appStoreID` |
| `AppVersion` | `major` → `minor` → `patch` |
| `KillSwitches` | `disableBatchProcessing` → `disableCustomStampImport` → `disableDiagnosticsUpload` |
| `enabledStampPacks` | unordered。各要素を UTF-8 で符号化しバイト順にソート |

---

## 5. `contentFingerprint` とプロジェクト設定ハッシュ

**署名用エンコーダと共用しません。** 用途が違えばスキーマ変更のタイミングも違い、片方の変更がもう片方の署名を壊します。

### 5.1 `contentFingerprint`

**ファイル全体の SHA-256 だけを入力にします。** 型宣言は [アーキテクチャ設計](architecture.md) の 6.6 が正本です。

```
contentFingerprint = SHA-256( "content-fingerprint-v2" || fullFileBytes )
```

| 項目 | 規則 |
| --- | --- |
| ドメイン分離子 | `"content-fingerprint-v2"` の UTF-8 バイト列を先頭へ置く |
| 入力 | **ファイルの全バイト**（ストリームで逐次投入する） |
| 出力 | **32 バイト固定**。文字列化しない |
| 計算時点 | 物質化の直後、インポート Saga の中（[画像処理](image-pipeline.md)） |
| 対象 | **取り込みファイル**（ピッカーが返した実データ）。正規化後の派生画像ではない |
| 読み取り | `FileHandle` からのチャンク読み（1MB 程度）。ファイル全体をメモリへ載せない |

**ファイルサイズと撮影日時を別途混ぜません。** どちらも全バイトに含まれているため識別能力が増えず、**EXIF パーサの差だけで同一ファイルの fingerprint が変わる**経路を作ります。

**ドメイン分離子を先頭へ置くのは、他のハッシュ用途とバイト列が衝突しないようにするためです。** スキーマを変える場合はこの文字列を `-v3` へ上げます。

##### 部分ハッシュを採らない

先頭・末尾の 64KB だけを入力にすると、**中央部分だけが異なる 2 枚の写真が同一素材と判定されます。** 同じカメラの連写では先頭の EXIF ブロックと末尾のパディングが一致しやすく、ファイルサイズも近くなるため、**無料枠を回避する経路として現実的な難易度になります。**

##### `StampAssetHash`

| 項目 | 規約 |
| --- | --- |
| 対象 | **最終保存バイト列**（縮小・変換したあとの実体） |
| アルゴリズム | SHA-256 |
| 計算時点 | `ManagedFileStore` へ書く直前 |
| 使う箇所 | `StampSource.custom` / `StampAsset` の主キー / `CustomStamp.assetHash` / `ProjectStampAsset.assetHash` |

**この 4 か所で同じ型を共用します。** 片方だけ `String` にすると、正準化での表現が揺れます。

入力ファイルそのもののバイト列だと、同じ画像を PNG と HEIC で取り込むと別実体になります。正規化済みピクセルだと、デコードの実装差で値が揺れます。**保存バイト列が、実際にディスク上にある唯一の表現です。**

### 5.1.1 EXIF 撮影日時の解釈

**`DateTimeOriginal` だけでは UTC を決められません。** EXIF は日時・小数秒・UTC オフセットを別フィールドに持ちます。

| フィールド | 用途 |
| --- | --- |
| `DateTimeOriginal` | ローカル日時（`YYYY:MM:DD HH:MM:SS`） |
| `SubSecTimeOriginal` | 小数秒 |
| `OffsetTimeOriginal` | UTC オフセット（`+09:00` など） |

**UTC への変換に必要なのは `DateTimeOriginal` と `OffsetTimeOriginal` の 2 つです。** `SubSecTimeOriginal` は精度を上げるだけで、無くても変換できます。

| 状況 | `utcMillis` |
| --- | --- |
| `DateTimeOriginal` ＋ `OffsetTimeOriginal` ＋ `SubSecTimeOriginal` | **ミリ秒精度で変換する** |
| `DateTimeOriginal` ＋ `OffsetTimeOriginal`（小数秒なし） | **秒精度で変換する**（小数秒は 0 とみなす） |
| `OffsetTimeOriginal` が無い | **`nil`。** 端末の現在タイムゾーンを使わない |
| `DateTimeOriginal` が無い | **`nil`** |

3 つのローカル表記フィールドは、`utcMillis` の可否にかかわらず取得できたものをそのまま `OriginalCaptureMetadata` へ保持します。

| 用途 | 扱い |
| --- | --- |
| `contentFingerprint` | **時刻を含めない**（5.1 で入力から外れている） |
| 写真ライブラリ保存 | `PHAsset.creationDate` を優先し、無ければ `utcMillis`、それも無ければ `creationDate` を設定しない |
| 出力 EXIF | **元のローカル日時とオフセットをそのまま保持する**（保持設定が ON の場合） |

**端末のタイムゾーンを補完に使いません。** 同じ写真を別の場所で開いたときに違う値になり、`suggestedCreationDate` が旅行のたびにずれます。

**出力 EXIF ではローカル日時を再構築しません。** 元の `DateTimeOriginal` と `OffsetTimeOriginal` をそのまま書き戻せば、変換の往復による誤差が生じません。

### 5.2 設定ハッシュ（2 種類）

**用途の異なる 2 つのハッシュを分けます。** 1 つにまとめると、匿名化結果に影響しない設定を変えただけで書き出しが不能になります。型宣言は [アーキテクチャ設計](architecture.md) の 6.6 が正本です。

| ハッシュ | 用途 | 含める範囲 |
| --- | --- | --- |
| `ProjectSettingsHash` | 「変更せず再書き出し」の権限判定（[アーキテクチャ設計](architecture.md) の 6.2） | **出力へ影響する全設定**（圧縮品質・メタデータ設定を含む） |
| `PreviewRenderHash` | 書き出し前のプレビュー確認の一致（[書き出し Saga](export-saga.md) の 1.1） | **見た目に影響する値だけ**（圧縮品質・メタデータ設定を含まない） |

**`PreviewConfirmation` は `PreviewRenderHash` を使います。** レビュー状態の規則（[アーキテクチャ設計](architecture.md) の 6.5）は、位置情報削除・撮影日時保持・圧縮品質の変更で確認状態を維持します。両方に `ProjectSettingsHash` を使うと、`reviewed` が維持されているのに確認の一致だけが崩れ、**書き出せなくなります。**

##### `renderRevision`

**`PreviewRenderHash` には `renderRevision` を含めます。**

| 対象 | 増やす契機 |
| --- | --- |
| レンダラーの実装変更（丸め、合成順、フィルタのパラメータ） | アプリの更新で見た目が変わったとき |
| 組み込みスタンプの図案変更 | 同じ `code` の描画結果を変えたとき |

**`StampSource.builtIn` は `code` しか持たないため、同じ `code` の画像を更新すると見た目が変わってもハッシュが変わりません。** `renderRevision` を混ぜることで、更新後の初回起動時に確認をやり直させます。

`renderRevision` はアプリにハードコードした `UInt32` で、**リモート設定から変更できません。**

##### `PreviewConfirmation` は永続化しない

**確認状態は再起動をまたいで保持しません。** `PreviewConfirmation` はセッション内の値とし、アプリを再起動したら必ず再確認を求めます。

保持しない理由は 2 つです。

- 再起動後に画面へ表示されているのは新しく描き直したプレビューであり、**利用者が「確認した」ものと同一である保証を型で作れません**
- 保持すれば `renderRevision` の管理だけでは足りず、OS のバージョン差による描画変化まで追う必要が出ます

バッチの `overviewConfirmed` も同様です。**再起動後は一覧の確認からやり直します。**

##### `ProjectSettingsHash` に含めるフィールドと順序（`schemaVersion` 1）

| 順 | フィールド | 型 |
| --- | --- | --- |
| 1 | `sourceCrop` | `NormalizedRect`（`left` → `top` → `rightExclusive` → `bottomExclusive`。各 `Double`） |
| 2 | `scaleMode` | `SourceScaleMode`（`fit = 1` / `fill = 2`） |
| 3 | `background` | `BackgroundSpec`（下記） |
| 4 | `regions` | **ordered**。要素数を前置きし、各要素を下記の順で書く |
| 5 | `outputAspect` | `OutputAspect`（`original = 1` / `square = 2` / `fourFive = 3` / `nineSixteen = 4`） |
| 6 | `outputFormat` | `ImageFormat`（`jpeg = 1` / `heic = 2` / `png = 3`） |
| 7 | `compressionQuality` | `Double` |
| 8 | `metadataPolicy` | `MetadataPolicy`（下記） |

`RenderRegionSpec`（4 の各要素）の順です。

| 順 | フィールド |
| --- | --- |
| 1 | `bounds`（`NormalizedRect`） |
| 2 | `rotationDegrees`（`Double`） |
| 3 | `shape`（`MaskShape`。`ellipse = 1` / `circle = 2` / `rectangle = 3` / `rounded = 4` ＋ `cornerRatio: Double`） |
| 4 | `featherRatio`（`Double`） |
| 5 | `origin`（`RegionOrigin`。`auto = 1` / `manual = 2`） |
| 6 | `op`（`RenderOpSpec`。下記） |

`RenderOpSpec` の case 番号と連想値です。

| case | 番号 | 連想値の順 |
| --- | --- | --- |
| `mosaic` | 1 | `cellRatio`（`Double`） |
| `blur` | 2 | `sigmaRatio`（`Double`） |
| `solid` | 3 | `color`（`UInt32`）→ `opacity`（`Double`） |
| `stamp` | 4 | `source` → `opacity`（`Double`） |

`StampSource` は `builtIn = 1` ＋ `code`（`String`）、`custom = 2` ＋ **`StampAsset` の内容ハッシュ**（32 バイト固定長）です。**DB の採番 ID を使いません。**

`BackgroundSpec` は `none = 1` / `blur = 2` ＋ `sigmaRatio`（`Double`）/ `solid = 3` ＋ `color`（`UInt32`）です。

`MetadataPolicy` は `removeLocation` → `removeDeviceInfo` → `removeSoftwareInfo` → `keepCaptureDate` の 4 つの `Bool` です。

##### `PreviewRenderHash` に含めるフィールドと順序（`schemaVersion` 1）

| 順 | フィールド |
| --- | --- |
| 1 | `renderRevision`（`UInt32`。上記） |
| 2 | `sourceCrop` |
| 3 | `scaleMode` |
| 4 | `background` |
| 5 | `regions`（ordered。`ProjectSettingsHash` と同じ要素順） |
| 6 | `outputAspect` |

**`ProjectSettingsHash` の 1〜5 から `outputFormat` / `compressionQuality` / `metadataPolicy` を除き、先頭に `renderRevision` を足したものです。**

除いた 3 つはいずれも見た目の確認をやり直す必要がありません。圧縮品質は厳密には画素が変わりますが、**確認の目的は匿名化の妥当性であり画質ではありません**（[アーキテクチャ設計](architecture.md) の 6.5）。

##### 含めないフィールド

出力へ影響しない値は含めません。**含めると、名前を変えただけで「変更した」と判定されます。** 両方のハッシュに共通です。

- プロジェクト名、作成日時、更新日時、お気に入りフラグ
- `DetectionStatus` / `ReviewStatus` / `ReviewDecision` / `overviewConfirmed`
- `detectionRevision` / `projectRevision`（`ExportInputSnapshot` が別に持つ）
- サムネイルの `ManagedFileRef`、`ProjectSourceLocator`
- DB の自動採番 ID

##### 規則

| 要因 | 規則 |
| --- | --- |
| `Map` の反復順 | キーの辞書順でソートしてから書く |
| 浮動小数 | **IEEE 754 の 64 ビット `Double.bitPattern`**。`Float` へ丸めない。`-0.0` は `+0.0` へ |
| 欠損値 | 長さ 0 のフィールドとして明示する |
| `regions` | ordered。順序を保持する |
| フィールド追加 | **末尾のみ。** 出力へ影響する設定を追加したら必ずここへ加え、`schemaVersion` を上げる |

**`Float`（32 ビット）へ丸めません。** `0.1500000000000000` と `0.1500000059604645` が同じハッシュになり、**設定を変えたのに無料の再書き出しとして通します。**

##### 最終式

**ドメイン分離子を先頭へ置きます。** 2 つのハッシュは入力の一部が共通であり、分離子が無ければ「`PreviewRenderHash` の入力とバイト単位で一致する `ProjectSettingsHash` の入力」を構成できます。

```
ProjectSettingsHash =
  SHA-256( "project-settings-v1" || canonicalProjectSettingsBytes )

PreviewRenderHash =
  SHA-256( "preview-render-v1" || canonicalPreviewRenderBytes )
```

| 項目 | 規則 |
| --- | --- |
| ドメイン分離子 | 上記文字列の UTF-8 バイト列。長さ前置きしない |
| `canonical…Bytes` | 上表のフィールドを 2 章の符号化規則で順に連結したもの |
| 先頭の `payloadType` / `schemaVersion` | **付けない。** これらは署名対象 payload の規約であり、ハッシュ入力ではない |
| 出力 | **32 バイト固定** |
| スキーマ変更 | 分離子を `-v2` へ上げる |

**`contentFingerprint` と同じ式ではありません。** あちらの入力はファイルの全バイトであり、長さ前置きも構造化された符号化もありません。**「同じ」と書くと、実装がどちらかの規則をもう一方へ持ち込みます。**

各 `schemaVersion` について、既知の `RenderSpec` と `ExportSetting` から生成したゴールデンバイト列を、**2 種類のハッシュそれぞれについて**テストへ埋め込みます。

---

## 6. ゴールデンテスト

各 `schemaVersion` について、固定の canonical bytes と HMAC 値をテストへ埋め込みます。**リファクタリングで正準形が変わると既存利用者の台帳がすべて `integrityFailure` になり、単体テストで気づけなければリリース後に発覚します。**

検証項目は [テスト計画](test-plan.md) の 2.7 にあります。
