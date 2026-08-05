import GRDB

// Queue 系テーブル（architecture.md 7.1 / 6.4）。Batch → BatchPreset →
// ExportQueueItem の順で作成する（ExportQueueItemがBatchとProjectの両方を
// 参照するため）。

/// `Batch`・`BatchPreset`・`ExportQueueItem` を作成する。
/// この関数の呼び出し時点で `Project` テーブルが既に存在している必要がある
/// （ExportQueueItem.projectID のFKが参照するため。Schema.swiftの呼び出し順を参照）。
func createQueueTables(_ database: Database) throws {
    try database.create(table: "Batch") { tableDef in
        tableDef.primaryKey("batchID", .blob)
        // BatchKind.rawValue（proBatch=1, trial=2）。
        tableDef.column("kind", .integer).notNull()
        tableDef.column("batchSizeLimit", .integer).notNull()
        tableDef.column("trialCreditCount", .integer).notNull()
        tableDef.column("concurrencyLimit", .integer).notNull()
    }

    try database.create(table: "BatchPreset") { tableDef in
        tableDef.primaryKey("batchPresetID", .blob)
        tableDef.column("name", .text).notNull()
        // architecture.md 7.1にはテーブル名以外の仕様が無く（「一括設定プリセット」
        // とだけ記載）、名前と内容の入れ物だけを用意する最小構成。列の詳細は
        // BatchPresetを読み書きする将来タスクの担当。
        tableDef.column("policySnapshotData", .blob).notNull()
    }

    try database.create(table: "ExportQueueItem") { tableDef in
        tableDef.primaryKey("queueItemID", .blob)
        tableDef.column("projectID", .blob).notNull().references("Project", onDelete: .cascade)
        tableDef.column("batchID", .blob).notNull().references("Batch", onDelete: .cascade)
        // ExportQueueStateの判別子。raw valueの割当はStore実装タスクの担当。
        tableDef.column("state", .integer).notNull()
        // ExportQueueFailure.errorCode。stateがfailedの時のみ使う想定。
        tableDef.column("failureErrorCode", .integer)
        tableDef.column("failureIsRetryable", .boolean)
        tableDef.column("failureOccurredAt", .datetime)
        // QueuePauseReasonの判別子。stateがpausedの時のみ使う想定。
        tableDef.column("pauseReason", .integer)
        tableDef.uniqueKey(["batchID", "projectID"])
    }
}
