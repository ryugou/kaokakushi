import Testing
import Foundation
import Domain
@testable import Application

// SourceImportCoordinator.importPickedPhoto（インポートSaga。Issue #8 サブプロジェクト5 A2
// Task 2）の検証。
//
// 正本: image-pipeline.md 5章「インポートSaga」（手順1〜4）。
//   1. PickedPhotoInput.importedFile の所有権を受け取り、EXIFを読む
//   2. 向きを正規化した原寸ファイルを作成しworking/へ書き込む
//   3. 単一DBトランザクションでProject・キュー項目・WorkingSourceRecordを作成する
//   4. 取り込みファイルを削除する（削除に失敗したらPendingFileDeletionへ積む）
// 手順1〜2はPickedPhotoLoader.load(_:)へ委譲する（実装はMediaKit、スコープ外）。
//
// 計画書（docs/superpowers/plans/2026-08-15-subproject5-a2-source-import.md）Task 2 Step 5の
// 4つの不変条件を、1件ずつ独立したテストとして固定する。
//
// 手順4（削除失敗 → PendingFileDeletion）の失敗経路の検証は
// SourceImportCoordinatorImportCleanupTests.swift へ分離している（ファイル400行制限）。

@Test("インポートはPickedPhotoLoaderで正規化しWorkingSourceStoreへ単一トランザクションで登録する")
func importCreatesProjectWithNormalizedSource() async throws {
    // makeLoadedPhoto()・makePickedPhotoInput()は呼ぶたびに別UUIDを生成するため、
    // photo.source.file と input.importedFile は必ず異なる値になる。これにより
    // sourceFile の取り違え（reviewer 指摘 Critical 3: `sourceFile: WorkingSourceFileRef(
    // input.importedFile)!` のような変異）を弁別できる。
    let photo = makeLoadedPhoto()
    let loader = FakePickedPhotoLoader(result: photo)
    let store = FakeWorkingSourceStore()
    let coordinator = makeSourceImportCoordinator(pickedPhotoLoader: loader, workingSourceStore: store)
    let input = makePickedPhotoInput()

    let projectID = try await coordinator.importPickedPhoto(input)

    #expect(await loader.loadCalls == [input.importedFile])
    let created = await store.createProjectWithWorkingSourceCalls
    #expect(created.count == 1)
    let call = try #require(created.first)

    // sourceFileはローダーが返した正規化ファイル（photo.source.file）由来でなければならない。
    // input.importedFileを取り違えると、取り込んだ全プロジェクトが手順4の削除で素材の実体を
    // 失う致命的なバグになる（reviewer 指摘 Critical 3）。
    #expect(call.sourceFile.ref == photo.source.file)
    #expect(call.projectID == projectID)
    #expect(call.sourceLocator.photoLibraryLocalIdentifier == input.providerAssetIdentifier)
    #expect(call.capture == photo.capture)
    #expect(call.libraryCreationDate == input.libraryCreationDate)
    #expect(call.representation == input.representation)
    #expect(call.createdAt == makeFixedClock()())
}

// MARK: - W4: PickedPhotoLoader.loadが契約に反した種別を返した場合の診断
//
// reviewer 指摘 W4: SourceImportError.invalidNormalizedSourceKind はガード節としては存在するが
// どのテストからも実行されていなかった。MediaKit 実装が契約（processingTemporary種別で返す）に
// 反した場合に、型不整合のままDB書き込みへ進まず検出できることを固定する。

