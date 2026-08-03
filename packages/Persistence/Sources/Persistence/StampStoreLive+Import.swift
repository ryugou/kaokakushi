import Foundation
import Domain
import GRDB
// CryptoKitはApple platform専用API。CIのpackage-testsジョブはmacos-15で動くため現状は
// 問題ないが、将来Persistenceパッケージ内のswift testをLinux上でも実行する計画が出た
// 場合はswift-crypto（import Crypto）への置き換えが必要になる。
import CryptoKit

// importCustomStamp（architecture.md「StampStore」節・「内容ハッシュの対象」節が正本）。

extension StampStoreLive {
    public func importCustomStamp(
        name: String,
        body: @Sendable (URL) async throws -> Void,
        thumbnailBody: @Sendable (URL) async throws -> Void
    ) async throws -> (stamp: CustomStamp, assetHash: StampAssetHash) {
        // bodyが一時ファイルへ書き終えた直後（atomic rename前）のバイト列を読み取る
        // （内容ハッシュの計算時点はManagedFileStoreへ書く直前——正本「内容ハッシュの
        // 対象」）。
        let (assetRef, savedBytes) = try await fileStore.createFile(kind: .stampAsset) { url in
            try await body(url)
            return try Data(contentsOf: url)
        }
        let assetHash = try StampAssetHash(bytes: Data(SHA256.hash(data: savedBytes)))

        // thumbnailは重複取り込みでもCustomStamp行ごとに必ず新規作成する（正本どおり）。
        let (thumbnailRef, _) = try await fileStore.createFile(kind: .stampThumbnail) { url in
            try await thumbnailBody(url)
        }

        let customStampID = CustomStampID(rawValue: UUID())
        let newRows = NewStampRows(
            assetHash: assetHash,
            assetFileID: assetRef.fileID,
            customStampID: customStampID,
            name: name,
            thumbnailFileID: thumbnailRef.fileID
        )
        let (didReuseExistingAsset, sortOrder) = try await database.dbQueue.write { connection in
            try Self.insertStampRows(connection, rows: newRows)
        }

        // 既存StampAssetが再利用された場合、新規に書いたファイルはどこにも参照されて
        // いないため直接削除する（正本「新規に書いたファイルは破棄する」。孤児GCの
        // PendingFileDeletion経路を使う必要は無い）。
        if didReuseExistingAsset {
            try await fileStore.delete(assetRef)
        }

        let stamp = CustomStamp(
            customStampID: customStampID,
            assetHash: assetHash,
            name: name,
            sortOrder: sortOrder,
            thumbnail: thumbnailRef
        )
        return (stamp: stamp, assetHash: assetHash)
    }

    /// insertStampRows へ渡す新規行の値ひとそろい（lint の引数上限対応で束ねた入力）。
    private struct NewStampRows {
        let assetHash: StampAssetHash
        let assetFileID: ManagedFileID
        let customStampID: CustomStampID
        let name: String
        let thumbnailFileID: ManagedFileID
    }

    /// 単一トランザクションで: (1) 既存StampAssetの有無を判定 (2) 無ければ新規作成
    /// (3) 既存最大sortOrder + 1を採番 (4) CustomStamp行を作成する。
    /// 戻り値は「既存StampAssetを再利用したか」と、採番したsortOrder。
    private static func insertStampRows(
        _ connection: Database,
        rows: NewStampRows
    ) throws -> (didReuseExistingAsset: Bool, sortOrder: Int32) {
        let existingCount = try Int.fetchOne(
            connection,
            sql: "SELECT count(*) FROM StampAsset WHERE contentHash = ?",
            arguments: [rows.assetHash.bytes]
        ) ?? 0
        let didReuseExistingAsset = existingCount > 0

        if !didReuseExistingAsset {
            try connection.execute(
                sql: "INSERT INTO StampAsset (contentHash, fileID) VALUES (?, ?)",
                arguments: [rows.assetHash.bytes, rows.assetFileID.rawValue]
            )
        }

        let maxSortOrder = try Int32.fetchOne(
            connection, sql: "SELECT COALESCE(MAX(sortOrder), 0) FROM CustomStamp"
        ) ?? 0
        let sortOrder = maxSortOrder + 1

        try connection.execute(
            sql: """
            INSERT INTO CustomStamp (customStampID, assetHash, name, sortOrder, thumbnailFileID)
            VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [
                rows.customStampID.rawValue, rows.assetHash.bytes, rows.name,
                sortOrder, rows.thumbnailFileID.rawValue
            ]
        )

        return (didReuseExistingAsset, sortOrder)
    }
}
