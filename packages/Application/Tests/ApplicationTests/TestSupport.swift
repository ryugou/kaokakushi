import Foundation
import Domain

// ApplicationTests 全体で共有するテストフィクスチャ。各テストファイルへ同じ定義をコピーせず、
// ここへ集約する（DomainTests/TestSupport.swift と同じ方針。simplify レビュー指摘の踏襲）。
// 時刻はすべて固定値を渡す（裸の Date() を使わない。Global Constraints）。

func makeExportID() -> ExportID {
    ExportID(rawValue: UUID())
}

func makeProjectID() -> ProjectID {
    ProjectID(rawValue: UUID())
}

func makeBatchID() -> BatchID {
    BatchID(rawValue: UUID())
}

/// kind = .output の OutputFileRef を組み立てる。
func makeOutputFileRef() -> OutputFileRef {
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    guard let outputRef = OutputFileRef(ref) else {
        fatalError("test setup invariant violated: kind must be .output")
    }
    return outputRef
}

/// 任意状態の OutputRecord フィクスチャ。settledAt を渡さなければ確定済み扱いにする
/// （settledAt / expiresAt は固定タイムスタンプで決定的にする）。
func makeOutputRecord(
    exportID: ExportID,
    projectID: ProjectID = makeProjectID(),
    state: OutputState,
    settledAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)
) -> OutputRecord {
    OutputRecord(
        exportID: exportID,
        projectID: projectID,
        batchID: nil,
        outputFile: makeOutputFileRef(),
        outputByteSize: 1_024,
        outputSHA256: Data(repeating: 0xAB, count: 32),
        state: state,
        generatedAt: Date(timeIntervalSince1970: 1_699_999_000),
        settledAt: settledAt,
        expiresAt: settledAt.map { $0.addingTimeInterval(86_400) },
        format: .jpeg,
        suggestedCreationDate: nil
    )
}

func makeEntitlement() -> Entitlement {
    Entitlement(
        plan: .free,
        status: .active,
        expiresAt: nil,
        lastVerifiedAt: Date(timeIntervalSince1970: 1_699_997_000),
        isSandbox: false
    )
}

/// accountingMode を差し替え可能な ExportJob フィクスチャ（settle の消費カウンタ検証用）。
func makeExportJob(
    exportID: ExportID,
    projectID: ProjectID = makeProjectID(),
    batchID: BatchID? = nil,
    accountingMode: ExportAccountingMode = .paidUnlimited
) -> ExportJob {
    ExportJob(
        exportID: exportID,
        projectID: projectID,
        batchID: batchID,
        queueItemID: nil,
        authorization: ExportAuthorization(
            entitlementSnapshot: makeEntitlement(),
            accountingMode: accountingMode,
            authorizedAt: Date(timeIntervalSince1970: 1_699_998_000)
        ),
        delivery: OutputDeliveryDescriptor(format: .jpeg, suggestedCreationDate: nil)
    )
}

func makeRecordOutputInput(exportID: ExportID) -> RecordOutputInput {
    RecordOutputInput(
        exportID: exportID,
        outputFile: makeOutputFileRef(),
        outputByteSize: 1_024,
        outputSHA256: Data(repeating: 0xAB, count: 32)
    )
}
