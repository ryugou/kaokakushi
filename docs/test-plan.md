# 顔かくし テスト計画

| 項目 | 内容 |
| --- | --- |
| 対象 | 顔かくし（iOS 単独） |
| 上位文書 | 顔かくし 技術スタックおよびアーキテクチャ設計 |
| 本書の範囲 | 層ごとの個別テスト項目の網羅一覧 |
| 本書の対象外 | テスト戦略そのもの（4 層への分割と各層が保証する内容は設計書 11 章が正） |

節番号の参照はすべてアーキテクチャ設計書のものです。

---

## 1. 層の割り当て

| 層 | 実行環境 | 対象 |
| --- | --- | --- |
| domain unit test | `swift test`（数秒。シミュレータ不要） | 純粋関数と状態機械 |
| application saga test | `swift test`（数十秒） | 偽ストアによる各中断点の検証 |
| adapter integration test | シミュレータ / 実機 | 実 GRDB、実 保護ファイル、実 Keychain、Vision、Core Image |
| process-death fault injection test | 実機 | 各手順の直後に強制終了し、再起動後の状態を検証 |

**各項目は、検証が成立する最も低い層へ置きます。**

---

## 2. domain unit test

純粋関数と状態機械のみ。ストレージもプロセスも関与しません。

### 2.1 クォータ・grant・トライアル（6.3）

- `QuotaPolicy`（月跨ぎ、TZ 変更、時刻巻き戻し、うるう年、月末 23:59:59 → 00:00:00、24 時間境界）
- `evaluate` が更新後の `UsageLedger` を返し、`unlimited` でも時刻更新と grant 整理が行われること
- `QuotaPolicy` と開始ゲートが `Plan` を参照せず `ResolvedCapabilities` のみを受け取ること
- `monthlyIntegrityLock` が解除条件を満たさないとき、`consumedExportIDs` が空でも `blocked(ledgerIntegrityFailure)` になること
- **端末時刻をどう変更しても `monthlyIntegrityLock` が解除されないこと。信頼できる時刻の観測だけが解除条件であること**
- `ExportGrant` が能力を問わず作成されること
- 同一素材の再書き出しで `firstSuccessAt` が更新されないこと
- 月末の初回成功から 24 時間以内なら、月をまたいでも `freeReexport` になること
- `rollPeriod` が `consumed` だけをリセットし、`grants` を月境界で捨てないこと
- 端末時刻を過去へ戻しても 24 時間の窓が延びないこと。`usageNow` が後退しないこと
- `Domain` の時間判定が `now` ではなく `usageNow` / `retentionNow` だけを受け取ること
- 未受け渡し出力の削除期限が端末時刻の変更で延びないこと
- `retentionNow` が `nil` のとき、履歴・未受け渡し出力・やり直し保証のいずれも削除されないこと
- `trialIntegrityLocked` のとき `remainingCredits` が 0 になり、トライアル画面へ進入できないこと
- `trialReservations` が残数計算に含まれること
- `batchTrial` が月間枠を消費しないこと
- 月間枠を使い切っていても、クレジットが残っていれば一括トライアルを開始できること
- 消費済みトライアル台帳に期限がなく、同じ 5 枚を繰り返し処理できること
- トライアル中のエフェクト利用範囲が、そのときの `ResolvedCapabilities` と一致すること
- `batchTrial(false)` でも `GrantAction.ensure` になること
- `freeMonthlyReexport` の `grantAction` が `preserveAuthorized` になること
- 破棄しても無料枠とトライアルクレジットが戻らないこと
- 顔 0 件の案内が `QuotaDecision` で分岐すること（6.1）

### 2.2 素材同一性（6.4）

