# サブプロジェクト5 A1: 素材取り込みポートの宣言 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `PickedPhotoLoader` と `FaceDetector` を Domain のポートとして宣言し、サブプロジェクト5 の後続作業（A2 の `SourceImportCoordinator`、B2/B4 の MediaKit 実装）が依存できる契約を確定する。

**Architecture:** 両プロトコルは `image-pipeline.md` 5章「プロトコルのシグネチャ」が正本。署名に現れる型（`ImageSource` / `LoadedPhoto` / `DetectionResult`）は既に `Rendering/Boundary.swift` に宣言済みのため、新規の型定義は不要。既存の `Ports/ImagePipeline.swift` へ追記し、同ファイルの「スコープ外のため含めない」という冒頭コメントを実態へ合わせる。

**Tech Stack:** Swift 6.3.3 / swift-testing / SwiftLint 0.65.0。Domain は Foundation のみに依存する。

## Global Constraints

- 実装は vibepod コンテナ内で行う（Swift 6.3.3・SwiftLint 0.65.0 が入っている）。`packages/Persistence` は CryptoKit 依存で Linux ではビルドできないため触らない
- SwiftLint: 1行120文字以内、変数名3文字以上、ファイル先頭コメントは `//` 形式、末尾カンマ禁止、関数50行以内、ファイル400行以内、連続空行禁止
- `git add` は変更対象ファイルを個別指定する（`git add -A` / `git add .` は禁止）
- Domain は Foundation のみに依存する。`CGImage` / `CIImage` / `URL` を型に持たない（`image-pipeline.md` 5章「境界型」）
- プロトコル署名は正本から**一字一句転記**する。推測で変えない
- `public` を付ける（他パッケージが Domain の公開 API として参照するため。既存 `Ports/*.swift` と同じ方針）

---

### Task 1: `FaceDetector` の宣言

**Files:**
- Modify: `packages/Domain/Sources/Domain/Ports/ImagePipeline.swift`（冒頭コメント 9-10 行目とプロトコル追加）
- Test: `packages/Domain/Tests/DomainTests/Ports/ImagePipelinePortsTests.swift`

**Interfaces:**
- Consumes: `ImageSource`（`Rendering/Boundary.swift`）、`DetectionResult`（同）
- Produces: `public protocol FaceDetector: Sendable { func detect(_ source: ImageSource) async throws -> DetectionResult }` — B2 の MediaKit 実装と、A2 の偽実装がこれに準拠する

- [x] **Step 1: 失敗するテストを書く**

`packages/Domain/Tests/DomainTests/Ports/ImagePipelinePortsTests.swift` の末尾に追記する。
既存の `makeImageSource()`（同ファイル 15-18 行目）を再利用する。

```swift
// MARK: - FaceDetector（image-pipeline.md 5章「プロトコルのシグネチャ」）

private actor MinimalFaceDetector: FaceDetector {
    private(set) var receivedSources: [ImageSource] = []
    private let result: DetectionResult

    init(result: DetectionResult) {
        self.result = result
    }

    func detect(_ source: ImageSource) async throws -> DetectionResult {
        receivedSources.append(source)
        return result
    }
}

@Test("FaceDetectorへの最小準拠がdetectへ渡されたImageSourceを記録し戻り値を返す")
func faceDetectorMinimalConformancePassesSourceAndReturnsResult() async throws {
    let expected = DetectionResult(
        faces: [],
        detectionPixelSize: PixelSize(width: 1920, height: 1440),
        revision: FaceDetectorRevision(rawValue: 3)
    )
    let subject = MinimalFaceDetector(result: expected)
    let source = makeImageSource()

    let actual = try await subject.detect(source)

    #expect(actual == expected)
    let received = await subject.receivedSources
    #expect(received.count == 1)
    #expect(received.first?.file == source.file)
    #expect(received.first?.pixelSize == source.pixelSize)
    #expect(received.first?.format == source.format)
}
```

`ImageSource` は `Equatable` に適合していないため、全フィールドをフィールド単位で比較する。
`.file` だけの比較ではテスト名が主張する「ImageSource を記録」を裏付けられない。

