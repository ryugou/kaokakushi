import Foundation
import GRDB
import Domain
@testable import Persistence

// ExportSagaStoreStartTests / ExportSagaStoreOutputTests / ExportSagaStoreRecoveryTests が
// 共有するヘルパー群。makeTestAppDatabase()・pendingFileDeletionExists（両方
// WorkingSourceStoreTestSupport.swift）・insertProject/insertBatch/insertExportJob/
// insertOutputRecord（SchemaTestSupport.swift）・makeRenderSpecFixture()
// （WorkingSourceStoreTestSupport.swift）・makeStampTestDirectories()
// （StampStoreTestSupport.swift）はそのまま再利用し、ここでは重複定義しない。

/// ExportSagaStoreLiveをテスト用に組み立てる。ExportSagaStoreLiveはファイル実体に一切
/// 触れない実装（出力ファイルの実削除はPendingFileDeletion経由の別タスクの担当）のため、
/// ManagedFileStoreへの依存自体を持たない。enabledStampPacks/hardMaxTrialCredits/
/// monthlyLimitはデフォルト値のままで足りるテストが大半のため引数のデフォルトを
/// コンストラクタと同じ値に揃える（差し戻し対応1番・3番）。deviceTimeZoneはUTC固定
/// （schemaTestReferenceDateがUTCで2023-11-14であることを前提にしたテストと一致させる）。
func makeExportSagaStore(
    database: AppDatabase,
    now: @escaping @Sendable () -> Date = { schemaTestReferenceDate },
    deviceTimeZone: @escaping @Sendable () -> TimeZone = { TimeZone(identifier: "UTC")! },
    enabledStampPacks: Set<String> = [],
    hardMaxTrialCredits: Int = 5,
    monthlyLimit: Int = 5
) -> ExportSagaStoreLive {
    ExportSagaStoreLive(
        database: database,
        now: now,
        deviceTimeZone: deviceTimeZone,
        limits: ExportSagaStoreLimits(
            enabledStampPacks: enabledStampPacks, hardMaxTrialCredits: hardMaxTrialCredits, monthlyLimit: monthlyLimit
        )
    )
}

/// kind = .output の OutputFileRef を組み立てる。kind を固定しているため
/// OutputFileRef.init(_:) は必ず成功する（makeWorkingSourceFileRefと同じ理由）。
func makeOutputFileRefFixture(fileID: UUID = UUID()) -> OutputFileRef {
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: fileID))
    guard let outputRef = OutputFileRef(ref) else {
        fatalError("test setup invariant violated: kind must be .output")
    }
    return outputRef
}

/// StartExportInputのフィクスチャビルダー。previewConfirmation.projectIDはデフォルトで
/// input.projectIDと一致させる（startExportがpreviewConfirmationProjectMismatchを検査
/// するようになったため。差し戻し対応7番）。意図的な不一致を検証するテストのために
/// previewConfirmationProjectIDだけ差し替えられるようにする。
func makeStartExportInputFixture(
    projectID: ProjectID,
    batchID: BatchID? = nil,
    queueItemID: ExportQueueItemID? = nil,
    outputFormat: ImageFormat = .jpeg,
    previewConfirmationProjectID: ProjectID? = nil
) throws -> StartExportInput {
    let exportSetting = ExportSetting(
        outputAspect: .square,
        outputFormat: outputFormat,
        compressionQuality: 0.9,
        metadataPolicy: MetadataPolicy(
            removeLocation: true, removeDeviceInfo: true, removeSoftwareInfo: true, keepCaptureDate: false
        )
    )
    let previewConfirmation = PreviewConfirmation(
        projectID: previewConfirmationProjectID ?? projectID,
        detectionRevision: 1,
        previewRenderHash: try PreviewRenderHash(bytes: Data(repeating: 0x01, count: 32))
    )
    return StartExportInput(
        projectID: projectID,
        batchID: batchID,
        queueItemID: queueItemID,
        renderSpec: try makeRenderSpecFixture(),
        exportSetting: exportSetting,
        previewConfirmation: previewConfirmation
    )
}

