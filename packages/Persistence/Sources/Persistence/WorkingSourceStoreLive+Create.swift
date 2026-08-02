import Foundation
import Domain
import GRDB

// createProjectWithWorkingSource（インポートSagaの手順3。image-pipeline.md 5章
// 「インポートSaga」「実装の所在」が正本）。単一トランザクションでProject・
// （queueItemIDがあれば）ExportQueueItem・WorkingSourceRecordを作成する。

extension WorkingSourceStoreLive {
    public func createProjectWithWorkingSource(_ input: CreateWorkingSourceInput) async throws {
        try await database.dbQueue.write { connection in
            try Self.insertProject(connection, input: input)

            // queueItemIDが渡された場合のみExportQueueItemを作成する（キュー経由でない
            // 単体処理では作らない）。ExportQueueItem.batchIDはNOT NULL制約のため、
            // batchIDが欠けた組み合わせは呼び出し元の契約違反としてthrowし、トランザクション
            // 全体をロールバックする（Projectの挿入も残さない）。
            if let queueItemID = input.queueItemID {
                guard let batchID = input.batchID else {
                    throw WorkingSourceStoreError.batchIDMissingForQueueItem(queueItemID: queueItemID)
                }
                try Self.insertWaitingQueueItem(
                    connection,
                    queueItemID: queueItemID,
                    projectID: input.projectID,
                    batchID: batchID
                )
            }

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

    /// キュー経由の取り込み時のみ作成するExportQueueItem。初期状態は必ずwaitingで、
    /// 失敗・一時停止関連の列はすべてNULL（まだ何も起きていないため）。
    private static func insertWaitingQueueItem(
        _ connection: Database,
        queueItemID: ExportQueueItemID,
        projectID: ProjectID,
        batchID: BatchID
    ) throws {
        try connection.execute(
            sql: """
            INSERT INTO ExportQueueItem (
                queueItemID, projectID, batchID, state, failureErrorCode,
                failureIsRetryable, failureOccurredAt, pauseReason
            ) VALUES (?, ?, ?, ?, NULL, NULL, NULL, NULL)
            """,
            arguments: [
                queueItemID.rawValue, projectID.rawValue, batchID.rawValue,
                ExportQueueStateColumn.waiting.rawValue
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
