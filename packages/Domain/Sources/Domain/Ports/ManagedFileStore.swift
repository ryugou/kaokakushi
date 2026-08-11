import Foundation

// ManagedFileStore プロトコル（architecture.md 7.3「ManagedFileStore」の「スコープ付き
// アクセス」小節）。
//
// `ManagedFileKind` / `ManagedFileID` / `ManagedFileRef` / `PendingFileDeletion` /
// `OutputFileRef` / `WorkingSourceFileRef` / `RasterFileRef` / `StampAssetFileRef` は
// 既に ManagedFileRef.swift（Task 1）に実装済みのため再宣言しない。
//
// `URL` は Foundation 型のため import 制約（Domain は Foundation のみ）に抵触しない。
// ジェネリックメソッドの `<R: Sendable>` と `@Sendable (URL) async throws -> R` は
// 正本コードブロックのシグネチャを一字一句転記する。
//
// アクセス修飾（public）の方針は ExportSagaStore.swift と同じ。

/// ファイル生成を 1 か所へ集約する永続化ポート（architecture.md 7.3）。
/// 「パスを返さない」だけでは `MediaKit` と `Rendering` がファイルを開けないため、
/// 永続的な `URL` は公開せず処理中だけ有効なスコープを渡す（同節「スコープ付きアクセス」）。
public protocol ManagedFileStore: Sendable {
    /// 読み取り。body の実行中だけ URL が有効
    func withReadAccess<R: Sendable>(
        _ ref: ManagedFileRef,
        _ body: @Sendable (URL) async throws -> R
    ) async throws -> R

    /// 新規作成。body が書いた一時ファイルを、復帰後に上の順序で確定する
    func createFile<R: Sendable>(
        kind: ManagedFileKind,
        _ body: @Sendable (URL) async throws -> R
    ) async throws -> (ref: ManagedFileRef, result: R)

    func delete(_ ref: ManagedFileRef) async throws

    /// 実体の存在確認のみを行う（スコープ付きアクセスは取得しない。image-pipeline.md
    /// 「実体の存在確認」）。
    /// - 実体が無ければ `false` を返す
    /// - 存在確認そのものが失敗した場合（保護データ利用不可・I/O 障害など）は throw する。
    ///   呼び出し側はこれを「欠損」として扱ってはならない（実在する素材の不可逆な削除に
    ///   つながるため）
    func exists(_ ref: ManagedFileRef) async throws -> Bool
}
