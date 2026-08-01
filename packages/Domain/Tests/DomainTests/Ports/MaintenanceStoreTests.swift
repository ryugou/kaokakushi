import Testing
@testable import Domain
import Foundation

/// Task 4: 起動時 GC が使う永続化ポート（architecture.md「MaintenanceStore」節）。
///
/// `MaintenanceStore` への最小準拠が、各メソッドの引数をシグネチャどおりに受け取り
/// 戻り値を伝えることを検証する。`PendingFileDeletion` 等は Task 1 で実装済みのため
/// ここでは組み立てにのみ使う。

private actor FakeMaintenanceStore: MaintenanceStore {
    private(set) var loadPendingFileDeletionsCallCount = 0
    private(set) var clearPendingFileDeletionCalls: [ManagedFileRef] = []
    private(set) var listExistingFileIDsCalls: [ManagedFileKind] = []
    private(set) var listReferencedFileIDsCalls: [ManagedFileKind] = []
    private(set) var registerOrphanCalls: [ManagedFileRef] = []

    var pendingFileDeletionsResult: [PendingFileDeletion] = []
    var existingFileIDsResult: Set<ManagedFileID> = []
    var referencedFileIDsResult: Set<ManagedFileID> = []

    func loadPendingFileDeletions() async throws -> [PendingFileDeletion] {
        loadPendingFileDeletionsCallCount += 1
        return pendingFileDeletionsResult
    }

    func clearPendingFileDeletion(_ file: ManagedFileRef) async throws {
        clearPendingFileDeletionCalls.append(file)
    }

    func listExistingFileIDs(kind: ManagedFileKind) async throws -> Set<ManagedFileID> {
        listExistingFileIDsCalls.append(kind)
        return existingFileIDsResult
    }

    func listReferencedFileIDs(kind: ManagedFileKind) async throws -> Set<ManagedFileID> {
        listReferencedFileIDsCalls.append(kind)
        return referencedFileIDsResult
    }

    func registerOrphan(_ file: ManagedFileRef) async throws {
        registerOrphanCalls.append(file)
    }
}

@Test("MaintenanceStoreへの最小準拠が全メソッドの引数を渡された値どおりに記録する")
func fakeMaintenanceStoreForwardsArguments() async throws {
    let store = FakeMaintenanceStore()

    _ = try await store.loadPendingFileDeletions()

    let clearedRef = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    try await store.clearPendingFileDeletion(clearedRef)

    _ = try await store.listExistingFileIDs(kind: .stampAsset)
    _ = try await store.listReferencedFileIDs(kind: .stampAsset)

    let orphanRef = ManagedFileRef(kind: .historyThumbnail, fileID: ManagedFileID(rawValue: UUID()))
    try await store.registerOrphan(orphanRef)

    #expect(await store.loadPendingFileDeletionsCallCount == 1)
    #expect(await store.clearPendingFileDeletionCalls == [clearedRef])
    #expect(await store.listExistingFileIDsCalls == [.stampAsset])
    #expect(await store.listReferencedFileIDsCalls == [.stampAsset])
    #expect(await store.registerOrphanCalls == [orphanRef])
}

@Test("孤児判定はlistExistingFileIDsにありlistReferencedFileIDsに無いIDである")
func orphanDetectionIsExistingMinusReferenced() async throws {
    let store = FakeMaintenanceStore()
    let referencedID = ManagedFileID(rawValue: UUID())
    let orphanID = ManagedFileID(rawValue: UUID())
    await store.setExistingFileIDsResult([referencedID, orphanID])
    await store.setReferencedFileIDsResult([referencedID])

    let existing = try await store.listExistingFileIDs(kind: .rasterTemporary)
    let referenced = try await store.listReferencedFileIDs(kind: .rasterTemporary)
    let orphans = existing.subtracting(referenced)

    #expect(orphans == [orphanID])
}

private extension FakeMaintenanceStore {
    func setExistingFileIDsResult(_ ids: Set<ManagedFileID>) {
        existingFileIDsResult = ids
    }

    func setReferencedFileIDsResult(_ ids: Set<ManagedFileID>) {
        referencedFileIDsResult = ids
    }
}
