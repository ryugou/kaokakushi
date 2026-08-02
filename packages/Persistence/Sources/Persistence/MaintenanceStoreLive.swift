import Foundation
import Domain
import GRDB

// MaintenanceStoreの実装（architecture.md 7.5「孤児ファイルのGC」「MaintenanceStore」が
// 正本。Issue #6 Task 4）。起動時GCが使う永続化ポート1つに集約する。
//
// listReferencedFileIDsの参照元はkindごとに固定されている（architecture.md 7.5の対応表）。
// このタスク時点のschema v1（Task 2確定済み）には`.historyThumbnail`の参照列が存在しない
// ため常に空集合を返す。他のkindの実装詳細は本ファイルと
// MaintenanceStoreLive+References.swiftに分割する。

/// MaintenanceStoreLiveが送出する専用エラー（AppDatabaseError/ManagedFileStoreErrorと
/// 同じ方針: Sendable, Equatable, LocalizedError）。
public enum MaintenanceStoreError: Error, Sendable, Equatable {
    /// loadPendingFileDeletions: PendingFileDeletion.kind列の値がManagedFileKindの
    /// どのraw valueとも一致しなかった。スキーマとDomainのenumが不整合になっている
    /// （マイグレーション漏れ、または手動でのDB改変が疑われる）場合に握りつぶさず
    /// 復旧エラーとして送出する。
    case unknownPendingFileDeletionKind(rawValue: Int)
}

extension MaintenanceStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownPendingFileDeletionKind(let rawValue):
            return """
            MaintenanceStore: PendingFileDeletion.kind=\(rawValue) はManagedFileKindの \
            どのraw valueとも一致しません。スキーマとDomainのManagedFileKindが不整合に \
            なっている可能性があります（マイグレーション漏れ、または手動でのDB改変を \
            疑ってください）。PendingFileDeletionテーブルの内容とアプリのバージョンを \
            確認してください。
            """
        }
    }
}

/// MaintenanceStoreの実装。起動時の孤児ファイルGC専用（architecture.md 7.5）。
public struct MaintenanceStoreLive: MaintenanceStore {
    // WorkingSourceStoreLiveと同じ理由（複数ファイルへの分割）でinternalのままにする。
    let database: AppDatabase
    let directories: ManagedFileDirectories

    public init(database: AppDatabase, directories: ManagedFileDirectories) {
        self.database = database
        self.directories = directories
    }

    /// 未処理のPendingFileDeletionをすべて読む。デコードできないkindが来た場合は
    /// 握りつぶさず`MaintenanceStoreError.unknownPendingFileDeletionKind`をthrowする。
    public func loadPendingFileDeletions() async throws -> [PendingFileDeletion] {
        let rows = try await database.dbQueue.read { connection in
            try Row.fetchAll(connection, sql: "SELECT kind, fileID FROM PendingFileDeletion")
        }
        return try rows.map { row in
            let kindRawValue: Int = row["kind"]
            guard
                let kindUInt32 = UInt32(exactly: kindRawValue),
                let kind = ManagedFileKind(rawValue: kindUInt32)
            else {
                throw MaintenanceStoreError.unknownPendingFileDeletionKind(rawValue: kindRawValue)
            }
            let fileID: UUID = row["fileID"]
            return PendingFileDeletion(file: ManagedFileRef(kind: kind, fileID: ManagedFileID(rawValue: fileID)))
        }
    }

    /// 実体削除に成功した行を消す。
    public func clearPendingFileDeletion(_ file: ManagedFileRef) async throws {
        try await database.dbQueue.write { connection in
            try connection.execute(
                sql: "DELETE FROM PendingFileDeletion WHERE kind = ? AND fileID = ?",
                arguments: [file.kind.rawValue, file.fileID.rawValue]
            )
        }
    }

    /// 孤児ファイルを削除候補として登録する。`INSERT OR IGNORE`により、同じ孤児を
    /// 複数回登録してもPRIMARY KEY制約違反でクラッシュしない（冪等性）。
    public func registerOrphan(_ file: ManagedFileRef) async throws {
        try await database.dbQueue.write { connection in
            try connection.execute(
                sql: "INSERT OR IGNORE INTO PendingFileDeletion (kind, fileID) VALUES (?, ?)",
                arguments: [file.kind.rawValue, file.fileID.rawValue]
            )
        }
    }

    /// kindごとの管理ディレクトリ内に実在するファイルIDの一覧。ディレクトリが未作成の
    /// 場合は空集合を返す（GC初回実行時にディレクトリが無くても落とさない）。ファイル名を
    /// UUIDとしてパースできないもの（"tmp-"接頭辞の一時ファイル等）は無視する
    /// （正常系ではManagedFileStoreLiveの手順7により残らないはずだが、防御的にスキップする）。
    public func listExistingFileIDs(kind: ManagedFileKind) async throws -> Set<ManagedFileID> {
        let directory = directories.directory(for: kind)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        var result = Set<ManagedFileID>()
        for entry in entries {
            guard let uuid = UUID(uuidString: entry.lastPathComponent) else {
                continue
            }
            result.insert(ManagedFileID(rawValue: uuid))
        }
        return result
    }
}
