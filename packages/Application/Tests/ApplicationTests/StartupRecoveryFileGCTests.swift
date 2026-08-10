import Foundation
import Testing
import Domain
@testable import Application

// StartupRecoveryFileGCTests — 起動時の孤児ファイル GC（Issue #7 Task 11）。
//
// 正本: architecture.md 7.5「孤児ファイルのGC」手順(1)〜(3)と MaintenanceStore 対応表、
// export-saga.md 5章 手順2。FakeMaintenanceStore / FakeManagedFileStore だけを注入し、
// StartupRecoveryCoordinator.swift の削除経路・登録経路・失敗時の扱いを検証する
// （ExportSagaStore / OutputDeliveryStore 側の実行順序は StartupRecoveryTests.swift が正本）。

private struct Boom: Error, Equatable {}

@Test("起動時に未処理のPendingFileDeletionが削除されclearPendingFileDeletionされること")
private func pendingFileDeletionIsDeletedAndCleared() async throws {
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    await maintenanceStore.seedPendingFileDeletion(ref)
    await managedFileStore.seedExistingFile(ref)
    let coordinator = makeCoordinator(maintenanceStore: maintenanceStore, managedFileStore: managedFileStore)

    let report = try await coordinator.runStartupRecovery()

    #expect(await managedFileStore.deleteCalls == [ref])
    #expect(await maintenanceStore.clearPendingFileDeletionCalls == [ref])
    #expect(await maintenanceStore.containsPendingFileDeletion(ref) == false)
    #expect(report.deletedFileCount == 1)
    #expect(report.failedFileDeletionCount == 0)
}

@Test("削除に失敗した項目はclearPendingFileDeletionされず、登録が残ること（次回再試行できること）")
private func failedDeletionLeavesRegistrationForRetry() async throws {
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    await maintenanceStore.seedPendingFileDeletion(ref)
    await managedFileStore.setDeleteFailure(Boom())
    let coordinator = makeCoordinator(maintenanceStore: maintenanceStore, managedFileStore: managedFileStore)

    let report = try await coordinator.runStartupRecovery()

    #expect(await managedFileStore.deleteCalls == [ref])
    #expect(await maintenanceStore.clearPendingFileDeletionCalls.isEmpty)
    #expect(await maintenanceStore.containsPendingFileDeletion(ref) == true)
    #expect(report.deletedFileCount == 0)
    #expect(report.failedFileDeletionCount == 1)
    // 削除失敗の原因がkind付きでreportへ運ばれること（Task 11 レビュー W-1）。
    #expect(report.failedFileDeletions.map(\.kind) == [.output])
}

@Test("種別ごとの差集合がregisterOrphanへ登録され、その後削除されること")
private func orphanFilesAreRegisteredThenDeleted() async throws {
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let referencedID = ManagedFileID(rawValue: UUID())
    let orphanID = ManagedFileID(rawValue: UUID())
    let referencedRef = ManagedFileRef(kind: .output, fileID: referencedID)
    let orphanRef = ManagedFileRef(kind: .output, fileID: orphanID)
    await managedFileStore.seedExistingFile(referencedRef)
    await managedFileStore.seedExistingFile(orphanRef)
    await maintenanceStore.seedReferencedFileIDs(kind: .output, ids: [referencedID])
    let coordinator = makeCoordinator(maintenanceStore: maintenanceStore, managedFileStore: managedFileStore)

    let report = try await coordinator.runStartupRecovery()

    #expect(await maintenanceStore.registerOrphanCalls == [orphanRef])
    #expect(await managedFileStore.deleteCalls == [orphanRef])
    #expect(await maintenanceStore.containsPendingFileDeletion(orphanRef) == false)
    #expect(report.deletedFileCount == 1)
}

@Test(".historyThumbnailが孤児GCの対象外であること")
private func historyThumbnailIsExcludedFromOrphanGC() async throws {
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let orphanRef = ManagedFileRef(kind: .historyThumbnail, fileID: ManagedFileID(rawValue: UUID()))
    await managedFileStore.seedExistingFile(orphanRef)
    let coordinator = makeCoordinator(maintenanceStore: maintenanceStore, managedFileStore: managedFileStore)

    _ = try await coordinator.runStartupRecovery()

    #expect(await maintenanceStore.listExistingFileIDsCalls.contains(.historyThumbnail) == false)
    #expect(await maintenanceStore.listReferencedFileIDsCalls.contains(.historyThumbnail) == false)
    let registeredKinds = await maintenanceStore.registerOrphanCalls.map(\.kind)
    #expect(registeredKinds.contains(.historyThumbnail) == false)
    // 対象外というだけでなく、現用中の実体が実際にディスク上へ残っていることそのものを
    // 固定する（Task 11 レビュー Suggestion。事故=現用実体の削除を直接検証する）。
    #expect(await managedFileStore.containsFile(orphanRef) == true)
}

