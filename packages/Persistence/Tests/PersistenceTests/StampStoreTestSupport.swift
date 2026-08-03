import Foundation
import GRDB
import Domain
@testable import Persistence

// StampStoreImportTests / StampStoreReferenceTests / StampStoreStorageTests が共有する
// ヘルパー群。makeTestAppDatabase()（WorkingSourceStoreTestSupport.swift）・insertProject
// （SchemaTestSupport.swift）はそのまま再利用し、ここでは重複定義しない。

/// テストごとに衝突しない一時ディレクトリ群を発行する
/// （ManagedFileStoreTests.makeTemporaryDirectoriesと同じ流儀）。
func makeStampTestDirectories() -> (root: URL, directories: ManagedFileDirectories) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("StampStoreTests-\(UUID().uuidString)")
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

/// StampStoreLive.importCustomStampを、テストで使う最小限のbody/thumbnailBodyで呼び出す
/// 共通ヘルパー。bytesがStampAsset.contentHashの元になり、thumbnailの内容自体は
/// テストで検証しないため固定値を書く。
func importStamp(
    _ store: StampStoreLive,
    name: String,
    bytes: Data
) async throws -> (stamp: CustomStamp, assetHash: StampAssetHash) {
    try await store.importCustomStamp(
        name: name,
        body: { url in try bytes.write(to: url) },
        thumbnailBody: { url in try Data([0xFF]).write(to: url) }
    )
}

func stampAssetRowCount(_ database: AppDatabase) throws -> Int {
    try database.dbQueue.read { connection in
        try Int.fetchOne(connection, sql: "SELECT count(*) FROM StampAsset") ?? -1
    }
}

func customStampRowCount(_ database: AppDatabase) throws -> Int {
    try database.dbQueue.read { connection in
        try Int.fetchOne(connection, sql: "SELECT count(*) FROM CustomStamp") ?? -1
    }
}

func stampAssetFileID(_ database: AppDatabase, contentHash: Data) throws -> UUID? {
    try database.dbQueue.read { connection in
        try UUID.fetchOne(
            connection, sql: "SELECT fileID FROM StampAsset WHERE contentHash = ?", arguments: [contentHash]
        )
    }
}

func projectStampAssetRowCount(_ database: AppDatabase, projectID: UUID, assetHash: Data) throws -> Int {
    try database.dbQueue.read { connection in
        try Int.fetchOne(
            connection,
            sql: "SELECT count(*) FROM ProjectStampAsset WHERE projectID = ? AND assetHash = ?",
            arguments: [projectID, assetHash]
        ) ?? -1
    }
}
