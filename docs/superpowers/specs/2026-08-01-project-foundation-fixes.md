# サブプロジェクト1 修正 spec（codex レビュー指摘対応）

| 項目 | 内容 |
| --- | --- |
| Issue | #4 |
| ブランチ | `feat/4-project-foundation`（checkout 済み） |
| 前提 | 実装本体はレビュー済み（xcodegen / 8パッケージ test / シミュレータビルド成功）。以下の指摘のみ修正する |
| 制約 | commit 可 / push・PR 禁止 / docs・ui-mock 変更禁止 / Python 禁止 |

## 修正1（Major）: CI に import 許可リスト走査を追加

architecture.md 3.3 の強制手段の表が明文で要求するチェック。`.github/workflows/ci.yml` に **ubuntu ランナーの軽量ジョブ**として追加する（macOS 不要・秒で終わる）。

- `packages/Domain/Sources/**/*.swift` の import 行（修飾つき `public import` / `internal import` / `@testable import` / `@_implementationOnly import` 等をすべて含む）を抽出し、**許可リスト `{Foundation}` 以外があれば fail**
- `packages/Application/Sources/**/*.swift` は許可リスト `{Foundation, Domain}` で同様に fail
- 実装はシェル（grep / awk）で自己完結させる。スクリプトは `scripts/check-imports.sh` として切り出し、CI とローカルの両方から実行可能にする

## 修正2（Major）: SwiftLint の import 正規表現を修飾対応へ

`.swiftlint.yml` の全 import 禁止ルールの regex を、次をすべて検出できる形へ変更する:
`import X` / `@testable import X` / `@_implementationOnly import X` / `public import X` / `package import X` / `internal import X` / `private import X` / `fileprivate import X`（修飾の組み合わせ含む）。

## 修正3（Major）: Application の禁止リストを Domain と同一へ拡張

architecture.md 3.3「`Application` にも同じ制約を課す」に従い、Application スコープの禁止 import を Domain と同じ10種（UIKit / SwiftUI / CoreGraphics / CoreImage / GRDB / Vision / Photos / PhotosUI / AVFoundation / Security）へ拡張する（本丸は修正1の許可リスト走査。SwiftLint 側は多層防御）。

## 修正4（Minor）: Domain の `Date()` 禁止ルール

architecture.md 3.3 の強制手段どおり、`packages/Domain` スコープで `Date()`（現在時刻の取得）を error 禁止する custom rule を追加する。`Date(timeIntervalSince1970:)` 等の引数つき初期化は許可する（regex は `Date()` の引数なし呼び出しのみを検出）。

## 修正5（Minor）: CI の並列化とキャッシュキー

- `build` ジョブの `needs:` を外し、swiftlint / package-tests / build / import-scan の4ジョブを並列にする
- DerivedData キャッシュキーへ Xcode バージョン（選択した Xcode のパスまたは `xcodebuild -version` 出力）を含め、`restore-keys` も同様に絞る

## 修正しないもの（レビュー指摘の棄却。理由を残す）

- 「`sort -V` は macOS で動かない」→ **誤指摘**。`/usr/bin/sort -V`（BSD sort）はホスト macOS で正常動作を実証済み。変更しない

## 受入条件

- `bash scripts/check-imports.sh` がローカルで成功する（現状の許可 import のみで pass、`internal import UIKit` を Domain に一時追加すると fail することを一時ファイルで確認して戻す）
- `.swiftlint.yml` / `ci.yml` が構文妥当
- kaneko 実装 → reviewer PASS（codex 再レビューはホスト側で別途実施）