@Test("削除に失敗したrefが同一起動内で再度deleteされないこと（deleteCallsに重複が現れない）")
private func failedDeletionIsNotRetriedWithinSameStartup() async throws {
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    await maintenanceStore.seedPendingFileDeletion(ref)
    // refは端末に実体として存在する状態を模す（実削除が失敗した以上、実体は残り続ける。
    // C-1: これが無いと registerOrphanFiles() がこの ref を孤児として再検出できず、
    // 二重削除試行のバグを検出できない）。
    await managedFileStore.seedExistingFile(ref)
    await managedFileStore.setDeleteFailure(Boom())
    let coordinator = makeCoordinator(maintenanceStore: maintenanceStore, managedFileStore: managedFileStore)

    _ = try await coordinator.runStartupRecovery()

    let deleteCalls = await managedFileStore.deleteCalls
    #expect(deleteCalls.count == 1)
    #expect(deleteCalls.filter { $0 == ref }.count == 1)
    #expect(await maintenanceStore.loadPendingFileDeletionsCallCount == 1)
}

@Test("削除失敗が復旧全体を止めないこと（後続のresolveOrphanedAttemptsまで到達すること）")
private func deletionFailureDoesNotStopRecovery() async throws {
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    await maintenanceStore.seedPendingFileDeletion(ref)
    await managedFileStore.setDeleteFailure(Boom())
    let coordinator = makeCoordinator(
        outputDeliveryStore: outputDeliveryStore,
        maintenanceStore: maintenanceStore,
        managedFileStore: managedFileStore
    )

    let report = try await coordinator.runStartupRecovery()

    #expect(report.failedFileDeletionCount == 1)
    #expect(await outputDeliveryStore.resolveOrphanedAttemptsCallCount == 1)
    #expect(await outputDeliveryStore.loadUnknownLibrarySavesCallCount == 1)
}

@Test("pending登録と実在ファイルの両方へ同一refをseedし削除に失敗しても、deleteCallsとfailedFileDeletionCountが二重にならないこと")
private func sameRefInPendingAndExistingFileIsCountedOnce() async throws {
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    await maintenanceStore.seedPendingFileDeletion(ref)
    await managedFileStore.seedExistingFile(ref)
    await managedFileStore.setDeleteFailure(Boom())
    let coordinator = makeCoordinator(maintenanceStore: maintenanceStore, managedFileStore: managedFileStore)

    let report = try await coordinator.runStartupRecovery()

    #expect(await managedFileStore.deleteCalls.count == 1)
    #expect(report.failedFileDeletionCount == 1)
}

@Test("clearPendingFileDeletionの失敗は実体削除の失敗と区別され、failedFileDeletionCountに含まれないこと")
private func clearPendingFileDeletionFailureIsNotCountedAsEntityDeletionFailure() async throws {
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    await maintenanceStore.seedPendingFileDeletion(ref)
    await managedFileStore.seedExistingFile(ref)
    await maintenanceStore.setClearPendingFileDeletionFailure(Boom())
    let coordinator = makeCoordinator(maintenanceStore: maintenanceStore, managedFileStore: managedFileStore)

    let report = try await coordinator.runStartupRecovery()

    // 実体の削除自体は成功しているため、端末に実体が残っている件数（failedFileDeletionCount）
    // には含めない（Task 11 レビュー W-2）。登録行を消せなかった件は別の理由種別で表現する。
    #expect(await managedFileStore.deleteCalls == [ref])
    #expect(report.failedFileDeletionCount == 0)
    #expect(report.pendingRecordClearFailures.map(\.kind) == [.output])
}

// S-2（Task 12 レビュー）: architecture.md「CancellationError は業務エラーとして扱わない」に
// 従い、孤児GCの削除失敗の計上から CancellationError を除外する。これは防御的な対応であり、
// ストア実装が CancellationError を投げた場合に備える（復旧は非構造化 Task の中で走るため、
// ゲート待機者のキャンセルはこの GC 側に伝播しない。Task 12 再レビュー S-1）。

