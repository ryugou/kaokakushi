import Testing
@testable import Domain
import Foundation

/// Task 4: 書き出し Saga の永続化ポート（export-saga.md 0 章）。
///
/// `ExportSagaStore` は具体的なロジックを持たないプロトコルのため、ここでは
/// (1) プロトコルへの最小準拠がコンパイルでき、各メソッドがシグネチャどおりの引数を
/// 受け取ること、(2) 入力型（StartExportInput / RecordOutputInput）が全フィールドを
/// 保持すること、(3) ExportStartDecision の2ケースを区別できることを検証する。

private func makeProjectID() -> ProjectID { ProjectID(rawValue: UUID()) }

private func makeExportSetting() -> ExportSetting {
    ExportSetting(
        outputAspect: .square,
        outputFormat: .jpeg,
        compressionQuality: 0.9,
        metadataPolicy: MetadataPolicy(
            removeLocation: true,
            removeDeviceInfo: true,
            removeSoftwareInfo: true,
            keepCaptureDate: false
        )
    )
}

private func makePreviewConfirmation(projectID: ProjectID) throws -> PreviewConfirmation {
    PreviewConfirmation(
        projectID: projectID,
        detectionRevision: 1,
        previewRenderHash: try PreviewRenderHash(bytes: Data(repeating: 0x01, count: 32))
    )
}

private func makeExportJob(exportID: ExportID, projectID: ProjectID) -> ExportJob {
    let entitlement = Entitlement(
        plan: .free,
        status: .active,
        expiresAt: nil,
        lastVerifiedAt: Date(timeIntervalSince1970: 0),
        isSandbox: false
    )
    return ExportJob(
        exportID: exportID,
        projectID: projectID,
        batchID: nil,
        queueItemID: nil,
        authorization: ExportAuthorization(
            entitlementSnapshot: entitlement,
            accountingMode: .freeMonthlyConsume,
            authorizedAt: Date(timeIntervalSince1970: 100)
        ),
        delivery: OutputDeliveryDescriptor(format: .jpeg, suggestedCreationDate: nil)
    )
}

// MARK: - StartExportInput / RecordOutputInput のフィールド保持

@Test("StartExportInputが全フィールドを保持し単体書き出しではbatchIDとqueueItemIDにnilを許容する")
func startExportInputHoldsAllFieldsAndAllowsNilForSingleExport() throws {
    let projectID = makeProjectID()
    let renderSpec = try makeRenderSpec()
    let exportSetting = makeExportSetting()
    let previewConfirmation = try makePreviewConfirmation(projectID: projectID)

    let subject = StartExportInput(
        projectID: projectID,
        batchID: nil,
        queueItemID: nil,
        renderSpec: renderSpec,
        exportSetting: exportSetting,
        previewConfirmation: previewConfirmation
    )

    #expect(subject.projectID == projectID)
    #expect(subject.batchID == nil)
    #expect(subject.queueItemID == nil)
    #expect(subject.renderSpec == renderSpec)
    #expect(subject.exportSetting == exportSetting)
    #expect(subject.previewConfirmation == previewConfirmation)
}

@Test("StartExportInputはバッチ書き出しでbatchIDとqueueItemIDを保持する")
func startExportInputHoldsBatchAndQueueItemIDsWhenPresent() throws {
    let projectID = makeProjectID()
    let batchID = BatchID(rawValue: UUID())
    let queueItemID = ExportQueueItemID(rawValue: UUID())

    let subject = StartExportInput(
        projectID: projectID,
        batchID: batchID,
        queueItemID: queueItemID,
        renderSpec: try makeRenderSpec(),
        exportSetting: makeExportSetting(),
        previewConfirmation: try makePreviewConfirmation(projectID: projectID)
    )

    #expect(subject.batchID == batchID)
    #expect(subject.queueItemID == queueItemID)
}

@Test("RecordOutputInputが全フィールドを保持する")
func recordOutputInputHoldsAllFields() {
    let exportID = ExportID(rawValue: UUID())
    let outputFile = makeOutputFileRef()
    let sha256 = Data(repeating: 0x22, count: 32)

    let subject = RecordOutputInput(
        exportID: exportID,
        outputFile: outputFile,
        outputByteSize: 2048,
        outputSHA256: sha256
    )

    #expect(subject.exportID == exportID)
    #expect(subject.outputFile == outputFile)
    #expect(subject.outputByteSize == 2048)
    #expect(subject.outputSHA256 == sha256)
}

// MARK: - ExportStartDecision の2ケース

@Test("ExportStartDecision.blockedはExportStartBlockを保持する")
func exportStartDecisionBlockedHoldsBlock() {
    let block = ExportStartBlock(reason: .monthlyLimitReached, limit: 10)
    let subject = ExportStartDecision.blocked(block)
    guard case let .blocked(heldBlock) = subject else {
        Issue.record("blockedケースであるべき")
        return
    }
    #expect(heldBlock == block)
}

@Test("ExportStartDecision.authorizedはExportJobを保持する")
func exportStartDecisionAuthorizedHoldsJob() {
    let job = makeExportJob(exportID: ExportID(rawValue: UUID()), projectID: makeProjectID())
    let subject = ExportStartDecision.authorized(job)
    guard case let .authorized(heldJob) = subject else {
        Issue.record("authorizedケースであるべき")
        return
    }
    #expect(heldJob.exportID == job.exportID)
}

// MARK: - ExportSagaStore への最小準拠（引数がシグネチャどおり伝わることを検証）

