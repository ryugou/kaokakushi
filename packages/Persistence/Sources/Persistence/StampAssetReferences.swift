import Foundation
import Domain
import GRDB

// StampAssetの参照解放（architecture.md「StampAsset」節「参照カウント」表・「契機」表・
// 「DBとファイルの更新順序」節が正本）。
//
// 参照が0になった実体を削除する手順はStampStore（removeCustomStamp /
// releaseStampReference）とHistoryDeletionStore（deleteHistoryUnit）の両方が必要とする。
// 判定条件・削除手順が片方だけ変更される事故を防ぐため、ここへ集約する。
//
// 呼び出し元はいずれもdbQueue.writeクロージャ内から呼ぶため、この関数内の操作は自動的に
// 同一トランザクションへ含まれる。deleteHistoryUnitからの呼び出しはProject行の削除
// （CASCADEで当該プロジェクトのProjectStampAsset行が消える）後に行われるため、そこで
// 数える残存参照は「他のプロジェクト・CustomStamp経由の参照のみ」になる。
enum StampAssetReferences {
    /// 参照カウント = CustomStamp.assetHashの行数 + ProjectStampAssetの行数
    /// （architecture.md「参照カウント」）。両方0なら実体（StampAsset行）を削除し、
    /// その実ファイルをPendingFileDeletionへ登録する（正本「DBとファイルの更新順序」の
    /// 削除手順1・2。ファイルの実削除はコミット後にGCが担当する）。
    static func releaseIfUnreferenced(_ connection: Database, assetHash: StampAssetHash) throws {
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
            // 呼び出し元（removeCustomStamp/releaseStampReference/deleteHistoryUnit）は
            // 削除対象行の存在を確認した上でこの関数を呼ぶため通常は起きないが、防御的に
            // no-opとする（握りつぶしではなく、削除すべき実体が既に無いだけの状態）。
            return
        }
        try connection.execute(sql: "DELETE FROM StampAsset WHERE contentHash = ?", arguments: [assetHash.bytes])
        try registerPendingFileDeletion(connection, kind: .stampAsset, fileID: fileID)
    }
}
