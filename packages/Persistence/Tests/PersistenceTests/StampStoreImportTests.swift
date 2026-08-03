import Foundation
import Testing
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

    @Test("同一バイト列で2回importするとStampAssetは1行に畳まれCustomStampは2行作られ2回目の一時ファイルが破棄されること")
    func importingDuplicateBytesReusesAssetAndDiscardsSecondFile() async throws {
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

        // 2回目のimportで新規に書かれた一時ファイルは既存StampAssetの再利用により
        // fileStore.delete済みでディスク上に残っていないこと（stampAsset用ディレクトリの
        // ファイル数が1のままであることで確認する）。
        let filesOnDisk = try FileManager.default.contentsOfDirectory(atPath: directories.stampAsset.path)
        #expect(filesOnDisk.count == 1)
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
}
