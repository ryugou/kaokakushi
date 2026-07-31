# 顔かくし テスト計画

| 項目 | 内容 |
| --- | --- |
| 対象 | 顔かくし（iOS 単独） |
| 親文書 | [アーキテクチャ設計](architecture.md) |
| 本書の範囲 | 層ごとの個別テスト項目の網羅一覧 |
| 本書の対象外 | テスト戦略そのもの（3 層への分割と各層が保証する内容は [アーキテクチャ設計](architecture.md) 11 章が正） |

節番号の参照は [アーキテクチャ設計](architecture.md) のものです。画像処理は [画像処理アーキテクチャ](image-pipeline.md)、書き出し手順は [書き出し Saga](export-saga.md)、ハッシュのバイト表現は [正準スキーマ](canonical-schema.md) を参照します。[ADR 0005](adr/0005-drop-tamper-resistance-backend-and-heavy-fault-tolerance.md) と [ADR 0006](adr/0006-accounting-per-delivered-output.md)（会計境界 v2：完了操作で消費・確定を一本化）の決定を反映済みです。

---

## 1. 層の割り当て

| 層 | 実行環境 | 対象 |
| --- | --- | --- |
| domain unit test | `swift test`（数秒。シミュレータ不要） | 純粋関数と状態機械 |
| application saga test | `swift test`（数十秒） | 偽ストアによる各中断点の検証 |
| adapter integration test | シミュレータ / 実機 | 実 GRDB、実ファイル保護、Vision、Core Image |

**各項目は、検証が成立する最も低い層へ置きます。** 中断・再起動後の挙動は状態機械のユニットテストで検証します（[書き出し Saga](export-saga.md) の状態を少数に抑えたため。ADR 0005）。

---

## 2. domain unit test

純粋関数と状態機械のみ。ストレージもプロセスも関与しません。

### 2.1 クォータとトライアル（[アーキテクチャ設計](architecture.md) の 6.3）

- `evaluateMonthlyQuota` / `rollPeriod`（月跨ぎ、端末 TZ 変更後の年月算出）
- `evaluateMonthlyQuota` が更新後の `UsageLedger` を返すこと
- `evaluateMonthlyQuota` が `access`（`SingleExportAccess`）を引数で受け取り `Plan` を見ないこと
- `monthlyLimit` を引数で受け取り、`consumed >= limit` で `blocked(limit:)` になること
- **`current != ledger.period` なら `period` が現在の年月へ切り替わること（巻き戻しを含む。ADR 0006）**
- 月初に `consumedExportIDs` だけがリセットされ、`trialConsumedExportIDs` は月をまたいで保持されること
- 消費が件数ではなく `ExportID` の集合で持たれ、同一 `exportID` の再適用を拒否できること
- 時刻は端末の現在時刻・現在タイムゾーンをそのまま使うこと（ADR 0005）
- 台帳が `app.db` の平文行であること（ADR 0005）
- 残クレジットの導出：`remainingCredits = max(0, policy.trialCreditCount - trialConsumedExportIDs.count)`
- `BatchPolicySnapshot` を DB から読んだ直後に hard max（50 / 5 / 5 / 1）と最小値へクランプすること
- `BatchKind` の DB 列値が `proBatch = 1` / `trial = 2` に固定され、`case` の宣言順を変えても既存行の解釈が変わらないこと
- `kind` を `.trial` から `.proBatch` へ書き換えても `batchSizeLimit` のクランプ先が 50 へ緩むが、`trialConsumedExportIDs`（上限 5）が選択枚数を独立して縛ること
- `canEnterBatch` が `canUseProBatch || (canUseBatchTrial && remainingCredits > 0)` で決まること
- `batch-credit`（残クレジット超過）/ `batch-size`（Free・Standard の総数 5 枚超過）/ `batch-limit`（Pro の総数 50 枚超過）の発火条件。`batch-credit` は総枚数上限より残クレジットが少ない場合に `batch-size` より先に発火すること
- バッチ選択とクレジット消費の判定が選択枚数と残クレジットのみで行われ、素材の同一性を問わないこと（ADR 0006）
- **確定した成果物ごとに 1 クレジットを消費すること。`settleBatch` は結果一覧での完了操作 1 回で、確定対象の枚数分だけをまとめて消費すること**（ADR 0006）
- トライアルクレジットに期限が無いこと。トライアルで解放するのは一括処理という操作方式のみで、エフェクト・スタンプの利用範囲は書き換わらないこと
- Pro へ加入済みならトライアルクレジットを消費しないこと
- 顔 0 件の案内が `MonthlyQuotaDecision` で分岐すること（単体処理は仕様 14.2 上も消費対象。一括の顔 0 件は `noFaceDetected` の勘定規則に従う）

