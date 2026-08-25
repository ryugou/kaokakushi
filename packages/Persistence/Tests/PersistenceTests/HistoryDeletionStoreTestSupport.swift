import Foundation
import GRDB
import Domain
@testable import Persistence

// HistoryDeletionStoreInspectTests / HistoryDeletionStoreDeleteTests /
// HistoryDeletionStoreStampReleaseTests / HistoryDeletionStoreBatchCleanupTests /
// HistoryDeletionStoreOverrideTestsが共有するヘルパー群。makeTestAppDatabase()
// （WorkingSourceStoreTestSupport.swift）・insertProject/insertBatch/insertFaceTrack/
// insertEffectSetting/insertExportSetting/insertWorkingSourceRecord/
// insertExportRecord/insertExportJob/insertOutputRecord/insertStampAsset/insertCustomStamp/
// insertProjectStampAsset/insertExportedSettingsEntry/countXxxRows（SchemaTestSupport.swift）・
// pendingFileDeletionExists/projectRowExists
// （WorkingSourceStoreTestSupport.swift）・outputRecordFields/outputRecordRowCount
// （ExportSagaStoreTestSupport.swift）・insertDeliveryOutputRecord
// （OutputDeliveryStoreTestSupport.swift）・stampAssetFileID（StampStoreTestSupport.swift）は
// そのまま再利用し、ここでは重複定義しない。

/// HistoryDeletionStoreLiveをテスト用に組み立てる。
func makeHistoryDeletionStore(database: AppDatabase) -> HistoryDeletionStoreLive {
    HistoryDeletionStoreLive(database: database)
}

// CASCADE連鎖の検証用に、Projectへ連鎖する7テーブルの行数をまとめて読む
// （cascade検証テストが1テーブルずつ読むと冗長になるため。SchemaTestSupport.swiftの
// countXxxRowsを束ねるだけで、新しいSQLは書かない）。
// swiftlint:disable large_tuple
func cascadeRowCounts(
    _ database: AppDatabase, projectID: UUID
) throws -> (
    faceTrack: Int, effectSetting: Int, exportSetting: Int, workingSourceRecord: Int,
    exportRecord: Int, exportedSettingsEntry: Int, projectStampAsset: Int
) {
    // swiftlint:enable large_tuple
    try database.dbQueue.read { connection in
        (
            faceTrack: try countFaceTrackRows(connection, projectID: projectID),
            effectSetting: try countEffectSettingRows(connection, projectID: projectID),
            exportSetting: try countExportSettingRows(connection, projectID: projectID),
            workingSourceRecord: try countWorkingSourceRecordRows(connection, projectID: projectID),
            exportRecord: try countExportRecordRows(connection, projectID: projectID),
            exportedSettingsEntry: try countExportedSettingsEntryRows(connection, projectID: projectID),
            projectStampAsset: try countProjectStampAssetRows(connection, projectID: projectID)
        )
    }
}

/// 対象batchIDのBatch行が存在するか。
func batchRowExists(_ database: AppDatabase, batchID: UUID) throws -> Bool {
    try database.dbQueue.read { connection in
        let count = try Int.fetchOne(
            connection, sql: "SELECT count(*) FROM Batch WHERE batchID = ?", arguments: [batchID]
        ) ?? 0
        return count > 0
    }
}

/// Projectへ連鎖する7テーブル全て（FaceTrack/EffectSetting/ExportSetting/
/// WorkingSourceRecord/ExportRecord/ExportedSettingsEntry/ProjectStampAsset）へ1行ずつ、
/// CASCADE検証に必要な最小構成で行を挿入する（deletesProjectAndCascadesAllDependentsが
/// 50行のテスト関数制限に収まるよう、セットアップを1箇所へまとめる。挿入する値の中身
/// 自体はテストの関心事ではない）。BatchはExportRecordから参照される形で引き続き必要
/// なため挿入する。
func seedProjectWithCascadingDependents(
    _ database: AppDatabase, projectID: UUID, batchID: UUID, sourceFileID: UUID, assetHash: Data
) async throws {
    try await database.dbQueue.write { connection in
        try insertProject(connection, projectID: projectID)
        let faceTrackID = UUID()
        try insertFaceTrack(connection, faceTrackID: faceTrackID, projectID: projectID)
        try insertEffectSetting(connection, faceTrackID: faceTrackID, projectID: projectID)
        try insertExportSetting(connection, projectID: projectID)
        try insertWorkingSourceRecord(connection, projectID: projectID, sourceFileID: sourceFileID)
        try insertBatch(connection, batchID: batchID)
        try insertExportRecord(connection, exportID: UUID(), projectID: projectID, batchID: batchID)
        try insertExportedSettingsEntry(connection, projectID: projectID)
        try insertStampAsset(connection, contentHash: assetHash, fileID: UUID())
        try insertProjectStampAsset(connection, projectID: projectID, assetHash: assetHash)
    }
}
