import GRDB

// app.db のスキーマ v1（architecture.md 7.1「app.db」のテーブル一覧・一意制約表・
// 外部キー表が正本。この3つに無い制約は作らず、この3つにある制約は1つも欠かさ
// ない）。
//
// マイグレーションは `registerMigration("v1")` 1件のみで全20テーブルを作成する。
// GRDBの DatabaseMigrator は各 registerMigration をトランザクションで包み、
// 途中で throw すればロールバックして呼び出し元へエラーを伝播する（GRDB本体の
// 契約）。これにより test-plan.md 4.2「スキーマ移行が単一トランザクションで確定し、
// 途中適用が観測されないこと」を、追加の仕組み無しで満たす。
// `eraseDatabaseOnSchemaChange` 等、既定を変える設定は追加しない。
//
// 1ファイル400行制限のため、テーブル定義はテーブル群ごとに
// `Schema+Project.swift` / `Schema+Stamp.swift` / `Schema+Queue.swift` /
// `Schema+Accounting.swift` / `Schema+Delivery.swift` へ分割し、この関数から
// 依存関係の順（親テーブルを先に作る）で呼び出す。呼び出し順序:
//   1. Project 系（Project → FaceTrack → EffectSetting → ExportSetting →
//      WorkingSourceRecord）
//   2. Stamp 系（StampAsset → CustomStamp → ProjectStampAsset。
//      ProjectStampAssetはProjectも参照するため1の後に置く）
//   3. Queue 系（Batch → BatchPreset → ExportQueueItem。ExportQueueItemは
//      ProjectとBatchの両方を参照するため1・このファイル内のBatch作成の後）
//   4. Accounting 系（ExportJob / OutputRecord / ExportRecord / UsageLedger /
//      ExportedSettingsEntry。いずれもProject・Batchを参照するため1・3の後）
//   5. Delivery 系（DeliveryAttempt / UnknownLibrarySave はOutputRecordを
//      参照するため4の後。PendingFileDeletion / SubscriptionStateはFK無し）
public enum AppSchema {
    /// v1スキーマを適用する DatabaseMigrator を組み立てる。
    /// 呼び出し側（AppDatabase.open(at:)）が `migrate(_ writer:)` を呼ぶ。
    public static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // リリース前は v1 マイグレーションを直接変更する（適用済み開発DBは作り直す）。
        // リリース後は v2 以降の追加のみ（オーケストレーター確定判断。Issue #6 Task 5後半）。

        migrator.registerMigration("v1") { database in
            try createProjectTables(database)
            try createStampTables(database)
            try createQueueTables(database)
            try createAccountingTables(database)
            try createDeliveryTables(database)
        }

        return migrator
    }
}
