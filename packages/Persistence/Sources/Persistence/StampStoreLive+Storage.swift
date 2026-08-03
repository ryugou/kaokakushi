import Foundation
import Domain
import GRDB

// loadCustomStamps / loadStampStorageBreakdown（architecture.md「StampStore」節・
// 「使用容量の表示」節・「実体欠損時の処理」節が正本）。

extension StampStoreLive {
    /// スタンプ一覧。sortOrder昇順で返す。
    public func loadCustomStamps() async throws -> [CustomStamp] {
        let rows = try await database.dbQueue.read { connection in
            try Row.fetchAll(
                connection,
                sql: """
                SELECT customStampID, assetHash, name, sortOrder, thumbnailFileID
                FROM CustomStamp ORDER BY sortOrder
                """
            )
        }
        return try rows.map(Self.makeCustomStamp)
    }

    /// 使用容量の内訳（登録中のマイスタンプ / 過去の加工履歴で使用中 / 合計）。
    public func loadStampStorageBreakdown() async throws -> StampStorageBreakdown {
        let rows = try await database.dbQueue.read { connection in
            try Row.fetchAll(
                connection,
                sql: """
                SELECT fileID, EXISTS(
                    SELECT 1 FROM CustomStamp cs WHERE cs.assetHash = StampAsset.contentHash
                ) AS isRegistered
                FROM StampAsset
                """
            )
        }

        var registeredBytes: Int64 = 0
        var historyOnlyBytes: Int64 = 0
        for row in rows {
            let fileID: UUID = row["fileID"]
            let isRegistered: Bool = row["isRegistered"]
            let byteSize = try await fileSize(fileID: ManagedFileID(rawValue: fileID))
            if isRegistered {
                registeredBytes += byteSize
            } else {
                historyOnlyBytes += byteSize
            }
        }

        return StampStorageBreakdown(
            registeredBytes: registeredBytes,
            historyOnlyBytes: historyOnlyBytes,
            totalBytes: registeredBytes + historyOnlyBytes
        )
    }

    private static func makeCustomStamp(_ row: Row) throws -> CustomStamp {
        let customStampID: UUID = row["customStampID"]
        let assetHashBytes: Data = row["assetHash"]
        let name: String = row["name"]
        let sortOrder: Int32 = row["sortOrder"]
        let thumbnailFileID: UUID = row["thumbnailFileID"]
        return CustomStamp(
            customStampID: CustomStampID(rawValue: customStampID),
            assetHash: try StampAssetHash(bytes: assetHashBytes),
            name: name,
            sortOrder: sortOrder,
            thumbnail: ManagedFileRef(kind: .stampThumbnail, fileID: ManagedFileID(rawValue: thumbnailFileID))
        )
    }

    /// 実体のファイルサイズを読む。実体欠損（ManagedFileStoreError.fileNotFound）は
    /// DB行を変更せず0を返し処理を継続する（architecture.md「実体欠損時の処理」。
    /// 履歴サムネイルと同じ扱い。該当行だけスキップしてクラッシュさせない）。
    private func fileSize(fileID: ManagedFileID) async throws -> Int64 {
        let ref = ManagedFileRef(kind: .stampAsset, fileID: fileID)
        do {
            return try await fileStore.withReadAccess(ref) { url in
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                return (attributes[.size] as? Int64) ?? 0
            }
        } catch ManagedFileStoreError.fileNotFound {
            return 0
        }
    }
}
