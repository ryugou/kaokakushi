import Foundation
import Domain
import GRDB

// loadCustomStamps / loadStampStorageBreakdown（architecture.md「StampStore」節・
// 「使用容量の表示」節・「実体欠損時の処理」節が正本）。

extension StampStoreLive {
    /// スタンプ一覧。sortOrder昇順で返す。
    public func loadCustomStamps() async throws -> [CustomStamp] {
        // 戻り値型を明示する（toolchain 差の推論割れ対策。Package.swift の GRDB ピン注記参照）
        let stamps: [CustomStamp] = try await database.dbQueue.read { connection in
            let rows = try Row.fetchAll(
                connection,
                sql: """
                SELECT customStampID, assetHash, name, sortOrder, thumbnailFileID
                FROM CustomStamp ORDER BY sortOrder
                """
            )
            return try rows.map(Self.makeCustomStamp)
        }
        return stamps
    }

    /// 使用容量の内訳（登録中のマイスタンプ / 過去の加工履歴で使用中 / 合計）。
    public func loadStampStorageBreakdown() async throws -> StampStorageBreakdown {
        // Row自体はSendable未対応（GRDB 7.11.1）のためdbQueue.readのクロージャ境界を
        // 越えられない。fileID/isRegisteredへここでデコードし、Sendableなタプル配列だけを
        // 返す（クロージャ外の非同期fileSize呼び出しはデータベース処理と独立しているため
        // ループごとawaitする設計は変えない）。
        let assets: [(fileID: UUID, isRegistered: Bool)] = try await database.dbQueue.read { connection in
            let rows = try Row.fetchAll(
                connection,
                sql: """
                SELECT fileID, EXISTS(
                    SELECT 1 FROM CustomStamp cs WHERE cs.assetHash = StampAsset.contentHash
                ) AS isRegistered
                FROM StampAsset
                """
            )
            return rows.map { row in (fileID: row["fileID"] as UUID, isRegistered: row["isRegistered"] as Bool) }
        }

        var registeredBytes: Int64 = 0
        var historyOnlyBytes: Int64 = 0
        for asset in assets {
            let byteSize = try await fileSize(fileID: ManagedFileID(rawValue: asset.fileID))
            if asset.isRegistered {
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