/// SubscriptionStateの唯一行を挿入する。lastVerifiedAt/willRenew/fetchedAtは
/// startExportの評価に影響しないためschemaTestReferenceDate固定でよい（expiresAtは失効判定に
/// 影響するため引数で指定できる。既定nil = 無期限）。
func insertSubscriptionStateRow(
    _ connection: Database, plan: Int, status: Int, isSandbox: Bool = false, expiresAt: Date? = nil
) throws {
    try connection.execute(
        sql: """
        INSERT INTO SubscriptionState (plan, status, expiresAt, lastVerifiedAt, isSandbox, willRenew, fetchedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [plan, status, expiresAt, schemaTestReferenceDate, isSandbox, true, schemaTestReferenceDate]
    )
}

/// Batch行をkindを指定して挿入する。SchemaTestSupport.insertBatchはkind固定(1=proBatch)の
/// ため、trial(2)を打ち分けるこのテストでは使えない。
func insertBatchRow(_ connection: Database, batchID: UUID, kind: Int, trialCreditCount: Int32 = 5) throws {
    try connection.execute(
        sql: """
        INSERT INTO Batch (batchID, kind, batchSizeLimit, trialCreditCount, concurrencyLimit)
        VALUES (?, ?, ?, ?, ?)
        """,
        arguments: [batchID, kind, 50, trialCreditCount, 1]
    )
}

/// UsageLedgerの唯一行を挿入する。trialConsumedExportIDsはExportSagaStoreLive+Accounting.
/// swiftが確定したBLOB形式（ExportID = UUIDの16バイト表現の連結）に合わせる。
/// splitIntoUniqueChunksは16バイトチャンクの重複をfail-closedでcorruptUsageLedgerBlobと
/// して検出する契約のため、ここで生成するBLOBもtrialConsumedCount個の内容が異なる
/// チャンクにする必要がある（ゼロ埋め等で同一チャンクを繰り返すと、重複検出ロジックと
/// 自己矛盾し意図せず例外で落ちる。差し戻し対応）。UUIDは乱数由来のため衝突を実質的に
/// 無視できる。
func insertUsageLedgerRow(_ connection: Database, trialConsumedCount: Int) throws {
    var blob = Data()
    for _ in 0..<trialConsumedCount {
        blob.append(withUnsafeBytes(of: UUID().uuid) { Data($0) })
    }
    try connection.execute(
        sql: """
        INSERT INTO UsageLedger (periodYear, periodMonth, consumedExportIDs, trialConsumedExportIDs)
        VALUES (?, ?, ?, ?)
        """,
        arguments: [2023, 11, Data(), blob]
    )
}

/// Project行とSubscriptionState行を挿入する（recordGeneratedOutput/discardExport/
/// loadRunningJobs/deleteRunningJobsのテストが前提とする「startExportを呼べる状態」を
/// 用意する）。projectRevisionは常に0（insertProjectの固定値）。
func seedAuthorizedProject(_ database: AppDatabase, projectID: ProjectID, plan: Int = 2, status: Int = 1) async throws {
    try await database.dbQueue.write { connection in
        try insertProject(connection, projectID: projectID.rawValue)
        // SubscriptionState は単一行（複数行は multipleSingletonRows で fail-closed）。
        // 複数プロジェクトを seed するテストで二重挿入しないよう、既存行があれば挿入しない。
        let existing = try Int.fetchOne(connection, sql: "SELECT count(*) FROM SubscriptionState") ?? 0
        if existing == 0 {
            try insertSubscriptionStateRow(connection, plan: plan, status: status)
        }
    }
}

/// startExportを呼び、authorizedになる前提でExportJobを取り出す。accountingMode /
/// deliveryFormatのraw value割当をテスト側で重複して知る必要をなくすため、raw SQLでの
/// 直接INSERTではなくstartExport経由でExportJob行を作る（seedAuthorizedProjectと組み合わせて
/// 使う。同一projectIDに対して複数回呼んでも良い——1章はApplication層が「対象Project編集
/// 禁止」を運用するだけで、Persistence層は複数ExportJobの併存をDBレベルでは禁止しない）。
func authorizeExportJob(
    store: ExportSagaStoreLive, projectID: ProjectID, batchID: BatchID? = nil
) async throws -> ExportJob {
    let decision = try await store.startExport(
        try makeStartExportInputFixture(projectID: projectID, batchID: batchID), expectedProjectRevision: 0
    )
    guard case let .authorized(job) = decision else {
        fatalError("test setup invariant violated: startExport should authorize a freshly seeded project")
    }
    return job
}

func exportJobExists(_ database: AppDatabase, exportID: UUID) throws -> Bool {
    try database.dbQueue.read { connection in
        let count = try Int.fetchOne(
            connection, sql: "SELECT count(*) FROM ExportJob WHERE exportID = ?", arguments: [exportID]
        ) ?? 0
        return count > 0
    }
}

func outputRecordRowCount(_ database: AppDatabase, exportID: UUID) throws -> Int {
    try database.dbQueue.read { connection in
        try Int.fetchOne(
            connection, sql: "SELECT count(*) FROM OutputRecord WHERE exportID = ?", arguments: [exportID]
        ) ?? -1
    }
}

// テストフィクスチャの束（読み出し列ひとそろい）。
// swiftlint:disable large_tuple
func outputRecordFields(
    _ database: AppDatabase, exportID: UUID
) throws -> (state: Int, generatedAt: Date, settledAt: Date?, format: Int, outputFileID: UUID)? {
    // swiftlint:enable large_tuple
    try database.dbQueue.read { connection in
        guard let row = try Row.fetchOne(
            connection,
            sql: "SELECT state, generatedAt, settledAt, format, outputFileID FROM OutputRecord WHERE exportID = ?",
            arguments: [exportID]
        ) else {
            return nil
        }
        return (row["state"], row["generatedAt"], row["settledAt"], row["format"], row["outputFileID"])
    }
}