- [x] **Step 2: テストが失敗することを確認する**

Run: `swift test --package-path packages/Domain --filter faceDetectorMinimalConformance`
Expected: `cannot find type 'FaceDetector' in scope` でビルド失敗

- [x] **Step 3: プロトコルを宣言する**

`packages/Domain/Sources/Domain/Ports/ImagePipeline.swift` の `ImageEffectRenderer` の**前**に追記する
（正本 5章の並び順に合わせる）。

```swift
/// image-pipeline.md「プロトコルのシグネチャ」節
public protocol FaceDetector: Sendable {
    func detect(_ source: ImageSource) async throws -> DetectionResult
}
```

- [x] **Step 4: 冒頭コメントを実態へ合わせる**

同ファイル 9-10 行目の次の記述は、`FaceDetector` を宣言した時点で事実に反する。

```
// `PickedPhotoLoader` / `FaceDetector` は同じ正本節にあるが、インポートフローは別サブ
// プロジェクトの担当のためここには含めない（YAGNI。計画のスコープ外）。
```

これを削除し、代わりに次の趣旨へ**置換**する（訂正の追記ではなく置換。`document-write-rule.md` 6）。

```
// `PickedPhotoLoader` / `FaceDetector` は素材取り込み（サブプロジェクト5）で使う。実装は
// MediaKit が担当する。
```

Task 2 で `PickedPhotoLoader` も宣言するため、この文言はそのまま使える。

- [x] **Step 5: テストが通ることを確認する**

Run: `swift test --package-path packages/Domain --filter faceDetectorMinimalConformance`
Expected: PASS

- [x] **Step 6: 全体の検証**

Run: `swift test --package-path packages/Domain`
Expected: 全件 PASS（既存 340 件 + 1 件）

Run: `swiftlint lint --strict`
Expected: `0 violations`

Run: `bash scripts/check-imports.sh`
Expected: `OK`

- [x] **Step 7: コミット**

```bash
git add packages/Domain/Sources/Domain/Ports/ImagePipeline.swift packages/Domain/Tests/DomainTests/Ports/ImagePipelinePortsTests.swift
git commit -m "feat: FaceDetector ポートを宣言する (#8)"
```

---

### Task 2: `PickedPhotoLoader` の宣言

**Files:**
- Modify: `packages/Domain/Sources/Domain/Ports/ImagePipeline.swift`
- Test: `packages/Domain/Tests/DomainTests/Ports/ImagePipelinePortsTests.swift`

**Interfaces:**
- Consumes: `ManagedFileRef`（`Rendering/ManagedFileRef.swift`）、`LoadedPhoto`（`Rendering/Boundary.swift`）
- Produces: `public protocol PickedPhotoLoader: Sendable { func load(_ file: ManagedFileRef) async throws -> LoadedPhoto }` — B4 の MediaKit 実装と、A2 の偽実装がこれに準拠する

- [x] **Step 1: 失敗するテストを書く**

同じテストファイルの末尾に追記する。

```swift
// MARK: - PickedPhotoLoader（image-pipeline.md 5章「プロトコルのシグネチャ」）

private actor MinimalPickedPhotoLoader: PickedPhotoLoader {
    private(set) var receivedFiles: [ManagedFileRef] = []
    private let photo: LoadedPhoto

    init(photo: LoadedPhoto) {
        self.photo = photo
    }

    func load(_ file: ManagedFileRef) async throws -> LoadedPhoto {
        receivedFiles.append(file)
        return photo
    }
}

@Test("PickedPhotoLoaderへの最小準拠がloadへ渡されたManagedFileRefを記録し戻り値を返す")
func pickedPhotoLoaderMinimalConformancePassesFileAndReturnsPhoto() async throws {
    let capture = OriginalCaptureMetadata(
        dateTimeOriginal: "2026:08:11 09:30:00",
        subSecTimeOriginal: nil,
        offsetTimeOriginal: "+09:00",
        utcMillis: 1_754_872_200_000
    )
    let expected = LoadedPhoto(source: makeImageSource(), capture: capture)
    let subject = MinimalPickedPhotoLoader(photo: expected)
    let file = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))

    let actual = try await subject.load(file)

    #expect(actual.source.file == expected.source.file)
    #expect(actual.source.pixelSize == expected.source.pixelSize)
    #expect(actual.source.format == expected.source.format)
    #expect(actual.capture == capture)
    let received = await subject.receivedFiles
    #expect(received == [file])
}
```