private actor FakeExportSagaStore: ExportSagaStore {
    private(set) var startExportCalls: [(input: StartExportInput, expectedProjectRevision: Int64)] = []
    private(set) var recordGeneratedOutputCalls: [RecordOutputInput] = []
    private(set) var settleExportCalls: [ExportID] = []
    private(set) var settleBatchCalls: [(batchID: BatchID, settledAt: Date)] = []
    private(set) var discardExportCalls: [(exportID: ExportID, temporaryFiles: [ManagedFileRef])] = []
    private(set) var loadRunningJobsCallCount = 0
    private(set) var deleteRunningJobsCalls: [[ExportID]] = []

    var startExportResult: ExportStartDecision
    var loadRunningJobsResult: [ExportJob] = []

    init(startExportResult: ExportStartDecision) {
        self.startExportResult = startExportResult
    }

    func startExport(_ input: StartExportInput, expectedProjectRevision: Int64) async throws -> ExportStartDecision {
        startExportCalls.append((input, expectedProjectRevision))
        return startExportResult
    }

    func recordGeneratedOutput(_ input: RecordOutputInput) async throws {
        recordGeneratedOutputCalls.append(input)
    }

    func settleExport(_ exportID: ExportID) async throws {
        settleExportCalls.append(exportID)
    }

    func settleBatch(_ batchID: BatchID, settledAt: Date) async throws {
        settleBatchCalls.append((batchID, settledAt))
    }

    func discardExport(_ exportID: ExportID, temporaryFiles: [ManagedFileRef]) async throws {
        discardExportCalls.append((exportID, temporaryFiles))
    }

    func loadRunningJobs() async throws -> [ExportJob] {
        loadRunningJobsCallCount += 1
        return loadRunningJobsResult
    }

    func deleteRunningJobs(_ exportIDs: [ExportID]) async throws {
        deleteRunningJobsCalls.append(exportIDs)
    }
}

@Test("ExportSagaStoreへの最小準拠が全メソッドの引数を渡された値どおりに記録する")
func fakeExportSagaStoreForwardsArguments() async throws {
    let projectID = makeProjectID()
    let expectedBlock = ExportStartBlock(reason: .trialCreditsUnavailable, limit: nil)
    let store = FakeExportSagaStore(startExportResult: .blocked(expectedBlock))

    let input = StartExportInput(
        projectID: projectID,
        batchID: nil,
        queueItemID: nil,
        renderSpec: try makeRenderSpec(),
        exportSetting: makeExportSetting(),
        previewConfirmation: try makePreviewConfirmation(projectID: projectID)
    )
    let decision = try await store.startExport(input, expectedProjectRevision: 7)
    guard case let .blocked(block) = decision else {
        Issue.record("blockedケースであるべき")
        return
    }
    #expect(block == expectedBlock)

    let recordInput = RecordOutputInput(
        exportID: ExportID(rawValue: UUID()),
        outputFile: makeOutputFileRef(),
        outputByteSize: 512,
        outputSHA256: Data(repeating: 0x33, count: 32)
    )
    try await store.recordGeneratedOutput(recordInput)

    let exportID = ExportID(rawValue: UUID())
    try await store.settleExport(exportID)

    let batchID = BatchID(rawValue: UUID())
    let settledAt = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.settleBatch(batchID, settledAt: settledAt)

    let startCalls = await store.startExportCalls
    #expect(startCalls.count == 1)
    #expect(startCalls[0].expectedProjectRevision == 7)
    #expect(startCalls[0].input.projectID == projectID)

    let recordCalls = await store.recordGeneratedOutputCalls
    #expect(recordCalls.count == 1)
    #expect(recordCalls[0].exportID == recordInput.exportID)
    #expect(recordCalls[0].outputFile == recordInput.outputFile)
    #expect(recordCalls[0].outputByteSize == recordInput.outputByteSize)
    #expect(recordCalls[0].outputSHA256 == recordInput.outputSHA256)

    let settleExportCalls = await store.settleExportCalls
    #expect(settleExportCalls == [exportID])

    let settleBatchCalls = await store.settleBatchCalls
    #expect(settleBatchCalls.count == 1)
    #expect(settleBatchCalls[0].batchID == batchID)
    #expect(settleBatchCalls[0].settledAt == settledAt)
}

@Test("ExportSagaStoreへの最小準拠がdiscard/loadRunningJobs/deleteRunningJobsの引数を記録する")
func fakeExportSagaStoreForwardsJobMaintenanceArguments() async throws {
    let store = FakeExportSagaStore(startExportResult: .blocked(
        ExportStartBlock(reason: .trialCreditsUnavailable, limit: nil)))

    let discardedID = ExportID(rawValue: UUID())
    let temporaryFiles = [
        ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID())),
        ManagedFileRef(kind: .rasterTemporary, fileID: ManagedFileID(rawValue: UUID()))
    ]
    try await store.discardExport(discardedID, temporaryFiles: temporaryFiles)

    _ = try await store.loadRunningJobs()

    let deletedIDs = [ExportID(rawValue: UUID()), ExportID(rawValue: UUID())]
    try await store.deleteRunningJobs(deletedIDs)

    let discardCalls = await store.discardExportCalls
    #expect(discardCalls.count == 1)
    #expect(discardCalls[0].exportID == discardedID)
    #expect(discardCalls[0].temporaryFiles == temporaryFiles)

    let loadCallCount = await store.loadRunningJobsCallCount
    #expect(loadCallCount == 1)

    let deleteCalls = await store.deleteRunningJobsCalls
    #expect(deleteCalls == [deletedIDs])
}
