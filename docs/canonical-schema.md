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
| `lockedUntilTrustedMonthAfter` | 2 | `YearMonth` |
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
| 10 | `lastTrustedMonth` | `YearMonth?` |
| 11 | `trialIntegrityLocked` | `Bool` |

要素型のフィールド順です。

| 型 | 順 |
| --- | --- |
| `YearMonth` | `year`（`Int32`）→ `month`（`Int32`） |
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

| 項目 | 規則 |
| --- | --- |
| アルゴリズム | SHA-256 |
| 整数のバイト順 | ビッグエンディアン |
| 撮影日時 | UTC epoch milliseconds の `Int64`。取得元は **EXIF の `DateTimeOriginal` のみ** |

```
schemaVersion : UInt32                // 現行 1
fileSize      : UInt32(8)  + Int64
headChunk     : UInt32(n)  + bytes    // 先頭 min(65536, fileSize) バイト
tailChunk     : UInt32(n)  + bytes    // 末尾 min(65536, fileSize) バイト
capturedAt    : UInt32(8)  + Int64    // 無ければ UInt32(0) のみ
```

長さを前置きするのは、単純連結だと末尾チャンクの終わりと日時の始まりを区別できず、異なる入力が同じバイト列になりうるためです。

**64KB 未満のファイルでは重なりを許容し、両方ともファイル全体を書きます。** 「重複を除く」規則を入れると境界で取り違えます。

### 5.2 プロジェクト設定ハッシュ

アルゴリズムと形式は `contentFingerprint` と同じ（SHA-256、長さ前置き、`schemaVersion` 付き）です。

| 要因 | 規則 |
| --- | --- |
| `Map` の反復順 | キーの辞書順でソートしてから書く |
| 浮動小数 | **IEEE 754 の 64 ビット `Double.bitPattern`**。`Float` へ丸めない |
| DB の自動採番 ID | **含めない**（アプリ更新やデータ移行で変わる） |
| スタンプの参照 | DB ID ではなく `StampAsset` の内容ハッシュ |
| 欠損値 | 長さ 0 のフィールドとして明示する |
| `RenderSpec.regions` | ordered。順序を保持する |

**`Float`（32 ビット）へ丸めません。** `0.1500000000000000` と `0.1500000059604645` が同じハッシュになり、**設定を変えたのに無料の再書き出しとして通します。**

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
