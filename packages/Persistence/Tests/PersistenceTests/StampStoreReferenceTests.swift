import Foundation
import Testing
import GRDB
import Domain
@testable import Persistence

// StampStoreLive.removeCustomStamp / attachStampReference / releaseStampReferenceの
// テスト（architecture.md「StampStore」節・「参照カウント」表が正本。Issue #6 Task 4）。

@Suite("StampStoreLive references")
struct StampStoreReferenceTests {
    @Test("単独参照のCustomStampを削除するとStampAsset行が消えPendingFileDeletionに登録されること")
    func removingSoleReferenceDeletesStampAssetAndRegistersPendingDeletion() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeStampTestDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StampStoreLive(database: database, fileStore: ManagedFileStoreLive(directories: directories))
        let imported = try await importStamp(store, name: "単独参照", bytes: Data([0x20]))
        let fileID = try #require(try stampAssetFileID(database, contentHash: imported.assetHash.bytes))

        try await store.removeCustomStamp(imported.stamp.customStampID)

        #expect(try stampAssetRowCount(database) == 0)
        #expect(try pendingFileDeletionExists(database, kind: ManagedFileKind.stampAsset.rawValue, fileID: fileID))
    }

    @Test("ProjectStampAsset参照が残っている間はCustomStamp削除でもStampAsset行が消えないこと")
    func removingCustomStampKeepsStampAssetWhileProjectReferenceRemains() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeStampTestDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StampStoreLive(database: database, fileStore: ManagedFileStoreLive(directories: directories))
        let imported = try await importStamp(store, name: "併用参照", bytes: Data([0x21]))
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in try insertProject(connection, projectID: projectID.rawValue) }
        try await store.attachStampReference(projectID: projectID, assetHash: imported.assetHash)

        try await store.removeCustomStamp(imported.stamp.customStampID)

        #expect(try stampAssetRowCount(database) == 1)
    }

    @Test("attachStampReferenceで増やした参照がreleaseStampReferenceで0になった時点でStampAsset行が消えること")
    func attachThenReleaseDeletesStampAssetOnlyWhenAllReferencesAreGone() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeStampTestDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StampStoreLive(database: database, fileStore: ManagedFileStoreLive(directories: directories))
        let imported = try await importStamp(store, name: "参照カウント検証", bytes: Data([0x22]))
        let fileID = try #require(try stampAssetFileID(database, contentHash: imported.assetHash.bytes))
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in try insertProject(connection, projectID: projectID.rawValue) }

        try await store.attachStampReference(projectID: projectID, assetHash: imported.assetHash)
        try await store.removeCustomStamp(imported.stamp.customStampID)
        // CustomStamp参照は消えたが、ProjectStampAsset参照が残っているためまだ消えない。
        #expect(try stampAssetRowCount(database) == 1)

        try await store.releaseStampReference(projectID: projectID, assetHash: imported.assetHash)
        // 参照が0になったのでStampAsset行が消えPendingFileDeletionへ登録される。
        #expect(try stampAssetRowCount(database) == 0)
        #expect(try pendingFileDeletionExists(database, kind: ManagedFileKind.stampAsset.rawValue, fileID: fileID))
    }

    @Test("存在しないCustomStampIDに対するremoveCustomStampが冪等に成功すること")
    func removeCustomStampIsIdempotentForMissingID() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeStampTestDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StampStoreLive(database: database, fileStore: ManagedFileStoreLive(directories: directories))
        _ = try await importStamp(store, name: "冪等性確認用", bytes: Data([0x23]))
        let missingCustomStampID = CustomStampID(rawValue: UUID())

        try await store.removeCustomStamp(missingCustomStampID)

        #expect(try customStampRowCount(database) == 1)
    }

    @Test("同一projectID/assetHashへのattachStampReference再実行がProjectStampAsset行を増やさないこと")
    func attachStampReferenceIsIdempotentForSamePair() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeStampTestDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StampStoreLive(database: database, fileStore: ManagedFileStoreLive(directories: directories))
        let imported = try await importStamp(store, name: "重複attach確認用", bytes: Data([0x24]))
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in try insertProject(connection, projectID: projectID.rawValue) }

        try await store.attachStampReference(projectID: projectID, assetHash: imported.assetHash)
        try await store.attachStampReference(projectID: projectID, assetHash: imported.assetHash)

        let rowCount = try projectStampAssetRowCount(
            database, projectID: projectID.rawValue, assetHash: imported.assetHash.bytes
        )
        #expect(rowCount == 1)
    }
}
