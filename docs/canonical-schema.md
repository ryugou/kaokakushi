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
| `providerAssetKeyHash` のソルト | `source-provider-key-v1` |

**署名とソルトを分けるのは、性質が違うからです。** ソルトは値の秘匿が目的、署名鍵は完全性の保証が目的であり、同じ鍵を使うと片方の運用（ローテーション等）がもう片方へ波及します。

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
| unordered | `consumedExportIDs`、`sourceRecords`、`grants`、`trialEntries`、`trialReservations`、`sourceLeases`、`SourceRecord.aliases`、`RemoteConfig.enabledStampPacks` |
| ordered | `RenderSpec.regions`、`ReviewIssueID.affectedFaceTrackIDs` |

`affectedFaceTrackIDs` は「辞書順にソート済み」として構築されますが、それは**構築時の規則**であり、正準化がソートするのではありません。順序は値の一部です。

**分類は型に付けます。** unordered な集合は Swift の `Set` として宣言し、`Array` はすべて ordered として扱うのが原則です。`grants` などが `Array` なのは要素が `Hashable` でないためであり、この場合は**エンコーダ側に unordered として明示的に登録します。**

### 2.2 識別子

| 型 | 符号化 |
| --- | --- |
| `ProjectID` / `BatchID` / `ExportID` / `RegionID` / `SourceID` / `ManagedFileID` | `UUID` の 16 バイト |
| `FaceTrackID` | `String`（長さ前置き UTF-8） |
| `ManagedFileRef` | `kind`（`UInt32`）→ `fileID`（16 バイト） |

---

## 3. `enum` の固定番号

**`case` の宣言順に依存させません。** `case` を追加した時点で既存の全署名が変わるためです。

### `SourceAlias`

| case | 番号 | 連想値 |
| --- | --- | --- |
| `provider` | 1 | `String` |
| `content` | 2 | `String` |

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
| 8 | `lastObservedAt` | `Date` |
| 9 | `monthlyIntegrityLock` | `MonthlyIntegrityLock` |
| 10 | `lastTrustedMonth` | `TrustedUTCMonth?` |
| 11 | `trialIntegrityLocked` | `Bool` |

要素型のフィールド順です。

| 型 | 順 |
| --- | --- |
| `YearMonth` / `TrustedUTCMonth` | `year`（`Int32`）→ `month`（`Int32`） |
| `SourceRecord` | `sourceID` → `aliases`（unordered） |
| `GrantEntry` | `sourceID` → `firstSuccessAt` → `ownerExportID` |
| `TrialEntry` | `sourceID` → `ownerExportID` |
| `TrialReservation` | `sourceID` → `exportID` |
| `SourceLease` | `sourceID` → `exportID` |

### 4.2 `SubscriptionState`（`schemaVersion` 1）

**保存する型と署名する型を一致させます。**

```swift
/// ProtectedBlobStore へ保存する購入状態キャッシュ
struct SubscriptionState: Sendable, Equatable {
    let entitlement: Entitlement
    let willRenew: Bool
    let fetchedAt: Date        // RevenueCat から取得に成功した時刻
}

struct Entitlement: Sendable, Equatable {
    let plan: Plan
    let status: PlanStatus
    let expiresAt: Date?
    let lastVerifiedAt: Date
}
```

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
| 5 | `outputFile` | `ManagedFileRef` |
| 6 | `authorization` | `ExportAuthorization` |
| 7 | `verifiedOutput` | `VerifiedOutput?` |
| 8 | `finalizedAt` | `Date?` |
| 9 | `finalizedPeriod` | `YearMonth?` |
| 10 | `intent` | `AccountingIntent?` |
| 11 | `applied` | `AccountingApplied?` |
| 12 | `state` | `ExportCommitState` |

ネストした型のフィールド順です。

| 型 | 順 |
| --- | --- |
| `ExportAuthorization` | `entitlementSnapshot`（`Entitlement`）→ `accountingMode` → `authorizedAt` → `authorizedGrant` |
| `AuthorizedGrant` | `sourceID` → `firstSuccessAt` |
| `VerifiedOutput` | `byteSize`（`Int64`）→ `sha256`（32 バイト固定長。長さ前置きしない） |
| `AccountingIntent` | `consumeExportID` → `grantAction` → `trialSourceIDToEnsure` |
| `AccountingApplied` | `consumedInserted` → `grantInsertedByThisExport` → `trialInsertedByThisExport` |

`sha256` を固定長にするのは、長さが常に 32 バイトであり前置きが冗長なためです。他の `Data` は長さ前置きを維持します。

### 4.4 `RemoteConfigState`（`schemaVersion` 1）

| 順 | フィールド | 型 |
| --- | --- | --- |
| 1 | `highestAcceptedVersion` | `Int64` |
| 2 | `acceptedPayloadDigest` | 32 バイト固定長 |
| 3 | `lastKnownGood` | `RemoteConfigEnvelope` |

`RemoteConfigEnvelope` の順は `schemaVersion`（`Int32`）→ `configVersion`（`Int64`）→ `issuedAt` → `expiresAt` → `payload` です。

`RemoteConfig` の正式な型とフィールド順を固定します。**フィールドを追加する場合は末尾へ足し、`schemaVersion` を上げます。**

