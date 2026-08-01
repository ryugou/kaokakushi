import Foundation

// スタンプの永続化ポート（architecture.md「StampStore」節）。
//
// `StampAssetHash` は既に CommonValues.swift（Task 1）に実装済みのため再宣言しない。
//
// アクセス修飾（public）の方針は ExportSagaStore.swift と同じ。

/// スタンプ一覧の項目（仕様 19.6）
public struct CustomStamp: Sendable, Equatable {
    public let customStampID: CustomStampID
    public let assetHash: StampAssetHash    // 画像実体への参照
    public let name: String
    public let sortOrder: Int32
    public let thumbnail: ManagedFileRef    // .stampThumbnail。実体から再生成できるキャッシュ

    public init(
        customStampID: CustomStampID,
        assetHash: StampAssetHash,
        name: String,
        sortOrder: Int32,
        thumbnail: ManagedFileRef
    ) {
        self.customStampID = customStampID
        self.assetHash = assetHash
        self.name = name
        self.sortOrder = sortOrder
        self.thumbnail = thumbnail
    }
}

// Domain — 永続化ポート（architecture.md「StampStore」）。
// `CustomStamp` / `StampAsset` / `ProjectStampAsset` を扱う永続化ポートを 1 つに集約する
// （`Application` は `GRDB` を直接扱わないため。4.3）。
public protocol StampStore: Sendable {
    /// 取り込み。body が一時ファイルへ書いた内容の SHA-256 が既存の StampAsset と一致すれば
    /// それを再利用し、新規に書いたファイルは破棄する。一致しなければ新規 StampAsset を作る
    func importCustomStamp(
        _ body: @Sendable (URL) async throws -> Void
    ) async throws -> (stamp: CustomStamp, assetHash: StampAssetHash)

    /// スタンプ一覧
    func loadCustomStamps() async throws -> [CustomStamp]

    /// 一覧から削除する（CustomStamp 行のみ。StampAsset の参照カウントは変えない）
    func removeCustomStamp(_ id: CustomStampID) async throws

    /// Project のいずれかの領域が実体を使うようになった。UNIQUE(projectID, assetHash) により冪等
    func attachStampReference(projectID: ProjectID, assetHash: StampAssetHash) async throws
    /// Project からその実体を使う領域がすべて無くなった。同一トランザクションで参照数を導出し、
    /// 0 になった実体は同じトランザクション内で PendingFileDeletion へ登録する
    func releaseStampReference(projectID: ProjectID, assetHash: StampAssetHash) async throws

    /// 使用容量の内訳（登録中のマイスタンプ / 過去の加工履歴で使用中 / 合計）
    func loadStampStorageBreakdown() async throws -> StampStorageBreakdown
}

/// 使用容量の内訳（architecture.md「使用容量の表示」節が正本）
public struct StampStorageBreakdown: Sendable {
    public let registeredBytes: Int64     // 登録中のマイスタンプ（一覧に存在する CustomStamp が指す実体）
    public let historyOnlyBytes: Int64    // 一覧から削除済みだが過去の加工履歴で参照中の実体
    public let totalBytes: Int64

    public init(registeredBytes: Int64, historyOnlyBytes: Int64, totalBytes: Int64) {
        self.registeredBytes = registeredBytes
        self.historyOnlyBytes = historyOnlyBytes
        self.totalBytes = totalBytes
    }
}
