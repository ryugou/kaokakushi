import Foundation
import Testing
import Domain

// FakeExportSagaStore.recordGeneratedOutput の重複判定と settleExport / settleBatch の
// 消費カウンタ分離が正本（export-saga.md 3章・1.4）と一致することを検証する。
//
// Task 3 レビュー Critical 2 の再発防止テスト: 修正前は重複判定が
// `existingExportID != input.exportID` で自分自身を除外していたため、同一 exportID への
// 2回目の recordGeneratedOutput が成功し上書きされていた（このテストは修正前のコードでは
// 失敗する）。
// Task 3 レビュー Warning の再発防止テスト: 修正前は ledgerConsumedCount という単一カウンタに
// 畳まれており、accountingMode ごとの消費先を区別できなかった。

@Suite("FakeExportSagaStore.recordGeneratedOutput 重複判定")
struct FakeExportSagaStoreDuplicateTests {
    @Test("同一exportIDへの2回目の呼び出しはduplicatePendingOutputForExportIDをthrowする")
    func throwsOnDuplicateExportID() async throws {
        let exportID = makeExportID()
        let store = FakeExportSagaStore()
        await store.seedRunningJob(makeExportJob(exportID: exportID))
        try await store.recordGeneratedOutput(makeRecordOutputInput(exportID: exportID))

        await #expect(throws: FakeExportSagaStoreError.duplicatePendingOutputForExportID(exportID)) {
            try await store.recordGeneratedOutput(makeRecordOutputInput(exportID: exportID))
        }
    }

    @Test("別exportIDでも同一projectIDに未確定OutputRecordがあればduplicatePendingOutputをthrowする")
    func throwsOnDuplicateProjectIDAcrossDifferentExportIDs() async throws {
        let projectID = makeProjectID()
        let firstExportID = makeExportID()
        let secondExportID = makeExportID()
        let store = FakeExportSagaStore()
        await store.seedRunningJob(makeExportJob(exportID: firstExportID, projectID: projectID))
        await store.seedRunningJob(makeExportJob(exportID: secondExportID, projectID: projectID))
        try await store.recordGeneratedOutput(makeRecordOutputInput(exportID: firstExportID))

        await #expect(throws: FakeExportSagaStoreError.duplicatePendingOutput(projectID: projectID)) {
            try await store.recordGeneratedOutput(makeRecordOutputInput(exportID: secondExportID))
        }
    }
}

@Suite("FakeExportSagaStore の消費カウンタ分離")
struct FakeExportSagaStoreConsumptionTests {
    @Test("settleExport: freeMonthlyConsumeはmeteredConsumedCountだけを1加算する")
    func settleExportIncrementsMeteredCountForFreeMonthlyConsume() async throws {
        let exportID = makeExportID()
        let store = FakeExportSagaStore()
        await store.seedRunningJob(makeExportJob(exportID: exportID, accountingMode: .freeMonthlyConsume))
        await store.seedPendingOutput(makeRecordOutputInput(exportID: exportID))

        try await store.settleExport(exportID)

        #expect(await store.meteredConsumedCount == 1)
        #expect(await store.trialCreditConsumedCount == 0)
    }

    @Test("settleExport: paidUnlimitedはどちらのカウンタも増やさない")
    func settleExportDoesNotConsumeForPaidUnlimited() async throws {
        let exportID = makeExportID()
        let store = FakeExportSagaStore()
        await store.seedRunningJob(makeExportJob(exportID: exportID, accountingMode: .paidUnlimited))
        await store.seedPendingOutput(makeRecordOutputInput(exportID: exportID))

        try await store.settleExport(exportID)

        #expect(await store.meteredConsumedCount == 0)
        #expect(await store.trialCreditConsumedCount == 0)
    }

    @Test("settleBatch: batchTrialはtrialCreditConsumedCountを確定件数分だけ加算する")
    func settleBatchIncrementsTrialCreditCountPerSettledOutput() async throws {
        let batchID = makeBatchID()
        let firstExportID = makeExportID()
        let secondExportID = makeExportID()
        let store = FakeExportSagaStore()
        for exportID in [firstExportID, secondExportID] {
            await store.seedRunningJob(
                makeExportJob(exportID: exportID, batchID: batchID, accountingMode: .batchTrial)
            )
            await store.seedPendingOutput(makeRecordOutputInput(exportID: exportID))
        }

        try await store.settleBatch(batchID, settledAt: Date(timeIntervalSince1970: 1_700_000_200))

        #expect(await store.trialCreditConsumedCount == 2)
        #expect(await store.meteredConsumedCount == 0)
    }
}