@Test("実体削除でCancellationErrorが投げられても、failedFileDeletionCountへ計上されないこと")
private func cancellationErrorDuringDeleteIsExcludedFromFailureTally() async throws {
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    await maintenanceStore.seedPendingFileDeletion(ref)
    await managedFileStore.seedExistingFile(ref)
    await managedFileStore.setDeleteFailure(CancellationError())
    let coordinator = makeCoordinator(maintenanceStore: maintenanceStore, managedFileStore: managedFileStore)

    let report = try await coordinator.runStartupRecovery()

    #expect(report.failedFileDeletionCount == 0)
    #expect(report.failedFileDeletions.isEmpty)
    // 実削除は完了していないため、登録は次回起動での再試行に残る。
    #expect(await maintenanceStore.containsPendingFileDeletion(ref) == true)
}

@Test("clearPendingFileDeletionでCancellationErrorが投げられても、pendingRecordClearFailuresへ計上されないこと")
private func cancellationErrorDuringClearIsExcludedFromFailureTally() async throws {
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    await maintenanceStore.seedPendingFileDeletion(ref)
    await managedFileStore.seedExistingFile(ref)
    await maintenanceStore.setClearPendingFileDeletionFailure(CancellationError())
    let coordinator = makeCoordinator(maintenanceStore: maintenanceStore, managedFileStore: managedFileStore)

    let report = try await coordinator.runStartupRecovery()

    #expect(report.pendingRecordClearFailures.isEmpty)
    #expect(report.deletedFileCount == 0)
}

// S-2（Task 12 再レビュー）: registerOrphanFiles（手順(2)の registerOrphan の queue.run）が
// 投げた CancellationError は、deleteManagedFiles とは別の catch 節（runOrphanFileGC 自身）を
// 通るため、対称にするには runOrphanFileGC 側でも除外が必要だった。

@Test("registerOrphanでCancellationErrorが投げられても、fileGCFailureへ計上されないこと")
private func cancellationErrorDuringRegisterOrphanIsExcludedFromGCFailure() async throws {
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let orphanRef = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    await managedFileStore.seedExistingFile(orphanRef)
    await maintenanceStore.setRegisterOrphanFailure(CancellationError())
    let coordinator = makeCoordinator(maintenanceStore: maintenanceStore, managedFileStore: managedFileStore)

    let report = try await coordinator.runStartupRecovery()

    #expect(report.fileGCFailure == nil)
    #expect(report.deletedFileCount == 0)
}

@Test("孤児ファイルGC手順自体の失敗は復旧全体を止めず、reportのfileGCFailureへ記録されること")
private func fileGCFailureDoesNotStopRecoveryAndIsRecordedInReport() async throws {
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    await maintenanceStore.setLoadPendingFileDeletionsFailure(Boom())
    let coordinator = makeCoordinator(
        outputDeliveryStore: outputDeliveryStore,
        maintenanceStore: maintenanceStore,
        managedFileStore: managedFileStore
    )

    // GC起因のthrowは復旧全体を止めない（Task 11 レビュー W-3）。resolveOrphanedAttempts
    // 以降まで到達し、throwではなく正常な report が返ること自体がその検証になる。
    let report = try await coordinator.runStartupRecovery()

    #expect((report.fileGCFailure as? Boom) == Boom())
    #expect(report.deletedFileCount == 0)
    #expect(report.failedFileDeletionCount == 0)
    #expect(await outputDeliveryStore.resolveOrphanedAttemptsCallCount == 1)
    #expect(await outputDeliveryStore.loadUnknownLibrarySavesCallCount == 1)
}

@Test("手順(2)のlistExistingFileIDs失敗時も手順(1)で完走した集計は保持され、後続手順まで到達すること")
private func listExistingFileIDsFailureKeepsCompletedTallyAndDoesNotStopRecovery() async throws {
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let outputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    await maintenanceStore.seedPendingFileDeletion(ref)
    await managedFileStore.seedExistingFile(ref)
    await maintenanceStore.setListExistingFileIDsFailure(Boom())
    let coordinator = makeCoordinator(
        outputDeliveryStore: outputDeliveryStore,
        maintenanceStore: maintenanceStore,
        managedFileStore: managedFileStore
    )

    let report = try await coordinator.runStartupRecovery()

    // 手順(1)（pendingの削除）は完走しており、その集計は手順(2)の失敗で失われない（W-3）。
    #expect(report.deletedFileCount == 1)
    #expect((report.fileGCFailure as? Boom) == Boom())
    #expect(await outputDeliveryStore.resolveOrphanedAttemptsCallCount == 1)
    #expect(await outputDeliveryStore.loadUnknownLibrarySavesCallCount == 1)
}