@Test("PickedPhotoLoader.loadが不正な種別のファイルを返したらinvalidNormalizedSourceKindをthrowする")
func importThrowsInvalidNormalizedSourceKindWhenLoadedSourceHasWrongKind() async throws {
    let invalidFile = ManagedFileRef(kind: .rasterTemporary, fileID: ManagedFileID(rawValue: UUID()))
    let invalidPhoto = LoadedPhoto(
        source: ImageSource(file: invalidFile, pixelSize: makePixelSize(), format: .jpeg),
        capture: makeLoadedPhoto().capture
    )
    let loader = FakePickedPhotoLoader(result: invalidPhoto)
    let store = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )
    let input = makePickedPhotoInput()

    do {
        _ = try await coordinator.importPickedPhoto(input)
        Issue.record("エラーがthrowされるはずだった")
    } catch let error as SourceImportError {
        #expect(error == .invalidNormalizedSourceKind(invalidFile))
    } catch {
        Issue.record("想定外のエラー: \(error)")
    }

    // 型不整合を検出した時点でDB書き込みへは進まない。しかしloadは成功しており
    // （実体はすでにworking/へ書き込まれ、invalidFileとしてLoadedPhotoに載って返ってきている）、
    // 型変換の成否に関わらずload成功時点のファイルは後始末対象に含める（W-b）。
    // 後始末の対象はimportedFileとinvalidFileの両方。
    #expect(await store.createProjectWithWorkingSourceCalls.isEmpty)
    #expect(await maintenanceStore.registerOrphanCalls == [input.importedFile, invalidFile])
}

// MARK: - 不変条件1: DB確定より前に取り込みファイルを削除しない

@Test(
    "DB確定より前に取り込みファイルを削除しない",
    .timeLimit(.minutes(1))
)
func importDoesNotDeleteImportedFileBeforeDatabaseCommit() async throws {
    let store = FakeWorkingSourceStore()
    let gate = OneShotGate()
    await store.setGate(gate)
    let managedFileStore = FakeManagedFileStore()
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: FakePickedPhotoLoader(),
        workingSourceStore: store,
        managedFileStore: managedFileStore
    )
    let input = makePickedPhotoInput()

    let task = Task { try await coordinator.importPickedPhoto(input) }
    while await store.createProjectWithWorkingSourceCalls.isEmpty {
        await Task.yield()
    }

    // createProjectWithWorkingSourceがゲートで保留されている間は、取り込みファイルの削除が
    // まだ起きていないことを確認する（gate.wait()はキャンセルの影響を受けず開くまで確実に
    // 保留し続けるため、これは真のレースではなく決定的な検証である）。
    let deleteCallsWhileBlocked = await managedFileStore.deleteCalls
    #expect(deleteCallsWhileBlocked.isEmpty)

    await gate.open()
    _ = try await task.value

    let deleteCallsAfterCommit = await managedFileStore.deleteCalls
    #expect(deleteCallsAfterCommit == [input.importedFile])
}

// MARK: - 不変条件2: 手順3が失敗したら取り込み・正規化の両ファイルをPendingFileDeletionへ積む

@Test("手順3が失敗したら取り込みファイルと正規化ファイルの両方をPendingFileDeletionへ積む")
func importRegistersBothFilesAsOrphansWhenTransactionFails() async throws {
    struct TransactionBoom: Error, Equatable {}

    let photo = makeLoadedPhoto()
    let loader = FakePickedPhotoLoader(result: photo)
    let store = FakeWorkingSourceStore()
    await store.setCreateProjectWithWorkingSourceFailure(TransactionBoom())
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )
    let input = makePickedPhotoInput()

    await #expect(throws: TransactionBoom.self) {
        try await coordinator.importPickedPhoto(input)
    }

    let registered = await maintenanceStore.registerOrphanCalls
    #expect(registered.count == 2)
    #expect(registered.contains(input.importedFile))
    #expect(registered.contains(photo.source.file))
}

// MARK: - W2: 手順3失敗時、1件目のregisterOrphanが失敗しても2件目を試みる
//
// reviewer 指摘 W2: 旧実装は importedFile への registerOrphan が失敗すると、その場で
// 例外が伝播し normalizedSourceFile.ref への registerOrphan を一度も試みなかった
// （逐次 try のみで2件目が実行されない）。両方の孤児候補をベストエフォートで登録すべき
// （どちらも消し忘れると working/ 実体が永久に残る）ため、1件目の失敗が2件目の試行を
// 妨げないことを固定する。

