import Foundation
import Testing
import GRDB
import Domain
@testable import Persistence

// StampStoreLive.loadCustomStamps / loadStampStorageBreakdownのテスト
// （architecture.md「StampStore」節・「使用容量の表示」節・「実体欠損時の処理」節が
// 正本。Issue #6 Task 4）。

@Suite("StampStoreLive storage")
struct StampStoreStorageTests {
    @Test("loadCustomStampsがsortOrder昇順で一覧を返すこと")
    func loadCustomStampsReturnsListOrderedBySortOrder() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeStampTestDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StampStoreLive(database: database, fileStore: ManagedFileStoreLive(directories: directories))
        let first = try await importStamp(store, name: "1番目", bytes: Data([0x30]))
        let second = try await importStamp(store, name: "2番目", bytes: Data([0x31]))

        let loaded = try await store.loadCustomStamps()

        #expect(loaded.map(\.customStampID) == [first.stamp.customStampID, second.stamp.customStampID])
        #expect(loaded.map(\.sortOrder) == [1, 2])
    }

    @Test("loadStampStorageBreakdownが登録中と履歴専用のバイト数を分けて集計すること")
    func loadStampStorageBreakdownSeparatesRegisteredAndHistoryOnlyBytes() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeStampTestDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StampStoreLive(database: database, fileStore: ManagedFileStoreLive(directories: directories))
        _ = try await importStamp(store, name: "登録中", bytes: Data(repeating: 0x40, count: 10))
        let historyOnly = try await importStamp(store, name: "履歴専用", bytes: Data(repeating: 0x41, count: 20))
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in try insertProject(connection, projectID: projectID.rawValue) }
        try await store.attachStampReference(projectID: projectID, assetHash: historyOnly.assetHash)
        try await store.removeCustomStamp(historyOnly.stamp.customStampID)

        let breakdown = try await store.loadStampStorageBreakdown()

        #expect(breakdown.registeredBytes == 10)
        #expect(breakdown.historyOnlyBytes == 20)
        #expect(breakdown.totalBytes == 30)
    }

    @Test("実体が欠損しているStampAssetはサイズ0として扱われ処理が継続すること")
    func loadStampStorageBreakdownTreatsMissingFileAsZeroBytes() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeStampTestDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StampStoreLive(database: database, fileStore: ManagedFileStoreLive(directories: directories))
        let imported = try await importStamp(store, name: "欠損予定", bytes: Data(repeating: 0x42, count: 5))
        let fileID = try #require(try stampAssetFileID(database, contentHash: imported.assetHash.bytes))
        let fileURL = directories.stampAsset.appendingPathComponent(fileID.uuidString)
        try FileManager.default.removeItem(at: fileURL)

        let breakdown = try await store.loadStampStorageBreakdown()

        #expect(breakdown.registeredBytes == 0)
        #expect(breakdown.totalBytes == 0)
    }
}
