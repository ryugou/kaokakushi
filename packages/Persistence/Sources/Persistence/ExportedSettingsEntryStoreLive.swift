import Foundation
import Domain
import GRDB

// ExportedSettingsEntryStoreの実装（export-saga.md 1.2「変更せず再書き出しの免除」・
// architecture.md 6.2「比較対象を台帳へ持つ」が正本。Issue #7 Task 10）。
//
// 書き込みはExportSagaStoreLive+SettleSteps.swiftのupsertExportedSettingsEntryRowが、
// settleExport/settleBatchの単一トランザクション内で直接行う
// （ExportedSettingsEntryStoreプロトコルのdocコメント「書き込みは完了操作が
// Persistence内部で直接行うためこのポートには含めない」）。このファイルは
// 読み取り専用のloadEntry(for:)のみを実装する。

/// ExportedSettingsEntryStoreLiveが送出する専用エラー（MaintenanceStoreError/
/// ExportSagaStoreErrorと同じ方針: Sendable, Equatable, LocalizedError）。
public enum ExportedSettingsEntryStoreError: Error, Sendable, Equatable {
    /// loadEntry: ExportedSettingsEntry.settingsHash列のバイト長がProjectSettingsHashの
    /// 想定長（32バイト。CommonValues.swift）と一致しない。settle系（唯一の書き込み経路）は
    /// 常に32バイトのProjectSettingsHashをそのまま書き込むため、この不一致はデータ破損か
    /// 手動でのDB改変を疑うべき状態であり、握りつぶさずthrowする。
    case invalidSettingsHashLength(projectID: ProjectID, byteCount: Int)
}

extension ExportedSettingsEntryStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSettingsHashLength(let projectID, let byteCount):
            return """
            ExportedSettingsEntryStore: projectID=\(projectID.rawValue.uuidString) の \
            ExportedSettingsEntry.settingsHash（バイト長 \(byteCount)）がProjectSettingsHashの \
            想定長（32バイト）と一致しません。settleExport/settleBatchが書き込んだ値と \
            異なる形式で上書きされていないか、ExportedSettingsEntryテーブルが \
            壊れていないか確認してください。
            """
        }
    }
}

/// ExportedSettingsEntryStoreの実装。「変更せず再書き出し」免除の判定に使う確定記録
/// （export-saga.md 1.2）を読む専用。書き込みはExportSagaStoreLiveがsettle系トランザクション
/// 内で直接行うため、このLiveはloadEntryだけを持つ（MaintenanceStoreLiveと同じく
/// AppDatabaseのdbQueueだけに依存し、ファイル実体には一切触れない）。
public struct ExportedSettingsEntryStoreLive: ExportedSettingsEntryStore {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// 当該projectIDの確定記録を返す（無ければnil）。settingsHashのバイト長が
    /// ProjectSettingsHashの想定長と一致しなければ握りつぶさずthrowする
    /// （invalidColumnValue系と同じ「握りつぶさずfail-closedで報告する」方針）。
    public func loadEntry(for projectID: ProjectID) async throws -> ExportedSettingsEntry? {
        let row: Row? = try await database.dbQueue.read { connection in
            try Row.fetchOne(
                connection,
                sql: "SELECT settingsHash, exportedAt FROM ExportedSettingsEntry WHERE projectID = ?",
                arguments: [projectID.rawValue]
            )
        }
        guard let row else { return nil }
        let hashBytes: Data = row["settingsHash"]
        guard let settingsHash = try? ProjectSettingsHash(bytes: hashBytes) else {
            throw ExportedSettingsEntryStoreError.invalidSettingsHashLength(
                projectID: projectID, byteCount: hashBytes.count
            )
        }
        return ExportedSettingsEntry(projectID: projectID, settingsHash: settingsHash, exportedAt: row["exportedAt"])
    }
}
