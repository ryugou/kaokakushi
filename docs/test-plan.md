# 顔かくし テスト計画

| 項目 | 内容 |
| --- | --- |
| 対象 | 顔かくし（iOS 単独） |
| 親文書 | [アーキテクチャ設計](architecture.md) |
| 本書の範囲 | 層ごとの個別テスト項目の網羅一覧 |
| 本書の対象外 | テスト戦略そのもの（4 層への分割と各層が保証する内容は [アーキテクチャ設計](architecture.md) 11 章が正） |

節番号の参照は [アーキテクチャ設計](architecture.md) のものです。画像処理は [画像処理アーキテクチャ](image-pipeline.md)、書き出し手順は [書き出し Saga](export-saga.md)、バイト表現は [正準スキーマ](canonical-schema.md) を参照します。

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

### 2.1 クォータ・grant・トライアル（[アーキテクチャ設計](architecture.md) の 6.3）

- `evaluate` / `rollPeriod`（月跨ぎ、TZ 変更、時刻巻き戻し、うるう年、月末 23:59:59 → 00:00:00、24 時間境界）
- `evaluate` が更新後の `UsageLedger` を返し、`unlimited` でも時刻更新と grant 整理が行われること
- `evaluate` と開始ゲートが `Plan` を参照せず `ResolvedCapabilities` のみを受け取ること
- **`evaluate` が `monthlyLimit` を引数で受け取り、リモート設定の変更が判定へ反映されること**
- **`Domain` が `RemoteConfig` 型そのものを参照しないこと**
- `monthlyIntegrityLock` が解除条件を満たさないとき、`consumedExportIDs` が空でも `blocked(ledgerIntegrityFailure)` になること
- **端末時刻をどう変更しても `monthlyIntegrityLock` が解除されないこと。信頼できる時刻の観測だけが解除条件であること**
- **`trustedMonth` が `nil` のとき封鎖が解除されないこと**
- **月境界付近でタイムゾーンを変更しても、`TrustedUTCMonth` が動かないこと**
- **`observeTime` が `trustedNow` と `trustedMonth` を別フィールドとして返し、`usageNow` から由来を推測しないこと**
- `ExportGrant` が能力を問わず作成されること
- 同一素材の再書き出しで `firstSuccessAt` が更新されないこと
- 月末の初回成功から 24 時間以内なら、月をまたいでも `freeReexport` になること
- `rollPeriod` が `consumed` だけをリセットし、`grants` を月境界で捨てないこと
- 端末時刻を過去へ戻しても 24 時間の窓が延びないこと。`usageNow` が後退しないこと
- **`usageNow` の下限に信頼時刻が含まれること。** 端末時刻を前月へ戻しても、信頼時刻を得た時点で消費判定がその月へ進むこと
- `Domain` の時間判定が `now` ではなく `usageNow` / `retentionNow` だけを受け取ること
- **未来への大幅ジャンプ（30 日超）だけを根拠に、履歴・未受け渡し出力・やり直し保証のいずれも削除されないこと**
- **`retentionNow` が `nil` のとき、いずれも削除されないこと**
- **端末時刻を過去へ戻すと保持期間が延長されること**（利用者に不利ではないため許容する。`retentionNow` に `max` を掛けない）
- **信頼時刻を得た後は、その時刻に従って保持期間が判定されること**
- **リモート設定の `expiresAt` 判定には `trusted ?? usageNow` を使い、時計を過去へ戻しても古い設定が延命されないこと**
- **信頼時刻が `/v1/config` の `serverTime` から取られ、HTTP の `Date` ヘッダを使わないこと**
- **取得から 6 時間を超えた信頼時刻が `nil` として扱われること**
- **保存済みの信頼時刻より過去の値を受理しないこと**
- **設定取得が失敗し購入状態の取得に成功した場合だけ `CustomerInfo.requestDate` を使うこと。どちらも失敗なら `trustedNow = nil` になること**
- **`TrustedTimeState` が独立した署名対象として保存され、設定取得が失敗して RevenueCat だけ成功した場合でも保存できること**
- **鮮度判定が `usageNow − observedAtUsageNow` で行われ、端末時計の巻き戻しで鮮度が延びないこと**
- **`TrustedTimeState` の `integrityFailure` が `missing` と同じ扱いになり、信頼時刻なしとして封鎖側へ倒れること**
- **`UsageLedger` が `missing` でも、利用痕跡があれば保守的修復（封鎖付き）になること**
- **利用痕跡が無い `missing` でのみ通常の新規台帳が作られること。鍵の有無を痕跡に含めないこと**
- **台帳 blob だけを削除しても無料枠とトライアルが回復しないこと**
- **痕跡が `protected/` の他 3 blob と `AppLifecycle` 行であり、履歴テーブルの行を見ないこと**
- **「履歴を保存しない」設定で履歴が全削除されても、痕跡が残り封鎖されること**
- **手動での履歴全削除でも同じく封鎖されること**
- **`protected/` を全消去しても `AppLifecycle` 行があれば封鎖されること**
- **`protected/` 全消去 ＋ `DELETE FROM AppLifecycle` では封鎖されず、通常の新規台帳が作られること**（9.3 の対象外。**塞げないことを退行テストとして固定する**）
- **`AppLifecycle` が `id INTEGER PRIMARY KEY CHECK (id = 1)` により 2 行目を挿入できないこと**
- **`AppLifecycle` が `app.db` のテーブル一覧とスキーマ移行の定義に含まれていること**
- **`AppLifecycle` の挿入が起動時復旧の手順 9 で、痕跡の評価が手順 1 で行われ、真の初回起動が「痕跡あり」と誤判定されないこと**
- **手順 9 に到達せず終了した初回起動の次回起動でも、誤判定されずに `AppLifecycle` が挿入されること**
- **`AppLifecycle` がマイスタンプもプリセットも持たない Free 利用者でも必ず作られること**（痕跡が有料機能に依存しない）
- **`AppLifecycle` が履歴設定・手動削除・容量超過・期限削除のいずれの経路でも削除されないこと**
- **通信を遮断し端末時計を据え置いても、`unverifiedLedgerWrites >= 2000` で `verificationRequired` になること**
- **1 枚の新規写真の書き出しで台帳が 4 回書かれること**（インポート手順 4・書き出し手順 −2・手順 4・手順 8）
- **新しい素材を選ばない再書き出しでは 3 回であること**
- **2000 回が約 500〜670 枚に相当し、機内モードで Pro の 10 バッチまで通常どおり動くこと**
- **`unverifiedLedgerWrites` が `UsageLedgerStore.transact` の内側・保存直前に無条件で +1 されること**
- **`transact` が中断・失敗した場合に加算もロールバックされ、成功時は 1 回だけ増えること**
- **書き出しのロールバックや `finalizing` 以降からの復旧のやり直しでも、加算が手順 4 の台帳トランザクション単位でしか起きないこと**
- **`Purchases.getCustomerInfo()` が SDK キャッシュを返した場合（`requestDate` が前回と同じ）、「取得に成功」と扱わないこと**
- **その場合にキャッシュを置き換えず、`lastVerifiedAt` も動かさず、`recordEntitlementRefresh()` も呼ばないこと**
- **RevenueCat のホストを遮断したまま起動を繰り返しても、`unverifiedLedgerWrites` と 14 日の猶予がどちらもリセットされないこと**
- **`CacheFetchPolicy` がキャッシュを使わない設定で明示され、SDK の既定値に依存しないこと**
- **`SubscriptionState.lastRequestDate` が署名対象であり、DB 改変で書き換えられないこと**
- **`requestDate` が単調前進しない応答を受理しないこと**（`TrustedTimeState` の受理条件と同じ形）
- **`recordConfigRefresh()` が HTTP レスポンスの新規受信で呼ばれ、同一 `configVersion` で保存が起きなくても呼ばれること**
- **`configVersion` を上げない期間に台帳を 4000 回書いても、取得に成功し続けていれば失効から復帰すること**
- **リセットが `recordEntitlementRefresh()` / `recordConfigRefresh()` の 2 メソッドだけで行われ、`transact` の変換関数から到達できないこと**
- **変換関数が見る `LedgerMutableView` に `unverifiedLedgerWrites` と `ledgerWritesSinceConfigFetch` が含まれないこと**（型から外れていること）
- **リセット後の保存値が 1 になること**（0 を書き、保存直前の +1 が効く）
- **`SubscriptionState` の保存成功を確認してから `recordEntitlementRefresh()` を呼ぶこと**
- **リセットを先に行う実装では、保存直前の強制終了で古い有料キャッシュに 2000 回ぶんの寿命が追加されることを、退行テストとして押さえること**
- **リセットが失敗しても `SubscriptionState` を巻き戻さず、次回の取得成功で再試行すること**
- **台帳 blob の末尾 1 バイトを切り詰めると `integrityFailure` になり、`temporarilyUnavailable` にならないこと**
- **`payloadType` の不整合も `integrityFailure` になること**
- **ヘッダ長（16 バイト）未満のファイルが `integrityFailure` になること**（0 バイトを含む）
- **`errSecInteractionNotAllowed` / `errSecNotAvailable` が `temporarilyUnavailable`、`errSecItemNotFound` が `integrityFailure` になること**
- **端末ロック中の Keychain 読み取り失敗で台帳が `lockedUntilReinstall` つきで消えないこと**
- **恒久的な鍵喪失で修復が走り、アプリが永久停止しないこと**
- **未知の `OSStatus` が `temporarilyUnavailable` へ倒れ、懲罰側にならないこと**
- **ファイルを読み切れない I/O エラーと鍵取得の失敗だけが `temporarilyUnavailable` になること**
- **台帳が `valid` でないとき、`resolveCapabilities` へ渡す `unverifiedLedgerWrites` が上限値（2000）であり 0 でないこと**
- **台帳修復が `transact` を通らず `ProtectedBlobStore.save` を直接呼ぶため、保存直前の +1 が適用されないこと**
- **`unverifiedLedgerWrites` が `UsageLedger`（署名対象）にあり、DB 改変で書き換えられないこと**
- **修復が `UsageLedgerStore.repairLedger(evidence:)` を通り、`transact` と同じ待機キューを取ること**
- **`transact` の保存と修復が並行しても、どちらかが他方を上書きしないこと**
- **2 つの読み取り主体が同じ `integrityFailure` を観測しても修復が 1 回だけ走ること**（排他区間の内側で読み直す）
- **台帳修復の直後に `unverifiedLedgerWrites == 2000` / `ledgerWritesSinceConfigFetch == 4000`（どちらも上限値）となること**
- **修復が `SubscriptionState` blob を削除しないこと**（Free 利用者がオフラインで無料枠ごと止まる経路を作らない）
- **修復直後・オンラインで、`requestDate` が前進した取得に成功すれば Standard / Pro が月間枠に依存せず書き出せること**
- **修復直後・オフラインでは有料利用者が書き出せないこと**（受容する挙動。再検証まで `verificationRequired`）
- **修復直後・オフラインでも Free 利用者は月間枠の封鎖以外の理由で止まらないこと**（鮮度判定が有料能力にしか掛からない）
- **通信を遮断したまま台帳を繰り返し壊しても、毎回上限値が入るため有料能力を延命できないこと**
- **HMAC 鍵だけを失った有料利用者が、オンライン復帰後に書き出せること**（`integrityFailure` として修復されても袋小路にならない）
- **カウンタが低い時点の `valid` な台帳 blob へ巻き戻すと `integrityFailure` にならず修復も走らないこと**（9.3 が対象外と宣言した blob リプレイであることを退行テストとして記録する）
- **判定が `>= 2000` であること**（境界を含む）
- **導出した `ResolvedCapabilities` が有料能力を 1 つも含まないキャッシュには鮮度判定が掛からず、オフラインのまま台帳を 2000 回以上書いても無料枠の範囲で書き出せること**
- **判定キーが `plan != .free` ではなく導出後の能力であり、`plan == .free` に有料相当の能力を追加しても鮮度免除が穴にならないこと**
- **`plan != .free` のキャッシュでのみ鮮度切れが起き、`verificationRequired` になること**
- **`resolveCapabilities` が `unverifiedLedgerWrites` を引数で受け取り、台帳から読んだ値で判定すること**
- **`ledgerWritesSinceConfigFetch` が同じ `transact` で `unverifiedLedgerWrites` と同時に +1 されること**
- **`ledgerWritesSinceConfigFetch >= 4000` で last-known-good が失効し、機能停止フラグ以外がバンドル既定値へ戻ること**
- **通信を遮断し端末時計を据え置いても、高い `freeMonthlyExportLimit` を配信した設定が恒久化できないこと**
- **台帳修復の直後に `ledgerWritesSinceConfigFetch == 800`（上限値）となり、`RemoteConfigState` は削除されないこと**
- **そのため機能停止フラグが「期限切れ」として保持されること**（削除ではなく期限切れ扱い）
- **購入状態キャッシュが `expiresAt` 超過または `lastVerifiedAt` から 14 日超で `verificationRequired` になること**
- **`isSandbox` では 1 日で鮮度切れになること。能力そのものは本番と同じに解決されること**
- **鮮度判定の基準が `trustedNow ?? usageNow` であり、端末時計の巻き戻しで延命できないこと**
- **`enabledStampPacks` のバンドル既定値が同梱パックの全 ID であり、`RemoteConfigState` を消しても空集合にならないこと**
- **`BatchPolicySnapshot` を DB から読んだ直後に hard max と最小値へクランプすること**
- **`BatchKind` の DB 列値が `proBatch = 1` / `trial = 2` に固定され、`case` の宣言順を変えても既存行の解釈が変わらないこと**
- **`kind` を `.trial` から `.proBatch` へ書き換えても、`batchSizeLimit` のクランプ先が 5 のままにならず 50 へ緩むこと**（クランプ表の挙動確認）
- **それでも処理できる相異なる素材が 5 枚を超えないこと**（`remainingCredits` と `trialEntries` が別に縛るため）
- **`kind` がクランプの対象外であり、記録用の値として保持されること**
- **`trialCreditCount` を 500 へ書き換えても `remainingCredits` が 5 を超えないこと**
- **月次更新の判定に `ledgerTimeZone` を使い、信頼時刻を得ない起動では端末のタイムゾーン変更に追従しないこと**
- **東向きのタイムゾーン変更だけでは `period` が前進しないこと**
- **`evaluate` と `rollPeriod` が `deviceTimeZone` を引数で受け取り、`ledgerTimeZone` を直接書き換えないこと**
- **`rollPeriod` の内部手順 2 で、`deviceTimeZone` で求めた年月が保持中の `period` と等しいときだけ `ledgerTimeZone` が更新されること**
- **等しくないとき（月境界をまたぐ変更）は更新が保留され、`period` が前進しないこと**
- **月中のタイムゾーン変更では更新され、往復させても純利得が 0 になること**
- **`evaluate` が `trustedNow` を受け取り、それを `ledgerTimeZone` の更新判定にのみ使い、封鎖の解除には使わないこと**
- `trialIntegrityLocked` のとき `remainingCredits` が 0 になり、トライアル画面へ進入できないこと
- `trialReservations` が残数計算に含まれること
- `batchTrial` が月間枠を消費しないこと
- 月間枠を使い切っていても、クレジットが残っていれば一括トライアルを開始できること
- 消費済みトライアル台帳に期限がなく、同じ 5 枚を繰り返し処理できること
- トライアル中のエフェクト利用範囲が、そのときの `ResolvedCapabilities` と一致すること
- `batchTrial(false)` でも `GrantAction.ensure` になること
- `freeMonthlyReexport` の `grantAction` が `preserveAuthorized` になること
- 破棄しても無料枠とトライアルクレジットが戻らないこと
- 顔 0 件の案内が `QuotaDecision` で分岐すること（[アーキテクチャ設計](architecture.md) の 6.1）

