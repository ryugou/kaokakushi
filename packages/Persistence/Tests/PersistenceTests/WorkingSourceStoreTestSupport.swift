import Foundation
import GRDB
import Domain
@testable import Persistence

// WorkingSourceStoreTests / MaintenanceStoreTests が共有するヘルパー群。
//
// SchemaTestSupport.swift（挿入ヘルパー・schemaTestReferenceDate・isForeignKeyViolation）は
// そのまま再利用し、ここでは重複定義しない。ここに置くのは (1) AppDatabase.open(at:)を
// 経由した一時ファイルDBの用意、(2) DomainのStore入力型のフィクスチャ構築、
// (3) Store実装の内部状態を検証するための読み取りヘルパーのみ。

/// テストごとに衝突しない一時ファイルDBを用意する。in-memoryは使わない
/// （AppDatabaseTests.makeTemporaryDatabaseURLと同じ理由。journal_modeの検証が
/// in-memoryでは意味を成さないため）。呼び出し側はdeferでurlを削除すること。
func makeTestAppDatabase() throws -> (database: AppDatabase, url: URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersistenceStoreTests-\(UUID().uuidString).sqlite")
    let database = try AppDatabase.open(at: url)
    return (database, url)
}

/// kind = .processingTemporary の WorkingSourceFileRef を組み立てる。
/// kindを固定しているため WorkingSourceFileRef.init(_:) は必ず成功する。
func makeWorkingSourceFileRef(fileID: UUID = UUID()) -> WorkingSourceFileRef {
    let ref = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: fileID))
    guard let workingSourceFileRef = WorkingSourceFileRef(ref) else {
        fatalError("test setup invariant violated: kind must be .processingTemporary")
    }
    return workingSourceFileRef
}

/// EXIF由来の撮影メタデータのフィクスチャ。裸のDate()は使わずschemaTestReferenceDateから
/// 算出したutcMillisを使う。
func makeCaptureMetadata(utcMillis: Int64 = 1_700_000_000_123) -> OriginalCaptureMetadata {
    OriginalCaptureMetadata(
        dateTimeOriginal: "2023:11:14 22:13:20",
        subSecTimeOriginal: "123",
        offsetTimeOriginal: "+09:00",
        utcMillis: utcMillis
    )
}

/// 全面crop・fit・背景なし・領域なしの最小RenderSpec（CreateWorkingSourceInput.initialSpec用。
/// このTaskの永続化対象ではないため中身に意味は無い）。
func makeRenderSpecFixture() throws -> RenderSpec {
    let rect = try NormalizedRect(left: 0, top: 0, rightExclusive: 1, bottomExclusive: 1)
    return RenderSpec(sourceCrop: rect, scaleMode: .fit, background: .none, regions: [])
}

/// CreateWorkingSourceInputのフィクスチャビルダー。テストごとに変えたいフィールドだけ
/// 上書きする。
func makeCreateWorkingSourceInput(
    projectID: ProjectID = ProjectID(rawValue: UUID()),
    batchID: BatchID? = nil,
    queueItemID: ExportQueueItemID? = nil,
    sourceFile: WorkingSourceFileRef = makeWorkingSourceFileRef(),
    createdAt: Date = schemaTestReferenceDate,
    representation: SourceRepresentation = .original
) throws -> CreateWorkingSourceInput {
    CreateWorkingSourceInput(
        projectID: projectID,
        batchID: batchID,
        queueItemID: queueItemID,
        sourceFile: sourceFile,
        createdAt: createdAt,
        sourceLocator: ProjectSourceLocator(photoLibraryLocalIdentifier: "asset-identifier"),
        capture: makeCaptureMetadata(),
        libraryCreationDate: createdAt,
        representation: representation,
        initialSpec: try makeRenderSpecFixture()
    )
}

/// ExportQueueItemを任意のstate raw valueで挿入する。SchemaTestSupport.insertExportQueueItem
/// はstateを固定値(0)にしているため、terminal/non-terminalを打ち分けるこのテストでは
/// 使えない。新しいテーブルを作らず既存テーブルへ挿入するだけの薄いヘルパー。
func insertExportQueueItemWithState(
    _ connection: Database,
    queueItemID: UUID,
    projectID: UUID,
    batchID: UUID,
    state: Int,
    pauseReason: Int? = nil
) throws {
    try connection.execute(
        sql: """
        INSERT INTO ExportQueueItem (
            queueItemID, projectID, batchID, state, failureErrorCode,
            failureIsRetryable, failureOccurredAt, pauseReason
        ) VALUES (?, ?, ?, ?, NULL, NULL, NULL, ?)
        """,
        arguments: [queueItemID, projectID, batchID, state, pauseReason]
    )
}

