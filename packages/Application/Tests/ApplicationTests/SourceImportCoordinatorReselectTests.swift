import Testing
import Foundation
import Domain
@testable import Application

// SourceImportCoordinator.reselectSource（再選択 Saga。Issue #8 サブプロジェクト5 A2 Task 3）の
// 検証。
//
// 正本: image-pipeline.md 5章「再選択後の Saga」（手順1〜4）。
//   1. 向きを正規化した原寸ファイルを作成し、EXIFを読む
//   2. 単一DBトランザクションでWorkingSourceRecordの置換等を行う
//      （WorkingSourceRecordあり → replaceWorkingSource。なし → attachWorkingSourceToExistingProject。
//      本ファイルは「あり」側のみを対象とする。「なし」側はTask 4の担当のため実装・専用テストの
//      いずれも対象外）
//   3. 置換された旧sourceFileを削除する（失敗したらPendingFileDeletionへ積む）
//   4. 取り込みファイル（PickedPhotoInput.importedFile）を削除する
//      （失敗したらPendingFileDeletionへ積む。Issue #36で追加）
//
// 計画書（docs/superpowers/plans/2026-08-15-subproject5-a2-source-import.md）Task 3 Step 5の
// 4つの不変条件を、1件ずつ独立したテストとして固定する。手順4固有の削除失敗経路・削除可否判定の
// 単独検証（C-1相当）は SourceImportCoordinatorReselectCleanupTests.swift へ分離した
// （SourceImportCoordinatorImportTests.swift / SourceImportCoordinatorImportCleanupTests.swift の
// 分割と同じ理由。ファイル400行制限〈Global Constraints〉）。

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

// MARK: - 呼び出し順序: loadがloadWorkingSourceより先に呼ばれる
//
// reviewer Warning S2: image-pipeline.md 5章の正本は手順1（load）→手順2の分岐判定
// （loadWorkingSource）の順を定めており、現在の実装（SourceImportCoordinator+Reselect.swift）は
// この順を守っているが、Task 3→4間で実装の呼び出し順序が一時的に入れ替わった実績があるにも
// かかわらず、順序そのものを固定するテストが無かった。CallOrderRecorder（Fakes/
// CallOrderRecorder.swift）を両Fakeへ共通で注入し、Fakeを跨いだ呼び出し順序を検証する。

@Test("再選択はloadをloadWorkingSourceより先に呼ぶ")
func reselectCallsLoadBeforeLoadWorkingSource() async throws {
    let projectID = makeProjectID()
    let existingSourceFile = try makeWorkingSourceFileRef()
    let store = FakeWorkingSourceStore()
    await store.seedWorkingSource(
        WorkingSourceRecord(projectID: projectID, sourceFile: existingSourceFile, createdAt: makeFixedClock()())
    )
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.seedExistingFile(existingSourceFile.ref)
    let loader = FakePickedPhotoLoader()
    let recorder = CallOrderRecorder()
    await loader.setCallOrderRecorder(recorder)
    await store.setCallOrderRecorder(recorder)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        managedFileStore: managedFileStore
    )
    let input = makePickedPhotoInput()

    try await coordinator.reselectSource(projectID: projectID, input: input)

    // 正本どおりload（手順1）がloadWorkingSource（手順2の分岐判定）より先に呼ばれることを、
    // Fakeを跨いだ共通の順序記録で固定する。
    #expect(await recorder.entries == ["load", "loadWorkingSource"])
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

    // 削除対象は「置換された旧sourceFile」（existingSourceFile。手順3）と「取り込みファイル」
    // （input.importedFile。手順4）の両方である（正本「再選択後のSaga」手順3・4。Issue #36で
    // 手順4の削除を追加した）。呼び出し順は手順3→手順4（reselectSource参照）。
    #expect(await managedFileStore.deleteCalls == [existingSourceFile.ref, input.importedFile])
    // W-1: FakeWorkingSourceStoreが模すPendingFileDeletion相当の記録は旧sourceFileのみ
    // （取り込みファイルの削除はDBのreplaceWorkingSource経路を通らないためこの記録には
    // 現れない。削除成功そのものはmanagedFileStore.deleteCallsで検証済み）。
    #expect(await store.pendingFileDeletionFileRefs == [existingSourceFile.ref])
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
    // ここでcatchせずtry awaitするのが検証になる。setDeleteFailureは全delete呼び出しに影響する
    // ため、手順4（取り込みファイルの削除）も同様に失敗しregisterOrphanへ積まれる
    // （Issue #36。どちらか一方の失敗が他方の試行を妨げない設計。reselectSource参照）。
    try await coordinator.reselectSource(projectID: projectID, input: input)

    #expect(await maintenanceStore.registerOrphanCalls == [existingSourceFile.ref, input.importedFile])
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
        // 手順3の削除失敗（真因）を優先して保持する（Cleanup.swiftの契約）。手順4も同様に
        // 削除・registerOrphanとも失敗するが、先に発生した手順3側の失敗だけが呼び出し元へ
        // 伝わる（Issue #36「両方試みるが最初の失敗を保持する」設計。reselectSource参照）。
        #expect(error.cause is DeleteBoom)
        #expect(error.cleanupFailure is RegisterOrphanBoom)
    } catch {
        Issue.record("想定外のエラー: \(error)")
    }

    // 手順3が失敗した後も手順4の削除は試みられる（諦めない）ことを、registerOrphanの呼び出し
    // 件数で確認する（両方ともdelete・registerOrphanが失敗するため、両方がregisterOrphanCallsに
    // 記録される）。
    let registered = await maintenanceStore.registerOrphanCalls
    #expect(registered.count == 2)
    #expect(registered.contains(existingSourceFile.ref))
    #expect(registered.contains(input.importedFile))
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

    // 手順3（旧sourceFile）・手順4（取り込みファイル）とも、DB確定（ゲートが開く）後に削除される
    // （Issue #36で手順4の削除を追加した）。
    let deleteCallsAfterCommit = await managedFileStore.deleteCalls
    #expect(deleteCallsAfterCommit == [existingSourceFile.ref, input.importedFile])
}

