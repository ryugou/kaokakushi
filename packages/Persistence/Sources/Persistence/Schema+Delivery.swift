import GRDB

// Delivery 系テーブル（architecture.md 7.1）。DeliveryAttempt・UnknownLibrarySaveは
// OutputRecordを参照するため、この関数はSchema.swiftの呼び出し順で
// createAccountingTables の後に呼ばれる必要がある。PendingFileDeletion・
// SubscriptionStateはFKを持たないため順序に制約は無い。

/// `DeliveryAttempt`・`UnknownLibrarySave`・`PendingFileDeletion`・
/// `SubscriptionState` を作成する。
func createDeliveryTables(_ database: Database) throws {
    try database.create(table: "DeliveryAttempt") { tableDef in
        // PRIMARY KEYがOutputRecordへのFK（CASCADE）を兼ねる。
        tableDef.primaryKey("exportID", .blob).references("OutputRecord", onDelete: .cascade)
        tableDef.column("startedAt", .datetime).notNull()
        // OutputState.rawValue（試行開始前のstate。中断時の復旧に使う）。
        tableDef.column("previousState", .integer).notNull()
    }

    try database.create(table: "UnknownLibrarySave") { tableDef in
        // PRIMARY KEYがOutputRecordへのFK（CASCADE）を兼ねる。
        tableDef.primaryKey("exportID", .blob).references("OutputRecord", onDelete: .cascade)
        tableDef.column("occurredAt", .datetime).notNull()
    }

    try database.create(table: "PendingFileDeletion") { tableDef in
        // 複合PRIMARY KEYが一意制約表のUNIQUE(kind, fileID)を兼ねる。
        // primaryKey(body:)内のcolumn()はNOT NULLを自動付与する。
        tableDef.primaryKey {
            // ManagedFileKind.rawValue（output=1, stampAsset=2, historyThumbnail=3,
            // stampThumbnail=4, processingTemporary=5, rasterTemporary=6）。
            tableDef.column("kind", .integer)
            tableDef.column("fileID", .blob)
        }
    }

    try database.create(table: "SubscriptionState") { tableDef in
        // 一意制約表に記載が無いため明示的なPRIMARY KEY/UNIQUEは追加しない
        // （UsageLedgerと同じ理由。単一行であることはApplication層が保証する）。
        // Plan.rawValue / PlanStatus.rawValue。
        tableDef.column("plan", .integer).notNull()
        tableDef.column("status", .integer).notNull()
        tableDef.column("expiresAt", .datetime)
        tableDef.column("lastVerifiedAt", .datetime).notNull()
        tableDef.column("isSandbox", .boolean).notNull()
        tableDef.column("willRenew", .boolean).notNull()
        tableDef.column("fetchedAt", .datetime).notNull()
    }
}
