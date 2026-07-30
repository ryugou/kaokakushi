# ui-mock: 完了フローの実装 spec

| 項目 | 内容 |
| --- | --- |
| 目的 | ADR 0006（勘定の単位＝完了した成果物）の完了フローを UI モックへ反映する |
| 対象 | `ui-mock/` のみ。`docs/` は変更しない |
| 根拠 | `docs/adr/0006-accounting-per-delivered-output.md`、`docs/adr/0005-drop-tamper-resistance-backend-and-heavy-fault-tolerance.md` |
| ブランチ | `ui-mock/completion-flow` を作成して作業する。commit 可、push・PR 作成は禁止 |

## 背景（要点のみ）

勘定の仕様が変わった。生成（書き出し）で枠を計上するが、**確定（完了）は生成後の出力確認画面での明示的な完了操作**で行う。完了前は破棄してのやり直しが無料（reissue）。完了後は保存・共有が何度でも無料で、やり直しは新規 1 枠。24 時間再書き出し（free-reexport）と強制更新は廃止済み。

## 新しい画面フロー

```
書き出し設定 →「加工した写真をつくる」→ 処理中(processing)
  → 出力確認画面(confirm)【新設】
      - 出力プレビュー
      - [完了する]（primary）→ 完了画面(done) へ
      - [やり直す]（secondary）→ 出力を破棄して編集画面(effect)へ戻る
      - 注記（常時表示）:「完了すると1枚として確定します。完了後の作り直しは新しい1枚として数えます。」
      - 注記:「やり直しは無料枠を消費しません。」
      - Free プランでは残り枚数の文脈（例: 今月の残り あと N 枚）を表示
  → 完了画面(done)【既存 done-screen を完了後専用に改修】
      - タイトルは完成を示す（例: 「完成しました」）
      - 写真ライブラリへ保存 / 共有ボタン群（何度でも実行可。追加消費なしの注記は維持）
      - やり直し導線は置かない
```

## 変更内容

### 1. `components/app-provider.tsx`

- pending 出力の状態に「完了済みか」を追加する（例: `settled: boolean`）
- アクションを追加:
  - `completePending()`: 完了を確定し `done` へ遷移する
  - `redoPending()`: 出力を破棄し、同じ写真・同じ設定のまま編集画面（`effect`）へ戻る。次回の書き出しを reissue（追加消費なし）として扱う
- クォータ表示の分類から `free-reexport`（24 時間再書き出し）を廃止し、`reissue` を追加する。`reissue` は `redoPending()` 経由で再書き出しするときだけ成立する
- 消費カウント: 初回生成で 1 消費。reissue の再生成では追加消費しない
- `savePending` / `sharePending` は完了後（`settled`）のみ呼ばれる前提に整理する
- `guardNewWork`（未完了のまま離脱する際の警告）は維持し、文言を「完了していない写真があります。破棄するとやり直しは無料ですが、この出力は失われます」相当へ調整する

### 2. 新規 `components/screens/output-confirm-screen.tsx`

上記フローの出力確認画面。画面 ID は `confirm` とし、`processing` の完了遷移先を `done` から `confirm` へ変更する。レイアウトは done-screen に合わせる（MediaCanvas 中央、ボタン縦積み、注記は text-[11px] muted）。

### 3. `components/screens/done-screen.tsx`

- 完了後専用にする。`delivered` 分岐による「保存前/保存後」の出し分けは維持してよいが、**完了前状態の表現（「加工した写真ができました」＋初回保存導線としての性格）を「完成しました」系へ変更**する
- コメント「生成が終わった時点で枠を消費しているので、受け渡しまで到達させる」を削除する（前提が変わった）
- 「保存や共有は何度でも行えます。追加で無料枠は消費しません。」の注記は維持

### 4. `components/screens/export-screen.tsx`

- `quotaDecision === "free-reexport"` の分岐と「24時間以内の再書き出し」文言を削除する
- 代わりに `reissue` のとき「やり直しのため、無料枠は使用しません」を表示する（フッターと skipFaces 警告内の両方）

### 5. `components/update-gate.tsx`

ADR 0005 により強制更新は廃止。強制更新（全画面ブロック）の UI・状態を削除し、任意の更新推奨（「後で」を選べる。skippedVersion 相当の挙動）だけを残す。未受け渡し出力があるときは推奨を出さない挙動があれば維持する。

### 6. 横断確認

- `grep -rn "24時間\|free-reexport\|reexportOf" ui-mock/components` で旧概念の残存を確認し、除去または reissue へ置換する（`reexportOf` は「有料スタンプの変更せず再書き出し」ロック用途なら名称維持でよい。用途を確認して判断し、非自明なら差し戻す）
- killSwitch / リモート設定 / 台帳修復に相当するモック要素があれば削除する（grep で確認。無ければ何もしない）

## 受入条件

- `pnpm exec tsc --noEmit` が成功する（ui-mock ディレクトリで実行。`--manifest-path` 相当は不要、`pnpm --dir ui-mock exec tsc --noEmit`）
- 上記フローの画面遷移がコード上で一貫している（processing → confirm → done、confirm → effect）
- 旧概念（24時間再書き出し・強制更新の全画面ブロック）が UI 文言・分岐から消えている
- 完了操作の注記文言が上記のとおり入っている

## 禁止事項

- `docs/` 配下の変更
- push・PR 作成
- Python の使用
- spec にない非自明な判断（発見したら実装せず最終出力で差し戻す）
