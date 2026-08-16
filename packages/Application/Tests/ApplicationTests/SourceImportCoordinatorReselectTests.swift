import Testing
import Foundation
import Domain
@testable import Application

// SourceImportCoordinator.reselectSource（再選択 Saga。Issue #8 サブプロジェクト5 A2 Task 3）の
// 検証。
//
// 正本: image-pipeline.md 5章「再選択後の Saga」（手順1〜3）。
//   1. 向きを正規化した原寸ファイルを作成し、EXIFを読む
//   2. 単一DBトランザクションでWorkingSourceRecordの置換等を行う
//      （WorkingSourceRecordあり → replaceWorkingSource。なし → attachWorkingSourceToExistingProject。
//      本ファイルは「あり」側のみを対象とする。「なし」側はTask 4の担当のため実装・専用テストの
//      いずれも対象外）
//   3. 置換された旧sourceFileを削除する（失敗したらPendingFileDeletionへ積む）
//
// 計画書（docs/superpowers/plans/2026-08-15-subproject5-a2-source-import.md）Task 3 Step 5の
// 4つの不変条件を、1件ずつ独立したテストとして固定する。

/// あり側の標準フィクスチャ: FakeWorkingSourceStore へ既存の WorkingSourceRecord を仕込む。
/// 戻り値の sourceFile は input.importedFile / photo.source.file とは別の ManagedFileID を持つ
/// （取り違えを弁別できるよう、常に新規UUIDを割り当てる WorkingSourceFileRef を使う）。
private func makeWorkingSourceFileRef() throws -> WorkingSourceFileRef {
    let ref = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))
    return try #require(WorkingSourceFileRef(ref))
}

@Test("再選択はレコードがあればPickedPhotoLoaderで正規化しWorkingSourceStoreへ単一トランザクションで置換する")
func reselectReplacesWorkingSourceWhenRecordExists() async throws {
    let projectID = makeProjectID()
    let existingSourceFile = try makeWorkingSourceFileRef()
    let store = FakeWorkingSourceStore()
    await store.seedWorkingSource(
        WorkingSourceRecord(projectID: projectID, sourceFile: existingSourceFile, createdAt: makeFixedClock()())
    )
    // photo.source.fileはmakeLoadedPhoto()呼び出しのたびに別UUIDを生成するため、existingSourceFile
    // ・input.importedFileのいずれとも異なる。3者の取り違え（旧ファイルを新ファイルとして登録する等）
    // を弁別できる（SourceImportCoordinatorImportTests.swift の同種コメントと同じ理由）。
    let photo = makeLoadedPhoto()
    let loader = FakePickedPhotoLoader(result: photo)
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.seedExistingFile(existingSourceFile.ref)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        managedFileStore: managedFileStore
    )
    let input = makePickedPhotoInput()

    try await coordinator.reselectSource(projectID: projectID, input: input)

    #expect(await store.loadWorkingSourceCalls == [projectID])
    #expect(await loader.loadCalls == [input.importedFile])
    let calls = await store.replaceWorkingSourceCalls
    #expect(calls.count == 1)
    let call = try #require(calls.first)

    #expect(call.projectID == projectID)
    // newSourceFileはローダーが返した正規化ファイル（photo.source.file）由来でなければならない。
    // 旧ファイル（existingSourceFile）やinput.importedFileを取り違えると、再選択のたびに素材の
    // 実体を失う致命的なバグになる（SourceImportCoordinatorImportTests.swift Critical 3と同型）。
    #expect(call.newSourceFile.ref == photo.source.file)
    #expect(call.replacedAt == makeFixedClock()())
    #expect(call.capture == photo.capture)
    #expect(call.libraryCreationDate == input.libraryCreationDate)
    #expect(call.representation == input.representation)
    #expect(call.sourceLocator.photoLibraryLocalIdentifier == input.providerAssetIdentifier)
}

// MARK: - 不変条件1: 成功経路で旧sourceFileが削除される

@Test("再選択が成功したら置換された旧sourceFileが削除される")
func reselectDeletesReplacedSourceFileOnSuccess() async throws {
    let projectID = makeProjectID()
    let existingSourceFile = try makeWorkingSourceFileRef()
    let store = FakeWorkingSourceStore()
    await store.seedWorkingSource(
        WorkingSourceRecord(projectID: projectID, sourceFile: existingSourceFile, createdAt: makeFixedClock()())
    )
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.seedExistingFile(existingSourceFile.ref)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: FakePickedPhotoLoader(),
        workingSourceStore: store,
        managedFileStore: managedFileStore
    )
    let input = makePickedPhotoInput()

    try await coordinator.reselectSource(projectID: projectID, input: input)

    // 削除対象は「置換された旧sourceFile」（existingSourceFile）であり、新しく作られた
    // 正規化ファイルやinput.importedFileではない（正本「置換された旧sourceFileを削除する」）。
    #expect(await managedFileStore.deleteCalls == [existingSourceFile.ref])
}