/// 不変条件3の関連テスト: replaceWorkingSource（手順2）自体が失敗しDBが結局確定しなかった
/// （ロールバックした）ケース。reviewer が mutation テストで実証した Critical 2:
/// `performReselect` の catch 節（または replaceWorkingSource 呼び出し直後）に「旧sourceFileを
/// 削除する」危険なコードを注入しても既存の155 testsが全緑のままだった。DBが確定しなかった以上、
/// 旧sourceFileはまだ「置換された旧ファイル」として参照され続けているはずであり、削除してよい
/// 根拠がない（reselectDoesNotDeleteReplacedSourceFileBeforeDatabaseCommitが検証する「保留中＝
/// まだ確定していない」ケースと対を成す、「確定に失敗した」ケース）。
///
/// Issue #36: 手順2が失敗した場合、作成済みのファイル（取り込み・正規化の両方）を
/// PendingFileDeletionへ積み、起動時の孤児GCに委ねる（正本「再選択後のSaga」「手順2が失敗した
/// 場合...」）。ここでは正規化ファイル（photo.source.file）が既に working/ へ書き込まれた後に
/// replaceWorkingSourceが失敗する状況を模すため、ローダーの結果を明示的に捕捉する。
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
    let photo = makeLoadedPhoto()
    let loader = FakePickedPhotoLoader(result: photo)
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.seedExistingFile(existingSourceFile.ref)
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
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

    // DBが確定しなかった以上、手順3（旧sourceFileの削除）へ到達してはならない。
    #expect(await managedFileStore.deleteCalls.isEmpty)
    // Issue #36本体: 取り込みファイル（input.importedFile）と正規化ファイル（photo.source.file）
    // の両方がPendingFileDeletion相当（registerOrphan）へ積まれる。旧sourceFile
    // （existingSourceFile.ref）は手順2失敗時点ではまだ「置換された旧ファイル」の判定
    // （replacedSourceFileToDelete）に到達していないため対象に含まれない。
    let registered = await maintenanceStore.registerOrphanCalls
    #expect(registered.count == 2)
    #expect(registered.contains(input.importedFile))
    #expect(registered.contains(photo.source.file))
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

    // ゲートが開くと手順2は（失敗注入していないため）成功し、手順3・4のqueue.run（delete）へ
    // 進む。呼び出し元のtaskは既にキャンセル済みのため、SerialTaskQueue.run自身のキャンセル
    // チェックがmanagedFileStore.deleteを呼び出す前にCancellationErrorをthrowする
    // （削除は実行されない。手順3・4のいずれも同様）。deleteReplacedSourceFile /
    // deleteReselectedImportedFileのcatchはこれを削除失敗として扱いregisterOrphanを試みる。
    // これがrunShieldedFromCancellationで守られていれば、キャンセル済み文脈でも両方完走し
    // Saga全体は成功として返る（手順2は既にコミット済みのため。Issue #36で手順4を追加）。
    try await task.value

    let deleteCalls = await managedFileStore.deleteCalls
    #expect(deleteCalls.isEmpty)
    #expect(await maintenanceStore.registerOrphanCalls == [existingSourceFile.ref, input.importedFile])
}

// 不変条件5（C-1: ローダーが既存sourceFileと同一IDを返しても実体を削除しない）と、手順4固有の
// 削除失敗経路・削除可否判定の単独検証は SourceImportCoordinatorReselectCleanupTests.swift へ
// 分離した（ファイル冒頭コメント参照。ファイル400行制限〈Global Constraints〉）。
