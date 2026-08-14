import Testing
import Foundation
import Domain
@testable import Application

// SourceImportCoordinator.importPickedPhoto（インポートSaga。Issue #8 サブプロジェクト5 A2
// Task 2）手順4（取り込みファイルの削除）が失敗した場合の後始末経路の検証。
//
// 正本: image-pipeline.md 5章「インポートSaga」手順4「取り込みファイルを削除する（削除に
// 失敗したらPendingFileDeletionへ積む）」。
//
// SourceImportCoordinatorImportTests.swift から分離した（そちらに追記すると
// ファイル400行制限〈Global Constraints〉を超えるため。SourceImportTestSupport.swift
// 冒頭コメントと同じ理由）。
//
// reviewer 一次レビュー Critical 2: deleteImportedFile の catch 節（削除失敗時に
// registerOrphan で積む経路）がどのテストからも実行されていなかった。3件で固定する:
// 1. 削除失敗 → registerOrphan 成功 → Saga 全体は成功
// 2. 削除失敗 → registerOrphan も失敗 → CleanupPreservingError(cause: 削除失敗)
// 3. registerOrphan 呼び出し自体のキャンセルシールド
//    （SourceImportCoordinatorImportTests.swift の Step6 と同型）

@Test("手順4の削除が失敗してもregisterOrphanが成功すればインポート全体は成功する")
func importSucceedsWhenDeleteFailsButRegisterOrphanSucceeds() async throws {
    struct DeleteBoom: Error, Equatable {}

    let store = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.setDeleteFailure(DeleteBoom())
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: FakePickedPhotoLoader(),
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )
    let input = makePickedPhotoInput()

    // 手順3は成功しているため、手順4の削除失敗はSaga全体を失敗させない（正本「削除に失敗したら
    // PendingFileDeletionへ積む」）。throwせず正常にProjectIDを返すことそのものが不変条件の
    // 主張であり、ここでcatchせずtry awaitするのが検証になる。
    let projectID = try await coordinator.importPickedPhoto(input)

    let created = await store.createProjectWithWorkingSourceCalls
    #expect(created.first?.projectID == projectID)
    #expect(await maintenanceStore.registerOrphanCalls == [input.importedFile])
}

@Test("手順4の削除もregisterOrphanも失敗したら削除失敗の理由をcauseに保持したままthrowする")
func importThrowsCleanupPreservingErrorWhenDeleteAndRegisterOrphanBothFail() async throws {
    struct DeleteBoom: Error, Equatable {}
    struct RegisterOrphanBoom: Error, Equatable {}

    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.setDeleteFailure(DeleteBoom())
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    await maintenanceStore.setRegisterOrphanFailure(RegisterOrphanBoom())
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: FakePickedPhotoLoader(),
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )
    let input = makePickedPhotoInput()

    do {
        _ = try await coordinator.importPickedPhoto(input)
        Issue.record("エラーがthrowされるはずだった")
    } catch let error as CleanupPreservingError {
        // 削除失敗（真因）を優先して保持する。registerOrphan自体の失敗理由も失わない
        // （Global Constraints「エラーの握りつぶし禁止」）。
        #expect(error.cause is DeleteBoom)
        #expect(error.cleanupFailure is RegisterOrphanBoom)
    } catch {
        Issue.record("想定外のエラー: \(error)")
    }
}

@Test(
    "手順4のregisterOrphanはキャンセル済み文脈でもシールドされ完走する",
    .timeLimit(.minutes(1))
)
func deleteImportedFileRegisterOrphanIsShieldedFromCancellation() async throws {
    let photo = makeLoadedPhoto()
    let loader = FakePickedPhotoLoader(result: photo)
    let store = FakeWorkingSourceStore()
    let gate = OneShotGate()
    await store.setGate(gate)
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    // registerOrphanChecksCancellationを立てて初めて、シールドを外すとregisterOrphanの最初の
    // 呼び出しがcheckCancellationで即throwし失敗することを検出できる（Step6と同じ理由）。
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

    // ゲートが開くと手順3は（失敗注入していないため）成功し、手順4のqueue.run（delete）へ
    // 進む。呼び出し元のtaskは既にキャンセル済みのため、SerialTaskQueue.run自身のキャンセル
    // チェック（4.2「キュー投入前」）がmanagedFileStore.deleteを呼び出す前にCancellationErrorを
    // throwする（削除は実行されない）。deleteImportedFileの catch はこれを削除失敗として扱い
    // registerOrphanを試みる。これがrunShieldedFromCancellationで守られていれば、キャンセル
    // 済み文脈でも完走しSaga全体は成功として返る（手順3は既にコミット済みのため）。
    let projectID = try await task.value
    _ = projectID

    let deleteCalls = await managedFileStore.deleteCalls
    #expect(deleteCalls.isEmpty)
    #expect(await maintenanceStore.registerOrphanCalls == [input.importedFile])
}
