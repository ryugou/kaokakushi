# ui-mock: 完了フロー レビュー指摘の修正 spec

| 項目 | 内容 |
| --- | --- |
| 目的 | 一次レビュー（FAIL）の指摘 C1 / M1 / m1 / m2 / m3 を修正する |
| 対象 | `ui-mock/` のみ。`docs/` は変更しない |
| 前提 | ブランチ `ui-mock/completion-flow`（86a7d1c）上で作業する。commit 可、push・PR 作成は禁止 |
| 根拠 | `docs/adr/0006-accounting-per-delivered-output.md`（バッチ完了の規則を追記済み）、`docs/superpowers/specs/2026-07-30-ui-mock-completion-flow-design.md` |

## C1（Critical）: discard ダイアログの自己矛盾を解消する

`components/pending-dialogs.tsx`

- **役割分離**: reissue（無料やり直し）の約束は出力確認画面（`output-confirm-screen.tsx`）だけが行う。ダイアログ側は「無料」を主張しない
- `UnsavedOutputDialog`: 「やり直しは無料」の文言を削除する。完了後にのみ表示される実態に合わせ、「保存していない完成写真があります。離れると保存できなくなります」相当へ
- `DiscardDialog`: `pendingOutput.settled` で文言を出し分ける
  - 完了前（settled == false）: 「この出力を破棄してやり直しますか？ やり直しは無料枠を消費しません」
  - 完了後（settled == true）: 現行どおり「使用した無料枠は戻りません」系
- `RecoveryDialog` の `pendingLabel`: 「保存していない加工済み写真が〜」を `UnsavedOutputDialog` と同じ用語系（「完了していない写真が〜」または統一後の表現）へ揃える（m1）

## M1（Major）: バッチにも完了フローを実装する

ADR 0006 追記の規則に従う:

- バッチの全成果物の生成後、**結果一覧画面に [完了する]（primary）を置く。1 回の操作でバッチ内の全成果物が確定**（`settled: true`）する
- 完了ボタン付近の注記: 「完了すると N 枚として確定します。完了後の作り直しは新しい枚数として数えます。」（N は成果物数。トライアルなら消費クレジット数の文脈で表示）
- **完了前**: 結果一覧の各写真に「やり直す」導線を置く（該当写真を破棄して編集/再処理へ。追加消費なしの注記）。一括保存・共有ボタンは**無効または非表示**
- **完了後**: 一括保存・共有を有効化。やり直し導線は消す
- `app-provider.tsx`: バッチの `PendingOutput.settled` 固定 `false` を廃し、バッチ用の完了アクションを追加。`markDelivered` 等の受け渡し系はバッチでも `settled` を前提とする
- 既存のバッチ確認モード（事前確認 / 1枚ずつ）のフローは変えない。完了操作は「生成後の結果一覧」に追加するだけ

## m2: 防御的ガード

`app-provider.tsx` の `markDelivered`（および保存・共有系アクション）冒頭に `settled` でないときは何もしないガードを入れる（export-saga.md 8 章の「保存・共有系は settledAt != nil を事前条件とする」に対応）。

## m3: 命名衝突の解消

`batch-screen.tsx` のローカル変数 `settled`（バッチ内の処理完了件数）を `settledCount` 等へリネームし、ADR 0006 の完了フラグ `settled` と区別する。

## 受入条件

- `pnpm --dir ui-mock exec tsc --noEmit` が成功する
- 単体・バッチとも「完了前: やり直し無料 / 保存・共有不可」「完了後: 保存・共有可 / やり直しは新規消費」が UI 文言と状態管理の両方で一貫する
- 「無料」の約束が出力確認画面（単体）とバッチ結果一覧（完了前）にのみ現れ、ダイアログ間の矛盾がない

## 禁止事項

- `docs/` 配下の変更、push・PR 作成、Python の使用
- spec にない非自明な判断（発見したら実装せず最終出力で差し戻す）
