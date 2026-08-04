import Foundation
import Domain

// StampStoreの実装（architecture.md「StampStore」節・「参照カウント」表・「DBとファイルの
// 更新順序」節が正本。Issue #6 Task 4）。
//
// 参照カウント = CustomStamp.assetHashの行数 + ProjectStampAssetの行数（正本の式）。
// 作成はファイル→DBの順（失敗時はファイルが孤児として残るだけ）、削除はDB→
// PendingFileDeletion登録→（コミット後の）ファイル削除の順（正本「DBとファイルの
// 更新順序」）に従う。
//
// 400行制限のため、メソッド群を以下へ分割する（WorkingSourceStoreLiveの分割パターンを
// 踏襲）:
//   - StampStoreLive.swift（このファイル）: struct定義・init
//   - StampStoreLive+Import.swift: importCustomStamp
//   - StampStoreLive+References.swift: removeCustomStamp / attachStampReference /
//     releaseStampReference（参照が0になった実体の解放はHistoryDeletionStoreと共有する
//     StampAssetReferences.swiftが担当する）
//   - StampStoreLive+Storage.swift: loadCustomStamps / loadStampStorageBreakdown

/// StampStoreの実装。GRDBのAppDatabaseとManagedFileStoreを1つずつ受け取り、全メソッドを
/// dbQueue.write / dbQueue.readとfileStoreの呼び出しだけで完結させる。
///
/// `database` / `fileStore` はpublicではないが、複数ファイルへ分割したextensionから
/// 参照する必要があるため（WorkingSourceStoreLiveと同じ理由）モジュール内既定アクセス
/// （internal）のままにする。外部パッケージからは見えない。
public struct StampStoreLive: StampStore {
    let database: AppDatabase
    let fileStore: ManagedFileStore

    public init(database: AppDatabase, fileStore: ManagedFileStore) {
        self.database = database
        self.fileStore = fileStore
    }
}
