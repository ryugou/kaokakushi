import Foundation
import Testing
import GRDB
@testable import Persistence

// architecture.md 7.1 の一意制約・外部キー表を、実DBの制約違反として固定する
// （test-plan.md 4.2）。マイグレーション自体の検証はSchemaTestsが担当し、
// このファイルは個々の制約（RESTRICT/SET NULL/部分UNIQUE/CASCADE）に役割を絞る。
//
// AppDatabase.open(at:) 経由の実ファイルDBを使う（in-memoryは使わない）。

@Suite("SchemaConstraints")
struct SchemaConstraintTests {

    private func makeTemporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaConstraintTests-\(UUID().uuidString).sqlite")
    }

    private func openTestDatabase() throws -> (AppDatabase, URL) {
        let url = makeTemporaryDatabaseURL()
        return (try AppDatabase.open(at: url), url)
    }

    // MARK: - RESTRICT

    @Test("非終端のOutputRecordが存在するProjectの削除がRESTRICTで失敗すること")
    func projectDeletionRestrictedByPendingOutputRecord() throws {
        let (appDatabase, url) = try openTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()

        try appDatabase.dbQueue.write { database in
            try insertProject(database, projectID: projectID)
            try insertOutputRecord(database, exportID: UUID(), projectID: projectID, batchID: nil, settledAt: nil)
        }

        do {
            try appDatabase.dbQueue.write { database in
                try database.execute(sql: "DELETE FROM Project WHERE projectID = ?", arguments: [projectID])
            }
            Issue.record("非終端OutputRecordが存在するのにProject削除が成功した")
        } catch let error where isForeignKeyViolation(error) {
            // 期待どおりRESTRICTで拒否された。
        } catch {
            Issue.record("外部キー制約違反以外がthrowされた: \(error)")
        }
    }

    @Test("進行中のExportJobが存在するProjectの削除がRESTRICTで失敗すること")
    func projectDeletionRestrictedByRunningExportJob() throws {
        let (appDatabase, url) = try openTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()

        try appDatabase.dbQueue.write { database in
            try insertProject(database, projectID: projectID)
            try insertExportJob(database, exportID: UUID(), projectID: projectID, batchID: nil)
        }

        do {
            try appDatabase.dbQueue.write { database in
                try database.execute(sql: "DELETE FROM Project WHERE projectID = ?", arguments: [projectID])
            }
            Issue.record("進行中ExportJobが存在するのにProject削除が成功した")
        } catch let error where isForeignKeyViolation(error) {
            // 期待どおりRESTRICTで拒否された。
        } catch {
            Issue.record("外部キー制約違反以外がthrowされた: \(error)")
        }
    }

    // MARK: - SET NULL

    @Test("Batch削除でOutputRecord/ExportRecord/ExportJobのbatchIDがSET NULLになること")
    func batchDeletionSetsNullOnDependentBatchIDs() throws {
        let (appDatabase, url) = try openTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()
        let batchID = UUID()
        let outputExportID = UUID()
        let recordExportID = UUID()
        let jobExportID = UUID()

        try appDatabase.dbQueue.write { database in
            try insertProject(database, projectID: projectID)
            try insertBatch(database, batchID: batchID)
            try insertOutputRecord(
                database, exportID: outputExportID, projectID: projectID, batchID: batchID, settledAt: nil
            )
            try insertExportRecord(database, exportID: recordExportID, projectID: projectID, batchID: batchID)
            try insertExportJob(database, exportID: jobExportID, projectID: projectID, batchID: batchID)

            try database.execute(sql: "DELETE FROM Batch WHERE batchID = ?", arguments: [batchID])
        }

        try appDatabase.dbQueue.read { database in
            let outputBatchID = try UUID.fetchOne(
                database, sql: "SELECT batchID FROM OutputRecord WHERE exportID = ?", arguments: [outputExportID]
            )
            #expect(outputBatchID == nil)

            let recordBatchID = try UUID.fetchOne(
                database, sql: "SELECT batchID FROM ExportRecord WHERE exportID = ?", arguments: [recordExportID]
            )
            #expect(recordBatchID == nil)

            let jobBatchID = try UUID.fetchOne(
                database, sql: "SELECT batchID FROM ExportJob WHERE exportID = ?", arguments: [jobExportID]
            )
            #expect(jobBatchID == nil)
        }
    }

    // MARK: - 部分UNIQUE

    @Test("同一projectIDで未確定のOutputRecordを2件INSERTすると一意制約違反になること")
    func pendingOutputRecordPartialUniqueRejectsSecondPendingRow() throws {
        let (appDatabase, url) = try openTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()

        try appDatabase.dbQueue.write { database in
            try insertProject(database, projectID: projectID)
            try insertOutputRecord(database, exportID: UUID(), projectID: projectID, batchID: nil, settledAt: nil)
        }

        do {
            try appDatabase.dbQueue.write { database in
                try insertOutputRecord(database, exportID: UUID(), projectID: projectID, batchID: nil, settledAt: nil)
            }
            Issue.record("未確定OutputRecordの2件目INSERTが成功してしまった")
        } catch DatabaseError.SQLITE_CONSTRAINT_UNIQUE {
            // 期待どおり部分UNIQUEインデックスで拒否された。
        } catch {
            Issue.record("SQLITE_CONSTRAINT_UNIQUE以外がthrowされた: \(error)")
        }
    }

    @Test("1件目のOutputRecordをsettleしてから2件目（未確定）をINSERTすると成功すること")
    func pendingOutputRecordPartialUniqueAllowsAfterFirstIsSettled() throws {
        let (appDatabase, url) = try openTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()
        let firstExportID = UUID()

        try appDatabase.dbQueue.write { database in
            try insertProject(database, projectID: projectID)
            try insertOutputRecord(
                database, exportID: firstExportID, projectID: projectID, batchID: nil, settledAt: nil
            )

            try database.execute(
                sql: "UPDATE OutputRecord SET settledAt = ? WHERE exportID = ?",
                arguments: [schemaTestReferenceDate, firstExportID]
            )

            // 部分インデックスがNULLの行だけを見ていることの確認: settledAt確定後の
            // 同一projectIDに対する2件目（未確定）のINSERTは成功するはず。
            try insertOutputRecord(database, exportID: UUID(), projectID: projectID, batchID: nil, settledAt: nil)
        }

        try appDatabase.dbQueue.read { database in
            let pendingCount = try Int.fetchOne(
                database,
                sql: "SELECT count(*) FROM OutputRecord WHERE projectID = ? AND settledAt IS NULL",
                arguments: [projectID]
            )
            #expect(pendingCount == 1)
        }
    }

    // MARK: - StampAsset RESTRICT

    @Test("CustomStampが参照するStampAssetの削除が失敗すること")
    func stampAssetDeletionRestrictedByCustomStamp() throws {
        let (appDatabase, url) = try openTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let assetHash = schemaTestHash(seed: 0x01)

        try appDatabase.dbQueue.write { database in
            try insertStampAsset(database, contentHash: assetHash, fileID: UUID())
            try insertCustomStamp(database, customStampID: UUID(), assetHash: assetHash)
        }

        do {
            try appDatabase.dbQueue.write { database in
                try database.execute(sql: "DELETE FROM StampAsset WHERE contentHash = ?", arguments: [assetHash])
            }
            Issue.record("CustomStampが参照しているのにStampAsset削除が成功した")
        } catch let error where isForeignKeyViolation(error) {
            // 期待どおりRESTRICTで拒否された。
        } catch {
            Issue.record("外部キー制約違反以外がthrowされた: \(error)")
        }
    }

    @Test("ProjectStampAssetが参照するStampAssetの削除が失敗すること")
    func stampAssetDeletionRestrictedByProjectStampAsset() throws {
        let (appDatabase, url) = try openTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let assetHash = schemaTestHash(seed: 0x02)
        let projectID = UUID()

        try appDatabase.dbQueue.write { database in
            try insertProject(database, projectID: projectID)
            try insertStampAsset(database, contentHash: assetHash, fileID: UUID())
            try insertProjectStampAsset(database, projectID: projectID, assetHash: assetHash)
        }

        do {
            try appDatabase.dbQueue.write { database in
                try database.execute(sql: "DELETE FROM StampAsset WHERE contentHash = ?", arguments: [assetHash])
            }
            Issue.record("ProjectStampAssetが参照しているのにStampAsset削除が成功した")
        } catch let error where isForeignKeyViolation(error) {
            // 期待どおりRESTRICTで拒否された。
        } catch {
            Issue.record("外部キー制約違反以外がthrowされた: \(error)")
        }
    }

    // MARK: - CASCADE連鎖

    /// cascadeChainDeletesDependentRows専用のfixtureセットアップ。CASCADEを検証
    /// したいので、削除自体をRESTRICTで拒否してしまうOutputRecord・進行中
    /// ExportJobはあえて作らない。
    private func insertCascadeFixture(
        _ database: Database,
        projectID: UUID,
        faceTrackID: UUID,
        batchID: UUID,
        assetHash: Data
    ) throws {
        try insertProject(database, projectID: projectID)
        try insertBatch(database, batchID: batchID)
        try insertFaceTrack(database, faceTrackID: faceTrackID, projectID: projectID)
        try insertEffectSetting(database, faceTrackID: faceTrackID, projectID: projectID)
        try insertExportSetting(database, projectID: projectID)
        try insertWorkingSourceRecord(database, projectID: projectID, sourceFileID: UUID())
        try insertExportQueueItem(database, queueItemID: UUID(), projectID: projectID, batchID: batchID)
        try insertExportRecord(database, exportID: UUID(), projectID: projectID, batchID: nil)
        try insertExportedSettingsEntry(database, projectID: projectID)
        try insertStampAsset(database, contentHash: assetHash, fileID: UUID())
        try insertProjectStampAsset(database, projectID: projectID, assetHash: assetHash)
    }

    /// insertCascadeFixtureで作った全テーブルの行が、Project削除後に0件になった
    /// ことを検証する。throwする可能性がある呼び出しを先にletへ束縛してから
    /// #expectへ渡す（#expectへ直接tryを渡す書き方に統一しない。マクロ展開後の
    /// 挙動をこの場で確認できないため、確実にコンパイルできる形を優先する）。
    private func assertCascadeFixtureIsGone(_ database: Database, projectID: UUID) throws {
        let faceTrackCount = try countFaceTrackRows(database, projectID: projectID)
        let effectSettingCount = try countEffectSettingRows(database, projectID: projectID)
        let exportSettingCount = try countExportSettingRows(database, projectID: projectID)
        let workingSourceRecordCount = try countWorkingSourceRecordRows(database, projectID: projectID)
        let exportQueueItemCount = try countExportQueueItemRows(database, projectID: projectID)
        let exportRecordCount = try countExportRecordRows(database, projectID: projectID)
        let exportedSettingsEntryCount = try countExportedSettingsEntryRows(database, projectID: projectID)
        let projectStampAssetCount = try countProjectStampAssetRows(database, projectID: projectID)

        #expect(faceTrackCount == 0)
        #expect(effectSettingCount == 0)
        #expect(exportSettingCount == 0)
        #expect(workingSourceRecordCount == 0)
        #expect(exportQueueItemCount == 0)
        #expect(exportRecordCount == 0)
        #expect(exportedSettingsEntryCount == 0)
        #expect(projectStampAssetCount == 0)
    }

    @Test("Projectを削除すると依存する子行がCASCADEで消えること")
    func cascadeChainDeletesDependentRows() throws {
        let (appDatabase, url) = try openTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()
        let faceTrackID = UUID()
        let batchID = UUID()
        let assetHash = schemaTestHash(seed: 0x03)

        try appDatabase.dbQueue.write { database in
            try insertCascadeFixture(
                database, projectID: projectID, faceTrackID: faceTrackID, batchID: batchID, assetHash: assetHash
            )
            try database.execute(sql: "DELETE FROM Project WHERE projectID = ?", arguments: [projectID])
        }

        try appDatabase.dbQueue.read { database in
            try assertCascadeFixtureIsGone(database, projectID: projectID)
        }
    }

    /// cascadeChainDeletesDependentRowsはProject削除経由の連鎖のみを確認しており、
    /// FaceTrack単独の削除でEffectSettingがCASCADEで消えることは未検証だった
    /// （Issue #6 Task 2レビューからの申し送り）。ここではProjectを経由せずFaceTrackを
    /// 直接削除し、EffectSettingが単独でもCASCADEされることを確認する。
    @Test("FaceTrackを単独削除するとEffectSettingがCASCADEで消えること")
    func faceTrackDeletionCascadesEffectSetting() throws {
        let (appDatabase, url) = try openTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()
        let faceTrackID = UUID()

        try appDatabase.dbQueue.write { database in
            try insertProject(database, projectID: projectID)
            try insertFaceTrack(database, faceTrackID: faceTrackID, projectID: projectID)
            try insertEffectSetting(database, faceTrackID: faceTrackID, projectID: projectID)
            try database.execute(sql: "DELETE FROM FaceTrack WHERE faceTrackID = ?", arguments: [faceTrackID])
        }

        let effectSettingCount = try appDatabase.dbQueue.read { database in
            try countEffectSettingRows(database, projectID: projectID)
        }
        #expect(effectSettingCount == 0)
    }
}
