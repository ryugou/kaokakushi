import Foundation

// 書き出しジョブの型群（export-saga.md 2 章「ExportJob と OutputRecord」）。
//
// ExportJob は状態を表すフィールドを持たない。行の存在そのものが「生成中、または生成済みで
// 完了操作の確認待ち」を表す（export-saga.md 2 章）。

/// 正本は Sendable のみ（Authorization / OutputDeliveryDescriptor の等価性比較は
/// 正本コードブロックの用途に含まれないため Equatable を追加しない）
public struct ExportJob: Sendable {
    public let exportID: ExportID
    public let projectID: ProjectID
    public let batchID: BatchID?
    public let queueItemID: ExportQueueItemID?      // 単体書き出しでは nil。手順 0 で固定する
    public let authorization: ExportAuthorization   // 開始時に固定する（1.5）
    public let delivery: OutputDeliveryDescriptor   // 認可時に確定。生成時に OutputRecord へコピーする

    public init(
        exportID: ExportID,
        projectID: ProjectID,
        batchID: BatchID?,
        queueItemID: ExportQueueItemID?,
        authorization: ExportAuthorization,
        delivery: OutputDeliveryDescriptor
    ) {
        self.exportID = exportID
        self.projectID = projectID
        self.batchID = batchID
        self.queueItemID = queueItemID
        self.authorization = authorization
        self.delivery = delivery
    }
}

public struct OutputDeliveryDescriptor: Sendable {
    public let format: ImageFormat
    public let suggestedCreationDate: Date?

    public init(format: ImageFormat, suggestedCreationDate: Date?) {
        self.format = format
        self.suggestedCreationDate = suggestedCreationDate
    }
}