### 2.2 素材同一性（[アーキテクチャ設計](architecture.md) の 6.4）

- **`SourceIdentity` 同士の直接比較を使わず、`sourceID`（alias グラフの連結成分）で同一性を判定していること**
- **provider 一致と content 一致が別レコードを指す場合に、1 件へ統合されること**
- **統合時に最も古い `firstSuccessAt` が維持され、トライアルが消費済みへ倒れること**
- **統合時に `grants` / `trialEntries` / `trialReservations` / `sourceLeases` のすべてが勝者 `sourceID` へ書き換わること**
- **`SourceRecord` が grant / trial / reservation / lease / `projectSourceSnapshots` のどれからも参照されなくなった場合だけ削除されること**
- **snapshot の `identity` が alias を共有する `SourceRecord` が GC されないこと**
- **素材同一性の照合が alias グラフの連結成分で行われ、`SourceIdentity` の直接比較を使わないこと**
- **`provider = P1, content = F1` の素材が `P1, F2` として再取得され、その後 `nil, F2` で再選択されたときに一致すること**
- **一致した再選択・再接続で、候補の alias が同じ `SourceRecord` へ追加されること**
- **`SourceLease` が `accountingMode` を持ち、統合時に勝者 `sourceID` へ書き換わっても保持されること**
- **`paidUnlimited` の書き出し中に `SourceRecord` が GC されないこと**（`SourceLease` が効いていること）
- 台帳の**全不変条件**が、保存前と署名検証直後の両方で検査されること
- **同じ `sourceID` の `SourceLease` が 2 件以上あるとき、通常状態として通さず復旧エラーになること**
- `contentFingerprint` が**ドメイン分離子 `content-fingerprint-v2` をファイル全バイトの前へ置いた SHA-256** であること
- **中央部分だけが異なる 2 ファイルが、別の `contentFingerprint` になること**（部分ハッシュでは衝突する素材で検証する）
- ファイル全体をチャンク読みで投入しても、一括読み込みと同じダイジェストになること
- **撮影日時が `OriginalCaptureMetadata` として別に保持され、`contentFingerprint` の入力に入らないこと**
- **撮影日時の取得元が EXIF のみであり、PhotoKit 権限の有無で変わらないこと**
- ファイル更新日時を使わないこと
- `representation` が `contentFingerprint` の入力に含まれないこと
- `BatchSelectionClassifier` が alias の共有関係を推移的に閉じ、選択中の重複を畳むこと
- **`SourceRecord` があっても `TrialEntry` が無ければ「新規」と分類されること。** 単体書き出しの grant・認可中の lease・有料書き出し中の参照だけでは消費済みにならない
- **`TrialEntry` があれば「消費済み」と分類されること**
- **`TrialReservation` のみの素材が「新規枠を占有中」として扱われ、残数計算と分類で二重に数えられないこと**
- **実行直前の再検証が、選択画面と同じ `trialEntries` の条件を使うこと**
- **`contentFingerprint` がファイル全体の SHA-256 のみから決まり、ファイルサイズと撮影日時を混ぜないこと**
- **EXIF に `OffsetTimeOriginal` が無いとき、端末タイムゾーンで補完しないこと**
- **`ContentFingerprint` / `StampAssetHash` が 32 バイト固定であること**
- **provider alias が得られる場合、OS がトランスコードした写真を新規素材として数えないこと。得られない場合は余分に消費しうることを設計上許容する**