- **`isSameSource` を直接使わず、`sourceID` で同一性を判定していること**
- **provider 一致と content 一致が別レコードを指す場合に、1 件へ統合されること**
- **統合時に最も古い `firstSuccessAt` が維持され、トライアルが消費済みへ倒れること**
- **統合時に `grants` / `trialEntries` / `trialReservations` / `sourceLeases` のすべてが勝者 `sourceID` へ書き換わること**
- **`SourceRecord` が grant / trial / reservation / lease のどれからも参照されなくなった場合だけ削除されること**
- **`paidUnlimited` の書き出し中に `SourceRecord` が GC されないこと**（`SourceLease` が効いていること）
- 台帳の不変条件 1〜7 が、保存前と署名検証直後の両方で検査されること
- `contentFingerprint` が長さ前置き・ビッグエンディアン・UTC epoch ms で計算されること
- 64KB 未満のファイルで先頭・末尾チャンクが重複しても正しく計算されること
- 撮影日時が無い場合に長さ 0 のフィールドとして扱われること
- **撮影日時の取得元が EXIF のみであり、PhotoKit 権限の有無で変わらないこと**
- ファイル更新日時を使わないこと
- `representation` が `contentFingerprint` の入力に含まれないこと
- `BatchSelectionClassifier` が alias の共有関係を推移的に閉じ、選択中の重複を畳むこと
- OS がトランスコードした写真を新規素材として数えないこと

### 2.3 レビュー状態とトリアージ（6.1 / 6.5）

- `BatchTriagePolicy`（6 つの要確認理由の各単独・複合、空集合）
- `triage` の入力が 5.1 の共通モデルだけであること。OS 固有の値に依存しないこと
- `ReviewIssue` が**発生単位**で列挙され、小さい顔が 3 人なら 3 件になること
- **`lowConfidence` が顔ごとに 1 件の `ReviewIssue` になること**
- `ReviewIssueID` が `detectionRevision` を含み、`overlappingFaces` では顔 ID が辞書順に並ぶこと
- **`ReviewIssueID` が `projectID`（`ProjectID` 型）を含み、同じ revision の別写真の `noFaceDetected` が別 ID になること**
- **`affectedFaceTrackIDs` が ID から導出され、二重に保持されないこと**
- 再検出で `detectionRevision` が増え、その写真の `ReviewIssue` / `ReviewDecision` / `Reviewed` が破棄されること
- `ReviewDecision` が `ReviewIssueID` ごとに記録され、全 `ReviewIssue` が埋まるまで `reviewed` にならないこと
- 1 人分の `ReviewIssueID` へ判断を記録しただけでは `reviewed` にならないこと
- `manualRegionAdded` が `regionID` を保持し、その領域の削除で判断が破棄されること
- `reviewRequired` かつ `unreviewed` の写真が 1 枚でも残る間は一括書き出しを開始できないこと
- `reviewed` がアプリの判断では立たないこと。検出ステータスが利用者操作で変わらないこと
- `noFaceDetected` がグループ一括対応の対象外であること
- `DetectionStatus` と `ReviewIssue` が利用者の判断で変化しないこと
- 理由別の一括対応で、その理由の `ReviewIssue` が 1 件も取りこぼされないこと
- 1 枚ずつ確認で `normal` の写真が「確認して次へ」により `reviewed` になること
- 顔の初期状態が常に加工対象であること（6.1 の不変条件）
- 背景処理の変更で `reviewed` が解除されること。メタデータ設定の変更では解除されないこと
- `requiresUserReview` の導出がモードで異なること。1 枚ずつ確認では `normal` の未確認写真も含むこと
- 確認状態の解除が変更範囲に限定されること。`hasOverride` の写真が共通設定変更で `unreviewed` にならないこと
- `overviewConfirmed` が、匿名化結果または構図に影響する変更で必ず `false` になること
- 共通設定の変更が `hasOverride` の立った写真へ波及しないこと。全上書きが確認を経ること
- 書き出しの成立条件がモードごとに異なること。1 枚ずつ確認では末尾到達と確認ボタンを求めないこと
- 確認段階から設定へ戻っても検出結果が保持されること。この経路で写真の選択を変更できないこと

### 2.4 バッチ選択と能力（6.2 / 6.5）

