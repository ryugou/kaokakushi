import Foundation
import Testing
import GRDB
import Domain
@testable import Persistence

// ExportedSettingsEntryStoreLiveのテスト（export-saga.md 1.2「変更せず再書き出しの免除」・
// architecture.md 6.2「比較対象を台帳へ持つ」が正本。Issue #7 Task 10）。
//
// 書き込み（upsert）はExportSagaStoreLiveがsettle系トランザクション内で直接行うため、
// このLive自体はloadEntryのみを持つ。ここではloadEntryの往復と、settleExport経由で
// upsertされた行を読めることの両方を検証する（raw SQL挿入だけでなく、実際の書き込み
// 経路とも噛み合っていることを確認するため）。

@Suite("ExportedSettingsEntryStoreLive")
struct ExportedSettingsEntryStoreTests {
    @Test("登録済みprojectIDのエントリを読め、settingsHashとexportedAtが一致すること")
    func loadsExistingEntryForRegisteredProject() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertExportedSettingsEntry(connection, projectID: projectID.rawValue)
        }
        let store = ExportedSettingsEntryStoreLive(database: database)

        let entry = try await store.loadEntry(for: projectID)

        #expect(entry?.projectID == projectID)
        #expect(entry?.settingsHash.bytes == schemaTestHash(seed: 0xCD))
        #expect(entry?.exportedAt == schemaTestReferenceDate)
    }

    @Test("未登録のprojectIDではnilを返すこと")
    func returnsNilForUnregisteredProject() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ExportedSettingsEntryStoreLive(database: database)

        let entry = try await store.loadEntry(for: ProjectID(rawValue: UUID()))

        #expect(entry == nil)
    }

    @Test("settingsHashのバイト長がProjectSettingsHashの想定長(32バイト)と異なる行にinvalidSettingsHashLengthをthrowすること")
    func loadEntryThrowsForInvalidSettingsHashLength() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        // 想定長32バイトに対し1バイト短い31バイトのハッシュを直接挿入し、settle系書き込み
        // 経路を経由しない手動改変・マイグレーション漏れ相当のデータ破損を模す。
        let invalidHash = Data(repeating: 0xEE, count: 31)
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try connection.execute(
                sql: """
                INSERT INTO ExportedSettingsEntry (projectID, settingsHash, exportedAt)
                VALUES (?, ?, ?)
                """,
                arguments: [projectID.rawValue, invalidHash, schemaTestReferenceDate]
            )
        }
        let store = ExportedSettingsEntryStoreLive(database: database)

        do {
            _ = try await store.loadEntry(for: projectID)
            Issue.record("31バイトのsettingsHashを持つ行が存在するのにloadEntryがthrowしなかった")
        } catch let error as ExportedSettingsEntryStoreError {
            guard case .invalidSettingsHashLength(let errorProjectID, let byteCount) = error else {
                Issue.record("期待したエラーケース(invalidSettingsHashLength)ではない: \(error)")
                return
            }
            #expect(errorProjectID == projectID)
            #expect(byteCount == 31)
        } catch {
            Issue.record("ExportedSettingsEntryStoreError以外がthrowされた: \(error)")
        }
    }

    @Test("settleExport経由でupsertされたエントリを読めること")
    func loadsEntryUpsertedThroughSettleExport() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let sagaStore = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID)
        let job = try await authorizeExportJob(store: sagaStore, projectID: projectID)
        try await sagaStore.recordGeneratedOutput(RecordOutputInput(
            exportID: job.exportID,
            outputFile: makeOutputFileRefFixture(),
            outputByteSize: 2_048,
            outputSHA256: Data(repeating: 0x40, count: 32)
        ))
        try await sagaStore.settleExport(job.exportID)
        let expectedFields = try exportedSettingsEntryFields(database, projectID: projectID.rawValue)
        let entryStore = ExportedSettingsEntryStoreLive(database: database)

        let entry = try await entryStore.loadEntry(for: projectID)

        #expect(entry?.projectID == projectID)
        #expect(entry?.settingsHash.bytes == expectedFields?.settingsHash)
        #expect(entry?.exportedAt == expectedFields?.exportedAt)
    }
}
