import Testing
import Foundation
import Domain
@testable import Application

// SourceImportCoordinator.reselectSource（再接続 Saga。Issue #8 サブプロジェクト5 A2 Task 4）の
// 検証。
//
// 正本: image-pipeline.md 5章「再選択後の Saga」（手順1〜3）の分岐表。
//   `WorkingSourceRecord` **なし**（完了操作で削除済み・履歴から開いた）
//   → `attachWorkingSourceToExistingProject`（行を新規作成し `createdAt` は `attachedAt`）
//
// 本ファイルは分岐の「なし」側（SourceImportCoordinatorReselectTests.swift の「あり」側と対）を
// 対象とする。計画書（docs/superpowers/plans/2026-08-15-subproject5-a2-source-import.md）
// Task 4 Step 4 の3つの不変条件のうち、不変条件2（候補ファイル削除）は実装しない
// （SourceImportCoordinator+Reselect.swift ファイル冒頭コメント「論点2」「論点3」参照。
// Issue #36 で追跡中）ため、ここでもテストを追加しない。

@Test("WorkingSourceRecordが無い場合、attachWorkingSourceToExistingProjectでPickedPhotoLoaderの結果を新規作成する")
func reselectAttachesWorkingSourceWhenRecordDoesNotExist() async throws {
    let projectID = makeProjectID()
    let store = FakeWorkingSourceStore()
    // seedWorkingSourceを呼ばない = WorkingSourceRecordが無い状態。
    let photo = makeLoadedPhoto()
    let loader = FakePickedPhotoLoader(result: photo)
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )
    let input = makePickedPhotoInput()

    try await coordinator.reselectSource(projectID: projectID, input: input)

    #expect(await store.loadWorkingSourceCalls == [projectID])
    #expect(await loader.loadCalls == [input.importedFile])
    #expect(await store.replaceWorkingSourceCalls.isEmpty)
    let calls = await store.attachToExistingProjectCalls
    #expect(calls.count == 1)
    let call = try #require(calls.first)

    #expect(call.projectID == projectID)
    // sourceFileはローダーが返した正規化ファイル（photo.source.file）由来でなければならない。
    // input.importedFileを取り違えると正規化前のファイルをDBへ登録してしまう致命的なバグになる
    // （SourceImportCoordinatorReselectTests.swiftの「あり」側テストと同型）。
    #expect(call.sourceFile.ref == photo.source.file)
    #expect(call.capture == photo.capture)
    #expect(call.libraryCreationDate == input.libraryCreationDate)
    #expect(call.representation == input.representation)
    #expect(call.sourceLocator.photoLibraryLocalIdentifier == input.providerAssetIdentifier)

    // 「なし」側には「置換された旧sourceFile」が存在しないため、手順3は一切実行されない。
    // 新規正規化ファイル（DBへ登録済み）を削除すると素材の実体を失う（あり側 Critical 2 と同型）。
    #expect(await managedFileStore.deleteCalls.isEmpty)
    #expect(await maintenanceStore.registerOrphanCalls.isEmpty)
}

// MARK: - 不変条件1: createdAtがattachedAtで設定される

@Test("再接続後にloadWorkingSourceで読み直すとcreatedAtがattachedAtと一致する")
func reselectAttachSetsCreatedAtToAttachedAt() async throws {
    let projectID = makeProjectID()
    let store = FakeWorkingSourceStore()
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: FakePickedPhotoLoader(),
        workingSourceStore: store
    )
    let input = makePickedPhotoInput()

    try await coordinator.reselectSource(projectID: projectID, input: input)

    // 正本の分岐表「なし」側: 「行を新規作成し createdAt は attachedAt」。attachToExistingProjectCalls
    // から渡したattachedAtと、その結果としてストアに反映されたcreatedAtの両方を固定クロック
    // （makeFixedClock）の値と突き合わせる。
    let call = try #require(await store.attachToExistingProjectCalls.first)
    #expect(call.attachedAt == makeFixedClock()())
    let record = try #require(await store.loadWorkingSource(for: projectID))
    #expect(record.createdAt == makeFixedClock()())
}