- トライアルの選択判定が「総枚数 5 枚」と「新規写真 ≤ 残クレジット」の 2 条件であること。残 0 枚でも消費済みの写真は選べること
- `canEnterBatch` が `canUseProBatch` / `canUseBatchTrial` / `trialIntegrityLocked` / 残数 / entry の有無から導かれること
- `canUseProBatch` / `canUseBatchTrial` が能力で判定され、`plan = pro` かつ `status = pending` が通常一括にならないこと
- 消費済みの写真だけで 6 枚選ぼうとしたとき `batch-size` が発火すること
- 50 枚超過が `batch-limit` であり、アップグレード誘導を伴わないこと
- `EntitlementResolver`（仕様 27.4 の全購入状態）
- `plan = standard` かつ `status = pending` で `singleExportAccess == .metered` になること
- `CapabilityResolution.verificationRequired` で書き出し認可が開始されず、Free 降格の表示も出ないこと
- キャッシュ `missing` かつオフラインで `verificationRequired` になること
- `canEdit` が能力で判定され、`requiredPlan` の戻り値比較で可否を決めないこと
- バッチ内の 1 枚を単体編集するとき `canEdit` に従うこと
- `requiredPlan` が設定内容から導かれ、作成時のプランに依存しないこと
- 降格後の再書き出しでも `freeReexport` が成立し、24 時間以内なら消費しないこと
- Free 範囲のプロジェクトが Free で編集・書き出しできること
- 降格後の操作可否が 6.2 の表と一致すること
- 追加スタンプとカスタムスタンプで、降格後の再書き出し可否が同一であること
- `AdFrequencyPolicy`（表示禁止条件、初回書き出し、連続表示の抑止）

### 2.5 レンダリング（5.2 / 5.4）

- 拡張率適用、`RenderSpec` 生成、`compileRenderDraft`、座標正規化
- `compileRenderDraft` が `RenderPlan` へ絶対ピクセル値のみを入れ、比率を残さないこと。**`SourcePlacement.sourceRect` と `BackgroundOp.blurFromSource.sourceRect` も `PixelRect` であること**
- `compileRenderDraft` が `sourceSize` を受け取り、元画像基準の正規化値をピクセルへ変換すること
- `bindRasterAssets` が `stampKeys` に対応する asset を 1 件でも欠けば失敗すること
- `left` / `top` が floor、`right` / `bottom` が ceil で丸められ、領域が外側へ広がること
- `RenderRegion.bounds` が出力キャンバス基準へ変換されること
- `sourceCrop` の不変条件違反が例外になり、クランプで黙って直されないこと
- `manual` の領域が `auto` より後の `order` になること
- `Domain` が `StampRasterizer` プロトコルのみを持ち、`CoreGraphics` を参照しないこと
- `StampRasterKey` に位置・回転・不透明度・形状が含まれないこと
- **`opacity = 0` / `cellSizePx < 2`（特に 1px） / `sigmaPx = 0` / 幅 0 の領域が `throw` されること**
- **`RenderOpSpec` / `RenderOp` / `RenderOpDraft` に生の `Double` が残っていないこと**
- **`NaN` や無限大の座標が `throw` されること**
- **完全に透明なカスタムスタンプ画像が取り込み時に拒否されること**
- **`isMasked == true` の顔に no-op 相当の値が渡されたとき `compileRenderDraft` が `throw` すること**
- 永続データのデコード時にも検証済み値型の `throws` 版が呼ばれること
- キーフレーム補間（v2 機能だが仕様確定のため v1 で実装・テスト）

### 2.6 設定ハッシュと正準化（6.4 / 9.1）

- 設定ハッシュが `Map` のキー順・**`Double.bitPattern`（64 ビット）**・内容ハッシュ参照で正準化され、DB ID に依存しないこと
- **`Float` へ丸めた場合に区別できなくなる 2 つの `Double` が、異なる設定ハッシュになること**
- `-0.0` が `+0.0` へ正規化されること
- プロジェクト設定ハッシュの一致判定により、Free の「変更せず再書き出し」が許可されること

### 2.7 HMAC canonical bytes のゴールデンテスト（9.1）

**各 `schemaVersion` について、固定の canonical bytes と HMAC 値をテストへ埋め込みます。**

| 検証 | 目的 |
| --- | --- |
| 既知の値から生成した canonical bytes が、期待するバイト列と一致する | 符号化の変更を検出する |
| 固定鍵で計算した HMAC が、期待する値と一致する | 署名の互換性を検出する |
| 集合の構築順を変えても同じバイト列になる | unordered の分類が正しい |
| ordered 配列の順序を変えると別のバイト列になる | ordered の分類が正しい |

対象 payload は `UsageLedger` / `SubscriptionState` / `ExportCommit` / `RemoteConfigState` の 4 種すべて。

