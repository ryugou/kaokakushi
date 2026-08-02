import Foundation
import Domain
import GRDB

// replaceWorkingSource（素材更新Sagaの手順2）とattachWorkingSourceToExistingProject
// （履歴の既存Projectへの再接続）。どちらも「WorkingSourceRecordを置き換え、Projectの
// 撮影メタデータを更新し、FaceTrackを破棄し、revisionを進める」という同じ骨格を持つため
// （image-pipeline.md 5章「再選択後のSaga」手順2の分岐表）、共通処理をこのファイル内の
// privateヘルパーへ集約する。

extension WorkingSourceStoreLive {
    /// 単一トランザクションで: (1) 旧sourceFileIDを読む (2) WorkingSourceRecordをupsert
    /// (3) Projectの撮影メタデータを更新 (4) FaceTrackを全削除（EffectSettingはFK CASCADE
    /// で連動削除されるため追加のDELETE文は不要） (5) detectionRevision/projectRevisionを
    /// +1 (6) 旧sourceFileIDがあればPendingFileDeletionへ登録する
    /// （image-pipeline.md 5章「再選択後のSaga」）。
    public func replaceWorkingSource(_ input: ReplaceWorkingSourceInput) async throws {
        try await database.dbQueue.write { connection in
            let previousSourceFileID = try Self.loadSourceFileID(connection, projectID: input.projectID)

            try Self.upsertWorkingSourceRecord(
                connection,
                projectID: input.projectID,
                sourceFileID: input.newSourceFile.ref.fileID,
                createdAt: input.replacedAt
            )
            try Self.updateProjectCaptureMetadata(
                connection,
                projectID: input.projectID,
                capture: input.capture,
                libraryCreationDate: input.libraryCreationDate,
                representation: input.representation
            )
            try Self.discardFaceTracksAndBumpRevisions(connection, projectID: input.projectID)

            if let previousSourceFileID {
                try Self.registerPendingFileDeletion(connection, fileID: previousSourceFileID)
            }
        }
    }

    /// 履歴の既存Projectへの再接続。呼び出し契約上この時点でWorkingSourceRecordは
    /// 存在しない前提だが、念のためUPSERT的に書く（spec確定判断）。万一契約違反で
    /// 既存WorkingSourceRecordが残っていた場合に備え、upsert前に旧sourceFileIDを読み、
    /// upsert後にPendingFileDeletionへ登録することで旧ファイルが失われないようにする
    /// （replaceWorkingSourceと同じ防御。呼び出し位置・呼び出し方も揃えている）。
    /// 通常経路（契約どおりWorkingSourceRecordが存在しない場合）は旧ファイルが無いため
    /// PendingFileDeletion登録は行われない。
    public func attachWorkingSourceToExistingProject(_ input: AttachWorkingSourceInput) async throws {
        try await database.dbQueue.write { connection in
            let previousSourceFileID = try Self.loadSourceFileID(connection, projectID: input.projectID)

            try Self.upsertWorkingSourceRecord(
                connection,
                projectID: input.projectID,
                sourceFileID: input.sourceFile.ref.fileID,
                createdAt: input.attachedAt
            )
            try Self.updateProjectCaptureMetadata(
                connection,
                projectID: input.projectID,
                capture: input.capture,
                libraryCreationDate: input.libraryCreationDate,
                representation: input.representation
            )
            try Self.discardFaceTracksAndBumpRevisions(connection, projectID: input.projectID)

            if let previousSourceFileID {
                try Self.registerPendingFileDeletion(connection, fileID: previousSourceFileID)
            }
        }
    }

    /// WorkingSourceRecordが無ければ新規作成し、あれば置換する単一のSQL文
    /// （PRIMARY KEYがprojectIDのため`ON CONFLICT(projectID) DO UPDATE`で両ケースを
    /// 原子的に扱える。読み取り→分岐という2段階を避け競合の余地を作らない）。
    private static func upsertWorkingSourceRecord(
        _ connection: Database,
        projectID: ProjectID,
        sourceFileID: ManagedFileID,
        createdAt: Date
    ) throws {
        try connection.execute(
            sql: """
            INSERT INTO WorkingSourceRecord (projectID, sourceFileID, createdAt)
            VALUES (?, ?, ?)
            ON CONFLICT(projectID) DO UPDATE SET
                sourceFileID = excluded.sourceFileID,
                createdAt = excluded.createdAt
            """,
            arguments: [projectID.rawValue, sourceFileID.rawValue, createdAt]
        )
    }

    private static func updateProjectCaptureMetadata(
        _ connection: Database,
        projectID: ProjectID,
        capture: OriginalCaptureMetadata,
        libraryCreationDate: Date?,
        representation: SourceRepresentation
    ) throws {
        try connection.execute(
            sql: """
            UPDATE Project SET
                captureDateTimeOriginal = ?,
                captureSubSecTimeOriginal = ?,
                captureOffsetTimeOriginal = ?,
                captureUtcMillis = ?,
                libraryCreationDate = ?,
                sourceRepresentation = ?
            WHERE projectID = ?
            """,
            arguments: [
                capture.dateTimeOriginal,
                capture.subSecTimeOriginal,
                capture.offsetTimeOriginal,
                capture.utcMillis,
                libraryCreationDate,
                SourceRepresentationColumn(representation).rawValue,
                projectID.rawValue
            ]
        )
    }

    /// FaceTrackを全削除する（EffectSettingはFK CASCADEで連動削除されるため追加のDELETE
    /// 文は不要——spec確定判断）。続けてdetectionRevision/projectRevisionを+1する
    /// （再選択のたびに再検出・再確認が必要になることをrevisionの増加で表現する。
    /// image-pipeline.md 5章「再選択後のSaga」）。なお同章手順2が挙げるReviewIssue/
    /// ReviewDecision/ReviewStatusの破棄は、schema v1（Task 2確定済み）にこれらの永続
    /// テーブルが存在せず、`ReviewIssueID`が`detectionRevision`を含む設計により
    /// `detectionRevision`の増加で導出的に無効化されるため、ここでの明示的な行削除は
    /// 不要である。
    private static func discardFaceTracksAndBumpRevisions(_ connection: Database, projectID: ProjectID) throws {
        try connection.execute(
            sql: "DELETE FROM FaceTrack WHERE projectID = ?",
            arguments: [projectID.rawValue]
        )
        try connection.execute(
            sql: """
            UPDATE Project SET
                detectionRevision = detectionRevision + 1,
                projectRevision = projectRevision + 1
            WHERE projectID = ?
            """,
            arguments: [projectID.rawValue]
        )
    }
}