### 2.2 レビュー状態とトリアージ（[アーキテクチャ設計](architecture.md) の 6.1 / 6.4）

- `triage`（6 つの要確認理由の各単独・複合、空集合）
- `triage` の入力が [画像処理](image-pipeline.md) の共通モデル（`DetectionResult`）だけであること。OS 固有の値に依存しないこと
- `ReviewIssue` が**発生単位**で列挙され、小さい顔が 3 人なら 3 件になること
- `lowConfidence` が顔ごとに 1 件の `ReviewIssue` になること
- `ReviewIssueID` が `detectionRevision` を含み、`overlappingFaces` では顔 ID が辞書順に並ぶこと
- `ReviewIssueID` が `projectID` を含み、同じ revision の別写真の `noFaceDetected` が別 ID になること
- `FaceTrack` が `confidence` / `yawDegrees` / `pitchDegrees` / `rollDegrees` / `isSmallFace` を列として持ち、`triage` を再実行できること
- `noFaceDetected` の写真は `unmaskedExportConfirmed` 相当の記録が無いかぎり開始できないこと
- `affectedFaceTrackIDs` が ID から導出され、二重に保持されないこと
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
- 顔の初期状態が常に加工対象であること（不変条件）
- 背景処理の変更で `reviewed` が解除されること。メタデータ設定の変更では解除されないこと
- `requiresUserReview` の導出がモードで異なること。1 枚ずつ確認では `normal` の未確認写真も含むこと
- 確認状態の解除が変更範囲に限定されること。`hasOverride` の写真が共通設定変更で `unreviewed` にならないこと
- `overviewConfirmed` が、匿名化結果または構図に影響する変更で必ず `false` になること
- 共通設定の変更が `hasOverride` の写真へ波及しないこと。全上書きが確認を経ること
- 書き出しの成立条件がモードごとに異なること。1 枚ずつ確認では末尾到達と確認ボタンを求めないこと
- 確認段階から設定へ戻っても検出結果が保持されること。この経路で写真の選択を変更できないこと

### 2.3 バッチ選択と能力（[アーキテクチャ設計](architecture.md) の 6.2 / 6.4）

- `canEnterBatch` が `canUseProBatch` / `canUseBatchTrial` / 残クレジットから導かれること
- `canUseProBatch` / `canUseBatchTrial` が能力で判定され、`plan = pro` かつ `status = pending` が通常一括にならないこと
- `resolve(snapshot:usageNow:)`（`CustomerInfoSnapshot` の全状態）
- `plan = standard` かつ `status = pending` で `singleExportAccess == .metered` になること
- `CapabilityResolution.verificationRequired` で書き出し認可が開始されず、Free 降格の表示も出ないこと
- `missing` かつオフラインで `verificationRequired` になること
- `temporarilyUnavailable` かつメモリ上に検証済み `Entitlement` が無い（コールドスタート）とき `verificationRequired` になること。メモリ上に検証済み値があるときは維持されること
- 失効判定が `Entitlement.expiresAt` の超過のみで行われること（ADR 0005）
- `canEdit` が能力で判定され、`requiredPlan` の戻り値比較で可否を決めないこと
- バッチ内の 1 枚を単体編集するとき `canEdit` に従うこと
- `requiredPlan` が設定内容から導かれ、作成時のプランに依存しないこと
- Free 範囲のプロジェクトが Free で編集・書き出しできること
- 降格後の操作可否が 6.2 の表と一致すること
- 「変更せず再書き出し」の免除条件（確定記録の存在・設定ハッシュの一致・同一 `Project` であること・適用範囲は有料スタンプの能力要件のみ）が [書き出し Saga](export-saga.md) の 1.3 と一致すること
- 追加スタンプとカスタムスタンプで、降格後の再書き出し可否が同一であること
- 広告表示頻度の判定（表示禁止条件、初回書き出し、連続表示の抑止）

### 2.4 レンダリング（[画像処理](image-pipeline.md) の 2 / 4）

