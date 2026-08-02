import Foundation

// 起動時 GC が使う永続化ポート（architecture.md「MaintenanceStore」節）。
//
// `PendingFileDeletion` / `ManagedFileKind` / `ManagedFileID` / `ManagedFileRef` は
// 既に ManagedFileRef.swift（Task 1）に実装済みのため再宣言しない。
//
// アクセス修飾（public）の方針は ExportSagaStore.swift と同じ。

/// Domain — 永続化ポート。起動時の孤児ファイル GC が使う（architecture.md「MaintenanceStore」）。
public protocol MaintenanceStore: Sendable {
    /// 未処理の PendingFileDeletion をすべて読む
    func loadPendingFileDeletions() async throws -> [PendingFileDeletion]
    /// 実体削除に成功した行を消す
    func clearPendingFileDeletion(_ file: ManagedFileRef) async throws

    /// 種別ごとに、管理ディレクトリ内に実在するファイル ID の一覧を返す
    func listExistingFileIDs(kind: ManagedFileKind) async throws -> Set<ManagedFileID>
    /// 種別ごとに、DB 上のテーブルが参照している ID の一覧を返す
    func listReferencedFileIDs(kind: ManagedFileKind) async throws -> Set<ManagedFileID>

    /// 孤児ファイル（listExistingFileIDs にあり listReferencedFileIDs に無いもの）を削除候補として登録する
    func registerOrphan(_ file: ManagedFileRef) async throws
}
