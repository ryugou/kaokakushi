# サブプロジェクト5: プラットフォーム層（MediaKit・素材取り込み）設計

| 項目 | 内容 |
| --- | --- |
| 目的 | Issue #8 の実装範囲・分割・検証方法を定める |
| 読者 | この分割で実装を進める者 |
| 正本の範囲 | このサブプロジェクトの作業分割と、各分割の完了条件・検証方法 |
| 関連 | [画像処理](../../image-pipeline.md)（設計の正本）、[テスト計画](../../test-plan.md) 4章、[実装計画](../../implementation-plan.md) |

設計そのものの正本は `image-pipeline.md` である。この文書は**作業分割**だけを定める。
プロトコルのシグネチャ・座標規約・Saga 手順をここに複製しない。

---

## 1. 実装範囲

### 1.1 Domain に既に宣言済み（変更しない）

`StampRasterizer`（`Rendering/StampRasterizer.swift`）、`ImageEffectRenderer` / `ImageEncoder`
（`Ports/ImagePipeline.swift`）、`MediaSaver` / `SharePresenter`（`Ports/OutputPresentation.swift`）、
`WorkingSourceStore`（`Ports/WorkingSourceStore.swift`。Persistence 実装もサブプロジェクト3で完了済み）。

### 1.2 Domain へ新規宣言が必要

`PickedPhotoLoader` と `FaceDetector` の2つだけ（`image-pipeline.md` 5章「プロトコルのシグネチャ」が正本）。
サブプロジェクト4では「インポートフローは別サブプロジェクトの担当」として意図的に除外されていた。

### 1.3 実装が必要

| モジュール | 実装対象 | 使用フレームワーク |
| --- | --- | --- |
| `Rendering` | `StampRasterizer` | Core Graphics |
| `MediaKit` | `FaceDetector` | Vision |
| `MediaKit` | `ImageEffectRenderer` | Core Image |
| `MediaKit` | `ImageEncoder` | ImageIO |
| `MediaKit` | `PickedPhotoLoader` / `MediaSaver` | PhotoKit |
| `MediaKit` | `SharePresenter` | UIKit（`@MainActor`） |
| `Application` | `SourceImportCoordinator`（インポート／再選択／再接続／複製の4 Saga） | Foundation のみ |

---

## 2. 分割の原則

**コンテナで検証できる層とできない層の境界で分ける。**

vibepod の Swift profile は Foundation-only の SwiftPM パッケージしかビルドできない
（Vision / Core Image / PhotoKit / UIKit / `xcodebuild` は利用不可。vibepod README「Constraints」）。
この境界は「TDD の red→green がコンテナ内で回るか」の境界と一致する。

さらに `test-plan.md` 4.1 が **「実装と偽実装の両方へ同じスイートを実行する」**ことを要求している。
偽実装が本物と乖離すると saga テストが無意味になるためであり、サブプロジェクト4で実際にこの穴を踏んだ
（`FakeMaintenanceStore` が「削除に失敗した実体はディスクに残る」を再現しておらず、二重削除の欠陥を
テストがすり抜けた）。

したがって **適合テストスイートを Phase A で先に作り、Phase B の実装をそのスイートに通す**。

---

## 3. Phase A（コンテナで完結）

### A1: Domain のポート宣言と適合テストスイート

- `PickedPhotoLoader` / `FaceDetector` を `image-pipeline.md` 5章から一字一句転記して宣言する
- 戻り値型（`LoadedPhoto` / `DetectionResult` / `DetectedFace`）の過不足を正本と突き合わせ、不足を補う。
  既存の型を変更する場合は横断確認を行う（`document-write-rule.md` 7.1）
- **適合テストスイート**を、実装と偽実装の双方へ適用できる形で書く。スイートは
  プロトコルの契約（`image-pipeline.md` が定める不変条件）だけを検証し、実装詳細に触れない
- 偽実装（`FakeFaceDetector` / `FakePickedPhotoLoader` 等）を作り、スイートを通す

**完了条件**: `swift test --package-path packages/Domain` が緑。適合テストスイートが偽実装に対して
実行され、`image-pipeline.md` の契約項目を網羅していること。

### A2: `SourceImportCoordinator`

`image-pipeline.md` 5章「インポート Saga」「再選択後の Saga」「実装の所在」が正本。
4つの Saga（インポート／再選択／再接続／複製）を実装する。

守るべき不変条件（`test-plan.md` 4.3 が要求。すべてテストで固定する）:

- 手順3の DB 確定より前に取り込みファイルを削除しない
- 手順3が失敗したら、作成済みファイル（取り込み・正規化の両方）を `PendingFileDeletion` へ積む
- `PickedPhotoInput.importedFile` を作り直さず所有権を受け取る
- 再選択・再接続の成功経路でも旧 `sourceFile` を削除する
- 複製で新しい `projectID` の `WorkingSourceRecord` を作り、処理用ファイルを元 `Project` と共有しない
- 複製に `ExportedSettingsEntry` をコピーしない
- 元素材の実体が無い場合は `WorkingSourceRecord` を作らず複製する
- DB 登録の完了前に成功を呼び出し元へ返さない