- 拡張率適用、`RenderSpec` 生成、`compileRenderDraft`、座標正規化
- `compileRenderDraft` が `RenderPlan` へ絶対ピクセル値のみを入れ、比率を残さないこと
- `compileRenderDraft` が `sourceSize` を受け取り、元画像基準の正規化値をピクセルへ変換すること
- `bindRasterAssets` が `stampKeys` に対応する asset を 1 件でも欠けば失敗すること
- `left` / `top` が floor、`right` / `bottom` が ceil で丸められ、領域が外側へ広がること
- `sourceCrop` の不変条件違反が例外になり、クランプで黙って直されないこと
- `manual` の領域が `auto` より後の `order` になること
- `Domain` が `StampRasterizer` プロトコルのみを持ち、`CoreGraphics` を参照しないこと
- `StampRasterKey` に位置・回転・不透明度・形状が含まれないこと
- **`opacity = 0` / `cellSizePx < 2`（特に 1px） / `sigmaPx = 0` / 幅 0 の領域が `throw` されること**
- **`cellSizePx` が `floor(cellRatio × 領域短辺)` で求まり、1 以下なら 2 へ引き上げられること。引き上げても領域が 2px 未満なら `throw` すること**
- **`MosaicRatio` / `BlurRatio` / `FeatherRatio` / `ExpansionRatio` / `NormalizedRect` が `throws` の initializer だけを公開し、`NaN` と範囲外を拒否すること**
- **`RenderOpSpec` / `RenderOp` / `RenderOpDraft` に生の `Double` が残っていないこと**
- **`NaN` や無限大の座標が `throw` されること**
- **完全に透明なカスタムスタンプ画像が取り込み時に拒否されること**
- **`isMasked == true` の顔に no-op 相当の値が渡されたとき `compileRenderDraft` が `throw` すること**
- **`authorizeRenderSpec` が有料スタンプを含む `RenderSpec` を `canUsePremiumStamps == false` で `blocked` にすること**
- **`enabledStampPacks` が `ResolvedCapabilities` にあり、`authorizeRenderSpec` はこれを見ないこと**（UI のスタンプ選択では見る）
- **バッチの 1 項目が `blocked` のとき `failed(capabilityRequired)`（`isRetryable == false`）へ遷移し、バッチの完了判定が成立すること**
- **`premiumStampNotAvailable` / `customStampNotAvailable` でのみ Paywall が提示されること**
- **`unknownBuiltInStampCode` では Paywall を提示せず、`capabilityRequired` のエラーと設定変更の誘導になること**
- **`RenderSpecBlockReason` が 3 case であること**
- **カスタムスタンプを `canUseCustomStamps == false` で `blocked` にすること**
- **`StampCatalog` に無い `code` を `blocked` へ倒し、無料扱いにしないこと**
- **`StampCatalog` がアプリにハードコードされ、値を変更できないこと**
- 永続データのデコード時にも検証済み値型の `throws` 版が呼ばれること
- **境界型（`ImageSource` / `LoadedPhoto` / `DetectionResult` / `RenderedImage` / `OutputFile`）が `URL` もパス文字列も持たないこと**
- **`ImageSource` に未正規化を表す値が存在しないこと**
- **`OutputRecord.outputFile` が `OutputFileRef`、`WorkingSourceRecord.sourceFile` が `WorkingSourceFileRef`、`RenderedImage.file` が `RasterFileRef` であること**
- **`YearMonth` の実型が `Int32` であること。`FaceTrackID` が `UUID` であること**
- **`RenderedImage` が `RawBitmapDescriptor` を持ち、チャネル順・アルファ・色空間・bit depth が型で決まること**

### 2.5 設定ハッシュと正準化（[アーキテクチャ設計](architecture.md) の 6.2、[正準スキーマ](canonical-schema.md) の 5.2）

- 設定ハッシュが `Map` のキー順・**`Double.bitPattern`（64 ビット）**・内容ハッシュ参照で正準化され、DB ID に依存しないこと
- **`Float` へ丸めた場合に区別できなくなる 2 つの `Double` が、異なる設定ハッシュになること**
- **`RotationDegrees` が `[-180, 180)` へ正規化され、`370` と `10` が同じ設定ハッシュになること**
- `-0.0` が `+0.0` へ正規化されること
- プロジェクト設定ハッシュの一致判定により、Free の「変更せず再書き出し」が許可されること
- **正常書き出しの記録が無いプロジェクトが「変更せず再書き出し」の対象外になること**
- **`PreviewRenderHash` に圧縮品質とメタデータ設定が含まれないこと。それらを変えても確認の一致が崩れないこと**
- **`renderRevision` を上げると `PreviewRenderHash` が変わること**
- **2 つのハッシュがそれぞれ `project-settings-v1` / `preview-render-v1` のドメイン分離子を先頭に持つこと**
- **`PreviewConfirmation` が `projectID` / `detectionRevision` / `previewRenderHash` を持ち、`projectRevision` を含まないこと**
- **同じ設定・同じ領域の別 `Project` で `previewRenderHash` が一致しても、`projectID` の不一致で開始できないこと**
- **`BatchReviewState` が `batchID` を持ち、別バッチの確認状態を流用できないこと**
- **圧縮品質・メタデータ設定だけを変えて `projectRevision` が増えても、書き出しの開始条件が崩れないこと**
- **手動領域の追加・削除では `previewRenderHash` が変わり、開始条件が崩れること**
- **`PreviewConfirmation` と `overviewConfirmed` が再起動後に保持されず、再確認を求めること**
- **出力へ影響する子行（`FaceTrack` / `EffectSetting` / `ExportSetting` / `ProjectStampAsset`）の変更で、同一トランザクション内に `projectRevision` が増えること**
- **各ハッシュ（`StampAssetHash` / `ProjectSettingsHash` / `PreviewRenderHash`）について、既知の入力から生成した固定 canonical bytes と出力値をテストへ埋め込むこと**（符号化ロジックの変更を検出する。[正準スキーマ](canonical-schema.md) の 6）

