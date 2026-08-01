# サブプロジェクト1 再着地 spec（正規レビューフロー版）

| 項目 | 内容 |
| --- | --- |
| Issue | #4（レビューフロー不備により PR #15 を revert 済み。本タスクは正規フローでの再着地） |
| ブランチ | `feat/4-project-foundation-v2`（checkout 済み） |
| 制約 | commit 可 / push・PR 禁止 / docs（spec 自身を除く）・ui-mock 変更禁止 / Python 禁止 / 非自明な判断は実装せず差し戻す |

## 内容

**revert された実装（コミット `d668926`）を出発点として再適用する。** この内容は前回、reviewer PASS・codex 2周・第三者監査 PASS・ホスト検証（xcodegen / 8パッケージ swift test / シミュレータビルド / check-imports 否定ケース）・CI 4ジョブ全グリーンまで到達しており、**コード内容の再発明はしない**。`git show d668926` で全内容を取得できる（`git revert` の revert、または checkout でファイルを取り出す方法は任せる）。

再適用の上で、監査（survey-saga、2026-08-01）の残指摘2件を反映する:

1. `.swiftlint.yml` 冒頭コメント（16〜19行目付近）: 検出対象の修飾一覧に `@preconcurrency` / `@_exported` を追記（regex 本体は対応済み。コメントのみ古い）
2. `scripts/check-imports.sh` の「検出対象の import 文」コメント（15〜21行目付近）: 同様に `@preconcurrency` / `@_exported` を追記

## レビューフロー（このタスクの主目的。省略・代替禁止）

1. kaneko が上記を実施し、テスト結果・差分を evidence として返す
2. reviewer が一次レビュー（Critical 1件でも FAIL。FAIL なら kaneko へ差し戻し）
3. **code-review スキルの手順で codex レビューを実施**し、指摘があれば対応して PASS まで（bash で codex を直接実行しない）
4. コンテナで実行可能な検証: `bash scripts/check-imports.sh`（肯定・否定ケース含む）、swift toolchain があれば各パッケージの `swift build` / `swift test`

## 受入条件

- ファイル構成・内容が `d668926` ＋監査指摘2件の反映、と一致する（余計な変更を加えない）
- `bash scripts/check-imports.sh` OK、否定ケース（Domain へ `@preconcurrency import UIKit` を一時追加）で FAIL することを確認して戻す
- reviewer PASS と codex PASS の判定文を最終出力に含める
- ホスト側検証（xcodegen / xcodebuild / swift test / swiftlint）はホストで別途実施するため、実行すべきコマンド一覧を最終出力に含める
