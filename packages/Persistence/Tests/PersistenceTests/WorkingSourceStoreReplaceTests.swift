import Foundation
import Testing
import GRDB
import Domain
@testable import Persistence

// WorkingSourceStoreLive.replaceWorkingSource / attachWorkingSourceToExistingProjectの
// テスト（再選択後のSaga。image-pipeline.md 5章「再選択後のSaga」が正本）。

/// replaceWorkingSourceのreplacedAt用の固定値（schemaTestReferenceDateより後）。
/// 裸のDate()は使わない規約に従う。
private let laterReferenceDate = Date(timeIntervalSince1970: 1_700_000_100)

@Suite("WorkingSourceStoreLive.replaceWorkingSource / attachWorkingSourceToExistingProject")
struct WorkingSourceStoreReplaceTests {
    @Test("WorkingSourceRecordが置換されrevisionが2つとも+1されること")
    func replaceWorkingSourceUpdatesRecordAndBumpsRevisions() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let oldFileID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertWorkingSourceRecord(connection, projectID: projectID.rawValue, sourceFileID: oldFileID)
        }
        let newFileID = UUID()
        let input = ReplaceWorkingSourceInput(
            projectID: projectID,
            newSourceFile: makeWorkingSourceFileRef(fileID: newFileID),
            replacedAt: laterReferenceDate,
            capture: makeCaptureMetadata(),
            libraryCreationDate: laterReferenceDate,
            representation: .transcoded
        )

        try await store.replaceWorkingSource(input)

        let record = try workingSourceRecordFields(database, projectID: projectID.rawValue)
        #expect(record?.sourceFileID == newFileID)
        #expect(record?.createdAt == laterReferenceDate)
        let revisions = try projectRevisions(database, projectID: projectID.rawValue)
        #expect(revisions?.projectRevision == 1)
        #expect(revisions?.detectionRevision == 1)
    }

    @Test("replaceWorkingSourceでFaceTrackが破棄されEffectSettingもCASCADEで消えること")
    func replaceWorkingSourceDiscardsFaceTracksCascadingEffectSettings() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let faceTrackID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertWorkingSourceRecord(connection, projectID: projectID.rawValue, sourceFileID: UUID())
            try insertFaceTrack(connection, faceTrackID: faceTrackID, projectID: projectID.rawValue)
            try insertEffectSetting(connection, faceTrackID: faceTrackID, projectID: projectID.rawValue)
        }
        let input = ReplaceWorkingSourceInput(
            projectID: projectID,
            newSourceFile: makeWorkingSourceFileRef(),
            replacedAt: laterReferenceDate,
            capture: makeCaptureMetadata(),
            libraryCreationDate: laterReferenceDate,
            representation: .original
        )

        try await store.replaceWorkingSource(input)

        #expect(try faceTrackRowCount(database, projectID: projectID.rawValue) == 0)
        #expect(try effectSettingRowCount(database, projectID: projectID.rawValue) == 0)
    }

    @Test("replaceWorkingSourceで旧sourceFileIDがPendingFileDeletionへ登録されること")
    func replaceWorkingSourceRegistersOldFileIDForPendingDeletion() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let oldFileID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertWorkingSourceRecord(connection, projectID: projectID.rawValue, sourceFileID: oldFileID)
        }
        let input = ReplaceWorkingSourceInput(
            projectID: projectID,
            newSourceFile: makeWorkingSourceFileRef(),
            replacedAt: laterReferenceDate,
            capture: makeCaptureMetadata(),
            libraryCreationDate: laterReferenceDate,
            representation: .original
        )

        try await store.replaceWorkingSource(input)

        let kind = ManagedFileKind.processingTemporary.rawValue
        #expect(try pendingFileDeletionExists(database, kind: kind, fileID: oldFileID))
    }

    @Test("replaceWorkingSourceで新旧sourceFileIDが同一の場合PendingFileDeletionへ登録されないこと")
    func replaceWorkingSourceWithSameFileIDDoesNotRegisterPendingDeletion() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let sameFileID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertWorkingSourceRecord(connection, projectID: projectID.rawValue, sourceFileID: sameFileID)
        }
        let input = ReplaceWorkingSourceInput(
            projectID: projectID,
            newSourceFile: makeWorkingSourceFileRef(fileID: sameFileID),
            replacedAt: laterReferenceDate,
            capture: makeCaptureMetadata(),
            libraryCreationDate: laterReferenceDate,
            representation: .original
        )

        try await store.replaceWorkingSource(input)

        let kind = ManagedFileKind.processingTemporary.rawValue
        #expect(try pendingFileDeletionExists(database, kind: kind, fileID: sameFileID) == false)
        let record = try workingSourceRecordFields(database, projectID: projectID.rawValue)
        #expect(record?.sourceFileID == sameFileID)
    }

    @Test("attachWorkingSourceToExistingProjectで新規WorkingSourceRecordが作成されrevisionが増加すること")
    func attachWorkingSourceToExistingProjectCreatesRecordAndBumpsRevisions() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in try insertProject(connection, projectID: projectID.rawValue) }
        let newFileID = UUID()
        let input = AttachWorkingSourceInput(
            projectID: projectID,
            sourceFile: makeWorkingSourceFileRef(fileID: newFileID),
            attachedAt: laterReferenceDate,
            capture: makeCaptureMetadata(),
            libraryCreationDate: laterReferenceDate,
            representation: .original
        )

        try await store.attachWorkingSourceToExistingProject(input)

        let record = try workingSourceRecordFields(database, projectID: projectID.rawValue)
        #expect(record?.sourceFileID == newFileID)
        #expect(record?.createdAt == laterReferenceDate)
        let revisions = try projectRevisions(database, projectID: projectID.rawValue)
        #expect(revisions?.projectRevision == 1)
        #expect(revisions?.detectionRevision == 1)
    }

    @Test("attachWorkingSourceToExistingProjectの契約違反ケースで旧sourceFileIDがPendingFileDeletionへ登録されること")
    func attachWorkingSourceToExistingProjectRegistersOldFileIDOnContractViolation() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let oldFileID = UUID()
        let newFileID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertWorkingSourceRecord(connection, projectID: projectID.rawValue, sourceFileID: oldFileID)
        }
        let input = AttachWorkingSourceInput(
            projectID: projectID,
            sourceFile: makeWorkingSourceFileRef(fileID: newFileID),
            attachedAt: laterReferenceDate,
            capture: makeCaptureMetadata(),
            libraryCreationDate: laterReferenceDate,
            representation: .original
        )

        try await store.attachWorkingSourceToExistingProject(input)

        let kind = ManagedFileKind.processingTemporary.rawValue
        #expect(try pendingFileDeletionExists(database, kind: kind, fileID: oldFileID))
        let record = try workingSourceRecordFields(database, projectID: projectID.rawValue)
        #expect(record?.sourceFileID == newFileID)
    }

    @Test("attachWorkingSourceToExistingProjectで新旧sourceFileIDが同一の場合PendingFileDeletionへ登録されないこと")
    func attachWorkingSourceToExistingProjectWithSameFileIDSkipsPendingDeletion() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkingSourceStoreLive(database: database)
        let projectID = ProjectID(rawValue: UUID())
        let sameFileID = UUID()
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertWorkingSourceRecord(connection, projectID: projectID.rawValue, sourceFileID: sameFileID)
        }
        let input = AttachWorkingSourceInput(
            projectID: projectID,
            sourceFile: makeWorkingSourceFileRef(fileID: sameFileID),
            attachedAt: laterReferenceDate,
            capture: makeCaptureMetadata(),
            libraryCreationDate: laterReferenceDate,
            representation: .original
        )

        try await store.attachWorkingSourceToExistingProject(input)

        let kind = ManagedFileKind.processingTemporary.rawValue
        #expect(try pendingFileDeletionExists(database, kind: kind, fileID: sameFileID) == false)
        let record = try workingSourceRecordFields(database, projectID: projectID.rawValue)
        #expect(record?.sourceFileID == sameFileID)
    }
}
