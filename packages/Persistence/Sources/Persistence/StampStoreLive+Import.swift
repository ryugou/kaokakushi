import Foundation
import Domain
import GRDB
// CryptoKitはApple platform専用API。CIのpackage-testsジョブはmacos-15で動くため現状は
// 問題ないが、将来Persistenceパッケージ内のswift testをLinux上でも実行する計画が出た
// 場合はswift-crypto（import Crypto）への置き換えが必要になる。
import CryptoKit

// importCustomStamp（architecture.md「StampStore」節・「内容ハッシュの対象」節が正本）。

/// StampStoreLiveが送出する専用エラー。運用者が次のアクションを判断できるよう、
/// 契約違反の詳細を持つ（WorkingSourceStoreError/HistoryDeletionStoreErrorと同じ方針:
/// Sendable, Equatable, LocalizedError）。
public enum StampStoreError: Error, Sendable, Equatable {
    /// insertStampRows: 既存CustomStamp.sortOrderの最大値が既にInt32.maxだった。このまま
    /// +1すると符号付き32bit整数のオーバーフローでtrapし、DB破損や復元時のクラッシュを
    /// 招く。黙って折り返す・切り詰めるといった曖昧な挙動は選ばず、fail-closedとして
    /// 明示的にthrowする（採番の空き確保は呼び出し元の運用判断に委ねる）。
    case sortOrderOverflow
}

extension StampStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sortOrderOverflow:
            return """
            StampStore: CustomStamp.sortOrderの最大値が既にInt32.maxに達しているため、 \
            新規スタンプの採番ができません。採番はMAX(sortOrder) + 1で行うため、 \
            sortOrderが最大のCustomStamp行を削除するか、CustomStamp.sortOrder列を \
            再採番してから再試行してください。
            """
        }
    }
}

extension StampStoreLive {
    public func importCustomStamp(
        name: String,
        body: @Sendable (URL) async throws -> Void,
        thumbnailBody: @Sendable (URL) async throws -> Void
    ) async throws -> (stamp: CustomStamp, assetHash: StampAssetHash) {
        // bodyが一時ファイルへ書き終えた直後（atomic rename前）のバイト列を読み取る
        // （内容ハッシュの計算時点はManagedFileStoreへ書く直前——正本「内容ハッシュの
        // 対象」）。
        let (assetRef, savedBytes) = try await fileStore.createFile(kind: .stampAsset) { url in
            try await body(url)
            return try Data(contentsOf: url)
        }
        let assetHash = try StampAssetHash(bytes: Data(SHA256.hash(data: savedBytes)))

        // thumbnailは重複取り込みでもCustomStamp行ごとに必ず新規作成する（正本どおり）。
        let (thumbnailRef, _) = try await fileStore.createFile(kind: .stampThumbnail) { url in
            try await thumbnailBody(url)
        }

        let customStampID = CustomStampID(rawValue: UUID())
        let newRows = NewStampRows(
            assetHash: assetHash,
            assetFileID: assetRef.fileID,
            customStampID: customStampID,
            name: name,
            thumbnailFileID: thumbnailRef.fileID
        )
        // 既存StampAssetが再利用された場合、新規に書いたファイル（assetRef）はどこにも
        // 参照されなくなる（正本「新規に書いたファイルは破棄する」）。ここで直接
        // fileStore.deleteすると、DBコミット自体は成功しているのにこのクリーンアップの
        // I/O失敗でimportCustomStamp API全体が失敗する経路になってしまうため、
        // insertStampRows内（同一トランザクション）でPendingFileDeletionへ登録し、
        // 実削除は他Storeと同じく起動時GCに委ねる（didReuseExistingAssetはこの分岐の
        // ためだけにinsertStampRowsが返す値で、呼び出し元では使わない）。
        let (_, sortOrder) = try await database.dbQueue.write { connection in
            try Self.insertStampRows(connection, rows: newRows)
        }

        let stamp = CustomStamp(
            customStampID: customStampID,
            assetHash: assetHash,
            name: name,
            sortOrder: sortOrder,
            thumbnail: thumbnailRef
        )
        return (stamp: stamp, assetHash: assetHash)
    }

    /// insertStampRows へ渡す新規行の値ひとそろい（lint の引数上限対応で束ねた入力）。
    private struct NewStampRows {
        let assetHash: StampAssetHash
        let assetFileID: ManagedFileID
        let customStampID: CustomStampID
        let name: String
        let thumbnailFileID: ManagedFileID
    }

    /// 単一トランザクションで: (1) 既存StampAssetの有無を判定 (2) 無ければ新規作成、
    /// あれば新規に書いたファイルをPendingFileDeletionへ登録 (3) 既存最大sortOrder + 1を
    /// 採番（Int32.max到達時はStampStoreError.sortOrderOverflowをthrowしfail-closed。
    /// throwするとdbQueue.writeがロールバックするため、ここまでのStampAsset登録も
    /// 取り消される） (4) CustomStamp行を作成する。
    /// 戻り値は「既存StampAssetを再利用したか」と、採番したsortOrder。
    private static func insertStampRows(
        _ connection: Database,
        rows: NewStampRows
    ) throws -> (didReuseExistingAsset: Bool, sortOrder: Int32) {
        let existingCount = try Int.fetchOne(
            connection,
            sql: "SELECT count(*) FROM StampAsset WHERE contentHash = ?",
            arguments: [rows.assetHash.bytes]
        ) ?? 0
        let didReuseExistingAsset = existingCount > 0

        if didReuseExistingAsset {
            // 新規に書いたファイル（rows.assetFileID）は既存StampAssetの再利用により
            // どこからも参照されなくなった。同一トランザクション内でPendingFileDeletionへ
            // 登録し、実削除は起動時GCへ委ねる（importCustomStampのコメント参照）。
            try registerPendingFileDeletion(connection, kind: .stampAsset, fileID: rows.assetFileID.rawValue)
        } else {
            try connection.execute(
                sql: "INSERT INTO StampAsset (contentHash, fileID) VALUES (?, ?)",
                arguments: [rows.assetHash.bytes, rows.assetFileID.rawValue]
            )
        }

        let maxSortOrder = try Int32.fetchOne(
            connection, sql: "SELECT COALESCE(MAX(sortOrder), 0) FROM CustomStamp"
        ) ?? 0
        guard maxSortOrder != Int32.max else {
            throw StampStoreError.sortOrderOverflow
        }
        let sortOrder = maxSortOrder + 1

        try connection.execute(
            sql: """
            INSERT INTO CustomStamp (customStampID, assetHash, name, sortOrder, thumbnailFileID)
            VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [
                rows.customStampID.rawValue, rows.assetHash.bytes, rows.name,
                sortOrder, rows.thumbnailFileID.rawValue
            ]
        )

        return (didReuseExistingAsset, sortOrder)
    }
}