### 2.3 レビュー状態とトリアージ（[アーキテクチャ設計](architecture.md) の 6.1 / 6.5）

- `triage`（6 つの要確認理由の各単独・複合、空集合）
- `triage` の入力が [画像処理](image-pipeline.md) の 1 章の共通モデル（`DetectedFace`）だけであること。OS 固有の値に依存しないこと
- `ReviewIssue` が**発生単位**で列挙され、小さい顔が 3 人なら 3 件になること
- **`lowConfidence` が顔ごとに 1 件の `ReviewIssue` になること**
- `ReviewIssueID` が `detectionRevision` を含み、`overlappingFaces` では顔 ID が辞書順に並ぶこと
- **`ReviewIssueID` が `projectID`（`ProjectID` 型）を含み、同じ revision の別写真の `noFaceDetected` が別 ID になること**
- **書き出し認可が `DetectionStatus` を保存値ではなく `triage` の再実行で再導出すること**
- **`FaceTrack` が `confidence` / `yawDegrees` / `pitchDegrees` / `rollDegrees` / `isSmallFace` を列として持ち、`triage` を再実行できること**
- **`triage` 再導出と `ReviewDecision` 再検査が、書き出し Saga の認可検査一覧にも記載されていること**
- **`ReviewDecision` の完全性を認可時に再検査し、`ReviewStatus` を DB 改変で `reviewed` にしても開始できないこと**
- **`noFaceDetected` の写真は `unmaskedExportConfirmed` 相当の記録が無いかぎり開始できないこと**
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
- 顔の初期状態が常に加工対象であること（[アーキテクチャ設計](architecture.md) の 6.1 の不変条件）
- 背景処理の変更で `reviewed` が解除されること。メタデータ設定の変更では解除されないこと
- `requiresUserReview` の導出がモードで異なること。1 枚ずつ確認では `normal` の未確認写真も含むこと
- 確認状態の解除が変更範囲に限定されること。`hasOverride` の写真が共通設定変更で `unreviewed` にならないこと
- `overviewConfirmed` が、匿名化結果または構図に影響する変更で必ず `false` になること
- 共通設定の変更が `hasOverride` の立った写真へ波及しないこと。全上書きが確認を経ること
- 書き出しの成立条件がモードごとに異なること。1 枚ずつ確認では末尾到達と確認ボタンを求めないこと
- 確認段階から設定へ戻っても検出結果が保持されること。この経路で写真の選択を変更できないこと

### 2.4 バッチ選択と能力（[アーキテクチャ設計](architecture.md) の 6.2 / 6.5）

- トライアルの選択判定が「総枚数 5 枚」と「新規写真 ≤ 残クレジット」の 2 条件であること。残 0 枚でも消費済みの写真は選べること
- `canEnterBatch` が `canUseProBatch` / `canUseBatchTrial` / `trialIntegrityLocked` / 残数 / entry の有無から導かれること
- `canUseProBatch` / `canUseBatchTrial` が能力で判定され、`plan = pro` かつ `status = pending` が通常一括にならないこと
- 消費済みの写真だけで 6 枚選ぼうとしたとき `batch-size` が発火すること
- 50 枚超過が `batch-limit` であり、アップグレード誘導を伴わないこと
- `resolve(snapshot:usageNow:)`（仕様 27.4 の全購入状態）
- `plan = standard` かつ `status = pending` で `singleExportAccess == .metered` になること
- `CapabilityResolution.verificationRequired` で書き出し認可が開始されず、Free 降格の表示も出ないこと
- キャッシュ `missing` かつオフラインで `verificationRequired` になること
- **`temporarilyUnavailable` かつメモリ上に検証済み `Entitlement` が無い（コールドスタート）とき `verificationRequired` になること**
- **メモリ上に検証済み値があるときは維持されること**
- `canEdit` が能力で判定され、`requiredPlan` の戻り値比較で可否を決めないこと
- バッチ内の 1 枚を単体編集するとき `canEdit` に従うこと
- `requiredPlan` が設定内容から導かれ、作成時のプランに依存しないこと
- 降格後の再書き出しでも `freeReexport` が成立し、24 時間以内なら消費しないこと
- Free 範囲のプロジェクトが Free で編集・書き出しできること
- 降格後の操作可否が 6.2 の表と一致すること
- 追加スタンプとカスタムスタンプで、降格後の再書き出し可否が同一であること
- 広告表示頻度の判定（表示禁止条件、初回書き出し、連続表示の抑止）

### 2.5 レンダリング（[画像処理](image-pipeline.md) の 2 / 4）

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
- **`cellSizePx` が `floor(cellRatio × 領域短辺)` で求まり、1 以下なら 2 へ引き上げられること。引き上げても領域が 2px 未満なら `throw` すること**
- **`VisibleColor` が `SrgbArgb8888` の別名であり、アルファ 0 が initializer で拒否されること**
- **`MosaicRatio` / `BlurRatio` / `FeatherRatio` / `ExpansionRatio` / `NormalizedRect` が `throws` の initializer だけを公開し、`NaN` と範囲外を拒否すること**
- **`RenderOpSpec` / `RenderOp` / `RenderOpDraft` に生の `Double` が残っていないこと**
- **`NaN` や無限大の座標が `throw` されること**
- **完全に透明なカスタムスタンプ画像が取り込み時に拒否されること**
- **`isMasked == true` の顔に no-op 相当の値が渡されたとき `compileRenderDraft` が `throw` すること**
- **`authorizeRenderSpec` が有料スタンプを含む `RenderSpec` を `canUsePremiumStamps == false` で `blocked` にすること**
- **`authorizeRenderSpec` が手順 −2 と手順 1 の直前の 2 回評価され、`prepared` で停止中に `EffectSetting` を書き換えても手順 1 で検出されること**
- **`projectRevision` を据え置いた改変でも検出されること**
- **`enabledStampPacks` が `ResolvedCapabilities` にあり、`Domain` が `RemoteConfig` を参照しないこと**
- **バッチの 1 項目が `blocked` のとき `failed(capabilityRequired)`（`isRetryable == false`）へ遷移し、バッチの完了判定が成立すること**
- **`premiumStampNotAvailable` / `customStampNotAvailable` でのみ Paywall が提示されること**
- **`unknownBuiltInStampCode` では Paywall を提示せず、`capabilityRequired` のエラーと設定変更の誘導になること**
- **`RenderSpecBlockReason` が 3 case であり、`disabledStampPack` を持たないこと**
- **`authorizeRenderSpec` が `enabledStampPacks` を見ないこと**
- **運用側がパックを無効化しても、そのパックを使う既存プロジェクト（確定記録の有無を問わず）が再書き出しできること**
- **無効化したパックのスタンプを新規に選択できないこと**（UI 側の制約）
- **`RemoteConfigState` を削除しても書き出しの可否が変わらないこと**
- **`settingsEntryToApply.settingsHash` が手順 −2 の `ExportInputSnapshot.projectSettingsHash` から持ち回られ、手順 3 で再計算されないこと**
- **手順 2 の `fileVerified` で停止中に設定を有料スタンプへ書き換えても、手順 1 の再評価のハッシュ照合で検出されロールバックへ入ること**
- **能力要件に影響しない設定変更（領域の縮小・`cellRatio` の最小化・`isMasked` の解除）も、ハッシュ照合で検出されること**
- **「変更せず再書き出し」の免除が `exportedSettingsEntries` の確定記録のみを根拠とし、`pendingExportedSettingsEntries` では成立しないこと**
- **免除の適用範囲が有料スタンプの能力要件に限られ、クォータと開始ゲートを免除しないこと**
- **降格した利用者が既存作品を変更せず再書き出しできること**
- **カスタムスタンプを `canUseCustomStamps == false` で `blocked` にすること**
- **`StampCatalog` に無い `code` を `blocked` へ倒し、無料扱いにしないこと**
- **`enabledStampPacks` に無いパックのスタンプでも `authorized` になること**（認可は見ない。新規選択のみ UI が禁じる）
- **`EffectSetting` を DB 直接改変で有料スタンプへ書き換えても、手順 −2 の認可で開始が止まること**
- **`StampCatalog` の分類がリモート設定から変更できないこと**
- 永続データのデコード時にも検証済み値型の `throws` 版が呼ばれること
- **境界型（`ImageSource` / `LoadedPhoto` / `DetectionResult` / `RenderedImage` / `OutputFile`）が `URL` もパス文字列も持たないこと**
- **`ImageSource` に未正規化を表す値が存在しないこと**（`OrientationState` を持たない）
- **`ExportCommit.outputFile` / `OutputRecord.outputFile` が `OutputFileRef`、`WorkingSourceRecord.sourceFile` が `WorkingSourceFileRef`、`RasterizedStampAsset.rasterFile` が `RasterFileRef` であること**
- **`RasterizedStampAsset` が `pixelSize` / `rowBytes` を重複して持たず、`descriptor` だけを持つこと**
- **`YearMonth` / `TrustedUTCMonth` の実型が `Int32` であること。`FaceTrackID` が `UUID` であること**
- **`RenderedImage` と `RasterizedStampAsset` が `RawBitmapDescriptor` を持ち、チャネル順・アルファ・色空間・bit depth が型で決まること**

