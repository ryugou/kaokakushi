# ハッシュと正準符号化

| 項目 | 内容 |
| --- | --- |
| 目的 | 機能基盤として使うハッシュ（素材同一性・設定変更検出）の入力バイト表現を一意に定める |
| 読者 | `Persistence` の実装者、ハッシュまわりのテスト作成者 |
| 正本の範囲 | 符号化規則、ハッシュ入力に使う `enum` の固定番号、`contentFingerprint` / 設定ハッシュ 2 種 / `StampAssetHash` / `providerAssetKeyHash` の定義 |
| 関連 | [アーキテクチャ設計](architecture.md)、[画像処理](image-pipeline.md)（`RenderSpec` の型宣言）、[書き出し Saga](export-saga.md)（設定ハッシュの利用箇所）、[テスト計画](test-plan.md)（ゴールデンテスト） |

**この文書がハッシュ入力バイト表現の唯一の正本です。** 他の文書は型の意味を定義し、バイト表現には言及しません。

---

## 1. 原則

`JSONEncoder` や binary plist を正準形として使いません。集合と配列の順序、`Date` の表現、辞書のキー順が実装とバージョンに依存し、**同じ意味の値から別のハッシュが出れば、同一素材の判定や「変更せず再書き出し」の判定を誤ります。**

対象は `contentFingerprint` / `StampAssetHash` / `ProjectSettingsHash` / `PreviewRenderHash` / `providerAssetKeyHash` の 5 種（5 章）。基本型の符号化規則は 2 章です。

**スキーマを変える場合は、各ハッシュのドメイン分離子（`-v2` 等）を上げます。** 番号管理の仕組みは持たず、分離子の文字列そのものがバージョンを表します（5 章）。

---

## 2. 基本型の符号化

| 型 | 符号化 |
| --- | --- |
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

**順序に意味を持つ配列は、ソートせず元の順序を保持します。** `ProjectSettingsHash` / `PreviewRenderHash` の `regions`（`RenderRegionSpec` の配列）が対象で、一律にソートすると `RenderSpec` の描画順を変え、正準化が意味を持つデータを壊します。

**unordered な集合に `UUID` を含む場合は、次の規則で辞書順に比較してからソートします。**

> `UUID` の 16 バイトを**符号なしバイト列として辞書順**に比較する。

大文字小文字やハイフンの有無は順序へ影響しません。

### 2.2 識別子

| 型 | 符号化 |
| --- | --- |
| `ProjectID` / `BatchID` / `ExportID` / `RegionID` / `SourceID` / `ManagedFileID` | `UUID` の 16 バイト |
| `ContentFingerprint` / `StampAssetHash` | **32 バイト固定長**（長さ前置きしない） |
| `FaceTrackID` | `UUID` の 16 バイト |
| `ManagedFileRef` および種別つき参照（`OutputFileRef` ほか） | `kind`（`UInt32`）→ `fileID`（16 バイト） |

---

## 5. `contentFingerprint` とプロジェクト設定ハッシュ

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

**ファイルサイズと撮影日時を別途混ぜず、ドメイン分離子を先頭へ置きます。** 前者は全バイトに含まれるため識別能力が増えず EXIF パーサの差だけで fingerprint が変わる経路を作り、後者は他のハッシュ用途とのバイト列衝突を避けるためです（スキーマ変更時は `-v3` へ上げる）。

##### 部分ハッシュを採らない

先頭・末尾の 64KB だけを入力にすると、**中央部分だけが異なる 2 枚の写真が同一素材と判定されます。** 同じカメラの連写では先頭の EXIF ブロックと末尾のパディングが一致しやすく、ファイルサイズも近くなるため、**無料枠を回避する経路として現実的な難易度になります。**

##### `StampAssetHash`

| 項目 | 規約 |
| --- | --- |
| 対象 | **最終保存バイト列**（縮小・変換したあとの実体） |
| アルゴリズム | SHA-256 |
| 計算時点 | `ManagedFileStore` へ書く直前 |
| 使う箇所 | `StampSource.custom` / `StampAsset` の主キー / `CustomStamp.assetHash` / `ProjectStampAsset.assetHash` |

**この 4 か所で同じ型を共用し、対象は保存バイト列とします。** 片方だけ `String` にすると正準化の表現が揺れ、入力ファイルのバイト列では同じ画像の PNG/HEIC 取り込みで別実体になり、正規化済みピクセルではデコード実装差で値が揺れるため、ディスク上の唯一の表現である保存バイト列を採ります。

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