// MARK: - 不変条件2: 削除に失敗したらPendingFileDeletionへ積む

@Test("旧sourceFileの削除が失敗してもregisterOrphanが成功すれば再選択全体は成功する")
func reselectSucceedsWhenDeleteFailsButRegisterOrphanSucceeds() async throws {
    struct DeleteBoom: Error, Equatable {}

    let projectID = makeProjectID()
    let existingSourceFile = try makeWorkingSourceFileRef()
    let store = FakeWorkingSourceStore()
    await store.seedWorkingSource(
        WorkingSourceRecord(projectID: projectID, sourceFile: existingSourceFile, createdAt: makeFixedClock()())
    )
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.seedExistingFile(existingSourceFile.ref)
    await managedFileStore.setDeleteFailure(DeleteBoom())
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: FakePickedPhotoLoader(),
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )
    let input = makePickedPhotoInput()

    // 手順2は成功しているため、手順3の削除失敗はSaga全体を失敗させない（正本「削除に失敗したら
    // PendingFileDeletionへ積む」）。throwせず正常に完了することそのものが不変条件の主張であり、
    // ここでcatchせずtry awaitするのが検証になる。
    try await coordinator.reselectSource(projectID: projectID, input: input)

    #expect(await maintenanceStore.registerOrphanCalls == [existingSourceFile.ref])
}

@Test("旧sourceFileの削除もregisterOrphanも失敗したら削除失敗の理由をcauseに保持したままthrowする")
func reselectThrowsCleanupPreservingErrorWhenDeleteAndRegisterOrphanBothFail() async throws {
    struct DeleteBoom: Error, Equatable {}
    struct RegisterOrphanBoom: Error, Equatable {}

    let projectID = makeProjectID()
    let existingSourceFile = try makeWorkingSourceFileRef()
    let store = FakeWorkingSourceStore()
    await store.seedWorkingSource(
        WorkingSourceRecord(projectID: projectID, sourceFile: existingSourceFile, createdAt: makeFixedClock()())
    )
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.seedExistingFile(existingSourceFile.ref)
    await managedFileStore.setDeleteFailure(DeleteBoom())
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    await maintenanceStore.setRegisterOrphanFailure(RegisterOrphanBoom())
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
    } catch let error as CleanupPreservingError {
        #expect(error.cause is DeleteBoom)
        #expect(error.cleanupFailure is RegisterOrphanBoom)
    } catch {
        Issue.record("想定外のエラー: \(error)")
    }
}

// MARK: - 不変条件3: DB確定より前に旧ファイルを削除しない

@Test(
    "DB確定より前に旧sourceFileを削除しない",
    .timeLimit(.minutes(1))
)
func reselectDoesNotDeleteReplacedSourceFileBeforeDatabaseCommit() async throws {
    let projectID = makeProjectID()
    let existingSourceFile = try makeWorkingSourceFileRef()
    let store = FakeWorkingSourceStore()
    await store.seedWorkingSource(
        WorkingSourceRecord(projectID: projectID, sourceFile: existingSourceFile, createdAt: makeFixedClock()())
    )
    let gate = OneShotGate()
    await store.setGate(gate)
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.seedExistingFile(existingSourceFile.ref)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: FakePickedPhotoLoader(),
        workingSourceStore: store,
        managedFileStore: managedFileStore
    )
    let input = makePickedPhotoInput()

    let task = Task { try await coordinator.reselectSource(projectID: projectID, input: input) }
    while await store.replaceWorkingSourceCalls.isEmpty {
        await Task.yield()
    }

    // replaceWorkingSourceがゲートで保留されている間は、旧sourceFileの削除がまだ起きていない
    // ことを確認する（gate.wait()はキャンセルの影響を受けず開くまで確実に保留し続けるため、
    // これは真のレースではなく決定的な検証である）。
    let deleteCallsWhileBlocked = await managedFileStore.deleteCalls
    #expect(deleteCallsWhileBlocked.isEmpty)

    await gate.open()
    try await task.value

    let deleteCallsAfterCommit = await managedFileStore.deleteCalls
    #expect(deleteCallsAfterCommit == [existingSourceFile.ref])
}