### 2.6 設定ハッシュと正準化（[アーキテクチャ設計](architecture.md) の 6.4、[正準スキーマ](canonical-schema.md) の 5.2）

- 設定ハッシュが `Map` のキー順・**`Double.bitPattern`（64 ビット）**・内容ハッシュ参照で正準化され、DB ID に依存しないこと
- **`Float` へ丸めた場合に区別できなくなる 2 つの `Double` が、異なる設定ハッシュになること**
- **`RotationDegrees` が `[-180, 180)` へ正規化され、`370` と `10` が同じ設定ハッシュになること**
- `-0.0` が `+0.0` へ正規化されること
- プロジェクト設定ハッシュの一致判定により、Free の「変更せず再書き出し」が許可されること
- **`ExportedSettingsEntry` が署名済み台帳にあり、未署名の DB 行を書き換えても判定が変わらないこと**
- **正常書き出しの記録が無いプロジェクトが「変更せず再書き出し」の対象外になること**
- **`PreviewRenderHash` に圧縮品質とメタデータ設定が含まれないこと。それらを変えても確認の一致が崩れないこと**
- **`renderRevision` を上げると `PreviewRenderHash` が変わること**
- **2 つのハッシュがそれぞれ `project-settings-v1` / `preview-render-v1` のドメイン分離子を先頭に持ち、`payloadType` / `schemaVersion` を前置きしないこと**
- **同じ入力バイト列でも分離子が違えば別のハッシュになること**
- **`signedBytes` が `BE32(payloadType) || BE32(schemaVersion) || payloadBody` であり、`payloadBody` に先頭値が含まれないこと**
- **blob の外部形式が `BE32 || BE32 || BE64(length) || payloadBody || signature` であり、全体長が一致しなければ署名検証まで進まないこと**
- **`payloadType` が読み出そうとした `ProtectedBlobKey` の型と違えば破損として扱われること**
- **長さフィールドを改変するとファイルサイズとの照合で弾かれること**
- **`PreviewConfirmation` が `projectID` / `detectionRevision` / `previewRenderHash` を持ち、`projectRevision` を含まないこと**
- **同じ設定・同じ領域の別 `Project` で `previewRenderHash` が一致しても、`projectID` の不一致で開始できないこと**
- **`BatchReviewState` が `batchID` を持ち、別バッチの確認状態を流用できないこと**
- **圧縮品質・メタデータ設定だけを変えて `projectRevision` が増えても、書き出しの開始条件が崩れないこと**
- **手動領域の追加・削除では `previewRenderHash` が変わり、開始条件が崩れること**
- **`PreviewConfirmation` と `overviewConfirmed` が再起動後に保持されず、再確認を求めること**
- **出力へ影響する子行（`FaceTrack` / `EffectSetting` / `ExportSetting` / `ProjectStampAsset`）の変更で、同一トランザクション内に `projectRevision` が増えること**

### 2.7 HMAC canonical bytes のゴールデンテスト（[正準スキーマ](canonical-schema.md) の 6）

**各 `schemaVersion` について、固定の canonical bytes と HMAC 値をテストへ埋め込みます。**

| 検証 | 目的 |
| --- | --- |
| 既知の値から生成した canonical bytes が、期待するバイト列と一致する | 符号化の変更を検出する |
| 固定鍵で計算した HMAC が、期待する値と一致する | 署名の互換性を検出する |
| 集合の構築順を変えても同じバイト列になる | unordered の分類が正しい |
| ordered 配列の順序を変えると別のバイト列になる | ordered の分類が正しい |

対象 payload は `UsageLedger` / `SubscriptionState` / `ExportCommit` / `RemoteConfigState` / `TrustedTimeState` の 5 種すべて。

### 2.8 更新誘導（[アーキテクチャ設計](architecture.md) の 6.7）

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
- `canDeleteHistoryUnit` が列挙された全参照元を見ること（[アーキテクチャ設計](architecture.md) の 7.5）
- **絶対保護（非終端キュー項目 / `ExportCommit` 行の存在（`published` を含む）/ `isUndelivered` の `OutputRecord`）が、手動削除でも拒否されること**
- **お気に入り・編集中・`WorkingSourceRecord`・24 時間保証が、自動削除では保護され、明示確認付きの手動削除では上書きできること**
- **上書き対象ごとに、失われるものを示す確認文言が選ばれること**
- 未保存バッチが 1 件までに制限されること
- 一括処理の開始が推定必要容量の 1.2 倍の空き容量を要求すること
- 未保存出力がある状態では、単体・一括を問わず新規加工を開始できないこと
- 完了画面の離脱確認が `isUndelivered`（`generated` と `deliveryUnknown`）の残数で判定されること。一部保存済みでも出ること
- 復旧案内の枚数が `isUndelivered` の枚数であり、バッチ総枚数ではないこと
- 共有結果が `.completed` のときだけ `delivered` へ遷移すること。`.unknown` では維持されること
- リモート設定のフォールバック

---

## 3. application saga test

偽 DB・偽 `ProtectedBlobStore`・偽ファイル・偽 `ProtectedDataAvailability` を注入し、**各中断点**での挙動を検証します。実ストレージの原子性は検証しません（4 章の役割）。

### 3.1 コミット Saga

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
- 手順 6 の失敗時、ロールバックが `rollingBack` → 台帳 → ファイル → コミット → ゲートの順で実行されること
- ロールバックの手順 1（台帳の取り消し）が失敗した場合、コミットとファイルが残り復旧エラーになること
- 手順 9 の完了後にファイルを失っても、月間枠・grant・トライアルが戻らないこと
- 手順 9 完了後の Export A のファイル欠損で、同一素材を再書き出しした Export B の grant が消えないこと
- 生成完了後の異常終了では消費が戻らないこと
- 消費確定が手順 7 であり、保存や共有の回数に影響されないこと
- **`unavailable` のまま復旧を開始した場合に待機へ入ること**（[アーキテクチャ設計](architecture.md) の 7.4）

### 3.1.1 v1 で追加した中断点