**サブプロジェクト4の教訓を適用する**:
- 後始末（補償削除・`PendingFileDeletion` への登録）が DB 書き込みを伴う場合、キャンセル済み文脈でも
  完走させる（`Cleanup.swift` の `runShieldedFromCancellation` を使う）。生成・受け渡し経路と同じ扱い
- 偽ストアは「失敗したら実体が残る」等の現実を再現する。再現しない偽実装は欠陥を隠す

**完了条件**: `swift test --package-path packages/Application` が緑。上記の不変条件それぞれに対応する
テストが存在し、**当該のガードを外すとそのテストが落ちること**を実測で確認する。

---

## 4. Phase B（ホスト必須）

コード生成は vibepod で行い、**ビルド・テストはホストと CI で行う**（`packages/Persistence` と同じ運用）。
コンテナ内では当該パッケージをビルド対象から外す。

### B1: `Rendering` の `StampRasterizer`

`image-pipeline.md` 3章が正本。ラスタ画像の受け渡し契約（ヘッダなし raw bytes・行順・チャネル順・
`rowBytes >= width * 4`・**行末パディングのゼロ初期化**・straight alpha・sRGB）を満たす。

`test-plan.md` 4.6 の全項目をテストで固定する。とくに「行末パディングがゼロ初期化されていること」は
未初期化メモリの内容がファイルへ書かれる問題であり、必ず検証する。

B3 が依存するため Phase B の最初に行う。

### B2: `MediaKit` の `FaceDetector`

`image-pipeline.md` 1章が正本。Vision の左下原点を左上原点へ変換する（Y 軸反転）。
角度は非 Optional の `Measurement<UnitAngle>` から度へ変換する。検出用に長辺 1,920px 程度へ縮小し、
**中間ファイルを作らない**（メモリ内で完結し `ManagedFileStore` へ書かない）。

`test-plan.md` 4.5 のうち Vision 側の項目を固定する。`confidence` の分布確認は実素材が要るため、
テストでは「1.0 に張り付いていないこと」の観測に留め、閾値の決定は行わない
（`architecture.md` 12章の未決事項）。

### B3: `MediaKit` の `ImageEffectRenderer` とゴールデン画像テスト

`image-pipeline.md` 2章・4章が正本。`test-plan.md` 4.5 の Core Image 側と 4.7 の全項目を固定する。

ゴールデン画像の素材条件（`test-plan.md` 4.7 の表）:
仕様 30.4（強度の最小・最大、顔の回転、領域が画面端、領域の重なり、透明度、4形状）、
Y 軸反転の検出（画像**上端**だけに顔／**下端**だけに顔）、座標原点（`extent` の原点が `(0,0)` でない `CIImage`）。

**同じ `RenderSpec` から生成したプレビュー用と原寸用の出力が一致すること**が中核の検証である。

### B4: `MediaKit` の残りのポート

`PickedPhotoLoader`（PhotoKit・向き正規化・EXIF 読み取り）、`ImageEncoder`（ImageIO・メタデータ許可リスト・
**保存後に読み返して許可外の namespace とキーが無いことを検査**）、`MediaSaver`（PhotoKit・追加のみの権限）、
`SharePresenter`（`UIActivityViewController`・`@MainActor`）。

`test-plan.md` 4.4 の全項目を固定する。読み取り権限の有無で挙動が変わらないこと、
`OriginalCaptureMetadata` が EXIF のみから決まることを含む。

---

## 5. 実施順序

A1 → A2 → B1 → B2 → B3 → B4。

A1 は全ての前提（ポート契約と適合テストスイート）。A2 は偽実装ベースのため B を待たない。
B1 は B3 の依存。B2 は独立。B3 が最も難度が高い（ゴールデン画像）。B4 は PhotoKit 権限が絡む。

各段階を独立した PR とし、`code-review` スキルの全 Stage（一次5観点 → codex → CI+Copilot）を通す。

---

## 6. 検証方法の線引き

| 対象 | コンテナ | ホスト | CI（macOS） |
| --- | --- | --- | --- |
| `Domain` の宣言と適合テストスイート | ○ | ○ | ○ |
| `Application` の `SourceImportCoordinator` | ○ | ○ | ○ |
| `Rendering` / `MediaKit` の実装 | × | ○ | ○ |

コンテナで緑でも macOS での検証の代替にはならない（Linux の corelibs-foundation は Darwin と挙動が
異なる。vibepod README）。Phase A についても最終確認はホストと CI で行う。

## 7. このサブプロジェクトで扱わないもの

- UI（`App/` の画面実装）— サブプロジェクト6
- `AdPresenter` — サブプロジェクト8
- 手動領域（`image-pipeline.md` 6章）— UI を伴うためサブプロジェクト6以降
- `lowConfidence` の閾値決定 — 実機計測が必要（`architecture.md` 12章の未決事項）
