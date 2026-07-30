# 運用

| 項目 | 内容 |
| --- | --- |
| 目的 | リリース後に運用担当が判断・操作する事柄を定める |
| 読者 | リリース運用担当 |
| 正本の範囲 | 更新誘導の運用規則、設定値の変更手段、Sentry の運用 |
| 関連 | [アーキテクチャ設計](architecture.md)（`UpdateDecision` の判定、設定定数）、[ADR 0005](adr/0005-drop-tamper-resistance-backend-and-heavy-fault-tolerance.md) |

v1 は自前バックエンドを持ちません（[ADR 0005](adr/0005-drop-tamper-resistance-backend-and-heavy-fault-tolerance.md)）。サーバの監視・保守・配信作業は存在しません。

---

## 1. アプリ更新の誘導

判定そのもの（`evaluateUpdate` と `UpdateDecision`）は [アーキテクチャ設計](architecture.md) が正本です。

- バージョン情報は iTunes Lookup API（`https://itunes.apple.com/lookup?id=<appStoreID>`）で取得します。CDN キャッシュにより公開直後は古いバージョンが返ることがあり、誘導の開始が数時間遅れることは受容します
- 強制更新は持ちません。誘導は常に任意の推奨です
- 提示条件: ホーム画面または履歴画面の表示時のみ。検出中・顔選択中・編集中・書き出し中・書き出しエラー対応中・課金処理中は表示しません。`isUndelivered` の未受け渡し出力があるときも表示しません
- 「後で」を選んだバージョンを `skippedVersion` として記録し、より新しいバージョンが出たら再提示します。チェックの契機は起動時とフォアグラウンド復帰時です
- App Store は `openURL` で `https://apps.apple.com/app/id<appStoreID>` を開きます。`itms-apps://` スキームと `SKOverlay` は使いません

---

## 2. 設定値の変更

リモート設定は持ちません。閾値・上限（無料枠、バッチ上限、トリアージ閾値など）はバンドル内定数であり、変更はアプリ更新で行います。定数の一覧は [アーキテクチャ設計](architecture.md) の 10 章が正本です。

---

## 3. Sentry の運用

送信対象はクラッシュと未分類例外のみです（[アーキテクチャ設計](architecture.md)）。

| 項目 | 規約 |
| --- | --- |
| スパイク保護 | 有効化する |
| サンプリング | 有効化する。不良リリース時の突発的な消費を抑える |
| 保持期間 | 30 日（無料枠に合わせる） |
| セッションリプレイ | 有効化しない |
| 自動 breadcrumbs | 無効化する。列挙済みイベントだけを手動で記録する |

想定内のエラー（広告読み込み失敗、容量不足、保存権限拒否など）は Sentry へ送りません。
