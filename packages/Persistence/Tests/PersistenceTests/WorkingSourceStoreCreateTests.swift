import Foundation
import Testing
import GRDB
import Domain
@testable import Persistence

// WorkingSourceStoreLive.createProjectWithWorkingSourceのテスト（インポートSagaの手順3。
// image-pipeline.md 5章「インポートSaga」が正本）。

@Suite("WorkingSourceStoreLive.createProjectWithWorkingSource")
struct WorkingSourceStoreCreateTests {
    @Test("queueItemIDが無い場合、ProjectとWorkingSourceRecordが作成されExportQueueItemは作られないこと")
    func createsProjectAndWorkingSourceRecordWithoutQueueItem() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let fileID = UUID()
        let input = try makeCreateWorkingSourceInput(
            projectID: projectID,
            sourceFile: makeWorkingSourceFileRef(fileID: fileID)
        )

        try await store.createProjectWithWorkingSource(input)

        let revisions = try projectRevisions(database, projectID: projectID.rawValue)
        #expect(revisions?.projectRevision == 0)
        #expect(revisions?.detectionRevision == 0)
        let record = try workingSourceRecordFields(database, projectID: projectID.rawValue)
        #expect(record?.sourceFileID == fileID)
        let queueItemCount: Int = try await database.dbQueue.read { connection in
            try Int.fetchOne(
                connection,
                sql: "SELECT count(*) FROM ExportQueueItem WHERE projectID = ?",
                arguments: [projectID.rawValue]
            ) ?? -1
        }
        #expect(queueItemCount == 0)
    }

    @Test("queueItemID・batchIDが両方ある場合、state=waitingのExportQueueItemが作成されること")
    func createsExportQueueItemWhenQueueItemIDProvided() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let batchID = BatchID(rawValue: UUID())
        let queueItemID = ExportQueueItemID(rawValue: UUID())
        try await database.dbQueue.write { connection in try insertBatch(connection, batchID: batchID.rawValue) }
        let input = try makeCreateWorkingSourceInput(
            projectID: projectID,
            batchID: batchID,
            queueItemID: queueItemID
        )

        try await store.createProjectWithWorkingSource(input)

        let queueItem = try exportQueueItemStateAndPauseReason(database, queueItemID: queueItemID.rawValue)
        #expect(queueItem?.state == ExportQueueStateColumn.waiting.rawValue)
        #expect(queueItem?.pauseReason == nil)
    }

    @Test("queueItemIDがあるのにbatchIDが無い場合、batchIDMissingForQueueItemがthrowされ何もコミットされないこと")
    func throwsBatchIDMissingAndRollsBackWhenQueueItemIDProvidedWithoutBatchID() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let queueItemID = ExportQueueItemID(rawValue: UUID())
        let input = try makeCreateWorkingSourceInput(
            projectID: projectID,
            batchID: nil,
            queueItemID: queueItemID
        )

        do {
            try await store.createProjectWithWorkingSource(input)
            Issue.record("batchID無しでcreateProjectWithWorkingSourceが成功した")
        } catch let error as WorkingSourceStoreError {
            guard case .batchIDMissingForQueueItem(let missingQueueItemID) = error else {
                Issue.record("期待したエラーケース(batchIDMissingForQueueItem)ではない: \(error)")
                return
            }
            #expect(missingQueueItemID == queueItemID)
        } catch {
            Issue.record("WorkingSourceStoreError以外がthrowされた: \(error)")
        }

        #expect(try !projectRowExists(database, projectID: projectID.rawValue))
    }

    @Test("initialSpecへ非空のRenderSpecを渡してもEffectSetting/FaceTrackへ展開されないこと")
    func doesNotExpandInitialSpecIntoEffectSettingOrFaceTrack() async throws {
        // createProjectWithWorkingSourceはinitialSpecを意図的に使わない（EffectSetting/
        // FaceTrackへの展開はサブプロジェクト4/5のApplication層の担当。Issue #25参照。
        // WorkingSourceStoreLive+Create.swiftのdocコメント参照）。regionsを持つ実質的な
        // RenderSpecを渡しても2テーブルとも0件のままであることでそれを裏付ける。
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let input = CreateWorkingSourceInput(
            projectID: projectID,
            batchID: nil,
            queueItemID: nil,
            sourceFile: makeWorkingSourceFileRef(),
            createdAt: schemaTestReferenceDate,
            sourceLocator: ProjectSourceLocator(photoLibraryLocalIdentifier: "asset-identifier"),
            capture: makeCaptureMetadata(),
            libraryCreationDate: schemaTestReferenceDate,
            representation: .original,
            initialSpec: try makeRenderSpecFixtureWithRegion()
        )

        try await store.createProjectWithWorkingSource(input)

        #expect(try faceTrackRowCount(database, projectID: projectID.rawValue) == 0)
        #expect(try effectSettingRowCount(database, projectID: projectID.rawValue) == 0)
    }
}