- **`prepared` の `outputFile` が `nil` であり、`fileVerified` 以降は `OutputFileRef` が入っていること。手順 2 で `verifiedOutput` と同時に確定すること**
- **手順 7 が `published` を書き、コミット行を削除しないこと**
- **`finalizeExport` がコミットを削除せず、`deletePublished` が手順 9 で削除すること**
- **`deletePublished` が HMAC と `state == published` を再検査すること。呼び出しが手順 8 の台帳保存成功後に限られること**
- **`published` 以外の `state` で `deletePublished` が throw すること**
- **`published` から手順 8・9 を冪等に再実行でき、手順 3 へ戻らないこと**
- **ロールバックが手順 0 で `rollingBack` を書き、手順 1 完了後・手順 4 前の強制終了でも前進せずロールバックを再実行すること**
- **`rollingBack` から `readyToPublish` へ戻す DB 改変が行 HMAC で弾かれること**
- **`readyToPublish` でキャンセル要求を受けたとき、同一プロセス内でも `rollingBack` へ遷移し手順 7 を実行しないこと**
- **手順 8 が 4 回以上失敗したとき、pending を削除して手順 9 へ進み、アプリが止まらないこと**
- **その場合に成果物と会計が影響を受けず、「変更せず再書き出し」だけが成立しなくなること**
- **`UnknownLibrarySave` の追加が upsert であり、同じ `exportID` の再挿入で手順 7 が失敗しないこと**
- **`finalizeExport` が同じ `projectID` の `OutputRecord` の存在を事前検査し、手順 4 まで進んでから制約違反にならないこと**
- **`published` で 2 つ目の `OutputRecord` が作られないこと**
- **ゲートの解放が手順 9 またはロールバック完了であること**
- **手順 1 の途中で落ちた一時ファイルが、どのコミットからも参照されず孤児 GC で回収されること**
- **`FinalizeExportInput` が `exportID` と `queueItemID` の 2 つだけであり、`OutputRecord` / `ExportRecord` / `Project.updatedAt` を保存済みコミットから導出すること**
- **`queueItemID` が別 `Project` のキュー項目を指す場合に throw すること。`projectID` / `batchID` / `state == .exporting` をすべて検査すること**
- **単体書き出しで `queueItemID != nil` なら throw すること**
- **`loadSignedCommitRows` が手順 2 で、`loadRecoverySnapshot` が手順 2.8 で、`loadPostCommitRecoverySnapshot` が手順 4.2 でそれぞれ 1 回だけ呼ばれること。`checkForeignKeys` が復旧後に別途呼ばれること**
- **`ExportCommitColumns` が生のバイト列であり、署名検証前に `ProjectID` などへデコードされないこと**
- **手順 7 が `WorkingSourceRecord` を同一トランザクションで削除し、実体を `PendingFileDeletion` へ積むこと**
- **`AccountingIntent.settingsEntryToApply` が手順 4 で `pendingExportedSettingsEntries` へ入り、確定側へは入らないこと**
- **手順 8 で `ownerExportID` が一致する pending だけが確定側へ昇格すること。既に昇格済みなら何も起きないこと**
- **ロールバックが `ownerExportID` の一致する pending を削除し、確定側に触れないこと**
- **署名不正コミットの破棄でも pending が削除されること**
- **`published` へ到達していないコミットの pending が、起動時の手順 5.5 で削除されること**
- **一度も成功していない設定が「変更せず再書き出し」の判定に使われないこと**
- **`AccountingApplied` を単独の根拠にしないこと。`applied` 未保存で落ちても正しくロールバックできること**
- **`ProjectSourceSnapshot` が書き出しで追加も削除もされず、ロールバックの対象にもならないこと**
- **台帳を修復した起動では、署名が正常な非終端コミットも含めてすべて破棄され、キュー項目が `failed(ledgerRepaired)` になること**
- **`loadPostCommitRecoverySnapshot()` が手順 4 の完了直後に 1 回だけ呼ばれること**
- **`readyToPublish` から復旧して作られた出力が、手順 7.5 の復元対象と手順 8 の件数に含まれること**
- **手順 7 で削除された `WorkingSourceRecord` が、手順 4.5 の照合対象から外れていること**
- **`loadRecoverySnapshot()` が手順 2.8（手順 2.5 の後）で実行され、修復で破棄したコミットを手順 4 が復活させないこと**
- **`ExportCommitState` の固定番号が `published = 6` / `rollingBack = 7` であり、既存の `published` 行が `rollingBack` としてデコードされないこと**
- **状態別のロールバック経路がすべて手順 0（`markRollingBack`）を通ること。`finalizing` からのキャンセルでも前進しないこと**
- **`markRollingBack` が `published` / `rollingBack` に対して throw すること**
- **手順 8 が保護データ利用不可では諦めず、`waitUntilAvailable()` で待って再試行すること**
- **同一プロセス内 4 回目で諦め、起動時復旧では回数を引き継がず改めて 3 回試すこと**
- **`deletePublished` の事前条件が「pending が解消していること」であり、昇格と削除のどちらでも満たされること**
- **署名不正行がある間、手順 5.5 が `Project` 不在を理由とする pending 削除も行わないこと**
- **`(lease 1 / pending 1)` で復旧エラーが維持され、利用者が「すべて破棄して続ける」を選べること**
- **「すべて破棄して続ける」で、`accountingMode == .freeMonthlyConsume` の孤立 lease の `exportID` が `consumedExportIDs` へ入り、消費が確定すること**
- **`paidUnlimited` / `trialCredit` の孤立 lease では `consumedExportIDs` が変わらないこと**
- **コミット行を任意に削除して孤立 lease と孤立 pending の個数を作っても、`freeMonthlyConsume` の消費が回避できないこと**
- **「すべて破棄して続ける」が台帳の保存成功を確認したあとに、署名不正行を行 ID だけで削除すること**
- **削除しない実装では次回起動で同じ復旧エラーへ戻ることを、退行テストとして押さえること**
- **署名不正行が残る間に複数の `Project` を削除しても、孤児 pending が複数残ることが不変条件違反として扱われないこと**
- **手順 8 の昇格が継続的に失敗しても、手順 4 が「完了」として扱われ、手順 4.2〜9 が実行されること**
- **その状態で手順 7.5 が未受け渡し出力を復元し、手順 9 が通常画面を表示し、新しい書き出しが許可されること**
- **コミットが `published` のまま残り、次回起動の手順 4 が昇格を再試行すること**
- **`AppLifecycle` の挿入が手順 9 で行われ、手順 9 に到達しない起動では書かれないこと**
- **手順 5.5 の孤児 binding 判定が 4.2 の snapshot ではなくその時点の DB を読むこと**
- **同じ起動で `WorkingSourceRecord` もすべて破棄され、実体が `PendingFileDeletion` へ積まれること**
- **その破棄が署名不正行の規則（行 ID だけで削除し、フィールドを使わない）と同じ手順で行われること**
- **その破棄で `UsageLedger` へ触れないこと（整合性封鎖のまま）**
- **修復後の台帳で `exportedSettingsEntries` と `projectSourceSnapshots` が空になり、既存 `Project` が削除されないこと**
- **修復後は「変更せず再書き出し」が成立せず、新規プロジェクトとして通常の消費になること**
- **修復対象のキュー項目が `failed(ledgerRepaired)` になり、`paused` にならないこと**
- **`failed(ledgerRepaired)` が再試行不可（`isRetryable == false`）であること**
- **修復後の既存 `Project` が閲覧と削除だけ可能で、再接続を試みられないこと**
- **`SignedCommitRow.schemaVersion` から正準バイト列を再構築でき、`delivery` を含む全署名対象が列として読めること**
- **`delivery` を書き換えた行が署名検証で不正になること**
- **`DeliveryAttempt` が残った起動で、`previousState == .generated` なら `deliveryUnknown` になり、自動再保存しないこと**
- **`previousState == .delivered` なら `delivered` を維持し、写真ライブラリ保存の結果不明を別途提示すること**
- **共有成功 → 写真ライブラリ保存中に強制終了 → 再起動、で `delivered` が後退しないこと**
- **通常の保存失敗で `previousState` へ戻ること**
- **汎用の状態更新メソッドが存在せず、`delivered` → `generated` の遷移を呼び出せないこと**
- **同じ `exportID` の受け渡し操作が直列化され、`actor` の再入で並行しないこと**
- **写真ライブラリ保存の待機中に共有・破棄・別の保存が拒否されること**
- **保存待機中に共有が成功して `delivered` になった場合でも、保存失敗の `abandonDeliveryAttempt` が `generated` へ戻さないこと**
- **`completeLibrarySave` が `DeliveryAttempt` を削除し、`completeShare` は関与しないこと**
- **`delivered` 維持で `UnknownLibrarySave` が永続化され、再度の異常終了後も案内が残ること**
- **注記のある `delivered` 出力が起動時に削除されず、ファイルが保持されること**
- **`loadUnknownLibrarySaves()` で起動時に注記を取得できること**
- **`requiresDeliveryAttention` が `OutputDeliverySnapshot` 上にあり、`OutputRecord` 単体では判定できないこと**
- **保持条件に `requiresDeliveryAttention`、件数に `isUndelivered` が使われ、混同されないこと**
- **注記付き出力も 24 時間で削除され、その際に通知しないこと**
- **利用者が確認すると `UnknownLibrarySave` が消え、`OutputRecord` 削除でも CASCADE で消えること**
- **`resolveOrphanedAttempts()` が起動時復旧の手順 7 で必ず呼ばれ、解決後の全 `OutputDeliverySnapshot` を返すこと**
- **手順 7.5 と 8 が `PostCommitRecoverySnapshot` ではなく手順 7 の戻り値を使い、手順 4 で作られた出力と手順 7 の解決結果の両方が反映されること**
- **`deliveryUnknown` が未受け渡しとして 24 時間の保持と離脱確認に数えられること**
- **`OutputRecord` の `format` / `suggestedCreationDate` から `OutputFile` を復元でき、`Project` の現在値を参照しないこと**

### 3.2 認可とゲート

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
- 実行開始の直前に最新台帳で選択を再検証し、分類が変わっていれば開始しないこと（[アーキテクチャ設計](architecture.md) の 6.5）

### 3.3 署名不正コミット

