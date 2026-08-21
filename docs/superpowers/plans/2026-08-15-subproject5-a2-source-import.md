# サブプロジェクト5 A2: SourceImportCoordinator（インポート・再選択・再接続） 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 素材取り込みの 3 つの Saga（インポート／再選択／再接続）を `Application` の `SourceImportCoordinator` として実装し、ファイルシステムと DB の協調を単一トランザクションと補償削除で閉じる。

**Architecture:** `image-pipeline.md` 5章「インポート Saga」「再選択後の Saga」「実装の所在」が正本。DB 更新はすべて `WorkingSourceStore` の既存メソッド（`createProjectWithWorkingSource` / `replaceWorkingSource` / `attachWorkingSourceToExistingProject`）が単一トランザクションで行う。Coordinator は手順の順序と失敗時の補償を担う。`Application` は Foundation のみに依存し、実ファイル操作は `ManagedFileStore` ポート越しに行う。

**Tech Stack:** Swift 6.3.3 / swift-testing / SwiftLint 0.65.0。

## Global Constraints

- 実装は vibepod コンテナ内で行う。`packages/Persistence` は CryptoKit 依存で Linux ではビルドできないため触らない
- SwiftLint: 1行120文字以内、変数名3文字以上、ファイル先頭コメントは `//` 形式、末尾カンマ禁止、関数50行以内、ファイル400行以内、連続空行禁止
- `git add` は変更対象ファイルを個別指定する（`git add -A` / `git add .` は禁止）
- **複製 Saga は実装しない**（Issue #35。正本にポート定義が無い）
- **後始末（補償削除・`PendingFileDeletion` 登録）が DB 書き込みを伴う場合、キャンセル済み文脈でも完走させる。**`Cleanup.swift` の `runShieldedFromCancellation` を使う。生成・受け渡し経路と同じ扱い（Issue #32 で塞いだ欠陥と同型）
- **変更系操作はグローバル直列キュー（`SerialTaskQueue`）を経由し、キュー投入前に `recoveryGate.awaitRecoveryCompleted()` を待つ**（`architecture.md` 4.2 / 4.3。Issue #32 の C-2 と同じ要件）
- 偽ストアは「失敗したら実体が残る」等の現実を再現する。再現しない偽実装は欠陥を隠す（Issue #7 の教訓）

---

### Task 1: `PickedPhotoInput` の宣言

**Files:**
- Create: `packages/Domain/Sources/Domain/Ports/PickedPhotoInput.swift`
- Test: `packages/Domain/Tests/DomainTests/Ports/PickedPhotoInputTests.swift`

**Interfaces:**
- Consumes: `ManagedFileRef`、`SourceRepresentation`（`Ports/WorkingSourceStore.swift`）
- Produces: `public struct PickedPhotoInput` — Task 2 のインポート Saga が受け取る

- [ ] **Step 1: 失敗するテストを書く**

```swift
import Testing
@testable import Domain
import Foundation

// PickedPhotoInput（image-pipeline.md 5章「PickedPhotoInput」節）。
// App の bridge が物質化済みファイルとして Application へ渡す唯一の型。

@Test("PickedPhotoInputは全フィールドをそのまま保持する")
func pickedPhotoInputHoldsAllFields() {
    let file = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))
    let created = Date(timeIntervalSince1970: 1_754_872_200)

    let subject = PickedPhotoInput(
        importedFile: file,
        providerAssetIdentifier: "asset-1",
        libraryCreationDate: created,
        representation: .photoLibrary
    )

    #expect(subject.importedFile == file)
    #expect(subject.providerAssetIdentifier == "asset-1")
    #expect(subject.libraryCreationDate == created)
    #expect(subject.representation == .photoLibrary)
}

@Test("PickedPhotoInputはOptionalフィールドをnilで構築できる")
func pickedPhotoInputAllowsNilOptionals() {
    let file = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))

    let subject = PickedPhotoInput(
        importedFile: file,
        providerAssetIdentifier: nil,
        libraryCreationDate: nil,
        representation: .photoLibrary
    )

    #expect(subject.providerAssetIdentifier == nil)
    #expect(subject.libraryCreationDate == nil)
}
```

**注意**: `SourceRepresentation` の case 名は `packages/Domain/Sources/Domain/Ports/WorkingSourceStore.swift` を
Read して確認すること。上記の `.photoLibrary` は仮であり、実際の case 名へ置き換える。