### 2.8 更新誘導（6.7）

- `AppVersion` の比較が数値の組で行われ、`1.10.0 > 1.9.0` になること
- `CFBundleShortVersionString` のパース失敗で `.none` になり、強制更新へ倒れないこと
- `config == nil`（取得失敗）で `.none` になること
- `skippedVersion` と一致する `recommendedVersion` を再提示しないこと
- 前回提示から 24 時間未満なら `.recommended` を返さないこと。判定に `usageNow` を使うこと
- `recommendedVersion` が上がれば、スキップ済みでも再提示されること
- **`evaluateUpdate` が `appStoreID` の数字のみ形式を検証すること**

### 2.9 その他

- ストレージ必要量計算、`ExportQueue` 状態機械
- 履歴の保存期間と容量判定。24 時間のやり直し保証が容量超過時にも守られること
- `canDeleteHistoryUnit` が 8 種類の参照元すべてを見ること（7.5）
- 未保存バッチが 1 件までに制限されること
- 一括処理の開始が推定必要容量の 1.2 倍の空き容量を要求すること
- 未保存出力がある状態では、単体・一括を問わず新規加工を開始できないこと
- 完了画面の離脱確認が `generated` の残数で判定されること。一部保存済みでも出ること
- 復旧案内の枚数が `generated` の枚数であり、バッチ総枚数ではないこと
- 共有結果が `.completed` のときだけ `delivered` へ遷移すること。`.unknown` では維持されること
- リモート設定のフォールバック

---

## 3. application saga test

偽 DB・偽 `ProtectedBlobStore`・偽ファイル・偽 `ProtectedDataAvailability` を注入し、**各中断点**での挙動を検証します。実ストレージの原子性は検証しません（4 章の役割）。

### 3.1 コミット Saga（8.3 / 8.4 / 8.5）

- `ExportCommit` が各段階で中断しても、起動時に整合が回復すること
- `prepared` / `fileVerified` / `finalizing` / `accountingCommitted` / `readyToPublish` のいずれからもコミット行が最終的に消えること
- 復旧が終わるまで新しい書き出しを開始できないこと
- 手順 4 と 5 の間で中断しても、台帳更新を冪等に再適用できること
- `finalizedAt` が `finalizing` の保存時点で決まり、`fileVerified` では `nil` であること
- 中断して復旧した場合、月跨ぎの有無にかかわらず新しい `finalizedAt` で再適用されること
- **プロセスが生きたまま手順 3 と 7 の間で長時間停止した場合、手順 7-b の再確認で手順 3 から再確定されること**
- `generatedAt` / `expiresAt` / grant の起点が `finalizedAt` と一致すること
- `preserveAuthorized` を起動時復旧から適用しても、`finalizedAt` で grant が作られないこと
- 認可時の grant が会計時に期限切れでも、その 1 回は完了し、grant は再登録されないこと
- `accountingCommitted` からの復旧でファイル欠損時、実際に追加した会計要素だけが取り消されること
- 既存 grant を再利用しただけのコミットのロールバックで、その grant が削除されないこと
- 手順 4 の直後（`applied` 未保存）に落ちても、`ownerExportID` から正しくロールバックできること
- 検証済みファイルが手順 7 の完了まで UI・`MediaSaver`・`SharePresenter` へ公開されないこと
- `fileVerified` で落ちた場合、`verifiedOutput` と実体を突き合わせて復旧できること
- 手順 7 のサイズ・SHA-256 が `verifiedOutput` からのコピーであり、再計算でないこと
- 0 バイト・破損・SHA 不一致の出力ファイルで `readyToPublish` のコミット行が削除されないこと
- 手順 6 の失敗時、ロールバックが台帳 → `OutputRecord` → ファイル → コミット → ゲートの順で実行されること
- ロールバック手順 1 が失敗した場合、コミットとファイルが残り復旧エラーになること
- コミット行削除後にファイルを失っても、月間枠・grant・トライアルが戻らないこと
- コミット削除済みの Export A のファイル欠損で、同一素材を再書き出しした Export B の grant が消えないこと
- 生成完了後の異常終了では消費が戻らないこと
- 消費確定が手順 7 であり、保存や共有の回数に影響されないこと
- **`unavailable` のまま復旧を開始した場合に待機へ入ること**（7.4）

