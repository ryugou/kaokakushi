import Foundation
import Testing
import Domain
@testable import Persistence

// ExportSagaStoreLive.settleExport/settleBatchが行う台帳更新とconfirmed設定エントリ更新の
// テスト（architecture.md 6.3「時間の扱い」・export-saga.md 3章「手順」手順5・
// canonical-schema.md 5.2「ProjectSettingsHash」が正本）。

@Suite("ExportSagaStoreLive.settle 台帳・confirmed設定エントリ")
struct ExportSagaStoreSettleLedgerTests {
    @Test("月をまたぐsettleでconsumedExportIDsがリセットされperiodが更新され、trialConsumedExportIDsは保持されること")
    func rollsPeriodAndPreservesTrialConsumedIDsAcrossMonthBoundary() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID, plan: 1, status: 1)
        let staleConsumedIDs = makeExportIDs(count: 2)
        let preservedTrialIDs = makeExportIDs(count: 3)
        try await database.dbQueue.write { connection in
            try insertUsageLedgerRowWithIDs(
                connection, periodYear: 2_023, periodMonth: 10,
                consumedExportIDs: staleConsumedIDs, trialConsumedExportIDs: preservedTrialIDs
            )
        }
        let job = try await authorizeExportJob(store: store, projectID: projectID)
        #expect(job.authorization.accountingMode == .freeMonthlyConsume)
        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: job.exportID, outputFile: makeOutputFileRefFixture(), outputByteSize: 1_024,
            outputSHA256: Data(repeating: 0x60, count: 32)
        ))

        try await store.settleExport(job.exportID)

        let ledger = try usageLedgerFields(database)
        #expect(ledger?.periodYear == 2_023)
        #expect(ledger?.periodMonth == 11)
        #expect(ledger?.consumedExportIDs == Set([job.exportID]))
        #expect(ledger?.trialConsumedExportIDs == preservedTrialIDs)
    }

    @Test("freeMonthlyConsumeの消費がstartExport時ではなくsettle時にUsageLedgerへ記録されること")
    func recordsFreeMonthlyConsumptionAtSettleNotAtStart() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID, plan: 1, status: 1)
        let job = try await authorizeExportJob(store: store, projectID: projectID)
        #expect(job.authorization.accountingMode == .freeMonthlyConsume)
        #expect(try !usageLedgerRowExists(database))

        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: job.exportID, outputFile: makeOutputFileRefFixture(), outputByteSize: 1_024,
            outputSHA256: Data(repeating: 0x61, count: 32)
        ))
        #expect(try !usageLedgerRowExists(database))

        try await store.settleExport(job.exportID)

        let ledger = try usageLedgerFields(database)
        #expect(ledger?.consumedExportIDs.contains(job.exportID) == true)
    }

    @Test("ExportedSettingsEntry.settingsHashがstartExport時のrenderSpec/exportSettingから計算した値と一致すること")
    func computesSettingsHashFromStartExportRenderSpecAndExportSetting() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID)
        let input = try makeStartExportInputFixture(projectID: projectID)
        let decision = try await store.startExport(input, expectedProjectRevision: 0)
        guard case let .authorized(job) = decision else {
            Issue.record("authorizedであるべき")
            return
        }
        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: job.exportID, outputFile: makeOutputFileRefFixture(), outputByteSize: 1_024,
            outputSHA256: Data(repeating: 0x62, count: 32)
        ))

        try await store.settleExport(job.exportID)

        let expectedHash = try projectSettingsHash(
            renderSpec: input.renderSpec, exportSetting: input.exportSetting, digest: CryptoKitSha256Digest()
        )
        let entry = try exportedSettingsEntryFields(database, projectID: projectID.rawValue)
        #expect(entry?.settingsHash == expectedHash.bytes)
    }

    @Test("同一projectIDへの2回目のsettleでExportedSettingsEntryがUPSERT（行数1のまま更新）されること")
    func upsertsExportedSettingsEntryOnRepeatedSettleForSameProject() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeExportSagaStore(database: database)
        let projectID = ProjectID(rawValue: UUID())
        try await seedAuthorizedProject(database, projectID: projectID)
        let firstJob = try await authorizeExportJob(store: store, projectID: projectID)
        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: firstJob.exportID, outputFile: makeOutputFileRefFixture(), outputByteSize: 1_024,
            outputSHA256: Data(repeating: 0x63, count: 32)
        ))
        try await store.settleExport(firstJob.exportID)
        let firstHash = try exportedSettingsEntryFields(database, projectID: projectID.rawValue)?.settingsHash

        let secondInput = try makeStartExportInputFixture(projectID: projectID, outputFormat: .png)
        let secondDecision = try await store.startExport(secondInput, expectedProjectRevision: 0)
        guard case let .authorized(secondJob) = secondDecision else {
            Issue.record("2回目のauthorizedであるべき")
            return
        }
        try await store.recordGeneratedOutput(RecordOutputInput(
            exportID: secondJob.exportID, outputFile: makeOutputFileRefFixture(), outputByteSize: 2_048,
            outputSHA256: Data(repeating: 0x64, count: 32)
        ))
        try await store.settleExport(secondJob.exportID)

        let secondExpectedHash = try projectSettingsHash(
            renderSpec: secondInput.renderSpec, exportSetting: secondInput.exportSetting,
            digest: CryptoKitSha256Digest()
        )
        let updatedEntry = try exportedSettingsEntryFields(database, projectID: projectID.rawValue)
        #expect(updatedEntry?.settingsHash == secondExpectedHash.bytes)
        #expect(updatedEntry?.settingsHash != firstHash)
        let entryCount: Int = try await database.dbQueue.read { connection in
            try countExportedSettingsEntryRows(connection, projectID: projectID.rawValue)
        }
        #expect(entryCount == 1)
    }
}