/// 不変条件3の関連テスト: replaceWorkingSource（手順2）自体が失敗しDBが結局確定しなかった
/// （ロールバックした）ケース。reviewer が mutation テストで実証した Critical 2:
/// `performReselect` の catch 節（または replaceWorkingSource 呼び出し直後）に「旧sourceFileを
/// 削除する」危険なコードを注入しても既存の155 testsが全緑のままだった。DBが確定しなかった以上、
/// 旧sourceFileはまだ「置換された旧ファイル」として参照され続けているはずであり、削除してよい
/// 根拠がない（reselectDoesNotDeleteReplacedSourceFileBeforeDatabaseCommitが検証する「保留中＝
/// まだ確定していない」ケースと対を成す、「確定に失敗した」ケース）。
@Test("replaceWorkingSourceが失敗したら旧sourceFileを削除せずエラーをthrowする")
func reselectDoesNotDeleteReplacedSourceFileWhenReplaceWorkingSourceFails() async throws {
    struct Boom: Error, Equatable {}

    let projectID = makeProjectID()
    let existingSourceFile = try makeWorkingSourceFileRef()
    let store = FakeWorkingSourceStore()
    await store.seedWorkingSource(
        WorkingSourceRecord(projectID: projectID, sourceFile: existingSourceFile, createdAt: makeFixedClock()())
    )
    await store.setReplaceWorkingSourceFailure(Boom())
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.seedExistingFile(existingSourceFile.ref)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: FakePickedPhotoLoader(),
        workingSourceStore: store,
        managedFileStore: managedFileStore
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

    // DBが確定しなかった以上、手順3（旧sourceFileの削除）へ到達してはならない。
    #expect(await managedFileStore.deleteCalls.isEmpty)
}

// MARK: - 不変条件4: 補償削除（registerOrphan）はキャンセル済み文脈でも完走する
//
// SourceImportCoordinatorImportCleanupTests.swift の
// deleteImportedFileRegisterOrphanIsShieldedFromCancellation と同型。replaceWorkingSourceが
// ゲートで保留中に呼び出し元のTaskをキャンセルしてからゲートを開け、手順3のqueue.run（delete）が
// SerialTaskQueue自身のキャンセルチェックでCancellationErrorをthrowする状況を作る
// （managedFileStore.delete自体は呼ばれない）。この削除失敗によって発火する補償registerOrphanが
// runShieldedFromCancellation（Cleanup.swift）で守られ、キャンセル済み文脈でも完走することを
// 検証する。

@Test(
    "旧sourceFile削除失敗時の補償registerOrphanはキャンセル済み文脈でもシールドされ完走する",
    .timeLimit(.minutes(1))
)
func reselectRegisterOrphanIsShieldedFromCancellation() async throws {
    let projectID = makeProjectID()
    let existingSourceFile = try makeWorkingSourceFileRef()
    let store = FakeWorkingSourceStore()
    await store.seedWorkingSource(
        WorkingSourceRecord(projectID: projectID, sourceFile: existingSourceFile, createdAt: makeFixedClock()())
    )
    let gate = OneShotGate()
    await store.setGate(gate)
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.seedExistingFile(existingSourceFile.ref)
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    // registerOrphanChecksCancellationを立てて初めて、シールドを外すとregisterOrphanの最初の
    // 呼び出しがcheckCancellationで即throwし失敗することを検出できる
    // （FakeExportSagaStore.discardExportChecksCancellationと同じ理由）。
    await maintenanceStore.setRegisterOrphanChecksCancellation(true)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: FakePickedPhotoLoader(),
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )
    let input = makePickedPhotoInput()

    let task = Task { try await coordinator.reselectSource(projectID: projectID, input: input) }
    while await store.replaceWorkingSourceCalls.isEmpty {
        await Task.yield()
    }
    // replaceWorkingSourceがゲート待ちで保留されている間にキャンセルする。この時点でまだ
    // Task.isCancelledはtrueのまま、gate.wait()は影響を受けずopen()を待ち続ける。
    task.cancel()
    await gate.open()

    // ゲートが開くと手順2は（失敗注入していないため）成功し、手順3のqueue.run（delete）へ
    // 進む。呼び出し元のtaskは既にキャンセル済みのため、SerialTaskQueue.run自身のキャンセル
    // チェックがmanagedFileStore.deleteを呼び出す前にCancellationErrorをthrowする
    // （削除は実行されない）。deleteReplacedSourceFileのcatchはこれを削除失敗として扱い
    // registerOrphanを試みる。これがrunShieldedFromCancellationで守られていれば、キャンセル
    // 済み文脈でも完走しSaga全体は成功として返る（手順2は既にコミット済みのため）。
    try await task.value

    let deleteCalls = await managedFileStore.deleteCalls
    #expect(deleteCalls.isEmpty)
    #expect(await maintenanceStore.registerOrphanCalls == [existingSourceFile.ref])
}