### 2.6 更新誘導（[アーキテクチャ設計](architecture.md) の 6.6）

- `AppVersion` の比較が数値の組で行われ、`1.10.0 > 1.9.0` になること
- `CFBundleShortVersionString` のパース失敗で `.none` になること
- `latestOnStore == nil`（iTunes Lookup API の取得失敗）で `.none` になること
- `skippedVersion` と一致する `recommendedVersion` を再提示しないこと
- 前回提示から 24 時間未満なら `.recommended` を返さないこと。判定に `usageNow` を使うこと
- `recommendedVersion` が上がれば、スキップ済みでも再提示されること
- 更新誘導が常に任意の推奨であること（配信元は iTunes Lookup API のみ。ADR 0005）

### 2.7 その他

- ストレージ必要量計算、`ExportQueueState` 状態機械
- **履歴の保存期間と容量判定。容量超過時にも、完了前のやり直しは無制限のまま保たれ、完了済み未受け渡し出力（`isUndelivered`）の 24 時間保護は絶対保護として維持されること**
- `canDeleteHistoryUnit` が列挙された全参照元を見ること（[アーキテクチャ設計](architecture.md) の 7.5。Saga 経由でも同一判定になることは 3.6 参照）
- **絶対保護（非終端キュー項目 / 処理中の `ExportJob` / `isUndelivered` の `OutputRecord`）が、手動削除でも拒否されること**
- **お気に入り・編集中・`WorkingSourceRecord`（`OverridableProtection` の 3 値）が、自動削除では保護され、明示確認付きの手動削除では上書きできること**
- **上書き対象ごとに、失われるものを示す確認文言が選ばれること**
- 未保存バッチが 1 件までに制限されること
- 一括処理の開始が推定必要容量の 1.2 倍の空き容量を要求すること
- 未保存出力がある状態では、単体・一括を問わず新規加工を開始できないこと
- 完了画面の離脱確認が `isUndelivered`（`generated` と `deliveryUnknown`）の残数で判定されること。一部保存済みでも出ること
- 復旧案内の枚数が `isUndelivered` の枚数であり、バッチ総枚数ではないこと
- 共有結果が `.completed` のときだけ `delivered` へ遷移すること。`.unknown` では維持されること

---

## 3. application saga test

偽 `ExportSagaStore` / `OutputDeliveryStore` / 偽ファイルを注入し、**各中断点**での挙動を検証します。実ストレージの原子性は検証しません（4 章の役割）。

### 3.1 認可と生成

- 認可が `PreviewConfirmation` の一致検査と設定内容の能力検査（`authorizeRenderSpec`）の順に行われ、いずれか不成立なら開始しないこと。**`triage` の再導出は行わないこと**（保存済みの `DetectionStatus` / `ReviewStatus` / `ReviewDecision` をそのまま信頼する。ADR 0005）
- 単体の開始条件が現在の `projectID` / `detectionRevision` / `previewRenderHash` の一致であること。バッチはこれに加え `BatchReviewState.batchID` の一致とモード別の確認条件を満たすこと
- `reviewRequired` かつ `unreviewed` の写真が残っていれば開始しないこと
- `WorkingSourceRecord` の実体（ファイルの存在）だけを確認すること。無ければ無効化して再選択導線へ倒すこと
- 権限とクォータの評価で `.blocked` なら `ExportJob` を作らず、生成も開始しないこと
- 手順 0：`startExport` が `expectedProjectRevision` と不一致なら `throw` し、一致すれば `ExportJob` を挿入すること
- **生成の完了時点（`recordGeneratedOutput`）では `OutputRecord`（`settledAt: nil`）と出力ファイルだけが作られること。月間枠・トライアルクレジットのいずれも消費されないこと**（ADR 0006）
- **生成の完了時点で `ExportRecord` が作成されないこと。確定記録（`ExportedSettingsEntry`）も更新されないこと**
- **生成の完了時点でキュー項目が確定されないこと**
- **生成の完了時点で `WorkingSourceRecord` が削除されず保持され、素材を再レンダリングできること**
- **健全性確認**: 存在確認だけでは不足し、サイズが 0 でなく簡易デコードが成功することを確認すること。いずれか不成立なら中断として扱うこと
- 生成の失敗（レンダリング・移動・健全性確認の不成立）・利用者によるキャンセルが、`ExportJob` の削除と生成済みファイルのベストエフォート削除で後始末されること。**まだ何も消費していないため返還処理は不要であること**
- 開始後に契約の失効・月間上限への到達が起きても、`running` の写真は開始時の権限のまま生成を完了すること。`waiting` の写真は開始しないこと
- **直列実行キュー1本（並列数1）が、同時に処理中の `ExportJob` を 1 件までに保つこと**（ADR 0005）
- `startExport` が `expectedProjectRevision` つきで `ExportJob` 行を挿入し、revision が変わっていれば失敗すること

