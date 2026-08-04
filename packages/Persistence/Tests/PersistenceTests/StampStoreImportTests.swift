import Foundation
import Testing
import GRDB
import Domain
@testable import Persistence

// StampStoreLive.importCustomStampのテスト（architecture.md「StampStore」節・
// 「内容ハッシュの対象」節が正本。Issue #6 Task 4）。

@Suite("StampStoreLive import")
struct StampStoreImportTests {
    @Test("異なるバイト列で2回importすると別々のStampAsset.contentHashとCustomStamp行ができること")
    func importingDistinctBytesCreatesSeparateAssetsAndCustomStamps() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeStampTestDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StampStoreLive(database: database, fileStore: ManagedFileStoreLive(directories: directories))

        let first = try await importStamp(store, name: "スタンプA", bytes: Data([0x01, 0x02]))
        let second = try await importStamp(store, name: "スタンプB", bytes: Data([0x03, 0x04]))

        #expect(first.assetHash != second.assetHash)
        #expect(try stampAssetRowCount(database) == 2)
        #expect(try customStampRowCount(database) == 2)
    }

    @Test("同一バイト列で2回importするとStampAssetは1行に畳まれCustomStampは2行作られること")
    func importingDuplicateBytesReusesAssetAcrossTwoCustomStamps() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeStampTestDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StampStoreLive(database: database, fileStore: ManagedFileStoreLive(directories: directories))
        let bytes = Data([0x05, 0x06, 0x07])

        let first = try await importStamp(store, name: "スタンプA", bytes: bytes)
        let second = try await importStamp(store, name: "スタンプA複製", bytes: bytes)

        #expect(first.assetHash == second.assetHash)
        #expect(try stampAssetRowCount(database) == 1)
        #expect(try customStampRowCount(database) == 2)
    }

    @Test("重複importで新規ファイルがPendingFileDeletionへ登録され戻り値は既存StampAssetを指すこと")
    func importingDuplicateBytesRegistersNewFileForPendingDeletion() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeStampTestDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StampStoreLive(database: database, fileStore: ManagedFileStoreLive(directories: directories))
        let bytes = Data([0x0A, 0x0B, 0x0C])
        let kind = ManagedFileKind.stampAsset.rawValue

        let first = try await importStamp(store, name: "スタンプA", bytes: bytes)
        let existingFileID = try #require(try stampAssetFileID(database, contentHash: first.assetHash.bytes))
        let countBeforeSecondImport = try pendingFileDeletionCount(database, kind: kind)
        let second = try await importStamp(store, name: "スタンプA複製", bytes: bytes)
        let countAfterSecondImport = try pendingFileDeletionCount(database, kind: kind)

        #expect(first.assetHash == second.assetHash)
        #expect(countAfterSecondImport == countBeforeSecondImport + 1)
        // 参照中（StampAssetが指している）fileIDは削除予約されていないこと（退行防止）。
        #expect(try !pendingFileDeletionExists(database, kind: kind, fileID: existingFileID))
        // 実際に削除予約されたのは2回目のimportで新規作成された未参照fileIDであり、
        // 参照中のexistingFileIDとは別物であること。
        let registeredFileID = try #require(try pendingFileDeletionFileID(database, kind: kind))
        #expect(registeredFileID != existingFileID)
    }

    @Test("重複インポートでもthumbnailFileIDは毎回別ファイルとして作られること")
    func duplicateImportCreatesDistinctThumbnails() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeStampTestDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StampStoreLive(database: database, fileStore: ManagedFileStoreLive(directories: directories))
        let bytes = Data([0x08, 0x09])

        let first = try await importStamp(store, name: "スタンプA", bytes: bytes)
        let second = try await importStamp(store, name: "スタンプA複製", bytes: bytes)

        #expect(first.stamp.thumbnail.fileID != second.stamp.thumbnail.fileID)
    }

    @Test("3回importするとsortOrderが1,2,3と単調増加すること")
    func sortOrderIncrementsMonotonicallyAcrossImports() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeStampTestDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StampStoreLive(database: database, fileStore: ManagedFileStoreLive(directories: directories))

        let first = try await importStamp(store, name: "1番目", bytes: Data([0x10]))
        let second = try await importStamp(store, name: "2番目", bytes: Data([0x11]))
        let third = try await importStamp(store, name: "3番目", bytes: Data([0x12]))

        #expect(first.stamp.sortOrder == 1)
        #expect(second.stamp.sortOrder == 2)
        #expect(third.stamp.sortOrder == 3)
    }

    @Test("既存最大sortOrderがInt32.maxのときimportCustomStampがsortOrderOverflowを投げること")
    func importCustomStampThrowsSortOrderOverflowWhenMaxSortOrderReached() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeStampTestDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StampStoreLive(database: database, fileStore: ManagedFileStoreLive(directories: directories))
        let existingHash = schemaTestHash(seed: 0x01)
        try await database.dbQueue.write { connection in
            try insertStampAsset(connection, contentHash: existingHash, fileID: UUID())
            try insertCustomStamp(
                connection, customStampID: UUID(), assetHash: existingHash, sortOrder: Int32.max
            )
        }

        do {
            _ = try await importStamp(store, name: "オーバーフロー", bytes: Data([0x99]))
            Issue.record("sortOrderがInt32.maxの状態でimportCustomStampが成功した")
        } catch let error as StampStoreError {
            guard case .sortOrderOverflow = error else {
                Issue.record("期待したエラーケース(sortOrderOverflow)ではない: \(error)")
                return
            }
        } catch {
            Issue.record("StampStoreError以外がthrowされた: \(error)")
        }
    }
}
