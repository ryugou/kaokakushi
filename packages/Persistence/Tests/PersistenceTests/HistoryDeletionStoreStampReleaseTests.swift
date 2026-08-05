import Foundation
import Testing
import Domain
import GRDB
@testable import Persistence

// HistoryDeletionStoreLive.deleteHistoryUnitによるProjectStampAsset解放のテスト
// （architecture.md「StampAsset」節「参照カウント」表・「契機」表の「Projectを削除した」行が
// 正本）。

@Suite("HistoryDeletionStoreLive.deleteHistoryUnit ProjectStampAsset解放")
struct HistoryDeletionStoreStampReleaseTests {
    @Test("削除対象プロジェクトのみが参照するStampAssetは削除後に消えPendingFileDeletionへ登録されること")
    func releasesSoleReferencedStampAsset() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let assetHash = schemaTestHash(seed: 0x40)
        let fileID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertStampAsset(connection, contentHash: assetHash, fileID: fileID)
            try insertProjectStampAsset(connection, projectID: projectID.rawValue, assetHash: assetHash)
        }
        let store = makeHistoryDeletionStore(database: database)

        try await store.deleteHistoryUnit(.project(projectID), trigger: .storagePressure)

        #expect(try stampAssetFileID(database, contentHash: assetHash) == nil)
        #expect(try pendingFileDeletionExists(database, kind: ManagedFileKind.stampAsset.rawValue, fileID: fileID))
    }

    @Test("他のProjectも参照するStampAssetは削除後も残ること")
    func keepsStampAssetReferencedByAnotherProject() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let deletedProjectID = ProjectID(rawValue: UUID())
        let otherProjectID = ProjectID(rawValue: UUID())
        let assetHash = schemaTestHash(seed: 0x41)
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: deletedProjectID.rawValue)
            try insertProject(connection, projectID: otherProjectID.rawValue)
            try insertStampAsset(connection, contentHash: assetHash, fileID: UUID())
            try insertProjectStampAsset(connection, projectID: deletedProjectID.rawValue, assetHash: assetHash)
            try insertProjectStampAsset(connection, projectID: otherProjectID.rawValue, assetHash: assetHash)
        }
        let store = makeHistoryDeletionStore(database: database)

        try await store.deleteHistoryUnit(.project(deletedProjectID), trigger: .storagePressure)

        #expect(try stampAssetFileID(database, contentHash: assetHash) != nil)
    }

    @Test("CustomStampも参照するStampAssetは削除後も残ること")
    func keepsStampAssetReferencedByCustomStamp() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        let assetHash = schemaTestHash(seed: 0x42)
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertStampAsset(connection, contentHash: assetHash, fileID: UUID())
            try insertProjectStampAsset(connection, projectID: projectID.rawValue, assetHash: assetHash)
            try insertCustomStamp(connection, customStampID: UUID(), assetHash: assetHash)
        }
        let store = makeHistoryDeletionStore(database: database)

        try await store.deleteHistoryUnit(.project(projectID), trigger: .storagePressure)

        #expect(try stampAssetFileID(database, contentHash: assetHash) != nil)
    }
}
