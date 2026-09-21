import Foundation
import Testing
import GRDB
import Domain
@testable import Persistence

// WorkingSourceStoreLive.createProjectWithWorkingSourceのテスト（インポートSagaの手順3。
// image-pipeline.md 5章「インポートSaga」が正本）。

@Suite("WorkingSourceStoreLive.createProjectWithWorkingSource")
struct WorkingSourceStoreCreateTests {
    @Test("ProjectとWorkingSourceRecordが作成されること")
    func createsProjectAndWorkingSourceRecord() async throws {
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