### 3.2 認可とゲート（8.1）

- 書き出し開始前に `blocked` なら `ExportCommit` を作らないこと
- 開始後に契約が失効しても、その書き出しは開始時の権限で完了すること
- 失効時、`prepared` 以降の写真は完了し `waiting` の写真は開始しないこと
- **書き出しが全体で同時に 1 件までに制限されること**（`withExclusivePermit`）
- **`withExclusivePermit` の内側で、alias 解決から認可までが 1 回の `transact` で完了すること**
- **ゲートがコミット行の削除またはロールバック完了まで保持されること**
- **`prepared` の保存に失敗したとき、補償トランザクションが予約・lease・未参照 `SourceRecord` を削除しゲートを解放すること**
- 並列書き出し時も `UsageLedgerStore.transact` が直列化され、更新が失われないこと
- クォータ消費が `exportID`、トライアル消費が素材の同一性で冪等であること
- 待機中にキャンセルされた waiter がキューから除去され、permit を取得しないこと
- 同じ continuation が 2 回 resume されないこと
- `CancellationError` が Sentry へ送られず、キュー項目が `canceled` になること
- 実行開始の直前に最新台帳で選択を再検証し、分類が変わっていれば開始しないこと（6.5）

### 3.3 署名不正コミット（8.6）

- `ExportCommit` の署名検証失敗が復旧エラーになり、自動破棄されないこと
- 復旧エラーを「破棄して続ける」で解除でき、孤立 lease が 1 件なら予約が `TrialEntry` へ確定した上でコミットが削除されること
- **孤立 lease が 0 件のとき（`accountingCommitted` / `readyToPublish` で壊れた場合）、台帳を変更せずコミット行だけが削除されること**
- 孤立 lease が 2 件以上なら復旧エラーを維持し、台帳へ触れないこと
- **署名不正行の `outputFile` / `projectID` が参照されず、他の正常な出力と履歴が削除されないこと**
- **署名不正行がある間、孤児予約と孤児 lease の自動回収が保留されること**

### 3.4 出力再生成（8.7）

- **`restoreOutput` が `UsageLedger` を 1 バイトも変更せず、`generatedAt` / `expiresAt` を延長せず、`ExportRecord` を追加しないこと**
- **`originalExpiresAt` が過去なら `restoreOutput` を実行せず、`OutputRecord` を削除すること**
- `restoreOutput` がキューの成功件数を増やさないこと

### 3.5 トライアル予約（6.3）

- 残 1 枚で異なる素材の 2 件が並行認可されても、両方が `batchTrial(true)` にならないこと
- 予約が手順 −2 で作られ、手順 4 の台帳トランザクション内で `trialEntries` へ移ること
- 手順 0 の `prepared` 保存失敗で、補償トランザクションが**予約・`SourceLease`・未参照 `SourceRecord`** をすべて取り消すこと
- 同じ素材が `trialEntries` と `trialReservations` の両方に存在しないこと
- 同じ素材の再書き出しでトライアルクレジットが二重に減らないこと
- トライアルクレジットが成功枚数分だけ減り、失敗と中止では減らないこと

### 3.6 保護ストアの読み込み失敗（7.2）

- `UsageLedger` の署名検証失敗時、修復済み台帳が作られ、信頼できる時刻を得るまで月間枠が封じられ、トライアルは封じられたままであること
- 修復済み台帳の `trialReservations` / `sourceRecords` / `sourceLeases` が空であること
- `missing` で通常台帳が作られ、初回起動の利用者が封鎖されないこと
- `temporarilyUnavailable` で台帳が上書きされず、書き出し開始が保留されること
- `SubscriptionState` の署名不正時、オフラインで有料権限が新規付与されず、カスタムスタンプと履歴が削除されないこと

### 3.7 出力の寿命と履歴（7.5）

