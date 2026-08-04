import Foundation
import Domain
import GRDB

// listReferencedFileIDs（architecture.md 7.5「MaintenanceStore」直後の対応表が正本）。

extension MaintenanceStoreLive {
    /// 種別ごとに、DB上のテーブルが参照しているIDの一覧を返す。参照元はkindごとに
    /// 固定されている（architecture.md 7.5の対応表）。
    public func listReferencedFileIDs(kind: ManagedFileKind) async throws -> Set<ManagedFileID> {
        switch kind {
        case .output:
            return try await fetchReferencedIDs(sql: "SELECT outputFileID FROM OutputRecord")
        case .stampAsset:
            return try await fetchReferencedIDs(sql: "SELECT fileID FROM StampAsset")
        case .stampThumbnail:
            // architecture.md 1987行（正本）により、`.stampThumbnail`の参照元は
            // `CustomStamp.thumbnailFileID`（一覧サムネイルは行が参照を持つ。欠損時は
            // 実体から再生成する）。
            return try await fetchReferencedIDs(sql: "SELECT thumbnailFileID FROM CustomStamp")
        case .processingTemporary:
            return try await fetchReferencedIDs(sql: "SELECT sourceFileID FROM WorkingSourceRecord")
        case .historyThumbnail:
            // v1では`.historyThumbnail`の参照列を持たず常に空集合を返す（正本
            // architecture.md 7.5の対応表）。これによりhistoryThumbnail種別の孤児GCは
            // 今のところ機能しない（起動時GCが誤って現用中のhistory thumbnailを削除する
            // ことはない一方、本来削除すべき孤児も検出できない）。参照列の追加とGC有効化は
            // Issue #26。
            return []
        case .rasterTemporary:
            // image-pipeline.md「検出用の縮小画像の寿命」と同じ理由で、ラスタ一時ファイルは
            // DBに一切登録されない設計のため参照集合は常に空（1回のrender呼び出し内でのみ
            // 有効なメモリ上の一時ファイルであり、再起動をまたいで実体が残っていれば
            // それ自体が孤児）。
            return []
        }
    }

    private func fetchReferencedIDs(sql: String) async throws -> Set<ManagedFileID> {
        let ids = try await database.dbQueue.read { connection in
            try UUID.fetchAll(connection, sql: sql)
        }
        return Set(ids.map(ManagedFileID.init(rawValue:)))
    }
}
