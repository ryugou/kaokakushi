import Foundation
import Domain
import GRDB

// createProjectWithWorkingSource（インポートSagaの手順3。image-pipeline.md 5章
// 「インポートSaga」「実装の所在」が正本）。単一トランザクションでProject・
// WorkingSourceRecordを作成する。

extension WorkingSourceStoreLive {
    /// `input.initialSpec`（RenderSpec）は意図的に使わない。EffectSetting/FaceTrackへの
    /// 展開はサブプロジェクト4/5のApplication層の担当であり（Issue #25参照）、Project・
    /// WorkingSourceRecordの2テーブルをトランザクションで作るだけのこのPersistence層
    /// メソッドの担当範囲外である。取りこぼしではなく、EffectSetting/FaceTrackへ書き込む
    /// 処理をここに実装しないことがこのメソッドの契約そのもの。
    public func createProjectWithWorkingSource(_ input: CreateWorkingSourceInput) async throws {
        try await database.dbQueue.write { connection in
            try Self.insertProject(connection, input: input)

            try Self.insertWorkingSourceRecord(
                connection,
                projectID: input.projectID,
                sourceFileID: input.sourceFile.ref.fileID,
                createdAt: input.createdAt
            )
        }
    }

    /// Project行の新規INSERT。`detectionRevision` / `detectionPixelSizeWidth` /
    /// `detectionPixelSizeHeight` は0で初期化する（この時点では顔検出がまだ走っていない
    /// ため。NOT NULL制約を満たすための初期値であり、初回検出実行時にApplication層が
    /// 更新する値——image-pipeline.md 5章「インポートSaga」）。
    private static func insertProject(_ connection: Database, input: CreateWorkingSourceInput) throws {
        try connection.execute(
            sql: """
            INSERT INTO Project (
                projectID, projectRevision, detectionRevision, detectionPixelSizeWidth,
                detectionPixelSizeHeight, photoLibraryLocalIdentifier, captureDateTimeOriginal,
                captureSubSecTimeOriginal, captureOffsetTimeOriginal, captureUtcMillis,
                libraryCreationDate, sourceRepresentation
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                input.projectID.rawValue, 0, 0, 0, 0,
                input.sourceLocator.photoLibraryLocalIdentifier,
                input.capture.dateTimeOriginal,
                input.capture.subSecTimeOriginal,
                input.capture.offsetTimeOriginal,
                input.capture.utcMillis,
                input.libraryCreationDate,
                SourceRepresentationColumn(input.representation).rawValue
            ]
        )
    }

    private static func insertWorkingSourceRecord(
        _ connection: Database,
        projectID: ProjectID,
        sourceFileID: ManagedFileID,
        createdAt: Date
    ) throws {
        try connection.execute(
            sql: "INSERT INTO WorkingSourceRecord (projectID, sourceFileID, createdAt) VALUES (?, ?, ?)",
            arguments: [projectID.rawValue, sourceFileID.rawValue, createdAt]
        )
    }
}