- `OutputRecord` が `ExportCommit` 削除後も単独で期限判定できること
- 未受け渡しの出力が破棄または 24 時間経過まで保持されること
- 受け渡し成功後も完了画面を離れるまで出力が保持され、保存と共有を任意の順序で実行できること
- 異常終了後の起動時、`generated` では復旧案内が出て、`delivered` では出ないこと
- 「履歴を保存しない」設定で、未受け渡し出力・`UsageLedger`・未完了 `ExportCommit`・トライアル用 `SourceRecord` の 4 つ以外が残らないこと
- `canDeleteHistoryUnit` が非終端キュー・`OutputRecord`・非終端 `ExportCommit`・`WorkingSourceRecord`・再生成対象を保護すること
- `CustomStamp` を削除しても、それを使用したプロジェクトが再書き出しできること
- `StampAsset` が**最終保存バイト列**の内容ハッシュで重複排除され、参照カウントが 0 になったときのみ削除されること
- **`CustomStamp` の登録で参照カウントが 1 増え、一覧削除で 1 減ること。一覧でしか使われていない実体が一覧削除で消えること**
- 一括削除が `CustomStamp` のみを対象とし、参照中の `StampAsset` を消さないこと
- 削除で DB が先に更新され、`PendingFileDeletion` が同じトランザクションへ記録されること
- `WorkingSourceRecord` の実体が欠けたとき、そのキュー項目が `reselectionRequired` へ遷移すること

### 3.8 更新誘導との順序（6.7）

- **更新判定が復旧手順 −4〜7 の完了後に実行されること**
- **`.required` かつ `generated` の出力があるとき、受け渡し導線が先に提示されること**
- **その画面から新規加工・履歴・設定へ進めないこと**
- **保存または破棄で `generated` が 0 件になった時点で、通常の強制更新画面へ切り替わること**
- **`.recommended` が編集中・書き出し中・未受け渡し出力があるときに表示されないこと**
- Free が既存プロジェクトの編集画面を開けること。変更操作の時点で案内が出ること

---

## 4. adapter integration test

実 GRDB、実 保護ファイル、実 Keychain 鍵を使います。

### 4.1 プロトコル適合テスト

`MediaKit` / `Persistence` / `Billing` / `Ads` の各プロトコルに対し、**実装と偽実装の両方へ同じスイート**を実行します。偽実装が本物と違う挙動をすると saga テストが無意味になるため、この一致を検証します。

### 4.2 永続化の原子性（7.1 / 8.3）

- 手順 7 の DB トランザクションが原子的であり、`OutputRecord` / `ExportRecord` / キュー状態 / `Project` の更新とコミット削除が同時に成立すること
- 「コミットあり・`OutputRecord` なし」または「コミットなし・`OutputRecord` あり」以外の状態が観測されないこと
- 両スキーマの `journal_mode` が非 WAL であり、いずれかが WAL なら復旧エラーになること
- 両スキーマの `synchronous` が設定・検証されること
- 両 DB を変更する移行が `ATTACH` 済みの単一トランザクションで実行されること
- DB 間参照の整合検査が、`OutputRecord` / `ExportQueueItem` は孤児削除、`ExportCommit` は復旧エラーへ分岐すること

### 4.3 署名と鍵（9.1 / 7.2）

- `ExportCommit` が状態遷移のたびに再署名され、正規の更新で検証失敗しないこと
- `SignedPayload` の署名対象に `payloadType` が含まれ、種別間の付け替えが検出されること
- 実 Keychain の鍵で署名・検証が往復すること。鍵の破棄が `integrityFailure` になること
- HKDF による鍵の用途分離（`payload-signing-v1` / `source-provider-key-v1`）が実際に別の鍵を導くこと
- **blob `missing` / 鍵 `missing` で新規台帳が作られること**
- **blob `missing` / 鍵 `existing` でも新規台帳が作られ、復旧エラーにならないこと**

### 4.4 ファイル管理と保護（7.3 / 7.4）

- `ProtectedBlobStore` のデータと HMAC 鍵がともにバックアップ対象外であること
- 各ディレクトリのデータ保護クラスが 7.4 の表と一致すること
- ロック中に `.complete` のファイルへアクセスした場合、破損ではなく「保護データ利用不可」として処理が一時停止すること
- `OutputRecord` の実体解決が `ManagedFileRef` 経由であり、パス文字列の改変で専用ディレクトリ外を削除できないこと
- **`ManagedFileKind` が異なれば同じ `fileID` でも別ファイルとして扱われること**
- `ManagedFileStore` が保存のたびに `isExcludedFromBackup` と `FileProtectionType` を設定し、読み返して検証すること
- 属性の検証に失敗したファイルが完成扱いにならないこと
- `StampAsset` の作成が atomic rename を経ること