@Test("手順3失敗時に1件目のregisterOrphanが失敗しても2件目のregisterOrphanを試みる")
func importAttemptsSecondOrphanRegistrationEvenWhenFirstFails() async throws {
    struct TransactionBoom: Error, Equatable {}
    struct RegisterOrphanBoom: Error, Equatable {}

    let photo = makeLoadedPhoto()
    let loader = FakePickedPhotoLoader(result: photo)
    let store = FakeWorkingSourceStore()
    await store.setCreateProjectWithWorkingSourceFailure(TransactionBoom())
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    await maintenanceStore.setRegisterOrphanFailure(RegisterOrphanBoom())
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )
    let input = makePickedPhotoInput()

    do {
        _ = try await coordinator.importPickedPhoto(input)
        Issue.record("エラーがthrowされるはずだった")
    } catch let error as CleanupPreservingError {
        // 真因（手順3の失敗）を優先して保持する（Cleanup.swift の契約）。
        #expect(error.cause is TransactionBoom)
        #expect(error.cleanupFailure is RegisterOrphanBoom)
    } catch {
        Issue.record("想定外のエラー: \(error)")
    }

    let registered = await maintenanceStore.registerOrphanCalls
    #expect(registered.count == 2)
    #expect(registered.contains(input.importedFile))
    #expect(registered.contains(photo.source.file))
}

// MARK: - W3: load自体が失敗した場合もimportedFileをregisterOrphanへ積む
//
// reviewer 指摘 W3: PickedPhotoLoader.load が working/ へ正規化ファイルを書き込んだ後に
// 失敗しうる（例: 書き込み後のEXIF再読み込みで失敗）契約のため、load 自体の throw でも
// importedFile の所有権を手放してはならない。旧実装は load をキューの外で（後始末の
// catch の外側で）呼んでいたため、load 失敗時は importedFile がどこにも登録されなかった。

@Test("loadが失敗した場合も取り込みファイルをPendingFileDeletionへ積む")
func importRegistersImportedFileAsOrphanWhenLoadFails() async throws {
    struct LoadBoom: Error, Equatable {}

    let loader = FakePickedPhotoLoader()
    await loader.setFailure(LoadBoom())
    let store = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )
    let input = makePickedPhotoInput()

    await #expect(throws: LoadBoom.self) {
        try await coordinator.importPickedPhoto(input)
    }

    let registered = await maintenanceStore.registerOrphanCalls
    #expect(registered == [input.importedFile])
    #expect(await store.createProjectWithWorkingSourceCalls.isEmpty)
}

// MARK: - 不変条件3: PickedPhotoInput.importedFile を作り直さない

@Test("PickedPhotoInput.importedFileを作り直さない")
func importDoesNotRecreateImportedFile() async throws {
    let managedFileStore = FakeManagedFileStore()
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: FakePickedPhotoLoader(),
        managedFileStore: managedFileStore
    )
    let input = makePickedPhotoInput()

    _ = try await coordinator.importPickedPhoto(input)

    let createFileCalls = await managedFileStore.createFileCalls
    #expect(createFileCalls.isEmpty)
}

// MARK: - 不変条件4: DB登録の完了前に成功を呼び出し元へ返さない

@Test(
    "DB登録の完了前に成功を呼び出し元へ返さない",
    .timeLimit(.minutes(1))
)
func importDoesNotReturnBeforeDatabaseRegistrationCompletes() async throws {
    let store = FakeWorkingSourceStore()
    let gate = OneShotGate()
    await store.setGate(gate)
    let coordinator = makeSourceImportCoordinator(pickedPhotoLoader: FakePickedPhotoLoader(), workingSourceStore: store)
    let input = makePickedPhotoInput()

    let task = Task { try await coordinator.importPickedPhoto(input) }
    while await store.createProjectWithWorkingSourceCalls.isEmpty {
        await Task.yield()
    }

    // importPickedPhotoの完了を、task.value自体を待たない別系統のフラグで観測する。
    // task.valueをTaskGroup内で待ってからゲートを開ける前にスコープを抜けようとすると、
    // 構造化並行性がスコープ終了時に残った子タスクの完了(task.value)を待ち続けデッドロック
    // する（Task.valueは待ち手のキャンセルを無視して対象タスクの完了までブロックするため）。
    // ここでは完全に非構造の別Taskで観測することでこれを避ける
    // （ObservedFlagと同じ方針。SerialTaskQueueTests.swift参照）。
    let completionFlag = ImportCompletionFlag()
    Task {
        _ = try? await task.value
        await completionFlag.markCompleted()
    }

    try await Task.sleep(for: .milliseconds(100))
    #expect(await completionFlag.isCompleted == false)

    await gate.open()
    _ = try await task.value
    #expect(await store.createProjectWithWorkingSourceCalls.count == 1)
}

