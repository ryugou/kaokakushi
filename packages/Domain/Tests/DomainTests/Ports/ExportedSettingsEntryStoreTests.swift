import Testing
@testable import Domain
import Foundation

/// Task 10: 「変更せず再書き出し」免除の確定記録を読む永続化ポート
/// （export-saga.md 1.2「変更せず再書き出しの免除」、architecture.md 6.2「比較対象を台帳へ持つ」）。
///
/// `ExportedSettingsEntry` は Accounting/UsageLedger.swift（既存）で実装済みのため
/// ここでは再宣言しない。`ExportedSettingsEntryStore` への最小準拠が `loadEntry` の
/// 引数を記録し戻り値（存在する場合・存在しない場合の両方）を返すことを検証する。

private func makeProjectSettingsHash(fillByte: UInt8 = 0x11) throws -> ProjectSettingsHash {
    try ProjectSettingsHash(bytes: Data(repeating: fillByte, count: 32))
}

private actor FakeExportedSettingsEntryStore: ExportedSettingsEntryStore {
    private(set) var loadEntryCalls: [ProjectID] = []
    var result: ExportedSettingsEntry?

    init(result: ExportedSettingsEntry?) { self.result = result }

    func loadEntry(for projectID: ProjectID) async throws -> ExportedSettingsEntry? {
        loadEntryCalls.append(projectID)
        return result
    }
}

@Test("ExportedSettingsEntryStoreへの最小準拠がloadEntryの引数を記録し確定記録を返す")
func fakeExportedSettingsEntryStoreForwardsArgumentAndReturnsEntry() async throws {
    let projectID = ProjectID(rawValue: UUID())
    let entry = ExportedSettingsEntry(
        projectID: projectID,
        settingsHash: try makeProjectSettingsHash(),
        exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let store = FakeExportedSettingsEntryStore(result: entry)

    let loaded = try await store.loadEntry(for: projectID)

    #expect(loaded == entry)
    let calls = await store.loadEntryCalls
    #expect(calls == [projectID])
}

@Test("ExportedSettingsEntryStoreへの最小準拠は確定記録が無ければnilを返す")
func fakeExportedSettingsEntryStoreReturnsNilWhenMissing() async throws {
    let projectID = ProjectID(rawValue: UUID())
    let store = FakeExportedSettingsEntryStore(result: nil)

    let loaded = try await store.loadEntry(for: projectID)

    #expect(loaded == nil)
    let calls = await store.loadEntryCalls
    #expect(calls == [projectID])
}