**端末のタイムゾーンを補完に使わず、出力 EXIF でもローカル日時を再構築しません。** 前者は同じ写真を別の場所で開くと値がずれ `suggestedCreationDate` が旅行のたびに変わる問題を避けるためで、後者は元の `DateTimeOriginal` と `OffsetTimeOriginal` をそのまま書き戻せば往復誤差が生じないためです。

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

**`StampSource.builtIn` は `code` しか持たないため、同じ `code` の画像更新では見た目が変わってもハッシュが変わらず、アプリにハードコードした `UInt32`（リモート設定から変更不可）の `renderRevision` を混ぜることで更新後の初回起動時に確認をやり直させます。**

##### `PreviewConfirmation` は永続化しない

**確認状態は再起動をまたいで保持しません。** `PreviewConfirmation` はセッション内の値とし、アプリを再起動したら必ず再確認を求めます。

保持しない理由は 2 つです。

- 再起動後に画面へ表示されているのは新しく描き直したプレビューであり、**利用者が「確認した」ものと同一である保証を型で作れません**
- 保持すれば `renderRevision` の管理だけでは足りず、OS のバージョン差による描画変化まで追う必要が出ます

バッチの `overviewConfirmed` も同様です。**再起動後は一覧の確認からやり直します。**

##### `ProjectSettingsHash` に含めるフィールドと順序（`project-settings-v1`）

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

##### `PreviewRenderHash` に含めるフィールドと順序（`preview-render-v1`）

| 順 | フィールド |
| --- | --- |
| 1 | `renderRevision`（`UInt32`。上記） |
| 2 | `sourceCrop` |
| 3 | `scaleMode` |
| 4 | `background` |
| 5 | `regions`（ordered。`ProjectSettingsHash` と同じ要素順） |
| 6 | `outputAspect` |

**`ProjectSettingsHash` の 6〜8（`outputFormat` / `compressionQuality` / `metadataPolicy`）を除き、残る 1〜5 の先頭に `renderRevision` を足したものです。**

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
| フィールド追加 | **末尾のみ。** 出力へ影響する設定を追加したら必ずここへ加え、ドメイン分離子（`-v2`）を上げる |

**32 ビット `Float` へ丸めると `0.1500000000000000` と `0.1500000059604645` が同じハッシュになり、設定を変えたのに無料の再書き出しとして通ります。**

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
| 出力 | **32 バイト固定** |
| スキーマ変更 | 分離子を `-v2` へ上げる |

**`contentFingerprint` と同じ式ではありません。** あちらの入力はファイルの全バイトであり、長さ前置きも構造化された符号化もありません。**「同じ」と書くと、実装がどちらかの規則をもう一方へ持ち込みます。**

既知の `RenderSpec` と `ExportSetting` から生成したゴールデンバイト列を、**2 種類のハッシュそれぞれについて**テストへ埋め込みます。

### 5.3 `providerAssetKeyHash`

**鍵を使わない SHA-256 で計算します。** `SourceAlias.provider` の照合に使う値だけを求めます。

```
providerAssetKeyHash = SHA-256( "source-provider-v1" || BE32(providerKind) || localIdentifier )
```

| 項目 | 規則 |
| --- | --- |
| ドメイン分離子 | `"source-provider-v1"` の UTF-8 バイト列を先頭へ置く |
| `providerKind` | 提供元を表す固定 `UInt32`（2 章の enum 符号化）。現状 `phAsset = 1` の 1 種のみ |
| `localIdentifier` | `PHAsset.localIdentifier` の UTF-8 バイト列（末尾まで。長さ前置きしない） |
| 出力形式 | **32 バイトを小文字 16 進の 64 文字へ**（`String` として `SourceAlias.provider` へ保持する） |

**`providerKind` を挟むのは、将来別の提供元を追加したとき同じ生識別子文字列でもハッシュが衝突しないようにするためです。** 16 進固定にするのは、Base64 や大文字混在を許すと同じ入力から別の alias ができるためです。

---

## 6. ゴールデンテスト

各ハッシュ（`contentFingerprint` / `StampAssetHash` / `ProjectSettingsHash` / `PreviewRenderHash` / `providerAssetKeyHash`）について、既知の入力から生成した固定バイト列と出力値をテストへ埋め込みます。符号化ロジックが意図せず変わったときに検出するためです。

検証項目は [テスト計画](test-plan.md) にあります。
