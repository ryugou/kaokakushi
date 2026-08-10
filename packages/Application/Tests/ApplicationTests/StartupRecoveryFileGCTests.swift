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
    let maintenanceStore = FakeMaintenanceStore()
    let managedFileStore = FakeManagedFileStore()
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
    let maintenanceStore = FakeMaintenanceStore()
    let managedFileStore = FakeManagedFileStore()
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
}

@Test("種別ごとの差集合がregisterOrphanへ登録され、その後削除されること")
private func orphanFilesAreRegisteredThenDeleted() async throws {
    let maintenanceStore = FakeMaintenanceStore()
    let managedFileStore = FakeManagedFileStore()
    let referencedID = ManagedFileID(rawValue: UUID())
    let orphanID = ManagedFileID(rawValue: UUID())
    let orphanRef = ManagedFileRef(kind: .output, fileID: orphanID)
    await maintenanceStore.seedExistingFileIDs(kind: .output, ids: [referencedID, orphanID])
    await maintenanceStore.seedReferencedFileIDs(kind: .output, ids: [referencedID])
    await managedFileStore.seedExistingFile(orphanRef)
    let coordinator = makeCoordinator(maintenanceStore: maintenanceStore, managedFileStore: managedFileStore)

    let report = try await coordinator.runStartupRecovery()

    #expect(await maintenanceStore.registerOrphanCalls == [orphanRef])
    #expect(await managedFileStore.deleteCalls == [orphanRef])
    #expect(await maintenanceStore.containsPendingFileDeletion(orphanRef) == false)
    #expect(report.deletedFileCount == 1)
}

@Test(".historyThumbnailが孤児GCの対象外であること")
private func historyThumbnailIsExcludedFromOrphanGC() async throws {
    let maintenanceStore = FakeMaintenanceStore()
    let orphanID = ManagedFileID(rawValue: UUID())
    await maintenanceStore.seedExistingFileIDs(kind: .historyThumbnail, ids: [orphanID])
    let coordinator = makeCoordinator(maintenanceStore: maintenanceStore)

    _ = try await coordinator.runStartupRecovery()

    #expect(await maintenanceStore.listExistingFileIDsCalls.contains(.historyThumbnail) == false)
    #expect(await maintenanceStore.listReferencedFileIDsCalls.contains(.historyThumbnail) == false)
    let registeredKinds = await maintenanceStore.registerOrphanCalls.map(\.kind)
    #expect(registeredKinds.contains(.historyThumbnail) == false)
}

@Test("削除失敗が復旧全体を止めないこと（後続のresolveOrphanedAttemptsまで到達すること）")
private func deletionFailureDoesNotStopRecovery() async throws {
    let maintenanceStore = FakeMaintenanceStore()
    let managedFileStore = FakeManagedFileStore()
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