### 3.2 完了（`settleExport` / `settleBatch`）

- **`settleExport` が単一トランザクションで、消費（月間枠またはクレジット）・`settledAt` の設定・`ExportRecord` の作成・確定記録の更新・キュー項目の確定・`WorkingSourceRecord` の削除・`ExportJob` の削除を同時に行うこと**（ADR 0006）
- 一度設定した `settledAt` は変更されないこと。二重に完了操作を呼んでも消費が重複しないこと
- **`settleBatch` が結果一覧画面での完了操作 1 回で、対象バッチ内の確定対象の全出力を同一トランザクションで確定し、確定対象の枚数分だけクレジットを消費すること**（ADR 0006）
- 完了操作の付近に「完了すると 1 枚として確定し、以降の作り直しは新しい 1 枚になる」旨が明示されること
- 保存・共有が完了後にのみ行え、`beginDeliveryAttempt` / `completeLibrarySave` / `completeShare` が `settledAt != nil` を事前条件とすること（`nil` なら throw）
- 保存・共有は何度実行しても追加消費せず、成否が枠に影響しないこと（失敗しても出力は保持され再試行できる）

### 3.3 完了前の破棄

- **完了前の「やり直す」（`discardExport`）が確認用出力（`OutputRecord`）と出力ファイルを削除するだけであること。免除・返還・補償のいずれの処理も伴わないこと**（ADR 0006。まだ何も消費していないため、その概念自体が存在しない）
- 破棄後も月間枠・トライアルクレジットが変化しないこと
- **破棄後も素材（`WorkingSourceRecord`）が保持され、同じ設定・別の設定のいずれでも再レンダリングできること**
- 破棄の回数に制限が無いこと
- **完了前の出力が永続保護されないこと。アプリの再起動またはフローからの離脱で破棄されること**（消費していないため損失は操作の手間だけにとどまる）
- 24 時間の保持規則が、完了済みで未受け渡しの出力にのみ適用され、完了前の出力には適用されないこと

### 3.4 確定後の実体喪失（[書き出し Saga](export-saga.md) の 6 章）

- **実体が無い、または `outputByteSize` / `outputSHA256` と一致しないとき、`OutputRecord` を削除すること**（[書き出し Saga](export-saga.md) の 6 章。`OutputState` は `generated` / `deliveryUnknown` / `delivered` の3値であり、`discarded` という状態は存在しない。破棄は状態ではなく行の物理削除で表す）
- **`UsageLedger` を変更しないこと**（月間枠・トライアルクレジットのいずれも戻さない）
- 自動再生成を行わないこと。利用者へは新しい書き出しとして案内すること

### 3.5 起動時復旧

- **起動時復旧が次の順序で実行されること**: (1) `running` の `ExportJob` を削除する (2) `settledAt == nil` の未確定出力（`OutputRecord` と出力ファイル）を削除する (3) 孤児ファイルを GC で回収する (4) `resolveOrphanedAttempts` で残存 `DeliveryAttempt` を解決する (5) `UnknownLibrarySave` を読み込む (6) 復旧案内を提示する
- 復旧が完了するまで新しい書き出しを開始させないこと
- `DeliveryAttempt` が残っている場合、`previousState == generated` なら `deliveryUnknown` へ、`previousState == delivered` なら `delivered` を維持したうえで「保存結果が不明」を別途提示すること。状態を後退させないこと
- `resolveOrphanedAttempts` が解決後の全出力の受け渡し状態を返すこと。復旧案内はこの戻り値を使うこと

### 3.6 出力の寿命と履歴（[アーキテクチャ設計](architecture.md) の 7.5）

