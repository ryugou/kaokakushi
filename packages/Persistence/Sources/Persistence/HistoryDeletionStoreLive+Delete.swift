import Foundation
import Domain
import GRDB

// deleteHistoryUnit（architecture.md「Project削除Saga」・「削除の可否判定」・
// 「出力の削除経路」が正本。単一のdbQueue.writeトランザクションで完結させる）。
//
// 手順（正本「Project削除Saga」表 + オーケストレーター確定判断の事前読み取り順序）:
//   1. 削除可否判定（HistoryDeletionStoreLive+Context.swiftのevaluateDeletion）。拒否なら
//      throwして終了（DBは一切変更しない）。
//   2. CASCADE連鎖で消える前に、後続処理に必要な値を事前に読み取る。
//      (a) OutputRecord.outputFileID一覧 (b) WorkingSourceRecord.sourceFileID
//      (c) ProjectStampAsset.assetHash一覧 (d) ExportQueueItemのDISTINCT batchID一覧
//   3. OutputRecordを明示DELETEしoutputFileIDをPendingFileDeletionへ登録する
//      （OutputRecord.projectIDはonDelete: .restrictのため、残存行があるとProject本体の
//      DELETEがFK違反で失敗する。よって事前削除が必須）。
//   4. WorkingSourceRecord.sourceFileIDをPendingFileDeletionへ登録する（行自体はCASCADEに
//      任せ、明示DELETEはしない）。
//   5. Project本体をDELETEする。CASCADEでFaceTrack→EffectSetting、ExportSetting、
//      WorkingSourceRecord、ExportQueueItem、ExportRecord、ExportedSettingsEntry、
//      ProjectStampAssetが連鎖削除される。万一ExportJob/OutputRecordの残存行があれば
//      RESTRICT違反がthrowされ、トランザクション全体がロールバックされる（判定漏れへの
//      二重防御。正本どおりcatchして握りつぶさず伝播させる）。
//   6. cで読み取ったassetHashごとにProjectStampAssetの参照解放を行う
//      （StampAssetReferences.swift。StampStoreと共有する）。
//   7. dで読み取ったbatchIDごとに、ExportQueueItemの残存行が0件ならBatch行を削除する
//      （architecture.md「Project削除Saga」直後の解説。ExportRecord/OutputRecord/ExportJobの
//      batchID列はonDelete: .setNullのため追加対応不要）。

extension HistoryDeletionStoreLive {
    public func deleteHistoryUnit(_ unit: HistoryUnit, trigger: DeletionTrigger) async throws {
        let projectID = Self.projectID(for: unit)
        try await database.dbQueue.write { connection in
            let context = try Self.loadDeletionContext(connection, unit: unit, trigger: trigger)
            if let rejection = Self.evaluateDeletion(context, unit: unit) {
                throw rejection
            }

            let outputFileIDs = try Self.loadOutputFileIDs(connection, projectID: projectID)
            let sourceFileID = try WorkingSourceStoreLive.loadSourceFileID(connection, projectID: projectID)
            let assetHashes = try Self.loadProjectStampAssetHashes(connection, projectID: projectID)
            let batchIDs = try Self.loadDistinctBatchIDs(connection, projectID: projectID)

            try Self.deleteOutputRecordsAndRegisterPendingDeletion(
                connection, projectID: projectID, outputFileIDs: outputFileIDs
            )
            try Self.registerWorkingSourcePendingDeletion(connection, sourceFileID: sourceFileID)

            try connection.execute(sql: "DELETE FROM Project WHERE projectID = ?", arguments: [projectID.rawValue])

            for assetHash in assetHashes {
                try StampAssetReferences.releaseIfUnreferenced(
                    connection, assetHash: try StampAssetHash(bytes: assetHash)
                )
            }
            for batchID in batchIDs {
                try Self.deleteBatchIfEmpty(connection, batchID: batchID)
            }
        }
    }

    private static func loadOutputFileIDs(_ connection: Database, projectID: ProjectID) throws -> [UUID] {
        try UUID.fetchAll(
            connection,
            sql: "SELECT outputFileID FROM OutputRecord WHERE projectID = ?",
            arguments: [projectID.rawValue]
        )
    }

    private static func loadProjectStampAssetHashes(_ connection: Database, projectID: ProjectID) throws -> [Data] {
        try Data.fetchAll(
            connection,
            sql: "SELECT assetHash FROM ProjectStampAsset WHERE projectID = ?",
            arguments: [projectID.rawValue]
        )
    }

    private static func loadDistinctBatchIDs(_ connection: Database, projectID: ProjectID) throws -> [UUID] {
        try UUID.fetchAll(
            connection,
            sql: "SELECT DISTINCT batchID FROM ExportQueueItem WHERE projectID = ?",
            arguments: [projectID.rawValue]
        )
    }

    /// 手順3。行が無ければ何もしない（DELETEもPendingFileDeletion登録も不要）。
    /// PendingFileDeletionへの登録は1文（複数行VALUES）でまとめて行う。
    private static func deleteOutputRecordsAndRegisterPendingDeletion(
        _ connection: Database, projectID: ProjectID, outputFileIDs: [UUID]
    ) throws {
        guard !outputFileIDs.isEmpty else { return }
        try connection.execute(sql: "DELETE FROM OutputRecord WHERE projectID = ?", arguments: [projectID.rawValue])
        try registerPendingFileDeletions(connection, files: outputFileIDs.map { outputFileID in
            ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: outputFileID))
        })
    }

    /// 手順4。WorkingSourceRecord行自体はProject削除のCASCADEに任せ、ここではPending
    /// FileDeletionへの登録のみ行う。
    private static func registerWorkingSourcePendingDeletion(
        _ connection: Database, sourceFileID: ManagedFileID?
    ) throws {
        guard let sourceFileID else { return }
        try registerPendingFileDeletion(connection, kind: .processingTemporary, fileID: sourceFileID.rawValue)
    }

    /// 手順7。対象batchIDに一致するExportQueueItemが0件になっていればBatch行を削除する。
    private static func deleteBatchIfEmpty(_ connection: Database, batchID: UUID) throws {
        let remaining = try Int.fetchOne(
            connection, sql: "SELECT count(*) FROM ExportQueueItem WHERE batchID = ?", arguments: [batchID]
        ) ?? 0
        guard remaining == 0 else { return }
        try connection.execute(sql: "DELETE FROM Batch WHERE batchID = ?", arguments: [batchID])
    }
}
