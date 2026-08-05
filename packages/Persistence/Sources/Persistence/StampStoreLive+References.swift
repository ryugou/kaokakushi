import Foundation
import Domain
import GRDB

// removeCustomStamp / attachStampReference / releaseStampReference
// （architecture.md「StampStore」節・「参照カウント」表・「DBとファイルの更新順序」節が
// 正本）。
//
// 参照が0になった実体の削除手順はHistoryDeletionStore（deleteHistoryUnit）と共通のため、
// モジュール共有のStampAssetReferences.swiftへ集約している。

extension StampStoreLive {
    /// 一覧から削除する（CustomStamp行のみ）。行が既に無ければ何もせず冪等に成功する
    /// （呼び出し元の再試行等で複数回呼びうるため）。
    public func removeCustomStamp(_ id: CustomStampID) async throws {
        try await database.dbQueue.write { connection in
            guard let assetHashBytes = try Data.fetchOne(
                connection,
                sql: "SELECT assetHash FROM CustomStamp WHERE customStampID = ?",
                arguments: [id.rawValue]
            ) else {
                return
            }
            try connection.execute(
                sql: "DELETE FROM CustomStamp WHERE customStampID = ?",
                arguments: [id.rawValue]
            )
            let assetHash = try StampAssetHash(bytes: assetHashBytes)
            try StampAssetReferences.releaseIfUnreferenced(connection, assetHash: assetHash)
        }
    }

    /// Projectのいずれかの領域が実体を使うようになった。複合PRIMARY KEY
    /// (projectID, assetHash) がUNIQUEを兼ねるため、INSERT OR IGNOREで冪等にする。
    public func attachStampReference(projectID: ProjectID, assetHash: StampAssetHash) async throws {
        try await database.dbQueue.write { connection in
            try connection.execute(
                sql: "INSERT OR IGNORE INTO ProjectStampAsset (projectID, assetHash) VALUES (?, ?)",
                arguments: [projectID.rawValue, assetHash.bytes]
            )
        }
    }

    /// Projectからその実体を使う領域がすべて無くなった。同一トランザクションで参照数を
    /// 導出し、0になった実体は同じトランザクション内でPendingFileDeletionへ登録する。
    public func releaseStampReference(projectID: ProjectID, assetHash: StampAssetHash) async throws {
        try await database.dbQueue.write { connection in
            try connection.execute(
                sql: "DELETE FROM ProjectStampAsset WHERE projectID = ? AND assetHash = ?",
                arguments: [projectID.rawValue, assetHash.bytes]
            )
            try StampAssetReferences.releaseIfUnreferenced(connection, assetHash: assetHash)
        }
    }
}
