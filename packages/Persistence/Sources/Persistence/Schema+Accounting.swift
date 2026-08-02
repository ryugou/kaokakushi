import GRDB

// Accounting 系テーブル（architecture.md 7.1 / 6.3）。ExportJob → OutputRecord →
// ExportRecord → UsageLedger → ExportedSettingsEntry の順で作成する。
// いずれもProject・Batchを参照するため、この関数はSchema.swiftの呼び出し順で
// createProjectTables / createQueueTables の後に呼ばれる必要がある。

/// `ExportJob`・`OutputRecord`・`ExportRecord`・`UsageLedger`・
/// `ExportedSettingsEntry` を作成する。
func createAccountingTables(_ database: Database) throws {
    try createExportProgressTables(database)
    try createSettlementTables(database)
}

/// 書き出し進行中の状態（`ExportJob` / `OutputRecord` と部分 UNIQUE）。
private func createExportProgressTables(_ database: Database) throws {
    try database.create(table: "ExportJob") { tableDef in
        tableDef.primaryKey("exportID", .blob)
        tableDef.column("projectID", .blob).notNull().references("Project", onDelete: .restrict)
        tableDef.column("batchID", .blob).references("Batch", onDelete: .setNull)
        // ExportQueueItemの行そのもの（キュー経路の場合のみ）。FKは宣言しない
        // （外部キー表に記載が無い）。
        tableDef.column("queueItemID", .blob)
        tableDef.column("authorizedAt", .datetime).notNull()
        // ExportAccountingModeの判別子。raw valueの割当はStore実装タスクの担当。
        tableDef.column("accountingMode", .integer).notNull()
        // Plan.rawValue / PlanStatus.rawValue。
        tableDef.column("entitlementPlan", .integer).notNull()
        tableDef.column("entitlementStatus", .integer).notNull()
        tableDef.column("entitlementExpiresAt", .datetime)
        tableDef.column("entitlementLastVerifiedAt", .datetime).notNull()
        tableDef.column("entitlementIsSandbox", .boolean).notNull()
        // ImageFormatの判別子。raw valueの割当はStore実装タスクの担当。
        tableDef.column("deliveryFormat", .integer).notNull()
        tableDef.column("deliverySuggestedCreationDate", .datetime)
    }

    try database.create(table: "OutputRecord") { tableDef in
        tableDef.primaryKey("exportID", .blob)
        tableDef.column("projectID", .blob).notNull().references("Project", onDelete: .restrict)
        tableDef.column("batchID", .blob).references("Batch", onDelete: .setNull)
        // ManagedFileRef(.output, fileID)のfileID。
        tableDef.column("outputFileID", .blob).notNull()
        tableDef.column("outputByteSize", .integer).notNull()
        tableDef.column("outputSHA256", .blob).notNull()
        // OutputState.rawValue（generated=1, deliveryUnknown=2, delivered=3）。
        tableDef.column("state", .integer).notNull()
        tableDef.column("generatedAt", .datetime).notNull()
        tableDef.column("settledAt", .datetime)
        tableDef.column("expiresAt", .datetime)
        // ImageFormatの判別子。raw valueの割当はStore実装タスクの担当。
        tableDef.column("format", .integer).notNull()
        tableDef.column("suggestedCreationDate", .datetime)
    }

    // 「未確定の出力は1プロジェクトにつき1件」の部分UNIQUEインデックス
    // （architecture.md 7.1）。settledAtがNULLの行だけを対象にする。
    try database.create(
        index: "OutputRecord_on_projectID_where_pending",
        on: "OutputRecord",
        columns: ["projectID"],
        options: .unique,
        condition: Column("settledAt") == nil
    )
}

/// 完了操作で確定する記録（`ExportRecord` / `UsageLedger` / `ExportedSettingsEntry`）。
private func createSettlementTables(_ database: Database) throws {
    try database.create(table: "ExportRecord") { tableDef in
        tableDef.primaryKey("exportID", .blob)
        tableDef.column("projectID", .blob).notNull().references("Project", onDelete: .cascade)
        tableDef.column("batchID", .blob).references("Batch", onDelete: .setNull)
        tableDef.column("exportedAt", .datetime).notNull()
        // ExportAccountingModeの判別子。raw valueの割当はStore実装タスクの担当。
        tableDef.column("accountingMode", .integer).notNull()
        // ImageFormatの判別子。raw valueの割当はStore実装タスクの担当。
        tableDef.column("format", .integer).notNull()
        tableDef.column("outputByteSize", .integer).notNull()
    }

    try database.create(table: "UsageLedger") { tableDef in
        tableDef.column("periodYear", .integer).notNull()
        tableDef.column("periodMonth", .integer).notNull()
        // Set<ExportID>のシリアライズ形式は未確定。シリアライズ方式はExportSagaStore
        // 実装タスクの担当。
        tableDef.column("consumedExportIDs", .blob).notNull()
        tableDef.column("trialConsumedExportIDs", .blob).notNull()
        // 「台帳は1つ」だが一意制約表に記載が無いためDB制約としては追加しない。
        // 単一行であることはApplication層が保証する（architecture.md原文どおり、
        // 表に無い制約を追加発明しない）。
    }

    try database.create(table: "ExportedSettingsEntry") { tableDef in
        tableDef.primaryKey("projectID", .blob).references("Project", onDelete: .cascade)
        tableDef.column("settingsHash", .blob).notNull()
        tableDef.column("exportedAt", .datetime).notNull()
    }
}
