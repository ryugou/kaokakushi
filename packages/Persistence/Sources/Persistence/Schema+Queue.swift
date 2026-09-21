import GRDB

// Queue 系テーブル（architecture.md 7.1 / 6.4）。Batch → BatchPreset の順で
// 作成する。

/// `Batch`・`BatchPreset` を作成する。
func createQueueTables(_ database: Database) throws {
    try database.create(table: "Batch") { tableDef in
        tableDef.primaryKey("batchID", .blob)
        // BatchKind.rawValue（proBatch=1, trial=2）。
        tableDef.column("kind", .integer).notNull()
        tableDef.column("batchSizeLimit", .integer).notNull()
        tableDef.column("trialCreditCount", .integer).notNull()
        tableDef.column("concurrencyLimit", .integer).notNull()
        // 認可（export-saga.md 1.3・1.5）の平坦化。ExportSagaStoreLive.createBatchが
        // Batch作成と同一トランザクションで評価・固定する（一括処理キュー簡素化 Issue #40
        // 決定2）。列名・NULL可否はSchema+Accounting.swiftのExportJob認可列と完全に一致させる
        // （ExportSagaStoreLive+Mapping.swiftのdecodeAuthorizationをExportJob/Batch両方の
        // デコードで共有するため）。
        tableDef.column("authorizedAt", .datetime).notNull()
        // ExportAccountingModeの判別子。raw valueの割当はExportSagaStoreLive.swift
        // （ExportAccountingModeColumn）参照。
        tableDef.column("accountingMode", .integer).notNull()
        // Plan.rawValue / PlanStatus.rawValue。
        tableDef.column("entitlementPlan", .integer).notNull()
        tableDef.column("entitlementStatus", .integer).notNull()
        tableDef.column("entitlementExpiresAt", .datetime)
        tableDef.column("entitlementLastVerifiedAt", .datetime).notNull()
        tableDef.column("entitlementIsSandbox", .boolean).notNull()
    }

    try database.create(table: "BatchPreset") { tableDef in
        tableDef.primaryKey("batchPresetID", .blob)
        tableDef.column("name", .text).notNull()
        // architecture.md 7.1にはテーブル名以外の仕様が無く（「一括設定プリセット」
        // とだけ記載）、名前と内容の入れ物だけを用意する最小構成。列の詳細は
        // BatchPresetを読み書きする将来タスクの担当。
        tableDef.column("policySnapshotData", .blob).notNull()
    }
}