func projectRevisions(
    _ database: AppDatabase,
    projectID: UUID
) throws -> (projectRevision: Int, detectionRevision: Int)? {
    try database.dbQueue.read { connection in
        guard let row = try Row.fetchOne(
            connection,
            sql: "SELECT projectRevision, detectionRevision FROM Project WHERE projectID = ?",
            arguments: [projectID]
        ) else {
            return nil
        }
        return (row["projectRevision"], row["detectionRevision"])
    }
}

func workingSourceRecordFields(
    _ database: AppDatabase,
    projectID: UUID
) throws -> (sourceFileID: UUID, createdAt: Date)? {
    try database.dbQueue.read { connection in
        guard let row = try Row.fetchOne(
            connection,
            sql: "SELECT sourceFileID, createdAt FROM WorkingSourceRecord WHERE projectID = ?",
            arguments: [projectID]
        ) else {
            return nil
        }
        return (row["sourceFileID"], row["createdAt"])
    }
}

func exportQueueItemStateAndPauseReason(
    _ database: AppDatabase,
    queueItemID: UUID
) throws -> (state: Int, pauseReason: Int?)? {
    try database.dbQueue.read { connection in
        guard let row = try Row.fetchOne(
            connection,
            sql: "SELECT state, pauseReason FROM ExportQueueItem WHERE queueItemID = ?",
            arguments: [queueItemID]
        ) else {
            return nil
        }
        return (row["state"], row["pauseReason"])
    }
}

func pendingFileDeletionExists(_ database: AppDatabase, kind: UInt32, fileID: UUID) throws -> Bool {
    try database.dbQueue.read { connection in
        let count = try Int.fetchOne(
            connection,
            sql: "SELECT count(*) FROM PendingFileDeletion WHERE kind = ? AND fileID = ?",
            arguments: [kind, fileID]
        ) ?? 0
        return count > 0
    }
}

/// kind別のPendingFileDeletion行数。個々のfileIDまでは分からない重複import等の
/// テストで、import前後の件数差分から「1件増えたこと」を確認するために使う
/// （pendingFileDeletionExistsと同じSQLパターン。fileID条件が無い点だけが違う）。
func pendingFileDeletionCount(_ database: AppDatabase, kind: UInt32) throws -> Int {
    try database.dbQueue.read { connection in
        try Int.fetchOne(
            connection,
            sql: "SELECT count(*) FROM PendingFileDeletion WHERE kind = ?",
            arguments: [kind]
        ) ?? 0
    }
}

/// kind別のPendingFileDeletion行のfileID（該当kindの行が複数あるときの挙動はSQLの
/// `LIMIT 1`に委ねる未定義動作。呼び出し側のテストは対象kindのPendingFileDeletion行が
/// この1件のみである前提でしか使わないこと）。
func pendingFileDeletionFileID(_ database: AppDatabase, kind: UInt32) throws -> UUID? {
    try database.dbQueue.read { connection in
        try UUID.fetchOne(
            connection,
            sql: "SELECT fileID FROM PendingFileDeletion WHERE kind = ? LIMIT 1",
            arguments: [kind]
        )
    }
}

func faceTrackRowCount(_ database: AppDatabase, projectID: UUID) throws -> Int {
    try database.dbQueue.read { connection in try countFaceTrackRows(connection, projectID: projectID) }
}

func effectSettingRowCount(_ database: AppDatabase, projectID: UUID) throws -> Int {
    try database.dbQueue.read { connection in try countEffectSettingRows(connection, projectID: projectID) }
}

/// PendingFileDeletion行を直接挿入する（MaintenanceStoreTestsのフィクスチャ用。
/// SchemaTestSupport.swiftに同等のヘルパーが無いため、生SQLで1行挿入するだけの
/// 最小ヘルパーとしてここに置く）。
func insertPendingFileDeletion(_ connection: Database, kind: UInt32, fileID: UUID) throws {
    try connection.execute(
        sql: "INSERT INTO PendingFileDeletion (kind, fileID) VALUES (?, ?)",
        arguments: [kind, fileID]
    )
}

func projectRowExists(_ database: AppDatabase, projectID: UUID) throws -> Bool {
    try database.dbQueue.read { connection in
        let count = try Int.fetchOne(
            connection, sql: "SELECT count(*) FROM Project WHERE projectID = ?", arguments: [projectID]
        ) ?? 0
        return count > 0
    }
}
