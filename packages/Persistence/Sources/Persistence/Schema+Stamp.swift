import GRDB

// Stamp 系テーブル（architecture.md 7.1 / 7.5）。StampAsset（内容ハッシュを主キーと
// する不変の実体メタデータ）→ CustomStamp → ProjectStampAsset の順で作成する
// （CustomStamp/ProjectStampAssetがStampAssetを参照するため）。

/// `StampAsset`・`CustomStamp`・`ProjectStampAsset` を作成する。
/// この関数の呼び出し時点で `Project` テーブルが既に存在している必要がある
/// （ProjectStampAsset.projectID のFKが参照するため。Schema.swiftの呼び出し順を参照）。
func createStampTables(_ database: Database) throws {
    try database.create(table: "StampAsset") { tableDef in
        // 内容ハッシュ（SHA-256等。32バイトを想定）を主キーとする不変実体。
        tableDef.primaryKey("contentHash", .blob)
        // ManagedFileRef(.stampAsset, fileID)のfileID。
        tableDef.column("fileID", .blob).notNull()
    }

    try database.create(table: "CustomStamp") { tableDef in
        tableDef.primaryKey("customStampID", .blob)
        tableDef.column("assetHash", .blob).notNull().references("StampAsset", onDelete: .restrict)
        tableDef.column("name", .text).notNull()
        tableDef.column("sortOrder", .integer).notNull()
        // ManagedFileRef(.stampThumbnail, fileID)のfileID。kindは.stampThumbnail固定
        // なので列は持たない。
        tableDef.column("thumbnailFileID", .blob).notNull()
    }

    try database.create(table: "ProjectStampAsset") { tableDef in
        // 複合PRIMARY KEYが一意制約表のUNIQUE(projectID, assetHash)を兼ねる。
        // primaryKey(body:)内のcolumn()はNOT NULLを自動付与する。
        tableDef.primaryKey {
            tableDef.column("projectID", .blob)
            tableDef.column("assetHash", .blob)
        }
        tableDef.foreignKey(["projectID"], references: "Project", onDelete: .cascade)
        tableDef.foreignKey(["assetHash"], references: "StampAsset", onDelete: .restrict)
    }
}
