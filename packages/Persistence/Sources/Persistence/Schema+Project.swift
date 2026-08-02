import GRDB

// Project 系テーブル（architecture.md 7.1）。Project・FaceTrack・EffectSetting・
// ExportSetting・WorkingSourceRecordを、この順（親→子）で作成する。
// enum列（sourceRepresentation等）はraw valueをそのままINTEGER列へ保存する前提の
// 型（Int）で列を作るだけに留める。実際の変換コードはStore実装タスク（Task 3以降）
// の担当（Schema.swiftではDomainをimportしない）。

/// `Project`・`FaceTrack`・`EffectSetting`・`ExportSetting`・`WorkingSourceRecord`
/// を作成する。呼び出し順が依存関係（Project→FaceTrack→EffectSetting、
/// Project→ExportSetting、Project→WorkingSourceRecord）を満たすことに注意する。
func createProjectTables(_ database: Database) throws {
    try database.create(table: "Project") { tableDef in
        tableDef.primaryKey("projectID", .blob)
        // projectRevision の増加規則（子行の変更と同一トランザクションで増やす。
        // architecture.md 7.1）は Application 層のプロジェクト変更コマンドが担う。
        // DB トリガを持たないのは欠落ではなく設計判断（コマンド集約が正本）。
        tableDef.column("projectRevision", .integer).notNull()
        tableDef.column("detectionRevision", .integer).notNull()
        tableDef.column("detectionPixelSizeWidth", .integer).notNull()
        tableDef.column("detectionPixelSizeHeight", .integer).notNull()
        // ProjectSourceLocator.photoLibraryLocalIdentifier: 取り込み経路によってnil。
        tableDef.column("photoLibraryLocalIdentifier", .text)
        // OriginalCaptureMetadata由来。EXIFから取得できない場合はnil。
        tableDef.column("captureDateTimeOriginal", .text)
        tableDef.column("captureSubSecTimeOriginal", .text)
        tableDef.column("captureOffsetTimeOriginal", .text)
        tableDef.column("captureUtcMillis", .integer)
        // PHAsset.creationDate由来。取得できる場合のみ。
        tableDef.column("libraryCreationDate", .datetime)
        // SourceRepresentationの判別子。raw valueの割当はStore実装タスクの担当。
        tableDef.column("sourceRepresentation", .integer).notNull()
    }

    try database.create(table: "FaceTrack") { tableDef in
        tableDef.primaryKey("faceTrackID", .blob)
        tableDef.column("projectID", .blob).notNull().references("Project", onDelete: .cascade)
        tableDef.column("createdManually", .boolean).notNull()
        // NormalizedRect
        tableDef.column("boundsLeft", .double).notNull()
        tableDef.column("boundsTop", .double).notNull()
        tableDef.column("boundsRightExclusive", .double).notNull()
        tableDef.column("boundsBottomExclusive", .double).notNull()
        tableDef.column("confidence", .double).notNull()
        tableDef.column("yawDegrees", .double).notNull()
        tableDef.column("pitchDegrees", .double).notNull()
        tableDef.column("rollDegrees", .double).notNull()
        tableDef.column("isSmallFace", .boolean).notNull()
    }

    try database.create(table: "EffectSetting") { tableDef in
        // 1 FaceTrackにつき1設定。PRIMARY KEYがFaceTrackへのFK（CASCADE）を兼ねる。
        tableDef.primaryKey("faceTrackID", .blob).references("FaceTrack", onDelete: .cascade)
        // 一意制約表・外部キー表がEffectSetting.projectIDを明記しているため、
        // FaceTrack経由で辿れる値でも冗長に持つ。
        tableDef.column("projectID", .blob).notNull().references("Project", onDelete: .cascade)
        // op/shape/featherRatio/expansion（RenderOpSpec/MaskShape/FeatherRatio/
        // ExpansionRatios）はいずれも連想値付きのenum/構造体で、永続化フォーマットは
        // このタスクでは未確定。単一のBLOB列として列の存在と外部キー制約のみを
        // 保証する。シリアライズ方式はEffectSettingを読み書きするタスクの担当。
        tableDef.column("effectSpecData", .blob).notNull()
    }

    try database.create(table: "ExportSetting") { tableDef in
        // 1プロジェクトにつき1設定。PRIMARY KEYがProjectへのFK（CASCADE）を兼ねる。
        tableDef.primaryKey("projectID", .blob).references("Project", onDelete: .cascade)
        // OutputAspect / ImageFormatの判別子。raw valueの割当はStore実装タスクの担当。
        tableDef.column("outputAspect", .integer).notNull()
        tableDef.column("outputFormat", .integer).notNull()
        tableDef.column("compressionQuality", .double).notNull()
        // MetadataPolicyを展開したもの。
        tableDef.column("removeLocation", .boolean).notNull()
        tableDef.column("removeDeviceInfo", .boolean).notNull()
        tableDef.column("removeSoftwareInfo", .boolean).notNull()
        tableDef.column("keepCaptureDate", .boolean).notNull()
    }

    try database.create(table: "WorkingSourceRecord") { tableDef in
        // PRIMARY KEYがProjectへのFK（CASCADE）を兼ねる。
        tableDef.primaryKey("projectID", .blob).references("Project", onDelete: .cascade)
        // WorkingSourceFileRef（kindは.processingTemporary固定なので列は持たない）。
        tableDef.column("sourceFileID", .blob).notNull()
        tableDef.column("createdAt", .datetime).notNull()
    }
}