// MARK: - 不変条件3: DB登録の完了前に成功を返さない
//
// SourceImportCoordinatorImportTests.swift の
// importDoesNotReturnBeforeDatabaseRegistrationCompletes と同型（Task 2 不変条件4）。
// attachWorkingSourceToExistingProjectの呼び出し中にFakeWorkingSourceStore.gateで保留し、
// 別系統の完了フラグ（task.value自体を待たない）で「まだ完了していないこと」を観測する。

@Test(
    "DB登録の完了前に成功を呼び出し元へ返さない",
    .timeLimit(.minutes(1))
)
func reselectAttachDoesNotReturnBeforeDatabaseRegistrationCompletes() async throws {
    let projectID = makeProjectID()
    let store = FakeWorkingSourceStore()
    let gate = OneShotGate()
    await store.setGate(gate)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: FakePickedPhotoLoader(),
        workingSourceStore: store
    )
    let input = makePickedPhotoInput()

    let task = Task { try await coordinator.reselectSource(projectID: projectID, input: input) }
    while await store.attachToExistingProjectCalls.isEmpty {
        await Task.yield()
    }

    // task.value自体を待たない別系統のフラグで完了を観測する理由は
    // SourceImportCoordinatorImportTests.swiftの同型テストのコメント参照（構造化並行性の
    // デッドロック回避）。
    let completionFlag = AttachCompletionFlag()
    Task {
        _ = try? await task.value
        await completionFlag.markCompleted()
    }

    try await Task.sleep(for: .milliseconds(100))
    #expect(await completionFlag.isCompleted == false)

    await gate.open()
    try await task.value
    #expect(await store.attachToExistingProjectCalls.count == 1)
}

/// task.value自体を待たずに完了を観測するためのフラグ（SourceImportCoordinatorImportTests.swift
/// のImportCompletionFlagと同じ方針）。
private actor AttachCompletionFlag {
    private(set) var isCompleted = false
    func markCompleted() { isCompleted = true }
}

// MARK: - 不変条件4: attachWorkingSourceToExistingProjectの失敗はそのまま伝播し余分な副作用を残さない
//
// reviewer Warning W3: 「あり」側（SourceImportCoordinatorReselectTests.swiftの
// reselectDoesNotDeleteReplacedSourceFileWhenReplaceWorkingSourceFails）には書き込み失敗経路の
// テストがあるのに対し、「なし」側には対応するテストが無かった。「なし」側には手順3（旧ファイル
// 削除）が存在しないため検証すべき副作用は少ないが、書き込み失敗時にreselectSourceがエラーを
// そのまま呼び出し元へ伝播すること、および余計な副作用（managedFileStore.delete /
// maintenanceStore.registerOrphan）が一切起きないことは、あり側と同型の不変条件として固定する
// 価値がある。

@Test("attachWorkingSourceToExistingProjectが失敗したらエラーをそのまま伝播し副作用を残さない")
func reselectAttachPropagatesErrorWithoutSideEffectsWhenAttachWorkingSourceFails() async throws {
    struct Boom: Error, Equatable {}

    let projectID = makeProjectID()
    let store = FakeWorkingSourceStore()
    // seedWorkingSourceを呼ばない = WorkingSourceRecordが無い状態（「なし」側の分岐を通す）。
    await store.setAttachToExistingProjectFailure(Boom())
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: FakePickedPhotoLoader(),
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )
    let input = makePickedPhotoInput()

    do {
        try await coordinator.reselectSource(projectID: projectID, input: input)
        Issue.record("エラーがthrowされるはずだった")
    } catch let error as Boom {
        #expect(error == Boom())
    } catch {
        Issue.record("想定外のエラー: \(error)")
    }

    // 「なし」側には手順3（旧ファイル削除）が存在しないため、書き込み失敗時に削除は一切起きて
    // はならない。registerOrphanの空チェックは現時点の未実装スコープ（論点3。performReselect
    // 失敗時の新規正規化ファイル後始末はIssue #36で追跡中、本ファイル未実装）を固定するもので
    // あり仕様上の禁止ではない。Issue #36実装時はこの期待値の見直しが必要（reviewer Warning W-1）。
    #expect(await managedFileStore.deleteCalls.isEmpty)
    #expect(await maintenanceStore.registerOrphanCalls.isEmpty)
}
