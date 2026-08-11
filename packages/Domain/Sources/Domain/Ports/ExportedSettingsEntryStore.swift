import Foundation

// ExportedSettingsEntryStore — 「変更せず再書き出し」免除の確定記録を読む永続化ポート
// （export-saga.md 1.2「変更せず再書き出しの免除」、architecture.md 6.2「比較対象を台帳へ持つ」）。
//
// `ExportedSettingsEntry` は既に Accounting/UsageLedger.swift に実装済みのため再宣言しない。
//
// 書き込みは完了操作（settleExport / settleBatch）が Persistence 内部で直接行う
// （architecture.md 6.2「台帳への反映は完了操作で直接行う」）ため、このポートには含めない
// （書き込み用のインターフェースは正本コードブロックに存在しない）。
//
// アクセス修飾（public）の方針は ExportSagaStore.swift・WorkingSourceStore.swift と同じ。

/// 「変更せず再書き出し」免除の判定に使う確定記録の読み取りポート（export-saga.md 1.2）。
public protocol ExportedSettingsEntryStore: Sendable {
    /// 当該 projectID の確定記録を返す（無ければ nil）。
    func loadEntry(for projectID: ProjectID) async throws -> ExportedSettingsEntry?
}