```swift
struct RemoteConfig: Sendable, Decodable, Equatable {
    let freeMonthlyExportLimit: Int32
    let proBatchSizeLimit: Int32
    let trialBatchSizeLimit: Int32
    let trialCreditCount: Int32
    let batchConcurrencyLimit: Int32
    let lowConfidenceThreshold: Double
    let extremePoseYawDegrees: Double
    let extremePosePitchDegrees: Double
    let historyStorageLimitBytes: Int64
    let customStampLimit: Int32
    let customStampMaxEdgePixels: Int32
    let enabledStampPacks: Set<String>
    let interstitialAdExportInterval: Int32
    let update: UpdateConfig
    let killSwitches: KillSwitches
}

struct UpdateConfig: Sendable, Decodable, Equatable {
    let minimumSupportedVersion: AppVersion
    let recommendedVersion: AppVersion
    let appStoreID: String
}

struct AppVersion: Sendable, Comparable, Decodable {
    let major: Int32
    let minor: Int32
    let patch: Int32
}

/// 障害時に個別機能を止めるフラグ。安全性の中核に対応するキーは持たない
struct KillSwitches: Sendable, Decodable, Equatable {
    let disableBatchProcessing: Bool
    let disableCustomStampImport: Bool
    let disableDiagnosticsUpload: Bool
}
```

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

**ファイル全体を SHA-256 へ入れます。部分ハッシュにしません。**

| 項目 | 規則 |
| --- | --- |
| アルゴリズム | **SHA-256** |
| 入力 | **ファイルの全バイト**（ストリームで逐次投入する） |
| 整数のバイト順 | ビッグエンディアン |
| 撮影日時 | UTC epoch milliseconds の `Int64`。取得元は **EXIF の `DateTimeOriginal` のみ** |

```
schemaVersion : UInt32                // 現行 2
fileSize      : UInt32(8)  + Int64
contentDigest : UInt32(32) + bytes    // ファイル全体の SHA-256（32 バイト）
capturedAt    : UInt32(8)  + Int64    // 無ければ UInt32(0) のみ
```

長さを前置きするのは、単純連結だとフィールド境界を区別できず、異なる入力が同じバイト列になりうるためです。

##### 部分ハッシュを採らない

先頭 64KB と末尾 64KB だけを入力にすると、**中央部分だけが異なる 2 枚の写真が同一素材と判定されます。** 判定が「同一素材なのに二重消費」ではなく「別素材なのに無料で再書き出しできる」方向へ倒れるため、当初は許容していました。

しかしこれは**意図的に作れる衝突**です。同じカメラで撮った 2 枚は、先頭の EXIF ブロックと末尾のパディングが一致しやすく、ファイルサイズも近くなります。撮影日時が同じ連写であれば `capturedAt` も一致します。**無料枠を回避する経路として現実的な難易度になります。**

全体ハッシュの費用は、48 メガピクセルの HEIC でおおむね数 MB から 20MB 程度の読み取りです。**ストリームで投入すればメモリは一定に保てます。** 選択直後に 1 回だけ計算し、`contentFingerprint` として保持します。

| 項目 | 規約 |
| --- | --- |
| 読み取り | `FileHandle` からのチャンク読み（1MB 程度）で `SHA256` へ逐次投入する |
| 計算時点 | 物質化の直後、インポート Saga の中（[画像処理](image-pipeline.md)） |
| 対象 | **物質化したファイルの全バイト**。表示用の派生画像ではない |
| メモリ | チャンクサイズ分のみ。ファイル全体を載せない |

`schemaVersion` を 2 とし、旧形式（`1`）のデコーダは残しません。**v1 リリース前の変更であり、移行対象となる既存データが存在しません。**

### 5.2 プロジェクト設定ハッシュ（`ProjectSettingsHash`）

**このハッシュは権限制御に使います。** 有料スタンプを含むプロジェクトを Free で「変更せず再書き出し」できるかの判定、および書き出し前のプレビュー確認の一致判定（[書き出し Saga](export-saga.md) の 1.1）がこれに依存します。**含めるフィールドの取りこぼしは、そのまま権限の迂回になります。**

アルゴリズムと形式は `contentFingerprint` と同じ（SHA-256、長さ前置き、`schemaVersion` 付き）です。

##### 含めるフィールドと順序（`schemaVersion` 1）

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

##### 含めないフィールド

出力へ影響しない値は含めません。**含めると、名前を変えただけで「変更した」と判定されます。**

- プロジェクト名、作成日時、更新日時、お気に入りフラグ
- `DetectionStatus` / `ReviewStatus` / `ReviewDecision` / `overviewConfirmed`
- `detectionRevision` / `projectRevision`（これらは `ExportInputSnapshot` が別に持つ）
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

各 `schemaVersion` について、既知の `RenderSpec` と `ExportSetting` から生成したゴールデンバイト列をテストへ埋め込みます。

### 5.3 `StampAsset` の内容ハッシュ

| 項目 | 規約 |
| --- | --- |
| 対象 | **最終保存バイト列**（縮小・変換したあとの実体） |
| アルゴリズム | SHA-256 |
| 計算時点 | `ManagedFileStore` へ書く直前 |

入力ファイルそのもののバイト列だと、同じ画像を PNG と HEIC で取り込むと別実体になります。正規化済みピクセルだと、デコードの実装差で値が揺れます。**保存バイト列が、実際にディスク上にある唯一の表現です。**

---

## 6. ゴールデンテスト

各 `schemaVersion` について、固定の canonical bytes と HMAC 値をテストへ埋め込みます。**リファクタリングで正準形が変わると既存利用者の台帳がすべて `integrityFailure` になり、単体テストで気づけなければリリース後に発覚します。**

検証項目は [テスト計画](test-plan.md) の 2.7 にあります。
