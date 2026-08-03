import Foundation
import Domain
import GRDB

// removeCustomStamp / attachStampReference / releaseStampReference
// （architecture.md「StampStore」節・「参照カウント」表・「DBとファイルの更新順序」節が
// 正本）。

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
            try Self.deleteStampAssetIfUnreferenced(connection, assetHash: assetHash)
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
            try Self.deleteStampAssetIfUnreferenced(connection, assetHash: assetHash)
        }
    }

    /// 参照カウント = CustomStamp.assetHashの行数 + ProjectStampAssetの行数
    /// （architecture.md「参照カウント」）。両方0なら実体を削除候補としてPending
    /// FileDeletionへ登録し、StampAsset行を削除する（正本「DBとファイルの更新順序」の
    /// 削除手順1・2。ファイルの実削除はコミット後にGC等が担当する）。呼び出し元が
    /// dbQueue.write内から呼ぶため、この関数内の操作は自動的に同一トランザクションに
    /// 含まれる。
    private static func deleteStampAssetIfUnreferenced(_ connection: Database, assetHash: StampAssetHash) throws {
        let customStampCount = try Int.fetchOne(
            connection,
            sql: "SELECT count(*) FROM CustomStamp WHERE assetHash = ?",
            arguments: [assetHash.bytes]
        ) ?? 0
        let projectRefCount = try Int.fetchOne(
            connection,
            sql: "SELECT count(*) FROM ProjectStampAsset WHERE assetHash = ?",
            arguments: [assetHash.bytes]
        ) ?? 0
        guard customStampCount == 0, projectRefCount == 0 else {
            return
        }

        guard let fileID = try UUID.fetchOne(
            connection, sql: "SELECT fileID FROM StampAsset WHERE contentHash = ?", arguments: [assetHash.bytes]
        ) else {
            // 呼び出し元（removeCustomStamp/releaseStampReference）は削除対象行の
            // 存在を確認した上でこの関数を呼ぶため通常は起きないが、防御的にno-opとする
            // （握りつぶしではなく、削除すべき実体が既に無いだけの状態）。
            return
        }
        try connection.execute(sql: "DELETE FROM StampAsset WHERE contentHash = ?", arguments: [assetHash.bytes])
        try connection.execute(
            sql: "INSERT OR IGNORE INTO PendingFileDeletion (kind, fileID) VALUES (?, ?)",
            arguments: [ManagedFileKind.stampAsset.rawValue, fileID]
        )
    }
}