### 4.5 メタデータ（7.5 / 6.4）

- 写真ライブラリ登録日時の引き継ぎを、保存後に読み戻して検証すること。**権限がある場合とない場合の両方で検証する**
- **`contentFingerprint` の撮影日時が EXIF のみから決まり、PhotoKit 権限の有無で変わらないこと**
- 出力ファイルから位置情報・機器情報・編集ソフト情報が除去されていること

### 4.6 Vision と Core Image（5.1 / 5.4）

- Vision の左下原点座標が左上原点へ変換されること。**角度が非 Optional の `Measurement<UnitAngle>` から度へ変換され、符号の向きが 5.1 と一致すること**
- `FaceObservation.confidence` の分布が 1.0 に張り付いていないこと（5.1 の受入条件）
- `NormalizedRect` の `right` / `bottom` が排他的境界として扱われること
- `rotationDegrees` が時計回り正・領域中心基準で描画されること
- `opacity` がレンダラーで 1 回だけ乗算され、ドメイン側で色へ焼き込まれないこと
- クリップが回転の後に行われ、キャンバス端の回転領域が露出しないこと
- 背景処理が顔エフェクトより先に適用されること
- 重なり時に後のエフェクトが加工済み画像へ作用すること
- `Domain` の `PixelRect` が Core Image の Cartesian 矩形へ正しく変換されること
- `CIAffineClamp` を経ることで、画像端の顔のぼかしが薄くならないこと
- `extent` の原点が `(0, 0)` でない `CIImage` でも座標がずれないこと

### 4.7 スタンプラスタライズ（5.3）

- `plan` が参照する `bitmapID` が `rasterAssets` に無い場合、描画を開始せずエラーになること
- 同一 `StampRasterKey` のラスタライズが 1 回で済み、複数領域から再利用されること。**`rasterize(_ keys:)` が与えた全 key に対応する値を返すこと**
- `RasterizedStampAsset` の `bitmapID` スコープが `render` 呼び出し内に閉じ、並列レンダリングで衝突しないこと
- ラスタ一時ファイルの解放が冪等であること。二重解放でエラーにならないこと
- ラスタファイルの行末パディングがゼロ初期化されていること
- premultiplied から straight への変換が保存前に行われていること

### 4.8 Core Image 出力のゴールデン画像テスト（5.2 / 5.4）

**同じ `RenderSpec` から生成したプレビュー用と原寸用の出力が一致すること。** `sourceCrop` / `scaleMode` / `background` を適用した結果が設定と一致すること。

素材として固定化する条件は次のとおりです。

| 分類 | 条件 |
| --- | --- |
| 仕様 30.4 | 強度の最小・最大、顔の回転、領域が画面端、領域の重なり、透明度、4 形状 |
| Y 軸反転の検出 | 画像**上端**だけに顔がある / 画像**下端**だけに顔がある |
| 座標原点 | `extent` の原点が `(0, 0)` でない `CIImage` |

上下の非対称性は、Y 軸反転の誤りが最も現れやすい形です。中央に顔がある素材では反転しても差が出ません。

### 4.9 受け渡しと診断（8.8 / 9.2）

- `SharePresenter` が `UIActivityViewController` の結果を 4 値へ正しく写像すること
- `CrashReporter` が例外メッセージ・パス・URL を除去し、breadcrumbs を列挙済みイベントに限定すること
- `/v1/diagnostics` が未知フィールドを拒否すること
- リモート設定の `Date` が epoch milliseconds として往復すること
- 同一 `configVersion` で内容が異なる設定が拒否されること

---

## 5. process-death fault injection test（実機）

**各手順の直後にプロセスを強制終了し、再起動後の状態を検証します。**

強制終了の手段は次とします。