- `ExportCommit` の署名検証失敗が復旧エラーになり、自動破棄されないこと
- 復旧エラーを「破棄して続ける」で解除でき、孤立 lease が 1 件なら `accountingMode` に従って消費を確定した上でコミットが削除されること
- **`freeMonthlyConsume` の孤立 lease で `consumedExportIDs` へ追加されること。** 手順 4 より前にコミットを壊しても月間枠が消費されること
- **`batchTrial(true)` では予約が `TrialEntry` へ変換されること**
- **`paidUnlimited` / `freeMonthlyReexport` / `batchTrial(false)` では追加消費が起きないこと**
- **`consumedExportIDs` への追加が冪等であること**
- 孤立 lease が 2 件以上なら復旧エラーを維持し、台帳へ触れないこと
- **署名不正行の `outputFile` / `projectID` / `exportID` が参照されず、他の正常な出力と履歴が削除されないこと**
- **孤立 lease 1 件・孤立 pending 0 件で消費が確定し、pending は作られないこと**
- **孤立 lease 0 件・孤立 pending 1 件で pending が削除され、確定側へ昇格しないこと**
- **孤立 lease 0 件・孤立 pending 0 件で台帳が 1 バイトも変わらないこと**
- **署名不正行がある間、手順 5.5 が孤児 pending を削除しないこと**
- **そのため `(lease 1 / pending 1)` が `(1 / 0)` に見えず、復旧エラーが維持されること**
- **「破棄して続ける」の完了後に、保留していた手順 3 と 5.5 の孤児回収が実行されること**
- **回収前に新規認可が許可されず、空いているクレジットが「使用中」と判定されないこと**
- **孤児 pending の判定が「コミット行が存在しない」であり、復旧エラーで残った有効コミットの pending を消さないこと**
- **lease と pending がともに 1 件ある場合に復旧エラーが維持されること**
- **署名不正行がある間、孤児予約と孤児 lease の自動回収が保留されること**

### 3.4 コミット確定後の実体喪失

- **実体が無い、または記録値と一致しないとき、`OutputRecord` を削除すること**
- **`UsageLedger` を 1 バイトも変更しないこと**（月間枠・grant・トライアルのいずれも戻さない）
- **`retentionNow == nil` の間は削除も判定も保留すること**
- **自動再生成を行わないこと。** 利用者へは新しい書き出しとして案内すること
- 24 時間以内の同一素材なら、やり直しが `freeMonthlyReexport` になること

### 3.5 トライアル予約（[アーキテクチャ設計](architecture.md) の 6.3）

- 残 1 枚で異なる素材の 2 件が並行認可されても、両方が `batchTrial(true)` にならないこと
- 予約が手順 −2 で作られ、手順 4 の台帳トランザクション内で `trialEntries` へ移ること
- 手順 0 の `prepared` 保存失敗で、補償トランザクションが**予約・`SourceLease`・未参照 `SourceRecord`** をすべて取り消すこと
- 同じ素材が `trialEntries` と `trialReservations` の両方に存在しないこと
- 同じ素材の再書き出しでトライアルクレジットが二重に減らないこと
- **中止時点で手順 7 が未完了の写真は消費せず、既に手順 7 まで完了した写真のクレジットは戻らないこと**
- **`BatchPolicySnapshot` が開始時の値を保持し、再起動後もリモート設定の変更で動かないこと**

### 3.6 保護ストアの読み込み失敗（[アーキテクチャ設計](architecture.md) の 7.2）

- `UsageLedger` の署名検証失敗時、修復済み台帳が作られ、信頼できる時刻を得るまで月間枠が封じられ、トライアルは封じられたままであること
- 修復済み台帳の `trialReservations` / `sourceRecords` / `sourceLeases` が空であること
- `missing` で通常台帳が作られ、初回起動の利用者が封鎖されないこと
- `temporarilyUnavailable` で台帳が上書きされず、書き出し開始が保留されること
- `SubscriptionState` の署名不正時、オフラインで有料権限が新規付与されず、カスタムスタンプと履歴が削除されないこと

### 3.7 出力の寿命と履歴（[アーキテクチャ設計](architecture.md) の 7.5）

- `OutputRecord` が `ExportCommit` 削除後も単独で期限判定できること
- 未受け渡しの出力が破棄または 24 時間経過まで保持されること
- 受け渡し成功後も完了画面を離れるまで出力が保持され、保存と共有を任意の順序で実行できること
- 異常終了後の起動時、`isUndelivered` では復旧案内が出て、`delivered` では出ないこと
- 「履歴を保存しない」設定で、未受け渡し出力・注記付き `delivered` 出力・`UsageLedger`・未完了 `ExportCommit`・トライアル用 `SourceRecord` の 5 つ以外が残らないこと
- `canDeleteHistoryUnit` が**列挙された全参照元**を保護すること
- **`Batch` 削除が所属する全 `Project`・キュー項目・`ExportRecord` を 1 トランザクションで削除し、台帳側も全 `projectID` 分を 1 トランザクションで削除すること**
- **`deleteHistoryUnit` が `DeletionContext` を受け取らず、DB トランザクション内で読み直して再判定すること**
- **`inspectDeletion` の後・削除の前に新しい `ExportCommit` が作られた場合、削除が throw すること**
- **`hasUndeliveredOutputRecord` が `delivered` の出力を保護せず、`isUndelivered` のみを見ること**
- **1 枚でも絶対保護に触れていればバッチ全体が削除されないこと**
- **編集中 `Project` の破棄が `WorkingSourceRecord`・binding・snapshot をすべて削除すること**
- `CustomStamp` を削除しても、それを使用したプロジェクトが再書き出しできること
- `StampAsset` が**最終保存バイト列**の内容ハッシュで重複排除され、参照カウントが 0 になったときのみ削除されること
- **`CustomStamp` の登録で参照が 1 増え、一覧削除で 1 減ること。一覧でしか使われていない実体が一覧削除で消えること**
- **1 プロジェクト内で同じスタンプを複数領域へ使っても `ProjectStampAsset` が 1 行であること。最後の 1 領域を外した時点で行が消えること**
- **保存値の `referenceCount` が導出値と一致すること。不一致なら導出値を正として書き直すこと**
- 一括削除が `CustomStamp` のみを対象とし、参照中の `StampAsset` を消さないこと
- 削除で DB が先に更新され、`PendingFileDeletion` が同じトランザクションへ記録されること
- `WorkingSourceRecord` の実体が欠けたとき、そのキュー項目が `paused(.sourceReselectionRequired)` へ遷移すること。バッチ全体が止まらないこと
- **`createdAt` から 24 時間で処理用ファイルと `WorkingSourceRecord` が削除され、キュー項目が `paused(.sourceReselectionRequired)` になること**
- **`ProjectSourceSnapshot` が署名済み台帳にあり、再起動後も `sourceID` を解決できること**
- **未署名の DB 行を書き換えても `SourceIdentity` が変わらないこと**
- **`ProjectSourceSnapshot` が、書き出しの完了でも処理用ファイルの 24 時間期限でも削除されないこと**
- **`WorkingSourceBinding` の更新が台帳先行、削除が DB 先行で行われること**
- **更新の中断（台帳のみ進んだ状態）が起動時に `paused(.sourceReselectionRequired)` へ倒れること**
- **削除の中断（DB のみ進んだ状態）が孤児 binding として手順 5.5 で回収されること**
- **`sourceFile` を別 `Project` の `.processingTemporary` ファイルへ差し替えると、起動時と書き出し開始時の両方で検出されること**
- **プレビュー・再検出・複製・サムネイル生成のいずれも `VerifiedWorkingSourceResolver` を経由し、`WorkingSourceRecord` を直接読まないこと**
- **`withVerifiedSource` が照合と利用を 1 つのスコープへ閉じ、`handle` を外へ持ち出せないこと**
- **`FaceDetector` / `ImageEffectRenderer` が `VerifiedImageSource`（`OpenFileHandle` を持つ）を受け取り、`ManagedFileRef` から開き直せないこと**
- **`FaceDetector` / `ImageEffectRenderer` / `PickedPhotoLoader` の宣言が文書内に 1 か所ずつしか存在しないこと**（旧署名の残置がないこと）
- **`PickedPhotoLoader.load` が `ManagedFileRef` を受け取るのは取り込み経路だけであり、既存 `Project` の素材読み込みに使われないこと**
- **`OpenFileHandle` が `Foundation` と標準ライブラリだけで宣言され、`CoreGraphics` / `CoreImage` の型を引数に持たないこと**
- **`withMappedBytes` が同期・非エスケープであり、`UnsafeRawBufferPointer` を `body` の外へ持ち出せないこと**
- **`withMappedBytes` が照合に使ったのと同じディスクリプタを `mmap` し、パスを再解決しないこと**
- **検出経路では `body` の内側で縮小デコードが完了し、返す `CGImage` が独自のバッファを持つこと**
- **書き出し経路では `body` の外へ圧縮バイト列の `Data` を返し、デコード済みピクセルを返さないこと**
- **`body` を抜けた後にマップ解除済み領域の読み取りが発生しないこと**
- **書き出し 1 枚のピーク使用量が約 192MB にならず、ファイルサイズ相当＋タイル処理分に収まること**
- **効果の合成とエンコードが `body` の外側で行われ、`render` の `async` 契約が保たれること**
- **同期区間がバイト列のコピー（または縮小デコード）だけであること**
- **48 メガピクセルの原寸を 50 枚処理しても、`Data` への全読み込みによるメモリ枯渇が起きないこと**
- **処理用素材のファイルが書き込み一度きりであり、既存 inode への追記・切り詰めを行う経路が存在しないこと**（`SIGBUS` の前提確認）
- **検出用の縮小が `FaceDetector` の内側でメモリ内に行われ、`.processingTemporary` の中間ファイルが作られないこと**
- **`LoadedPhoto` が `detectionSource` を持たないこと**
- **`DetectionResult.detectionPixelSize` が検出器の内部縮小後の実寸を報告すること**
- **再検出が `withVerifiedSource` → `VerifiedImageSource` → `detect` の 1 経路のみを通り、`PickedPhotoLoader` を経由しないこと**
- **再検出中に原寸を差し替えても、別の写真の顔座標が `FaceTrack` へ保存されないこと**
- **照合・レンダリング・完了後の再計算がすべて同一の `handle` を経由すること**
- **`body` の実行中に inode を差し替えても、消費側が旧 inode を読み続け、完了後の再計算が一致すること**
- **同じ inode への上書きが完了後の再計算で検出され、結果が破棄されること**
- **`WorkingSourceVerifier` が `projectID` ごとに直列化され、`SourceImportCoordinator` と待機キューを共有すること**
- **`HistoryDeletionCoordinator` が全体キューに加えて削除対象の各 `projectID` の待機キューを取得し、`projectID` の昇順で取得すること**
- **プレビュー描画中・再検出中に同じ `Project` の削除を要求しても、`body` の完了まで待たされること**
- **`Batch` 削除で複数の `projectID` を取得してもデッドロックしないこと**
- **`HistoryDeletionCoordinator` が `ExportStartGate` を取得しないこと**（2 つの全体キューを跨がない）
- **`body` の完了後に同じディスクリプタでハッシュを再計算し、不一致なら結果を破棄して `invalid(.contentMismatch)` を返すこと**
- **照合の通過後にファイルを差し替えても、その回の処理には反映されず、完了時の再計算で検出されること**
- **プレビューが 1 回の `withVerifiedSource` の内側で完結し、`VerifiedWorkingSource` を編集セッション中に使い回さないこと**
- **`invalidateWorkingSource` が `projectID` だけを受け取り、`reason` を受け取らないこと**
- **排他区間の内側で照合をやり直し、再判定で有効なら `nowValid` を返して破棄しないこと**
- **再選択が正常完了した直後に陳腐化した無効化が走っても、`WorkingSourceRecord` が破棄されないこと**
- **無効化が `SourceImportCoordinator` の `projectID` 待機キューで直列化され、同じ `Project` の再選択と並行しないこと**
- **`invalid(.recordMissing)` では無効化が走らず、再接続の導線になること。無効化が冪等であること**
- **起動後に差し替えた場合、次の読み取りで検出されて `paused(.sourceReselectionRequired)` になること**
- **「Free 版として複製」のコピー元が検証を通ること。差し替えた画像を新 `Project` の正規 binding にできないこと**
- **正規化ファイルの内容を書き換えると、ハッシュ不一致で検出されること**
- **検出時にその `Project` が `paused(.sourceReselectionRequired)` になり、他の項目が止まらないこと**
- **`WorkingSourceRecord` があって binding が無い状態が不変条件違反として扱われること**
- **`replaceWorkingSource` が置換対象を DB トランザクション内で読み、呼び出し側の値を使わないこと**
- **`replaceWorkingSource` が `createdAt` を `replacedAt` へ更新し、直後に 24 時間期限へ到達しないこと**
- **`WorkingSourceRecord` の有無で `replaceWorkingSource` と `attachWorkingSourceToExistingProject` が選ばれること**
- **24 時間経過して `paused(.sourceReselectionRequired)` になったあとも、再選択の照合が成立すること**
- **`Project` 削除でのみ snapshot が削除されること**
- **履歴の既存 `Project` へ `attachWorkingSourceToExistingProject` で再接続でき、別写真では拒否されること**
- **再接続が `detectionRevision` / `projectRevision` を増やし、検出結果を再利用しないこと**
- **照合に `ProjectSourceLocator` を使わないこと（ファイル取り込みで `nil` でも成立すること）**
- **再選択で素材が一致しない場合、そのキュー項目で続行できないこと**
- **再選択が顔検出をやり直し、`detectionRevision` と `projectRevision` を増やし、旧 `FaceTrack` / `ReviewIssue` / `ReviewDecision` / `ReviewStatus` を破棄すること**
- **`PreviewConfirmation` が DB に存在せず、`detectionRevision` の増加だけで確認が無効になること**
- **再選択の候補が一時領域へ物質化される間、既存の `ProjectSourceSnapshot` が上書きされないこと**
- **候補が一致しないまま中断しても、元の素材と snapshot が失われないこと**
- **一致した場合の差し替え・派生データ破棄・リビジョン更新が単一の DB トランザクションで行われること**
- **再選択 Saga の手順 8（DB 側）の途中で終了した場合、DB トランザクションが巻き戻り、作成済みファイルは孤児として回収されること**
- **その削除で `Project` が消えないこと。`retentionNow == nil` の間は削除しないこと**
- **`isTerminal` が `completed` / `failed` / `canceled` のみ真であり、履歴削除の保護と完了判定が同じ述語を使うこと**