- `OutputRecord` が独立に期限判定できること
- 未受け渡しの出力が破棄または 24 時間経過まで保持されること
- 受け渡し成功後も完了画面を離れるまで出力が保持され、保存と共有を任意の順序で実行できること
- 異常終了後の起動時、`isUndelivered` では復旧案内が出て、`delivered` では出ないこと
- 「履歴を保存しない」設定で、未受け渡し出力・保存結果不明の注記が付いた `delivered` 出力・`UsageLedger` の消費記録・処理中の `ExportJob` とその生成済み出力の 4 つ以外が残らないこと
- `canDeleteHistoryUnit` が**列挙された全参照元**を保護すること
- **`Project` 削除時、それが `Batch` の最後の所属 `Project` なら `Batch` 行が同一トランザクションで削除されること**
- **所属 `Project` が残る場合は `Batch` 行が残ること**
- **`deleteHistoryUnit` が `DeletionContext` を受け取らず、DB トランザクション内で読み直して再判定すること**
- **`inspectDeletion` の後・削除の前に新しい `ExportJob` が作られた場合、削除が throw すること**
- **`hasUndeliveredOutputRecord` が `delivered` の出力を保護せず、`isUndelivered` のみを見ること**
- **編集中 `Project` の破棄が `WorkingSourceRecord` をすべて削除すること**
- `CustomStamp` を削除しても、それを使用したプロジェクトが再書き出しできること
- `StampAsset` が**最終保存バイト列**の内容ハッシュで重複排除され、参照カウントが 0 になったときのみ削除されること
- **`CustomStamp` の登録で参照が 1 増え、一覧削除で 1 減ること。一覧でしか使われていない実体が一覧削除で消えること**
- **1 プロジェクト内で同じスタンプを複数領域へ使っても `ProjectStampAsset` が 1 行であること。最後の 1 領域を外した時点で行が消えること**
- **保存値の `referenceCount` が導出値と一致すること。不一致なら導出値を正として書き直すこと**
- 一括削除が `CustomStamp` のみを対象とし、参照中の `StampAsset` を消さないこと
- 削除で DB が先に更新され、`PendingFileDeletion` が同じトランザクションへ記録されること
- `WorkingSourceRecord` の実体が欠けたとき、そのキュー項目が `paused(.sourceReselectionRequired)` へ遷移すること。バッチ全体が止まらないこと
- **`WorkingSourceRecord` の削除契機が、完了操作（`settleExport` / `settleBatch`）・プロジェクト破棄・実体欠損の 3 つに限られ、時間経過では削除されないこと**（[画像処理](image-pipeline.md) が正本）
- **`Project` の `capture` / `sourceRepresentation` / `libraryCreationDate` が、書き出しの完了や `WorkingSourceRecord` の削除では消えず、`Project` 自体の削除でのみ失われること**
- `WorkingSourceRecord` の有無で `replaceWorkingSource` と `attachWorkingSourceToExistingProject` が選ばれること
- **`paused(.sourceReselectionRequired)` になったあとも、再選択（実体の存在確認）が成立すること**
- **履歴の既存 `Project` へ `attachWorkingSourceToExistingProject` で再接続できること。選び直された写真は常に新しい素材として扱われること**（ADR 0006）
- **再接続が `detectionRevision` / `projectRevision` を増やし、検出結果を再利用しないこと**
- **再選択が顔検出をやり直し、`detectionRevision` と `projectRevision` を増やし、旧 `FaceTrack` / `ReviewIssue` / `ReviewDecision` / `ReviewStatus` を破棄すること**
- **`PreviewConfirmation` が DB に存在せず、`detectionRevision` の増加だけで確認が無効になること**
- **`isTerminal` が `completed` / `failed` / `canceled` のみ真であり、履歴削除の保護と完了判定が同じ述語を使うこと**

### 3.7 更新誘導との順序（[アーキテクチャ設計](architecture.md) の 6.6）

- 更新判定が起動時復旧の完了後に実行されること
- `.recommended` が編集中・書き出し中・未受け渡し出力があるときに表示されないこと
- Free が既存プロジェクトの編集画面を開けること。変更操作の時点で案内が出ること

---

## 4. adapter integration test

実 GRDB、実ファイル保護、Vision、Core Image を使います。

### 4.1 プロトコル適合テスト

`MediaKit` / `Persistence` / `Billing` / `Ads` の各プロトコルに対し、**実装と偽実装の両方へ同じスイート**を実行します。偽実装が本物と違う挙動をすると saga テストが無意味になるため、この一致を検証します。

### 4.2 永続化の原子性（[アーキテクチャ設計](architecture.md) の 7.1）