**型の適合（確認済み。この前提で書くこと）**:

| 型 | 適合 | 比較方法 |
| --- | --- | --- |
| `LoadedPhoto` | `Sendable` のみ | フィールド単位で比較する（全体比較は不可） |
| `ImageSource` | `Sendable` のみ | 全フィールド（`file` / `pixelSize` / `format`）をフィールド単位で比較する |
| `ManagedFileRef` | `Sendable, Hashable` | `==` と配列比較が使える |
| `OriginalCaptureMetadata` | `Sendable, Equatable` | `==` が使える |
| `DetectionResult` | `Sendable, Equatable` | `==` が使える（Task 1 で使用） |

`Equatable` を足すために既存型を変更してはならない。正本の型定義を変える判断はこの計画のスコープ外であり、
必要と判断した場合は実装せず差し戻す。

- [x] **Step 2: テストが失敗することを確認する**

Run: `swift test --package-path packages/Domain --filter pickedPhotoLoaderMinimalConformance`
Expected: `cannot find type 'PickedPhotoLoader' in scope` でビルド失敗

- [x] **Step 3: プロトコルを宣言する**

`packages/Domain/Sources/Domain/Ports/ImagePipeline.swift` の `FaceDetector` の**前**に追記する
（正本 5章の並び順は `PickedPhotoLoader` → `FaceDetector` → `ImageEffectRenderer` → `ImageEncoder`）。
doc コメントは正本から転記する。

```swift
/// image-pipeline.md「プロトコルのシグネチャ」節
public protocol PickedPhotoLoader: Sendable {
    /// 取り込み時のみ。まだ Project に結び付いていない新しいファイルを読み、向きを正規化する。
    /// 既存 Project の素材は WorkingSourceRecord 経由の ImageSource で読む
    func load(_ file: ManagedFileRef) async throws -> LoadedPhoto
}
```

- [x] **Step 4: テストが通ることを確認する**

Run: `swift test --package-path packages/Domain --filter pickedPhotoLoaderMinimalConformance`
Expected: PASS

- [x] **Step 5: 全体の検証**

Run: `swift test --package-path packages/Domain`
Expected: 全件 PASS（既存 340 件 + 2 件）

Run: `swift test --package-path packages/Application`
Expected: 全件 PASS（125 件。Domain の変更が Application を壊していないことの確認）

Run: `swiftlint lint --strict`
Expected: `0 violations`

Run: `bash scripts/check-imports.sh`
Expected: `OK`

- [x] **Step 6: コミット**

```bash
git add packages/Domain/Sources/Domain/Ports/ImagePipeline.swift packages/Domain/Tests/DomainTests/Ports/ImagePipelinePortsTests.swift
git commit -m "feat: PickedPhotoLoader ポートを宣言する (#8)"
```

---

## 完了後の手順

1. ホストで `swift test --package-path packages/Domain` / `--package-path packages/Application` / `swiftlint lint --strict` / `bash scripts/check-imports.sh` を実行し、実出力で成功を確認する
2. `code-review` スキルの全 Stage（一次5観点 → codex → PR 後の CI+Copilot）を通す
3. PR 本文に `Closes #8` は**書かない**（Issue #8 は A2・B1〜B5 が残るため閉じない）

## この計画で扱わないもの

- 偽実装（`FakeFaceDetector` / `FakePickedPhotoLoader`）— 使う側の A2 で作る（YAGNI）
- 契約スイート — 実装が揃う B5 で作る
- 既存の境界型（`ImageSource` / `LoadedPhoto` / `DetectionResult` / `DetectedFace`）の変更 — 正本どおりに
  宣言済みであり、変更が必要と判断した場合は実装せず差し戻す