### 3.8 更新誘導との順序（[アーキテクチャ設計](architecture.md) の 6.7）

- **更新判定が復旧手順 −4〜7.5 の完了後に実行されること**
- **`.required` かつ `isUndelivered` の出力があるとき、受け渡し導線が先に提示されること**
- **その画面から新規加工・履歴・設定へ進めないこと**
- **保存または破棄で `isUndelivered` が 0 件になった時点で、通常の強制更新画面へ切り替わること**
- **`.recommended` が編集中・書き出し中・未受け渡し出力があるときに表示されないこと**
- Free が既存プロジェクトの編集画面を開けること。変更操作の時点で案内が出ること

---

## 4. adapter integration test

実 GRDB、実 保護ファイル、実 Keychain 鍵を使います。

### 4.1 プロトコル適合テスト

`MediaKit` / `Persistence` / `Billing` / `Ads` の各プロトコルに対し、**実装と偽実装の両方へ同じスイート**を実行します。偽実装が本物と違う挙動をすると saga テストが無意味になるため、この一致を検証します。

### 4.2 永続化の原子性（[アーキテクチャ設計](architecture.md) の 7.1、[書き出し Saga](export-saga.md) の 3）

- 手順 7 の DB トランザクションが原子的であり、`OutputRecord` / `ExportRecord` / キュー状態 / `Project` / `WorkingSourceRecord` の更新とコミットの `published` 更新が同時に成立すること
- **「コミットあり・`OutputRecord` あり」が `published` のときだけ観測されること。それ以外の `state` では観測されないこと**
- `synchronous = EXTRA` と `foreign_keys = ON` が設定され、起動時に読み返して検証されること
- スキーマ移行が単一トランザクションで確定し、途中適用が観測されないこと
- **外部キー制約が有効であり、`Project` の削除が `OutputRecord` / `ExportCommit` の存在で RESTRICT されること**
- **`Project` の削除が `OutputRecord` / `ExportCommit` の存在で RESTRICT され、`FaceTrack` / `EffectSetting` / `ExportSetting` / `ExportQueueItem` / `ExportRecord` / `ProjectStampAsset` は CASCADE すること**
- **`Batch` の削除で `OutputRecord.batchID` / `ExportCommit.batchID` / `ExportRecord.batchID` が SET NULL になること**
- **`journal_mode` が `DELETE` であり、`TRUNCATE` / `PERSIST` / `WAL` なら復旧エラーになること**
- **`blobKeyRawValue` が `UsageLedger = 1` / `SubscriptionState = 2` / `RemoteConfigState = 3` / `TrustedTimeState = 4` で固定されていること**
- `PRAGMA foreign_key_check` が起動時に実行され、違反があれば復旧エラーになること

### 4.3 署名と鍵（[正準スキーマ](canonical-schema.md)、[アーキテクチャ設計](architecture.md) の 7.2）

- `ExportCommit` が状態遷移のたびに再署名され、正規の更新で検証失敗しないこと
- **`signedBytes` の先頭に `payloadType` が含まれ、種別間の付け替えが検出されること**
- 実 Keychain の鍵で署名・検証が往復すること。鍵の破棄が `integrityFailure` になること
- HKDF による鍵の用途分離（`payload-signing-v1` / `source-provider-key-v1`）が実際に別の鍵を導くこと
- **blob `missing` / 鍵 `missing` で新規台帳が作られること**
- **blob `missing` / 鍵 `existing` でも新規台帳が作られ、復旧エラーにならないこと**
- **`ProtectedBlobKey<UsageLedger>` へ `SubscriptionState` を渡すコードがコンパイルできないこと**（型検査）
- **`OutputMetadata` に許可フィールド以外を渡せないこと。`ImageEncoder` が元のメタデータ辞書を受け取らないこと**
- **読み込み時に `payloadType` と `schemaVersion` を型の宣言と照合し、`payloadType` 不一致は破損、`schemaVersion` 不一致は `unsupportedSchema` として移行へ回すこと**
- **HMAC-SHA256 の署名長が 32 バイトであること。HKDF-SHA256 の派生鍵が 32 バイトで、用途ごとに異なること**
- **`providerAssetKeyHash` が小文字 16 進 64 文字であること**
- **`ProtectedBlobKey` から固定の内部ファイルへ解決され、再起動後も同じ blob を読めること**
- **`ManagedFileID` を外部へ保存しなくても 4 種の blob を発見できること**

