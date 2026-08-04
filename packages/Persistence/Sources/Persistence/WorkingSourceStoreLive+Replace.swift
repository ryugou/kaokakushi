import Foundation
import Domain
import GRDB

// replaceWorkingSource（素材更新Sagaの手順2）とattachWorkingSourceToExistingProject
// （履歴の既存Projectへの再接続）。どちらも「WorkingSourceRecordを置き換え、Projectの
// 撮影メタデータを更新し、FaceTrackを破棄し、revisionを進める」という同じ骨格を持つため
// （image-pipeline.md 5章「再選択後のSaga」手順2の分岐表）、共通処理をこのファイル内の
// privateヘルパーへ集約する。

/// replaceWorkingSource / attachWorkingSourceToExistingProjectの差分（入力型が異なるだけで
/// 置き換え処理そのものは同一）を1つにまとめた値。引数を構造体へ束ねるのはlintの引数上限
/// 対応パターン（ExportSagaStoreLive.AccountingModeContextと同じ理由）。このファイル内の
/// privateヘルパーだけが使うためfile-scope privateで足りる。
private struct WorkingSourceReplacement {
    let projectID: ProjectID
    /// 新しい処理用素材のfileID（replaceならnewSourceFile、attachならsourceFile由来）。
    let sourceFileID: ManagedFileID
    /// WorkingSourceRecord.createdAtへ書く時刻（replaceならreplacedAt、attachならattachedAt）。
    let createdAt: Date
    let capture: OriginalCaptureMetadata
    let libraryCreationDate: Date?
    let representation: SourceRepresentation
}

extension WorkingSourceStoreLive {
    /// 単一トランザクションで: (1) 旧sourceFileIDを読む (2) WorkingSourceRecordをupsert
    /// (3) Projectの撮影メタデータを更新 (4) FaceTrackを全削除（EffectSettingはFK CASCADE
    /// で連動削除されるため追加のDELETE文は不要） (5) detectionRevision/projectRevisionを
    /// +1 (6) 旧sourceFileIDがあればPendingFileDeletionへ登録する
    /// （image-pipeline.md 5章「再選択後のSaga」）。
    public func replaceWorkingSource(_ input: ReplaceWorkingSourceInput) async throws {
        try await database.dbQueue.write { connection in
            try Self.applyWorkingSourceReplacement(connection, replacement: WorkingSourceReplacement(
                projectID: input.projectID,
                sourceFileID: input.newSourceFile.ref.fileID,
                createdAt: input.replacedAt,
                capture: input.capture,
                libraryCreationDate: input.libraryCreationDate,
                representation: input.representation
            ))
        }
    }

    /// 履歴の既存Projectへの再接続。呼び出し契約上この時点でWorkingSourceRecordは
    /// 存在しない前提だが、念のためUPSERT的に書く（spec確定判断）。万一契約違反で
    /// 既存WorkingSourceRecordが残っていた場合に備え、upsert前に旧sourceFileIDを読み、
    /// upsert後にPendingFileDeletionへ登録することで旧ファイルが失われないようにする
    /// （replaceWorkingSourceと同じ防御。手順そのものを共有しているため、呼び出し位置・
    /// 呼び出し方の差異は生じない）。通常経路（契約どおりWorkingSourceRecordが存在しない
    /// 場合）は旧ファイルが無いためPendingFileDeletion登録は行われない。
    public func attachWorkingSourceToExistingProject(_ input: AttachWorkingSourceInput) async throws {
        try await database.dbQueue.write { connection in
            try Self.applyWorkingSourceReplacement(connection, replacement: WorkingSourceReplacement(
                projectID: input.projectID,
                sourceFileID: input.sourceFile.ref.fileID,
                createdAt: input.attachedAt,
                capture: input.capture,
                libraryCreationDate: input.libraryCreationDate,
                representation: input.representation
            ))
        }
    }

    /// replaceWorkingSource / attachWorkingSourceToExistingProjectが共有する5段の骨格
    /// （上記replaceWorkingSourceのdocコメントの手順1〜6）。両者の違いは入力の取り出し方
    /// だけなので、DBへの手順はこの1箇所に集約する（片方だけ手順が変わる事故を防ぐ）。
    /// 呼び出し元のdbQueue.writeクロージャ内から呼ばれるため、全手順が同一トランザクションに
    /// 含まれる。
    private static func applyWorkingSourceReplacement(
        _ connection: Database, replacement: WorkingSourceReplacement
    ) throws {
        let previousSourceFileID = try Self.loadSourceFileID(connection, projectID: replacement.projectID)

        try Self.upsertWorkingSourceRecord(
            connection,
            projectID: replacement.projectID,
            sourceFileID: replacement.sourceFileID,
            createdAt: replacement.createdAt
        )
        try Self.updateProjectCaptureMetadata(
            connection,
            projectID: replacement.projectID,
            capture: replacement.capture,
            libraryCreationDate: replacement.libraryCreationDate,
            representation: replacement.representation
        )
        try Self.discardFaceTracksAndBumpRevisions(connection, projectID: replacement.projectID)

        if let previousSourceFileID {
            try registerPendingFileDeletion(
                connection, kind: .processingTemporary, fileID: previousSourceFileID.rawValue
            )
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
