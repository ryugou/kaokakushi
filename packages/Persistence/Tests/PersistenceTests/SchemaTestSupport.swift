import Foundation
import GRDB
@testable import Persistence

// SchemaTests / SchemaConstraintTests が共有する挿入ヘルパー群。
//
// Schema.swiftはDomainをimportせず生のGRDB列で定義されているため（Task 3以降が
// DatabaseValueConvertible適合を担当）、テスト側もRecordを介さず生SQLで最小限の
// 有効行を1件挿入するヘルパーとして実装する。時刻は裸のDate()を使わず、この
// ファイルの固定値（schemaTestReferenceDate）またはパラメータ経由の値のみを使う。

/// テスト全体で使う固定の基準時刻（2023-11-14T22:13:20Z）。裸のDate()を禁止する
/// 規約（docs/superpowers/plans/2026-08-02-persistence-adapter.md Global
/// Constraints）に従い、時刻はテストコードのどこでも明示的な値を使う。
let schemaTestReferenceDate = Date(timeIntervalSince1970: 1_700_000_000)

/// 32バイトのダミーハッシュ（StampAsset.contentHash / CustomStamp.assetHash /
/// ProjectStampAsset.assetHash / ExportedSettingsEntry.settingsHash 用）。
/// 引数のseedだけを変えて異なる値を作れるようにする。
func schemaTestHash(seed: UInt8) -> Data {
    Data(repeating: seed, count: 32)
}