### 4.4 ファイル管理と保護（[アーキテクチャ設計](architecture.md) の 7.3 / 7.4）

- `ProtectedBlobStore` のデータと HMAC 鍵がともにバックアップ対象外であること
- 各ディレクトリのデータ保護クラスが 7.4 の表と一致すること
- ロック中に `.complete` のファイルへアクセスした場合、破損ではなく「保護データ利用不可」として処理が一時停止すること
- `OutputRecord` の実体解決が `ManagedFileRef` 経由であり、パス文字列の改変で専用ディレクトリ外を削除できないこと
- **`ManagedFileKind` が異なれば同じ `fileID` でも別ファイルとして扱われること**
- `ManagedFileStore` が保存のたびに `isExcludedFromBackup` と `FileProtectionType` を設定し、読み返して検証すること
- 属性の検証に失敗したファイルが完成扱いにならないこと
- `StampAsset` の作成が atomic rename を経ること
- **インポート Saga の手順 1〜3 の途中で終了した場合、作成済みファイルが孤児として起動時 GC で回収されること**
- **`ProjectSourceSnapshot` が `Project` 行より先に台帳へ保存されること**
- **インポート手順 4 が同じ台帳トランザクションで `SourceRecord` を解決または作成し、不変条件 9 を満たすこと**
- **DB 登録に失敗した補償で、snapshot・binding・未参照 `SourceRecord` の 3 つが削除されること**
- **DB 登録を繰り返し失敗させても alias レコードが蓄積しないこと**
- **新規写真の初回インポート直後に台帳を保存できること**
- **DB 登録に失敗した場合、その snapshot が補償削除されること**
- **補償削除の前に終了しても、対応する `Project` が無い snapshot が起動時復旧の手順 5.5 で回収されること**
- **同じ走査で孤児 `exportedSettingsEntries` も削除されること**
- **`PostCommitRecoverySnapshot.projectIDs` が全 `Project` を含み、手順 5.5 の照合にこれを使うこと**
- **インポート Saga が `PickedPhotoInput.importedFile` を作り直さず、所有権を受け取ること**
- **DB 確定（手順 5）の後に取り込みファイルが削除され、削除失敗時は `PendingFileDeletion` へ積まれること**
- **DB 確定より前に取り込みファイルを削除しないこと**
- **再選択・再接続の成功経路でも候補ファイル（正規化前）が削除されること**
- **「Free 版として複製」で新しい `projectID` の snapshot が台帳へ追加され、処理用ファイルが元 `Project` と共有されないこと**
- **複製の DB 失敗で新 snapshot と binding が補償削除されること**
- **元素材の実体が無い場合、`WorkingSourceRecord` を作らず再接続待ちになること**
- **複製に `ExportedSettingsEntry` がコピーされないこと**
- **`Project` 削除で DB が先に確定し、その後に台帳から `ExportedSettingsEntry` / `ProjectSourceSnapshot` / `WorkingSourceBinding` と未参照 `SourceRecord` が削除されること**
- **DB 確定と台帳削除の間で終了しても、`Project` から認可情報だけが失われる状態にならないこと**
- **`WorkingSourceRecord` が最初から向き正規化済みの原寸ファイルを指すこと。差し替えが発生しないこと**
- **`contentFingerprint` が取り込みファイル（正規化前）から計算されること**
- **検出用の縮小画像がメモリ内で完結し、`ManagedFileStore` へ書かれず DB へも登録されないこと**
- **DB 登録の完了前に、選択処理の成功が呼び出し元へ返らないこと**

### 4.5 メタデータ（[アーキテクチャ設計](architecture.md) の 7.5 / 6.4）

- **読み取り権限あり** — 保存後に `PHAsset.creationDate` を読み戻し、元画像の登録日時と一致すること
- **読み取り権限なし** — 偽 `PHAssetCreationRequest` または adapter spy で、**EXIF の日時が渡されたこと、または `creationDate` が設定されなかったこと**を検証する。`PHAsset` を取得しにいかないこと
- **`OriginalCaptureMetadata` が EXIF のみから決まり、PhotoKit 権限の有無で変わらないこと**
- **`OffsetTimeOriginal` があり `SubSecTimeOriginal` が無い場合、秒精度で `utcMillis` が算出されること**
- 出力ファイルから位置情報・機器情報・編集ソフト情報が除去されていること

### 4.6 Vision と Core Image（[画像処理](image-pipeline.md) の 1 / 4）

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

### 4.7 スタンプラスタライズ（[画像処理](image-pipeline.md) の 3）

- `plan` が参照する `bitmapID` が `rasterAssets` に無い場合、描画を開始せずエラーになること
- 同一 `StampRasterKey` のラスタライズが 1 回で済み、複数領域から再利用されること。**`rasterize(_ keys:)` が与えた全 key に対応する値を返すこと**
- `RasterizedStampAsset` の `bitmapID` スコープが `render` 呼び出し内に閉じ、並列レンダリングで衝突しないこと
- ラスタ一時ファイルの解放が冪等であること。二重解放でエラーにならないこと
- ラスタファイルの行末パディングがゼロ初期化されていること
- premultiplied から straight への変換が保存前に行われていること

### 4.8 Core Image 出力のゴールデン画像テスト（[画像処理](image-pipeline.md) の 2 / 4）

**同じ `RenderSpec` から生成したプレビュー用と原寸用の出力が一致すること。** `sourceCrop` / `scaleMode` / `background` を適用した結果が設定と一致すること。

素材として固定化する条件は次のとおりです。

| 分類 | 条件 |
| --- | --- |
| 仕様 30.4 | 強度の最小・最大、顔の回転、領域が画面端、領域の重なり、透明度、4 形状 |
| Y 軸反転の検出 | 画像**上端**だけに顔がある / 画像**下端**だけに顔がある |
| 座標原点 | `extent` の原点が `(0, 0)` でない `CIImage` |

上下の非対称性は、Y 軸反転の誤りが最も現れやすい形です。中央に顔がある素材では反転しても差が出ません。

### 4.9 受け渡しと診断

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

- 手順 −2 / 0 / 1 / 2 / 3 / 4 / 5 / 6 / 7 / 8 / 9 の**各直後**で強制終了し、再起動後に整合が回復すること
- **手順 7 の直後（`published`）で落ちても、再起動時に手順 8・9 が完了し、出力と設定エントリの両方が確定すること**
- **手順 8 の直後・手順 9 の前に落ちても、`deletePublished` の再実行でコミット行が消えること**
- ロールバックの手順 1 の完了後に落ちても、`rollingBack` が残っているため再起動時の再実行が冪等であること
- 予約を作った直後に落ちた場合、孤児予約が起動時に回収され、その完了後に新規認可が許可されること
- `StampAsset` の作成で DB 更新の直前に落ちた場合、孤児ファイルが起動時 GC で回収されること
- `PendingFileDeletion` の削除に失敗した場合、次回起動時の GC で再試行されること
- 書き出し一時ファイルとラスタ一時ファイルの孤児が、起動時に回収されること
- `WorkingSourceRecord` の行を作る前に落ちた場合、処理用ファイルが孤児として回収されること
- **インポート Saga で `ProjectSourceSnapshot` を保存した直後に落ちた場合、`Project` が無い snapshot が手順 5.5 で回収されること**
- **DB 確定（手順 5）の直後に落ちた場合、`Project` と snapshot の両方が残り、そのまま編集を再開できること**
- **`PHAssetCreationRequest` の成功直後・DB 更新の前に落ちた場合、`previousState` に応じて `deliveryUnknown` または `delivered` へ解決されること**
- **同じ経路で `delivered` が `deliveryUnknown` へ後退しないこと**
- **`Project` 削除の DB 確定直後・台帳削除の前に落ちた場合、次回起動で 4 集合と未参照 `SourceRecord` が回収されること**
- **台帳だけが進んだ状態は存在しうるが、次回起動で `paused(.sourceReselectionRequired)` へ遷移し、別画像を利用できないこと**
- **その状態で素材・設定・検出結果のいずれも壊れないこと**
- **再選択 Saga の手順 9（補償）が走った場合、旧 binding へ戻って何も変わらない状態になること**

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
- **書き出し完了・キャンセル・プロジェクト破棄・保持期限の終了のいずれかの後に、参照のない処理用元画像コピーが残らないこと**（処理中の `WorkingSourceRecord` は正当な保持であり、これに含めない）
- 出力ファイルから位置情報・機器情報・編集ソフト情報が除去されていること
- **写真ライブラリの登録日時が、取得できる場合に引き継がれ、取得不能時は未設定になること**（現在時刻を明示指定しないこと）
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
