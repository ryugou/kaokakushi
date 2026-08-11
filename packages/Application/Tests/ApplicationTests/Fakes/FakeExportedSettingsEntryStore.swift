import Foundation
import Domain

// FakeExportedSettingsEntryStore — `ExportedSettingsEntryStore`
// (Domain/Ports/ExportedSettingsEntryStore.swift) の in-memory 偽実装（Issue #7 Task 10）。
//
// 正本は `ExportedSettingsEntryStore` の doc コメント。実 Persistence には依存しない。
//
// Fakes 配下の型はテストターゲット外から参照されないため internal で足りる
// （FakeWorkingSourceStore.swift と同じ方針）。

actor FakeExportedSettingsEntryStore: ExportedSettingsEntryStore {
    // MARK: - 呼び出し記録

    private(set) var loadEntryCalls: [ProjectID] = []

    // MARK: - 注入可能な失敗

    var loadEntryFailure: Error?

    // MARK: - in-memory 状態

    private var entries: [ProjectID: ExportedSettingsEntry] = [:]

    init() {}

    // MARK: - 失敗注入セッター（actor 隔離のため外部から直接代入できない）

    func setLoadEntryFailure(_ value: Error?) { loadEntryFailure = value }

    /// テストが「確定記録あり」のシナリオ用に直接注入する
    func seedEntry(_ entry: ExportedSettingsEntry) {
        entries[entry.projectID] = entry
    }

    // MARK: - ExportedSettingsEntryStore

    func loadEntry(for projectID: ProjectID) async throws -> ExportedSettingsEntry? {
        loadEntryCalls.append(projectID)
        if let failure = loadEntryFailure { throw failure }
        return entries[projectID]
    }
}