- [ ] **Step 2: テストが失敗することを確認する**

Run: `swift test --package-path packages/Domain --filter pickedPhotoInput`
Expected: `cannot find type 'PickedPhotoInput' in scope` でビルド失敗

- [ ] **Step 3: 型を宣言する**

`image-pipeline.md` 5章「`PickedPhotoInput`」から転記する。`public` を付け、メンバーワイズ
イニシャライザを明示する（既存の `Ports/*.swift` と同じ方針）。

```swift
import Foundation

// PickedPhotoInput — App の bridge が Application へ渡す唯一の型
// （image-pipeline.md 5章「PickedPhotoInput」節）。
//
// providerAssetIdentifier は PickedPhotoInput の寿命の中でのみ使う。ログへ出さず永続化しない
// （ADR 0006 により素材同一性の識別に使わなくなったため、ハッシュ化して保存することもない）。

/// image-pipeline.md 5章「`PickedPhotoInput`」節
public struct PickedPhotoInput: Sendable {
    public let importedFile: ManagedFileRef          // 7.3 で物質化済み
    public let providerAssetIdentifier: String?      // 一時的にのみ保持。保存・ログ禁止
    public let libraryCreationDate: Date?
    public let representation: SourceRepresentation  // architecture.md 7.5

    public init(
        importedFile: ManagedFileRef,
        providerAssetIdentifier: String?,
        libraryCreationDate: Date?,
        representation: SourceRepresentation
    ) {
        self.importedFile = importedFile
        self.providerAssetIdentifier = providerAssetIdentifier
        self.libraryCreationDate = libraryCreationDate
        self.representation = representation
    }
}
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `swift test --package-path packages/Domain --filter pickedPhotoInput`
Expected: PASS

- [ ] **Step 5: 全体の検証とコミット**

Run: `swift test --package-path packages/Domain`
Run: `swiftlint lint --strict`
Run: `bash scripts/check-imports.sh`

```bash
git add packages/Domain/Sources/Domain/Ports/PickedPhotoInput.swift packages/Domain/Tests/DomainTests/Ports/PickedPhotoInputTests.swift
git commit -m "feat: PickedPhotoInput を宣言する (#8)"
```

---

### Task 2: インポート Saga

**Files:**
- Create: `packages/Application/Sources/Application/SourceImportCoordinator.swift`
- Create: `packages/Application/Tests/ApplicationTests/Fakes/FakeWorkingSourceStore.swift`（既存があれば拡張）
- Create: `packages/Application/Tests/ApplicationTests/SourceImportCoordinatorImportTests.swift`

**Interfaces:**
- Consumes: `PickedPhotoInput`（Task 1）、`PickedPhotoLoader` / `WorkingSourceStore` / `ManagedFileStore` / `MaintenanceStore`（Domain のポート）、`SerialTaskQueue` / `RecoveryGate`（Application）
- Produces: `public actor SourceImportCoordinator` と `func importPickedPhoto(_ input: PickedPhotoInput) async throws -> ProjectID` — Task 3・4 が同じ actor を拡張する

**正本の手順**（`image-pipeline.md` 5章「インポート Saga」）:

1. `PickedPhotoInput.importedFile` の所有権を受け取り、EXIF を読む
2. 向きを正規化した原寸ファイルを作成し `working/` へ書き込む
3. 単一 DB トランザクションで `Project`・キュー項目・`WorkingSourceRecord` を作成する
4. 取り込みファイルを削除する（失敗したら `PendingFileDeletion` へ積む）

手順1〜2 は `PickedPhotoLoader.load(_:)` が担う（`LoadedPhoto` を返す。`image-pipeline.md` 5章
「`Domain` のプロトコル」表が「物質化済みファイルの読み込み、向き正規化」を責務としている）。

**手順3が失敗した場合、作成済みファイル（取り込み・正規化の両方）を `PendingFileDeletion` へ積む。**

- [ ] **Step 1: 失敗するテストを書く（正常系）**

`FakeWorkingSourceStore` / `FakePickedPhotoLoader` / `FakeManagedFileStore` / `FakeMaintenanceStore` を
使う。既存の Fake（`Fakes/` 配下）を確認し、無いものだけ追加する。

```swift
@Test("インポートはPickedPhotoLoaderで正規化しWorkingSourceStoreへ単一トランザクションで登録する")
func importCreatesProjectWithNormalizedSource() async throws {
    let loader = FakePickedPhotoLoader()
    let store = FakeWorkingSourceStore()
    let coordinator = makeSourceImportCoordinator(pickedPhotoLoader: loader, workingSourceStore: store)
    let input = makePickedPhotoInput()

    _ = try await coordinator.importPickedPhoto(input)

    #expect(await loader.loadCalls == [input.importedFile])
    let created = await store.createProjectWithWorkingSourceCalls
    #expect(created.count == 1)
}
```

**`makeSourceImportCoordinator` と `makePickedPhotoInput` は `TestSupport.swift` へ追加する**
（既存の `makeCoordinator` と同じ様式）。

- [ ] **Step 2: テストが失敗することを確認する**

Run: `swift test --package-path packages/Application --filter importCreatesProject`
Expected: `cannot find 'SourceImportCoordinator' in scope` でビルド失敗

- [ ] **Step 3: 最小実装を書く**

`SourceImportCoordinator` を actor として作り、`importPickedPhoto` を実装する。
**キュー投入前に `recoveryGate.awaitRecoveryCompleted()` を待つ**（Global Constraints）。

- [ ] **Step 4: テストが通ることを確認する**

Run: `swift test --package-path packages/Application --filter importCreatesProject`
Expected: PASS

- [ ] **Step 5: 不変条件のテストを追加する（1件ずつ red → green）**

次の 4 件を、それぞれ「テストを書く → 赤を確認 → 実装 → 緑を確認」の順で追加する。
**まとめて書かないこと。**

1. **DB 確定より前に取り込みファイルを削除しない**
   `FakeManagedFileStore.deleteCalls` が、`createProjectWithWorkingSource` の呼び出しより後に
   記録されることを検証する。呼び出し順序を記録する仕組みが Fake に無ければ追加する

2. **手順3が失敗したら、取り込みファイルと正規化ファイルの両方を `PendingFileDeletion` へ積む**
   `FakeWorkingSourceStore` に失敗注入を追加し、`FakeMaintenanceStore.registerOrphanCalls`
   （または相当するメソッド）に 2 件積まれることを検証する

3. **`PickedPhotoInput.importedFile` を作り直さない**
   `FakeManagedFileStore` の作成系メソッドが `importedFile` に対して呼ばれないことを検証する

4. **DB 登録の完了前に成功を呼び出し元へ返さない**
   `createProjectWithWorkingSource` が完了する前に `importPickedPhoto` が返らないことを、
   ゲート（`OneShotGate`、`TestSupport.swift`）で store を保留して検証する

- [ ] **Step 6: 補償削除のキャンセルシールドを検証する**

`runShieldedFromCancellation` を使っていることを、キャンセル済み文脈で補償削除が完走することで
検証する。`FakeMaintenanceStore` にキャンセル検査フックを足す
（`FakeExportSagaStore.discardExportChecksCancellation` と同型）。

**シールドを外すとこのテストが落ちることを実地で確認し、元に戻してからコミットする。**
その実出力を最終出力に含めること。

- [ ] **Step 7: 全体の検証とコミット**

```bash
git add packages/Application/Sources/Application/SourceImportCoordinator.swift packages/Application/Tests/ApplicationTests/SourceImportCoordinatorImportTests.swift packages/Application/Tests/ApplicationTests/TestSupport.swift
git commit -m "feat: インポート Saga を実装する (#8)"
```

---

### Task 3: 再選択 Saga

**Files:**
- Modify: `packages/Application/Sources/Application/SourceImportCoordinator.swift`（または `+Reselect.swift` へ分割）
- Create: `packages/Application/Tests/ApplicationTests/SourceImportCoordinatorReselectTests.swift`

**Interfaces:**
- Consumes: Task 2 の `SourceImportCoordinator`
- Produces: `func reselectSource(projectID: ProjectID, input: PickedPhotoInput) async throws`

**正本の手順**（`image-pipeline.md` 5章「再選択後の Saga」）:

1. 向きを正規化した原寸ファイルを作成し、EXIF を読む
2. 単一 DB トランザクションで `WorkingSourceRecord` の置換、`Project` の撮影メタデータ・再編集用参照の
   更新、`FaceTrack` / `ReviewIssue` / `ReviewDecision` / `ReviewStatus` の破棄、
   `detectionRevision` / `projectRevision` の増加を行う
3. 置換された旧 `sourceFile` を削除する（失敗したら `PendingFileDeletion` へ積む）

**手順2は `WorkingSourceRecord` の有無で分岐する**（正本の表）:

| 現在の状態 | 呼ぶメソッド |
| --- | --- |
| `WorkingSourceRecord` **あり**（実体が欠損している場合を含む） | `replaceWorkingSource` |
| `WorkingSourceRecord` **なし**（完了操作で削除済み・履歴から開いた） | `attachWorkingSourceToExistingProject` |

分岐は `loadWorkingSource(for:)` の結果で決める。

- [ ] **Step 1: 分岐のテストを書く（あり → `replaceWorkingSource`）**

- [ ] **Step 2: 赤を確認する**

- [ ] **Step 3: 実装する**

- [ ] **Step 4: 緑を確認する**

- [ ] **Step 5: 不変条件のテストを追加する（1件ずつ red → green）**

1. **成功経路で旧 `sourceFile` が削除される**
2. **削除に失敗したら `PendingFileDeletion` へ積む**
3. **DB 確定より前に旧ファイルを削除しない**
4. **補償削除がキャンセル済み文脈でも完走する**（Task 2 Step 6 と同型。**シールドを外すと落ちることを実測**）

- [ ] **Step 6: 全体の検証とコミット**

```bash
git commit -m "feat: 再選択 Saga を実装する (#8)"
```

---

### Task 4: 再接続 Saga

**Files:**
- Modify: `packages/Application/Sources/Application/SourceImportCoordinator.swift`（または分割ファイル）
- Create: `packages/Application/Tests/ApplicationTests/SourceImportCoordinatorAttachTests.swift`

**Interfaces:**
- Consumes: Task 3 の分岐ロジック
- Produces: 再接続経路（`attachWorkingSourceToExistingProject` を使う分岐）

再接続は Task 3 の分岐の「なし」側である。Task 3 で分岐を実装済みなら、このタスクは
**その経路の不変条件をテストで固定することが主眼**になる。

- [ ] **Step 1: `WorkingSourceRecord` が無い場合に `attachWorkingSourceToExistingProject` が呼ばれるテストを書く**

- [ ] **Step 2: 赤を確認する**（Task 3 の実装状況によっては最初から緑になる。その場合は
      「既存挙動をなぞっているだけ」であることを最終出力に明記し、実装を変えない）

- [ ] **Step 3: 実装または確認**

- [ ] **Step 4: 不変条件のテストを追加する**

1. **`createdAt` が `attachedAt` で設定される**（正本の表）
2. **候補ファイル（正規化前の旧 `sourceFile`）が削除される**
3. **DB 登録の完了前に成功を返さない**

- [ ] **Step 5: 全体の検証とコミット**

```bash
git commit -m "feat: 再接続 Saga を実装する (#8)"
```

---

## 完了後の手順

1. ホストで `swift test`（Domain / Application / Persistence）、`swiftlint lint --strict`、
   `bash scripts/check-imports.sh` を実行し、実出力で成功を確認する
2. `code-review` スキルの全 Stage（一次5観点 → codex → PR 後の CI+Copilot）を通す。
   **codex はコンテナで実行できないため、ホスト側の `codex:codex-rescue` 経由で実施する**
3. PR 本文に `Closes #8` は**書かない**（Issue #8 は A3・B1〜B5 が残るため閉じない）

## この計画で扱わないもの

- **複製 Saga** — Issue #35（正本にポート定義が無い）。A3 で扱う
- `MediaKit` の実装 — B2 / B4
- 契約スイート — B5
- **`initialSpec` の展開（`RenderSpec` → `EffectSetting` / `FaceTrack`）— 実装しない。**
  正本（`image-pipeline.md:1035-1036`）とPersistence の実装コメント
  （`WorkingSourceStoreLive+Create.swift:9-13`）は、展開を「サブプロジェクト4/5 の Application 層の
  担当」と定めている。しかし **`FaceTrack` を保存するポートが Domain に存在しない**（`Ports/` 配下に
  `FaceTrack` の記述ゼロ）。Issue #25（検出・レビュー状態列のスキーマ追加）が未着手のためである。

  A2 では `initialSpec` を `CreateWorkingSourceInput` へ渡すところまでを行い、展開は行わない
  （`WorkingSourceStoreLive` は意図的に使わない契約であり、渡すこと自体は正しい）。
  **展開先のポートを推測で設計してはならない。**Issue #25 の解決後に別タスクとして扱う
