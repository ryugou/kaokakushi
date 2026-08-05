import Foundation
import Testing
import GRDB
import Domain
@testable import Persistence

// MaintenanceStoreLiveのテスト（architecture.md 7.5「MaintenanceStore」「孤児ファイルのGC」
// が正本。Issue #6 Task 4）。

@Suite("MaintenanceStoreLive")
struct MaintenanceStoreTests {
    /// テストごとに衝突しない一時ディレクトリ群を発行する
    /// （ManagedFileStoreTests.makeTemporaryDirectoriesと同じ流儀）。
    private func makeTemporaryDirectories() -> (root: URL, directories: ManagedFileDirectories) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaintenanceStoreTests-\(UUID().uuidString)")
        let directories = ManagedFileDirectories(
            output: root.appendingPathComponent("outputs"),
            stampAsset: root.appendingPathComponent("stamps"),
            historyThumbnail: root.appendingPathComponent("thumbnails"),
            stampThumbnail: root.appendingPathComponent("stamp-thumbnails"),
            processingTemporary: root.appendingPathComponent("working"),
            rasterTemporary: root.appendingPathComponent("raster")
        )
        return (root, directories)
    }

    @Test("loadPendingFileDeletionsとclearPendingFileDeletionが往復すること")
    func loadAndClearPendingFileDeletionRoundTrip() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeTemporaryDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MaintenanceStoreLive(database: database, directories: directories)
        let keepFileID = UUID()
        let removeFileID = UUID()
        try await database.dbQueue.write { connection in
            try insertPendingFileDeletion(connection, kind: ManagedFileKind.output.rawValue, fileID: keepFileID)
            try insertPendingFileDeletion(
                connection, kind: ManagedFileKind.processingTemporary.rawValue, fileID: removeFileID
            )
        }

        let loaded = try await store.loadPendingFileDeletions()
        #expect(loaded.count == 2)

        try await store.clearPendingFileDeletion(
            ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: removeFileID))
        )

        let remaining = try await store.loadPendingFileDeletions()
        #expect(remaining.count == 1)
        #expect(remaining.first?.file.fileID.rawValue == keepFileID)
    }

    @Test("listExistingFileIDsがディスク上のファイルを返しUUIDとしてパースできない名前を無視すること")
    func listExistingFileIDsReturnsFilesOnDiskIgnoringUnparseableNames() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeTemporaryDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MaintenanceStoreLive(database: database, directories: directories)
        let validFileID = UUID()
        try FileManager.default.createDirectory(at: directories.stampAsset, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: directories.stampAsset.appendingPathComponent(validFileID.uuidString).path, contents: nil
        )
        FileManager.default.createFile(
            atPath: directories.stampAsset.appendingPathComponent("tmp-not-a-uuid").path, contents: nil
        )

        let existing = try await store.listExistingFileIDs(kind: .stampAsset)

        #expect(existing == [ManagedFileID(rawValue: validFileID)])
    }

    @Test("listExistingFileIDsがディレクトリ未作成の場合空集合を返すこと")
    func listExistingFileIDsReturnsEmptySetWhenDirectoryMissing() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeTemporaryDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MaintenanceStoreLive(database: database, directories: directories)

        let existing = try await store.listExistingFileIDs(kind: .rasterTemporary)

        #expect(existing.isEmpty)
    }

    @Test("listReferencedFileIDsが.processingTemporaryについてWorkingSourceRecord.sourceFileIDを返すこと")
    func listReferencedFileIDsReturnsWorkingSourceRecordReferenceForProcessingTemporary() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeTemporaryDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MaintenanceStoreLive(database: database, directories: directories)
        let projectID = UUID()
        let fileID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID)
            try insertWorkingSourceRecord(connection, projectID: projectID, sourceFileID: fileID)
        }

        let referenced = try await store.listReferencedFileIDs(kind: .processingTemporary)

        #expect(referenced == [ManagedFileID(rawValue: fileID)])
    }

    @Test(
        "listReferencedFileIDsが.historyThumbnail/.rasterTemporaryについて常に空集合を返すこと",
        arguments: [ManagedFileKind.historyThumbnail, .rasterTemporary]
    )
    func listReferencedFileIDsReturnsEmptySetForUnregisteredKinds(kind: ManagedFileKind) async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeTemporaryDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MaintenanceStoreLive(database: database, directories: directories)

        let referenced = try await store.listReferencedFileIDs(kind: kind)

        #expect(referenced.isEmpty)
    }

    @Test("listReferencedFileIDsが.stampThumbnailについてCustomStamp.thumbnailFileIDを返すこと")
    func listReferencedFileIDsReturnsCustomStampThumbnailFileIDForStampThumbnail() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeTemporaryDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MaintenanceStoreLive(database: database, directories: directories)
        let assetHash = schemaTestHash(seed: 0x30)
        let thumbnailFileID = UUID()
        try await database.dbQueue.write { connection in
            try insertStampAsset(connection, contentHash: assetHash, fileID: UUID())
            try insertCustomStamp(
                connection, customStampID: UUID(), assetHash: assetHash, thumbnailFileID: thumbnailFileID
            )
        }

        let referenced = try await store.listReferencedFileIDs(kind: .stampThumbnail)

        #expect(referenced == [ManagedFileID(rawValue: thumbnailFileID)])
    }

    @Test("listExistingFileIDsとlistReferencedFileIDsの差分が孤児ファイルの候補になること")
    func existingMinusReferencedYieldsOrphanCandidate() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeTemporaryDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MaintenanceStoreLive(database: database, directories: directories)
        let referencedFileID = UUID()
        let orphanFileID = UUID()
        try await database.dbQueue.write { connection in
            let projectID = UUID()
            try insertProject(connection, projectID: projectID)
            try insertWorkingSourceRecord(connection, projectID: projectID, sourceFileID: referencedFileID)
        }
        try FileManager.default.createDirectory(
            at: directories.processingTemporary, withIntermediateDirectories: true
        )
        for fileID in [referencedFileID, orphanFileID] {
            FileManager.default.createFile(
                atPath: directories.processingTemporary.appendingPathComponent(fileID.uuidString).path,
                contents: nil
            )
        }

        let existing = try await store.listExistingFileIDs(kind: .processingTemporary)
        let referenced = try await store.listReferencedFileIDs(kind: .processingTemporary)
        let orphans = existing.subtracting(referenced)

        #expect(orphans == [ManagedFileID(rawValue: orphanFileID)])
    }

    @Test("registerOrphanが冪等であること（同じファイルを複数回登録してもクラッシュせず1行のままであること）")
    func registerOrphanIsIdempotent() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeTemporaryDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MaintenanceStoreLive(database: database, directories: directories)
        let file = ManagedFileRef(kind: .rasterTemporary, fileID: ManagedFileID(rawValue: UUID()))

        try await store.registerOrphan(file)
        try await store.registerOrphan(file)

        let loaded = try await store.loadPendingFileDeletions()
        #expect(loaded.count == 1)
    }
}
