import Foundation

// 書き出し Saga の永続化ポート（export-saga.md 0 章「Application が使う永続化ポート」）。
//
// `ExportSagaStore` の各メソッドの doc コメントは事前条件・トランザクション境界を含めて
// 正本から一字一句転記する（省略しない。運用時にここを読めば「何が」「いつ」「どこまで」
// 確定するかが分かる必要があるため）。
//
// このファイルには含めない型: `ExportQueueItemID`（Identifiers.swift、Task 1）・
// `OutputAspect` / `MetadataPolicy` / `ExportSetting`（Accounting/ExportSetting.swift、
// Task 3）は既に実装済みのため再宣言しない。`OutputDeliveryStore` と
// `OutputDeliverySnapshot` は寿命・関心が異なるため OutputDeliveryStore.swift に分離する
// （spec のファイル配置どおり）。
//
// アクセス修飾（public）は正本の疑似コードには現れないが、Application 等の他パッケージが
// Domain の公開 API として参照するために必要（Identifiers.swift 等、既存ファイルの
// public 方針に合わせる）。protocol の各メソッドには `public` を付けない
// （Swift はプロトコル要件へのアクセス修飾を許さず、protocol 自体の修飾を継承するため）。

/// Application が使う書き出し Saga の永続化ポート（export-saga.md 0 章）。
public protocol ExportSagaStore: Sendable {
    /// 認可を評価し ExportJob を挿入する（1 章）。expectedProjectRevision と不一致なら throw
    func startExport(_ input: StartExportInput, expectedProjectRevision: Int64) async throws -> ExportStartDecision
    /// 確認用の OutputRecord(settledAt: nil) を作成する（3 章）。同じ projectID の未確定 OutputRecord が
    /// 既に存在すれば throw（部分 UNIQUE 制約。詳細は 3 章）。台帳・ExportRecord・キュー・WorkingSourceRecord には触れない
    func recordGeneratedOutput(_ input: RecordOutputInput) async throws
    /// 完了（単体専用。ExportJob.batchID == nil でなければ throw）。単一トランザクションで、台帳の加算または
    /// トライアルクレジットの消費・settledAt の確定・ExportRecord の作成・confirmed 設定エントリの更新・
    /// キュー項目の completed 更新・WorkingSourceRecord の削除を行う（3 章）。ここが唯一の確定境界。
    /// 削除する WorkingSourceRecord の WorkingSourceFileRef は同一トランザクションで PendingFileDeletion へ
    /// 登録する（実削除はコミット後、失敗時は起動時再試行。削除経路の正本はアーキテクチャ設計 7.5）。最後に ExportJob を削除する
    func settleExport(_ exportID: ExportID) async throws
    /// 完了（バッチ）。対象 batchID の未確定 OutputRecord をすべて対象に、settleExport と同じ内容
    /// （WorkingSourceRecord 削除に伴う PendingFileDeletion 登録を含む）を単一トランザクションで一括確定する。
    /// settledAt は呼び出し側が渡した時刻で全件に統一する。事前条件は 3 章
    func settleBatch(_ batchID: BatchID, settledAt: Date) async throws
    /// 失敗・キャンセル・やり直し・中断。ExportJob 行を削除する。対応する OutputRecord が存在すれば
    /// 同一トランザクションで削除し、その出力ファイル（存在すれば）と temporaryFiles（手順 1〜3 で
    /// 生成した一時ファイル。呼び出し元の生成パイプラインが保持する参照を渡す）を
    /// PendingFileDeletion へ登録する（実削除はコミット後。削除経路の正本はアーキテクチャ設計 7.5）。
    /// WorkingSourceRecord は削除しない（4 章）。台帳は未確定のため触れない。
    /// ExportJob 行が無ければ何もしない（temporaryFiles の登録も行わない。冪等）
    func discardExport(_ exportID: ExportID, temporaryFiles: [ManagedFileRef]) async throws
    /// 起動時復旧の入力（5 章）
    func loadRunningJobs() async throws -> [ExportJob]
    /// 起動時復旧。ExportJob 行と、対応する未確定（settledAt IS NULL）OutputRecord をまとめて削除する（5 章）
    func deleteRunningJobs(_ exportIDs: [ExportID]) async throws
}

/// 手順 0 の入力（export-saga.md 0 章）。
/// 正本は Sendable のみ（PreviewConfirmation は Equatable だが StartExportInput 自体を
/// 値として比較する用途が正本コードブロックに無いため Equatable を追加しない）
public struct StartExportInput: Sendable {
    public let projectID: ProjectID
    public let batchID: BatchID?
    public let queueItemID: ExportQueueItemID?   // 単体書き出しでは nil
    public let renderSpec: RenderSpec
    public let exportSetting: ExportSetting
    public let previewConfirmation: PreviewConfirmation   // 1.1

    public init(
        projectID: ProjectID,
        batchID: BatchID?,
        queueItemID: ExportQueueItemID?,
        renderSpec: RenderSpec,
        exportSetting: ExportSetting,
        previewConfirmation: PreviewConfirmation
    ) {
        self.projectID = projectID
        self.batchID = batchID
        self.queueItemID = queueItemID
        self.renderSpec = renderSpec
        self.exportSetting = exportSetting
        self.previewConfirmation = previewConfirmation
    }
}

/// 手順4（生成）の入力。ExportJob から導出できない値だけを渡す（export-saga.md 0 章）。
/// 正本は Sendable のみ（outputSHA256 等のバイト列を含み、値としての比較用途が
/// 正本コードブロックに無いため Equatable を追加しない。OutputRecord と同じ判断）
public struct RecordOutputInput: Sendable {
    public let exportID: ExportID
    public let outputFile: OutputFileRef
    public let outputByteSize: Int64
    public let outputSHA256: Data

    public init(exportID: ExportID, outputFile: OutputFileRef, outputByteSize: Int64, outputSHA256: Data) {
        self.exportID = exportID
        self.outputFile = outputFile
        self.outputByteSize = outputByteSize
        self.outputSHA256 = outputSHA256
    }
}

/// startExport の判定結果（export-saga.md 0 章）。
public enum ExportStartDecision: Sendable {
    case blocked(ExportStartBlock)
    case authorized(ExportJob)
}
