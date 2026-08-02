import Foundation

// 出力レコードの型群（export-saga.md 3 章「手順」+ architecture.md 7.5「履歴・出力・
// スタンプの寿命」）。

/// 手順4（生成）が作る確認用レコード（export-saga.md 3 章）。
/// 正本は Sendable のみ（outputSHA256 等のバイト列を含み、値としての比較用途が
/// 正本コードブロックに無いため Equatable を追加しない）
public struct OutputRecord: Sendable {
    public let exportID: ExportID
    public let projectID: ProjectID
    public let batchID: BatchID?
    public let outputFile: OutputFileRef
    public let outputByteSize: Int64
    public let outputSHA256: Data
    public let state: OutputState
    public let generatedAt: Date             // 生成完了時刻。settle の前後で不変
    public let settledAt: Date?              // settle（手順5）で確定する。nil の間は無期限に保護されない
    public let expiresAt: Date?              // settledAt + 24h。settle 時に確定する。settledAt が nil の間は nil
    public let format: ImageFormat
    public let suggestedCreationDate: Date?

    public init(
        exportID: ExportID,
        projectID: ProjectID,
        batchID: BatchID?,
        outputFile: OutputFileRef,
        outputByteSize: Int64,
        outputSHA256: Data,
        state: OutputState,
        generatedAt: Date,
        settledAt: Date?,
        expiresAt: Date?,
        format: ImageFormat,
        suggestedCreationDate: Date?
    ) {
        self.exportID = exportID
        self.projectID = projectID
        self.batchID = batchID
        self.outputFile = outputFile
        self.outputByteSize = outputByteSize
        self.outputSHA256 = outputSHA256
        self.state = state
        self.generatedAt = generatedAt
        self.settledAt = settledAt
        self.expiresAt = expiresAt
        self.format = format
        self.suggestedCreationDate = suggestedCreationDate
    }
}

// raw value は DB 列値（architecture.md 7.5 のコードブロックが正本。
// スキーマ移行をまたぐため case の宣言順に依存させない）。
public enum OutputState: UInt32, Sendable, Equatable {
    case generated = 1
    case deliveryUnknown = 2
    case delivered = 3
}

public extension OutputRecord {
    /// 受け取れていない可能性がある。判定はすべてこの述語を使う（settledAt != nil が前提）
    var isUndelivered: Bool {
        state == .generated || state == .deliveryUnknown
    }
}

/// 手順5（settle）で ExportJob の値だけから導出する確定記録（export-saga.md 3 章）。
/// 正本は Sendable のみ
public struct ExportRecord: Sendable {
    public let exportID: ExportID
    public let projectID: ProjectID
    public let batchID: BatchID?
    public let exportedAt: Date              // settledAt と同じ
    public let accountingMode: ExportAccountingMode
    public let format: ImageFormat
    public let outputByteSize: Int64

    public init(
        exportID: ExportID,
        projectID: ProjectID,
        batchID: BatchID?,
        exportedAt: Date,
        accountingMode: ExportAccountingMode,
        format: ImageFormat,
        outputByteSize: Int64
    ) {
        self.exportID = exportID
        self.projectID = projectID
        self.batchID = batchID
        self.exportedAt = exportedAt
        self.accountingMode = accountingMode
        self.format = format
        self.outputByteSize = outputByteSize
    }
}