| 手段 | 用途 |
| --- | --- |
| テスト用フックによる **`_exit(1)`** | 各手順の直後で決定的に落とす。`exit(0)` は正常終了であり `atexit` ハンドラやバッファのフラッシュが走るため、クラッシュ境界の検証にならない |
| 外部プロセスからの `SIGKILL` | シグナルハンドラを経由しない終了。テストランナーとは別プロセスから送る |
| メモリ圧迫によるジェッツァム | 実運用に最も近い経路。一括処理 50 枚で再現する |

**強制終了フックはテスト専用ビルドにのみ含めます。** ビルド構成のコンパイル条件（`#if DEBUG_FAULT_INJECTION`）で分離し、リリースビルドに含まれないことを CI で確認します。

**シミュレータではなく実機を使います。** シミュレータのファイルシステムは macOS のものであり、iOS のストレージスタック（データ保護クラス、ジャーナリングの挙動）と一致しません。

### 項目

- 手順 −2 / 0 / 1 / 2 / 3 / 4 / 5 / 6 / 7 の**各直後**で強制終了し、再起動後に整合が回復すること
- ロールバック手順 1 の完了後に落ちても、再起動時の再実行が冪等であること
- 予約を作った直後に落ちた場合、孤児予約が起動時に回収され、その完了後に新規認可が許可されること
- `StampAsset` の作成で DB 更新の直前に落ちた場合、孤児ファイルが起動時 GC で回収されること
- `PendingFileDeletion` の削除に失敗した場合、次回起動時の GC で再試行されること
- 書き出し一時ファイルとラスタ一時ファイルの孤児が、起動時に回収されること
- `WorkingSourceRecord` の行を作る前に落ちた場合、処理用ファイルが孤児として回収されること

---

## 6. 検出品質の回帰監視

仕様 30.2 の検出条件（正面、横顔、斜め、部分的な遮蔽、マスク、サングラス、暗所、逆光、遠景、集合写真、子ども、高齢者、異なる肌色、イラストの顔、鏡像、写真内の写真）は、**合否判定ではなく検出率の回帰監視**として計測します。

仕様 34.5 が「完全自動を約束しない」と定めている以上、閾値でビルドを落とすのは不適切です。リリース間で検出率が有意に低下した場合のみ調査対象とします。

同じ素材セットで要確認率も計測します。要確認率が高すぎると Pro の価値が失われ、低すぎると見落としが増えます。`extremePose` の角度閾値と `lowConfidence` の信頼度閾値はこの計測から決めます。

**iOS のバージョン更新で Vision の検出特性が変わることがあり、閾値の妥当性が崩れます。** 前リリースとの差が一定以上に開いた場合は閾値を見直します。

### `confidence` の有効性判定

閾値を有効にする前に、採用する `DetectFaceRectanglesRequest.Revision` について次を確認します。

| 計測項目 | 判定 |
| --- | --- |
| `confidence` の分布（ヒストグラム） | 常に `1.0` に張り付いていないこと |
| 目視で誤検出・見落とし近傍と判定した顔の `confidence` | 全体分布より有意に低いこと |
| リビジョンを変えたときの分布の差 | 採用するリビジョンを固定する根拠として記録する |

**この条件を満たさない場合、`lowConfidence` をトリアージから外します。**

---

## 7. プライバシーの受入テスト

- 履歴一覧とサムネイルに未加工の顔が現れないこと
- タスクスイッチャのスナップショットに編集中の未加工画面が残らないこと
- アプリ専用領域に元画像の永続コピーが残らないこと
- 出力ファイルから位置情報・機器情報・編集ソフト情報が除去されていること
- 写真ライブラリの登録日時が元画像から引き継がれていること
- `ProjectSourceLocator` の平文 `localIdentifier` がログ・分析・診断のいずれにも出ないこと

---

## 8. アクセシビリティ

仕様 29 章を受入条件とします。SwiftUI の `Canvas` は既定でアクセシビリティ要素を持たないため、`accessibilityLabel` / `accessibilityValue` / `accessibilityRepresentation` の明示的な付与が必須です。

- 顔レビュー画面の各顔領域に読み上げ可能なラベルがある
- 処理進捗が読み上げ可能である
- 色のみで状態を表現していない
- 文字サイズ変更に追従する
- 広告とアプリ機能が明確に区別される
- おまかせ一括の末尾到達判定が、VoiceOver による走査でも成立する

---

## 9. 実機マトリクス

仕様 30.8 に従います。