- **`settleExport` / `settleBatch` の DB トランザクションが原子的であり、`OutputRecord.settledAt` の設定・`ExportRecord` / キュー状態 / `Project` / `WorkingSourceRecord` の更新・`ExportJob` の削除が同時に成立すること**
- **完了操作の成功後にのみ `OutputRecord.settledAt` が確定していること。途中状態（消費だけ・`settledAt` だけ等）が観測されないこと**
- `synchronous = EXTRA` と `foreign_keys = ON` が設定され、起動時に読み返して検証されること
- スキーマ移行が単一トランザクションで確定し、途中適用が観測されないこと
- **外部キー制約が有効であり、`Project` の削除が `OutputRecord`（非終端）/ 処理中の `ExportJob` の存在で RESTRICT されること**
- **`Batch` の削除で `OutputRecord.batchID` / `ExportRecord.batchID` / `ExportJob.batchID` が SET NULL になること**
- **`OutputRecord.projectID` の部分 UNIQUE インデックス（`settledAt IS NULL`）が未確定出力を 1 プロジェクトにつき 1 件へ制限すること**
- **`journal_mode` が `DELETE` であり、`TRUNCATE` / `PERSIST` / `WAL` なら復旧エラーになること**
- `PRAGMA foreign_key_check` が起動時に実行され、違反があれば復旧エラーになること

### 4.3 ファイル管理と保護（[アーキテクチャ設計](architecture.md) の 7.3 / 7.4）

- `ManagedFileStore` が保存のたびに `isExcludedFromBackup` と `FileProtectionType` を設定し、読み返して検証すること
- 属性の検証に失敗したファイルが完成扱いにならないこと
- `StampAsset` の作成が atomic rename を経ること
- **インポート Saga の手順 1〜3 の途中で終了した場合、作成済みファイルが孤児として起動時 GC で回収されること**
- **`Project` の `capture` / `sourceRepresentation` / `libraryCreationDate` が `Project` 作成（手順 3）と同一トランザクションで保存されること**
- **DB 登録に失敗した場合、その `WorkingSourceRecord` と `Project`（`capture` / `sourceRepresentation` / `libraryCreationDate` を含む）が補償削除されること**
- **インポート Saga が `PickedPhotoInput.importedFile` を作り直さず、所有権を受け取ること**
- **DB 確定（手順 3）の後に取り込みファイルが削除され、削除失敗時は `PendingFileDeletion` へ積まれること**
- **DB 確定より前に取り込みファイルを削除しないこと**
- **再選択・再接続の成功経路でも候補ファイル（正規化前の旧 `sourceFile`）が削除されること**
- **「Free 版として複製」で新しい `projectID` の `WorkingSourceRecord` が作られ、処理用ファイルが元 `Project` と共有されないこと**
- **複製の DB 失敗で新 `WorkingSourceRecord` が補償削除されること**
- **元素材の実体が無い場合、`WorkingSourceRecord` を作らず複製すること**
- **複製に `ExportedSettingsEntry` がコピーされないこと**
- **`Project` 削除で DB が先に確定し、実体が `PendingFileDeletion` へ積まれること**
- **`WorkingSourceRecord` が最初から向き正規化済みの原寸ファイルを指すこと**
- **検出用の縮小画像がメモリ内で完結し、`ManagedFileStore` へ書かれず DB へも登録されないこと**
- **DB 登録の完了前に、選択処理の成功が呼び出し元へ返らないこと**

### 4.4 メタデータ（[アーキテクチャ設計](architecture.md) の 7.5）

- **読み取り権限あり** — 保存後に `PHAsset.creationDate` を読み戻し、元画像の登録日時と一致すること
- **読み取り権限なし** — 偽 `PHAssetCreationRequest` または adapter spy で、**EXIF の日時が渡されたこと、または `creationDate` が設定されなかったこと**を検証する。`PHAsset` を取得しにいかないこと
- **`OriginalCaptureMetadata` が EXIF のみから決まり、PhotoKit 権限の有無で変わらないこと**
- **`OffsetTimeOriginal` があり `SubSecTimeOriginal` が無い場合、秒精度で `utcMillis` が算出されること**
- 出力ファイルから位置情報・機器情報・編集ソフト情報が除去されていること

### 4.5 Vision と Core Image（[画像処理](image-pipeline.md) の 1 / 4）