func insertProject(_ database: Database, projectID: UUID) throws {
    try database.execute(
        sql: """
        INSERT INTO Project (
            projectID, projectRevision, detectionRevision, detectionPixelSizeWidth,
            detectionPixelSizeHeight, photoLibraryLocalIdentifier, captureDateTimeOriginal,
            captureSubSecTimeOriginal, captureOffsetTimeOriginal, captureUtcMillis,
            libraryCreationDate, sourceRepresentation
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [projectID, 0, 0, 0, 0, nil, nil, nil, nil, nil, nil, 0]
    )
}

func insertBatch(_ database: Database, batchID: UUID) throws {
    try database.execute(
        sql: """
        INSERT INTO Batch (batchID, kind, batchSizeLimit, trialCreditCount, concurrencyLimit)
        VALUES (?, ?, ?, ?, ?)
        """,
        arguments: [batchID, 1, 10, 0, 1]
    )
}

func insertFaceTrack(_ database: Database, faceTrackID: UUID, projectID: UUID) throws {
    try database.execute(
        sql: """
        INSERT INTO FaceTrack (
            faceTrackID, projectID, createdManually, boundsLeft, boundsTop,
            boundsRightExclusive, boundsBottomExclusive, confidence, yawDegrees,
            pitchDegrees, rollDegrees, isSmallFace
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [faceTrackID, projectID, false, 0.0, 0.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, false]
    )
}

func insertEffectSetting(_ database: Database, faceTrackID: UUID, projectID: UUID) throws {
    try database.execute(
        sql: "INSERT INTO EffectSetting (faceTrackID, projectID, effectSpecData) VALUES (?, ?, ?)",
        arguments: [faceTrackID, projectID, Data([0x01])]
    )
}

func insertExportSetting(_ database: Database, projectID: UUID) throws {
    try database.execute(
        sql: """
        INSERT INTO ExportSetting (
            projectID, outputAspect, outputFormat, compressionQuality,
            removeLocation, removeDeviceInfo, removeSoftwareInfo, keepCaptureDate
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [projectID, 0, 0, 0.9, true, true, true, false]
    )
}

func insertWorkingSourceRecord(_ database: Database, projectID: UUID, sourceFileID: UUID) throws {
    try database.execute(
        sql: "INSERT INTO WorkingSourceRecord (projectID, sourceFileID, createdAt) VALUES (?, ?, ?)",
        arguments: [projectID, sourceFileID, schemaTestReferenceDate]
    )
}

func insertExportQueueItem(
    _ database: Database,
    queueItemID: UUID,
    projectID: UUID,
    batchID: UUID
) throws {
    try database.execute(
        sql: """
        INSERT INTO ExportQueueItem (
            queueItemID, projectID, batchID, state, failureErrorCode,
            failureIsRetryable, failureOccurredAt, pauseReason
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [queueItemID, projectID, batchID, 0, nil, nil, nil, nil]
    )
}

func insertExportRecord(_ database: Database, exportID: UUID, projectID: UUID, batchID: UUID?) throws {
    try database.execute(
        sql: """
        INSERT INTO ExportRecord (
            exportID, projectID, batchID, exportedAt, accountingMode, format, outputByteSize
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [exportID, projectID, batchID, schemaTestReferenceDate, 0, 0, 1_024]
    )
}

func insertExportJob(_ database: Database, exportID: UUID, projectID: UUID, batchID: UUID?) throws {
    try database.execute(
        sql: """
        INSERT INTO ExportJob (
            exportID, projectID, batchID, queueItemID, authorizedAt, accountingMode,
            entitlementPlan, entitlementStatus, entitlementExpiresAt,
            entitlementLastVerifiedAt, entitlementIsSandbox, deliveryFormat,
            deliverySuggestedCreationDate
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
            exportID, projectID, batchID, nil, schemaTestReferenceDate, 0,
            1, 1, nil, schemaTestReferenceDate, false, 0, nil
        ]
    )
}

func insertOutputRecord(
    _ database: Database,
    exportID: UUID,
    projectID: UUID,
    batchID: UUID?,
    settledAt: Date?
) throws {
    try database.execute(
        sql: """
        INSERT INTO OutputRecord (
            exportID, projectID, batchID, outputFileID, outputByteSize, outputSHA256,
            state, generatedAt, settledAt, expiresAt, format, suggestedCreationDate
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
            exportID, projectID, batchID, UUID(), 2_048, schemaTestHash(seed: 0xAB),
            1, schemaTestReferenceDate, settledAt, nil, 0, nil
        ]
    )
}

func insertStampAsset(_ database: Database, contentHash: Data, fileID: UUID) throws {
    try database.execute(
        sql: "INSERT INTO StampAsset (contentHash, fileID) VALUES (?, ?)",
        arguments: [contentHash, fileID]
    )
}

func insertCustomStamp(_ database: Database, customStampID: UUID, assetHash: Data) throws {
    try database.execute(
        sql: """
        INSERT INTO CustomStamp (customStampID, assetHash, name, sortOrder, thumbnailFileID)
        VALUES (?, ?, ?, ?, ?)
        """,
        arguments: [customStampID, assetHash, "スタンプ", 0, UUID()]
    )
}

func insertProjectStampAsset(_ database: Database, projectID: UUID, assetHash: Data) throws {
    try database.execute(
        sql: "INSERT INTO ProjectStampAsset (projectID, assetHash) VALUES (?, ?)",
        arguments: [projectID, assetHash]
    )
}

func insertExportedSettingsEntry(_ database: Database, projectID: UUID) throws {
    try database.execute(
        sql: """
        INSERT INTO ExportedSettingsEntry (projectID, settingsHash, exportedAt)
        VALUES (?, ?, ?)
        """,
        arguments: [projectID, schemaTestHash(seed: 0xCD), schemaTestReferenceDate]
    )
}

/// CASCADE連鎖テスト専用の行数カウント群（cascadeChainDeletesDependentRows）。
/// テーブル名をSQLへ動的に埋め込む共通ヘルパーにはせず、1テーブル1関数へ固定する
/// （文字列連結でテーブル名を組み立てる経路自体を作らない）。
func countFaceTrackRows(_ database: Database, projectID: UUID) throws -> Int {
    try Int.fetchOne(
        database, sql: "SELECT count(*) FROM FaceTrack WHERE projectID = ?", arguments: [projectID]
    ) ?? -1
}

func countEffectSettingRows(_ database: Database, projectID: UUID) throws -> Int {
    try Int.fetchOne(
        database, sql: "SELECT count(*) FROM EffectSetting WHERE projectID = ?", arguments: [projectID]
    ) ?? -1
}

func countExportSettingRows(_ database: Database, projectID: UUID) throws -> Int {
    try Int.fetchOne(
        database, sql: "SELECT count(*) FROM ExportSetting WHERE projectID = ?", arguments: [projectID]
    ) ?? -1
}

func countWorkingSourceRecordRows(_ database: Database, projectID: UUID) throws -> Int {
    try Int.fetchOne(
        database,
        sql: "SELECT count(*) FROM WorkingSourceRecord WHERE projectID = ?",
        arguments: [projectID]
    ) ?? -1
}

func countExportQueueItemRows(_ database: Database, projectID: UUID) throws -> Int {
    try Int.fetchOne(
        database,
        sql: "SELECT count(*) FROM ExportQueueItem WHERE projectID = ?",
        arguments: [projectID]
    ) ?? -1
}

func countExportRecordRows(_ database: Database, projectID: UUID) throws -> Int {
    try Int.fetchOne(
        database, sql: "SELECT count(*) FROM ExportRecord WHERE projectID = ?", arguments: [projectID]
    ) ?? -1
}

func countExportedSettingsEntryRows(_ database: Database, projectID: UUID) throws -> Int {
    try Int.fetchOne(
        database,
        sql: "SELECT count(*) FROM ExportedSettingsEntry WHERE projectID = ?",
        arguments: [projectID]
    ) ?? -1
}

func countProjectStampAssetRows(_ database: Database, projectID: UUID) throws -> Int {
    try Int.fetchOne(
        database,
        sql: "SELECT count(*) FROM ProjectStampAsset WHERE projectID = ?",
        arguments: [projectID]
    ) ?? -1
}

/// GRDB は既定で primary result code（19 = SQLITE_CONSTRAINT）で報告するため、
/// 拡張コードではなく primary code とメッセージで外部キー制約違反を判定する。
func isForeignKeyViolation(_ error: Error) -> Bool {
    guard let databaseError = error as? DatabaseError else { return false }
    return databaseError.resultCode == .SQLITE_CONSTRAINT
        && (databaseError.message ?? "").contains("FOREIGN KEY")
}