/// task.value自体を待たずに完了を観測するためのフラグ（ObservedFlagと同じ方針。
/// SerialTaskQueueTests.swift参照）。
private actor ImportCompletionFlag {
    private(set) var isCompleted = false
    func markCompleted() { isCompleted = true }
}

// MARK: - Step 6: 手順3失敗時の補償registerOrphanのキャンセルシールド
//
// ExportCoordinatorGenerateTests.swift の innerCatchDiscardExportIsShieldedFromCancellation
// と同型。createProjectWithWorkingSourceが呼ばれた直後（ゲートで保留中）に呼び出し元のTaskを
// キャンセルしてからゲートを開け、手順3の失敗によって発火する補償registerOrphanが
// runShieldedFromCancellation（Cleanup.swift）で守られ、キャンセル済み文脈でも完走することを
// 検証する。

@Test(
    "手順3失敗時の補償registerOrphanはキャンセル済み文脈でもシールドされ完走する",
    .timeLimit(.minutes(1))
)
func compensatingRegisterOrphanIsShieldedFromCancellationOnTransactionFailure() async throws {
    struct TransactionBoom: Error, Equatable {}

    let photo = makeLoadedPhoto()
    let loader = FakePickedPhotoLoader(result: photo)
    let store = FakeWorkingSourceStore()
    await store.setCreateProjectWithWorkingSourceFailure(TransactionBoom())
    let gate = OneShotGate()
    await store.setGate(gate)
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    // registerOrphanChecksCancellationを立てて初めて、シールドを外すとregisterOrphanの最初の
    // 呼び出しがcheckCancellationで即throwし失敗することを検出できる
    // （FakeExportSagaStore.discardExportChecksCancellationと同じ理由）。
    await maintenanceStore.setRegisterOrphanChecksCancellation(true)

    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )
    let input = makePickedPhotoInput()

    let task = Task { try await coordinator.importPickedPhoto(input) }
    while await store.createProjectWithWorkingSourceCalls.isEmpty {
        await Task.yield()
    }
    // createProjectWithWorkingSourceがゲート待ちで保留されている間にキャンセルする。この時点で
    // まだTask.isCancelledはtrueのまま、gate.wait()は影響を受けずopen()を待ち続ける。
    task.cancel()
    await gate.open()

    // ゲートが開くとcreateProjectWithWorkingSourceはTransactionBoomをthrowする（失敗注入）。
    // 補償（registerOrphan x2）の成否に関わらず、runCleanupPreservingErrorが元のエラーを
    // 最優先でthrowするため、呼び出し元にはTransactionBoomが届く（CancellationErrorではない）。
    await #expect(throws: TransactionBoom.self) {
        try await task.value
    }

    let registered = await maintenanceStore.registerOrphanCalls
    #expect(registered.count == 2)
    #expect(registered.contains(input.importedFile))
    #expect(registered.contains(photo.source.file))
}

// 手順4（削除失敗 → PendingFileDeletion）の失敗経路のテストは
// SourceImportCoordinatorImportCleanupTests.swift へ分離した（このファイルに追記すると
// ファイル400行制限を超えるため。SourceImportTestSupport.swift 冒頭コメントと同じ理由）。
