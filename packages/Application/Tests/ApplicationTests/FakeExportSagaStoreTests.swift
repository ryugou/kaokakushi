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

// reviewer指摘 S-2 の再発防止テスト: 修正前の deleteUnsettledBatches は
// `batchAuthorizations` を無条件に全クリアしていた。本物の契約（export-saga.md 5章 手順2）は
// 「どの ExportRecord からも参照されない Batch 行（未 settle のまま中断されたバッチの残骸）」
// だけを削除するため、settle 済みバッチの認可まで消してしまうのは契約より過剰だった。

private func makeBatchStartExportInput(batchID: BatchID) throws -> StartExportInput {
    let projectID = makeProjectID()
    let hash = try makePreviewRenderHash()
    return StartExportInput(
        projectID: projectID,
        batchID: batchID,
        renderSpec: try makeRenderSpec(),
        exportSetting: makeExportSetting(),
        previewConfirmation: PreviewConfirmation(projectID: projectID, detectionRevision: 0, previewRenderHash: hash)
    )
}

@Suite("FakeExportSagaStore.deleteUnsettledBatches")
struct DeleteUnsettledBatchesTests {
    @Test("settle済みとしてマークされたbatchIDの認可はdeleteUnsettledBatchesで削除されないこと")
    func keepsAuthorizationForSettledBatchOnly() async throws {
        let store = FakeExportSagaStore()
        let settledBatchID = makeBatchID()
        let unsettledBatchID = makeBatchID()
        _ = try await createAuthorizedBatch(store, batchID: settledBatchID)
        _ = try await createAuthorizedBatch(store, batchID: unsettledBatchID)
        await store.markBatchSettled(settledBatchID)

        try await store.deleteUnsettledBatches()

        // settle済みのbatchIDは認可が残るため、startExportのバッチ経路はbatchNotFoundに
        // ならず認可されたExportJobを返す（本物の契約: ExportRecordから参照されるBatch行は
        // 削除されない）。
        let settledDecision = try await store.startExport(
            makeBatchStartExportInput(batchID: settledBatchID), expectedProjectRevision: 0
        )
        guard case .authorized = settledDecision else {
            Issue.record("settle済みbatchIDの認可が残っているならauthorizedであるべき: \(settledDecision)")
            return
        }
        // 未settleのbatchIDはBatch行の残骸としてGCされ、本物と同じ契約でbatchNotFoundになる。
        await #expect(throws: FakeExportSagaStoreError.batchNotFound(unsettledBatchID)) {
            _ = try await store.startExport(
                makeBatchStartExportInput(batchID: unsettledBatchID), expectedProjectRevision: 0
            )
        }
    }

    @Test("settleBatchの実行だけでbatchIDが自動的にsettle済みとしてマークされること（markBatchSettledを使わない）")
    func settleBatchAutomaticallyMarksBatchAsSettled() async throws {
        let store = FakeExportSagaStore()
        let batchID = makeBatchID()
        _ = try await createAuthorizedBatch(store, batchID: batchID)
        let exportID = makeExportID()
        await store.seedRunningJob(makeExportJob(exportID: exportID, batchID: batchID, accountingMode: .batchTrial))
        await store.seedPendingOutput(makeRecordOutputInput(exportID: exportID))

        try await store.settleBatch(batchID, settledAt: Date(timeIntervalSince1970: 1_700_000_300))
        try await store.deleteUnsettledBatches()

        // markBatchSettledを一度も呼んでいない。settleBatchの実行自体がsettledBatchIDsへ
        // 反映していなければ、deleteUnsettledBatchesでこのbatchIDの認可が消えbatchNotFoundに
        // なるはず。
        let decision = try await store.startExport(
            makeBatchStartExportInput(batchID: batchID), expectedProjectRevision: 0
        )
        guard case .authorized = decision else {
            Issue.record("settleBatch実行後はbatchIDがsettle済みとしてマークされているべき: \(decision)")
            return
        }
    }
}

// reviewer指摘（2回目レビュー項目6）の再発防止テスト: 修正前は`batchStartExportOverride`の
// 適用が`batchAuthorizations`の存在確認より前にあり、createBatchを一度も呼んでいない
// batchIDでもoverrideが設定されていれば`.blocked`等を返せてしまっていた。本物の契約
// （createBatchが先に呼ばれていなければstartExportのバッチ経路は到達しえない）を
// 偽実装でも壊さないことを確認する。

@Suite("FakeExportSagaStore.startExport バッチ経路のoverride適用順序")
struct BatchStartExportOverrideOrderingTests {
    @Test("未createBatchのbatchIDはoverride設定下でもbatchNotFoundになること")
    func unknownBatchIDStillThrowsBatchNotFoundEvenWithOverride() async throws {
        let store = FakeExportSagaStore()
        let unknownBatchID = makeBatchID()
        await store.setBatchStartExportOverride { _, _ in
            .blocked(ExportStartBlock(reason: .monthlyLimitReached, limit: nil))
        }

        await #expect(throws: FakeExportSagaStoreError.batchNotFound(unknownBatchID)) {
            _ = try await store.startExport(
                makeBatchStartExportInput(batchID: unknownBatchID), expectedProjectRevision: 0
            )
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
