# サブプロジェクト1: プロジェクト基盤 実装 spec

| 項目 | 内容 |
| --- | --- |
| Issue | #4 |
| ブランチ | `feat/4-project-foundation`（checkout 済み。このブランチ上で作業） |
| 正本 | [アーキテクチャ設計](../../architecture.md) の 2章（技術スタック）・3章（モジュール構成と依存方向）、[実装計画](../../implementation-plan.md) |
| 制約 | commit 可 / push・PR 禁止 / docs・ui-mock の変更禁止 / Python 禁止 / spec に無い非自明な判断は実装せず差し戻す |

## 重要な前提: コンテナは Linux

この作業環境（コンテナ）は Linux であり、**xcodegen / xcodebuild / iOS シミュレータは実行できない**。したがって:

- 成果物は**宣言的な構成ファイルの作成**が中心で、コンテナ内での検証は「YAML / Package.swift の構文妥当性」「ファイル構成の自己確認」まで
- Swift toolchain がコンテナにあれば `swift build --package-path packages/Domain` 等の純粋パッケージのビルドまで実施し、結果を報告に含める（無ければその旨を報告）
- **ビルドの最終検証（xcodegen generate / xcodebuild / swift test）はホスト側で別途行う**。完了報告に「ホストで実行すべき検証コマンド一覧」を含めること

## 作るもの

### 1. XcodeGen 定義（`project.yml`）

- プロジェクト名: `KaoKakushi`、アプリターゲット: `KaoKakushi`
- `bundleIdPrefix: com.ryugou`（Bundle ID: `com.ryugou.kaokakushi`）
- iOS deployment target: **26.0**、Swift 6、**strict concurrency = complete**
- アプリソースは `App/` ディレクトリ（`KaoKakushiApp.swift` に最小の SwiftUI App と「顔かくし」表示の ContentView を置く）
- Info.plist 生成設定（表示名「顔かくし」、`NSPhotoLibraryAddUsageDescription` 等の権限文言は**まだ入れない** — 後続 Issue の範囲）
- ローカルパッケージを `packages/` 配下として参照

### 2. SwiftPM ローカルパッケージ骨格（`packages/` 配下、8つ）

各パッケージ: `Package.swift`（swift-tools-version 6.0 以上）＋ 最小のソース1ファイル＋テストターゲット（プレースホルダテスト1件。`XCTest` ではなく **Swift Testing**（`import Testing`）を使う）。

| パッケージ | 依存（architecture.md 3.1 / 3.2 を正本として厳守） |
| --- | --- |
| `Domain` | 依存なし（**Foundation のみ import 可**） |
| `Rendering` | Domain |
| `MediaKit` | Domain |
| `Persistence` | Domain（**GRDB はこの Issue では追加しない** — #6 の範囲） |
| `Application` | Domain（Persistence には依存しない — ポートは Domain のプロトコル、実装は App 組み立て時に注入） |
| `Billing` | Domain（RevenueCat は #10 の範囲） |
| `Ads` | Domain（AdMob SDK は #11 の範囲） |
| `Analytics` | Domain（Sentry は後続の範囲） |

アプリターゲットは Application / MediaKit / Rendering / Persistence / Billing / Ads / Analytics へ依存する（組み立ての場）。

**外部依存はこの Issue では一切追加しない**（CI を速く保ち、バージョン判断を各 Issue へ委ねる）。

### 3. SwiftLint 構成（`.swiftlint.yml`）

- 基本ルールは既定＋`custom_rules` で **import 制限**（architecture.md 3.3 が正本。作業前に必ず該当節を Read して転記すること）:
  - `packages/Domain/**`: `UIKit` / `SwiftUI` / `CoreGraphics` / `CoreImage` / `GRDB` / `Photos` / `PhotosUI` / `AVFoundation` / `Security` の import を error で禁止
  - `packages/Application/**`: architecture.md 4.3 の禁止 import を error で禁止
- SwiftLint 本体はホスト・CI で実行する前提（brew / GitHub Actions）。SPM プラグインは追加しない（ビルド時間を増やさないため）

### 4. GitHub Actions CI（`.github/workflows/ci.yml`）

**`github-actions-optimize` スキルを必ず使用して作成すること。**

- トリガー: PR と main への push
- ジョブ構成（macOS ランナー。Xcode 26 系が利用できるイメージを選び、`xcode-select` でバージョンを固定）:
  1. SwiftLint（`--strict`）
  2. 各パッケージの `swift test`（8パッケージ。マトリクスまたはループで）
  3. `xcodegen generate` → `xcodebuild build`（iOS Simulator 向け、署名なし: `CODE_SIGNING_ALLOWED=NO`）
- キャッシュ（SPM / DerivedData）を適切に設定

### 5. `.gitignore` 追記

`*.xcodeproj`（XcodeGen 生成物のためコミットしない）/ `DerivedData/` / `.build/` / `.swiftpm/` / `xcuserdata/` を追加（既存内容は保持）。

### 6. README 追記（任意・最小）

ルート README が無ければ作成し、`xcodegen generate` → `open KaoKakushi.xcodeproj` の2行の開発手順だけ書く。

## 受入条件（コンテナ内で確認できる範囲）

- 全ファイルが上記構成どおり存在する
- `project.yml` / `ci.yml` / `.swiftlint.yml` が構文的に妥当（yq / python 以外の手段で確認。swift toolchain があれば各 Package.swift を `swift package dump-package` で検証）
- 依存方向が architecture.md 3.1 / 3.2 と一致している（自己確認結果を報告に記載）
- kaneko 実装 → reviewer レビュー PASS → code-review スキルの codex レビュー PASS

## ホスト側検証（完了報告に含めるコマンド一覧の想定）

- `xcodegen generate`
- `xcodebuild -project KaoKakushi.xcodeproj -scheme KaoKakushi -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
- `for p in Domain Rendering MediaKit Persistence Application Billing Ads Analytics; do swift test --package-path packages/$p; done`
- `swiftlint lint --strict`（ホストに未インストールなら報告のみ）
