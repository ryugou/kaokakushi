import Foundation
import Domain
import GRDB

// ProjectStampAsset解放ロジック（architecture.md「StampAsset」節「参照カウント」表・
// 「契機」表の「Projectを削除した」行が正本）。
//
// StampStoreLive+References.swiftのdeleteStampAssetIfUnreferencedと同型のロジックだが、
// private staticのため直接呼び出せない。HistoryDeletionStoreLive+Delete.swiftの
// deleteHistoryUnitは既にProject行を削除しCASCADEでこのプロジェクトのProjectStampAsset行を
// 消した後に本関数を呼ぶため、ここで数える残存参照数は「他のプロジェクト・CustomStamp経由の
// 参照のみ」になる（オーケストレーター確定判断: コード重複は許容。StampStoreLive+
// References.swift側の可視性は変更しない）。

extension HistoryDeletionStoreLive {
    /// 参照カウント = CustomStamp.assetHashの行数 + ProjectStampAssetの行数
    /// （architecture.md「参照カウント」）。両方0なら実体を削除しPendingFileDeletionへ
    /// 登録する（StampStoreLive+References.swift.deleteStampAssetIfUnreferencedと同じ手順）。
    static func releaseStampAssetIfUnreferenced(_ connection: Database, assetHash: StampAssetHash) throws {
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
            // deleteHistoryUnitは削除前に読み取ったassetHashだけを渡すため通常は起きないが、
            // 防御的にno-opとする（握りつぶしではなく、削除すべき実体が既に無いだけの状態）。
            return
        }
        try connection.execute(sql: "DELETE FROM StampAsset WHERE contentHash = ?", arguments: [assetHash.bytes])
        try connection.execute(
            sql: "INSERT OR IGNORE INTO PendingFileDeletion (kind, fileID) VALUES (?, ?)",
            arguments: [ManagedFileKind.stampAsset.rawValue, fileID]
        )
    }
}