- Vision の左下原点座標が左上原点へ変換されること。**角度が非 Optional の `Measurement<UnitAngle>` から度へ変換され、符号の向きが [画像処理](image-pipeline.md) の 4 章と一致すること**
- `FaceObservation.confidence` の分布が 1.0 に張り付いていないこと（[画像処理](image-pipeline.md) の 1 の受入条件）
- `NormalizedRect` の `right` / `bottom` が排他的境界として扱われること
- `rotationDegrees` が時計回り正・領域中心基準で描画されること
- `opacity` がレンダラーで 1 回だけ乗算され、ドメイン側で色へ焼き込まれないこと
- クリップが回転の後に行われ、キャンバス端の回転領域が露出しないこと
- 背景処理が顔エフェクトより先に適用されること
- 重なり時に後のエフェクトが加工済み画像へ作用すること
- `Domain` の `PixelRect` が Core Image の Cartesian 矩形へ正しく変換されること
- `CIAffineClamp` を経ることで、画像端の顔のぼかしが薄くならないこと
- `extent` の原点が `(0, 0)` でない `CIImage` でも座標がずれないこと

### 4.6 スタンプラスタライズ（[画像処理](image-pipeline.md) の 3）

- `plan` が参照する `bitmapID` が `rasterAssets` に無い場合、描画を開始せずエラーになること
- 同一 `StampRasterKey` のラスタライズが 1 回で済み、複数領域から再利用されること。**`rasterize(_ keys:)` が与えた全 key に対応する値を返すこと**
- `RasterizedStampAsset` の `bitmapID` スコープが `render` 呼び出し内に閉じ、並列レンダリングで衝突しないこと
- ラスタ一時ファイルの解放が冪等であること。二重解放でエラーにならないこと
- ラスタファイルの行末パディングがゼロ初期化されていること
- premultiplied から straight への変換が保存前に行われていること

### 4.7 Core Image 出力のゴールデン画像テスト（[画像処理](image-pipeline.md) の 2 / 4）

**同じ `RenderSpec` から生成したプレビュー用と原寸用の出力が一致すること。** `sourceCrop` / `scaleMode` / `background` を適用した結果が設定と一致すること。

素材として固定化する条件は次のとおりです。

| 分類 | 条件 |
| --- | --- |
| 仕様 30.4 | 強度の最小・最大、顔の回転、領域が画面端、領域の重なり、透明度、4 形状 |
| Y 軸反転の検出 | 画像**上端**だけに顔がある / 画像**下端**だけに顔がある |
| 座標原点 | `extent` の原点が `(0, 0)` でない `CIImage` |

上下の非対称性は、中央に顔がある素材では差が出ない Y 軸反転の誤りを最も検出しやすい形です。

### 4.8 受け渡しと診断（[書き出し Saga](export-saga.md) の 7 章）

- `SharePresenter` が `UIActivityViewController` の結果を 4 値へ正しく写像すること
- `CrashReporter` が例外メッセージ・パス・URL を除去し、breadcrumbs を列挙済みイベントに限定すること
- **Sentry への送信対象がクラッシュと未分類例外のみであること。広告読み込み失敗・容量不足・保存権限拒否など想定内のエラーは送らないこと**

---

## 5. 検出品質の回帰監視

仕様 30.2 の検出条件（正面、横顔、斜め、部分的な遮蔽、マスク、サングラス、暗所、逆光、遠景、集合写真、子ども、高齢者、異なる肌色、イラストの顔、鏡像、写真内の写真）は、**合否判定ではなく検出率の回帰監視**として計測します。

仕様 34.5 の「完全自動を約束しない」に基づき閾値でビルドを落とさず、リリース間で検出率が有意に低下した場合のみ調査対象とします。

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

## 6. プライバシーの受入テスト

- 履歴一覧とサムネイルに未加工の顔が現れないこと
- タスクスイッチャのスナップショットに編集中の未加工画面が残らないこと
- **書き出し完了・キャンセル・プロジェクト破棄のいずれかの後に、参照のない処理用元画像コピーが残らないこと**（処理中の `WorkingSourceRecord` は正当な保持であり、これに含めない）
- 出力ファイルから位置情報・機器情報・編集ソフト情報が除去されていること
- **写真ライブラリの登録日時が、取得できる場合に引き継がれ、取得不能時は未設定になること**（現在時刻を明示指定しないこと）
- `ProjectSourceLocator` の平文 `localIdentifier` がログ・分析・診断のいずれにも出ないこと

---

## 7. アクセシビリティ

仕様 29 章を受入条件とします。SwiftUI の `Canvas` は既定でアクセシビリティ要素を持たないため、`accessibilityLabel` / `accessibilityValue` / `accessibilityRepresentation` の明示的な付与が必須です。

- 顔レビュー画面の各顔領域に読み上げ可能なラベルがある
- 処理進捗が読み上げ可能である
- 色のみで状態を表現していない
- 文字サイズ変更に追従する
- 広告とアプリ機能が明確に区別される
- おまかせ一括の末尾到達判定が、VoiceOver による走査でも成立する

---

## 8. 実機マトリクス

仕様 30.8 に従います。
