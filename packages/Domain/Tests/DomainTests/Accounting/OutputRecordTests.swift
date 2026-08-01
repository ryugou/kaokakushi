import Testing
@testable import Domain
import Foundation

/// Task 3: 出力レコードの型群（export-saga.md 3 章 + architecture.md 7.5）。
///
/// `OutputState` の固定 rawValue（1/2/3。architecture.md 7.5 の表）、
/// `OutputRecord.isUndelivered` の述語（generated/deliveryUnknown で true、delivered で false）、
/// `OutputRecord` / `ExportRecord` のフィールド保持を検証する。

private func makeOutputFileRef() -> OutputFileRef {
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    guard let outputRef = OutputFileRef(ref) else {
        fatalError("test setup invariant violated: kind must be .output")
    }
    return outputRef
}

// MARK: - OutputState の固定 rawValue（architecture.md 7.5 の表）

@Test(
    "OutputStateのrawValueが正本の表どおりgenerated=1/deliveryUnknown=2/delivered=3",
    arguments: [
        (OutputState.generated, UInt32(1)),
        (OutputState.deliveryUnknown, UInt32(2)),
        (OutputState.delivered, UInt32(3))
    ]
)
func outputStateRawValueMatchesCanonicalDoc(state: OutputState, expected: UInt32) {
    #expect(state.rawValue == expected)
}

// MARK: - OutputRecord.isUndelivered

@Test(
    "isUndeliveredはgenerated/deliveryUnknownでtrueでdeliveredでfalse",
    arguments: [
        (OutputState.generated, true),
        (OutputState.deliveryUnknown, true),
        (OutputState.delivered, false)
    ]
)
func isUndeliveredReflectsState(state: OutputState, expected: Bool) {
    let subject = OutputRecord(
        exportID: ExportID(rawValue: UUID()),
        projectID: ProjectID(rawValue: UUID()),
        batchID: nil,
        outputFile: makeOutputFileRef(),
        outputByteSize: 1024,
        outputSHA256: Data(repeating: 0x11, count: 32),
        state: state,
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        settledAt: state == .delivered ? Date(timeIntervalSince1970: 1_700_000_100) : nil,
        expiresAt: nil,
        format: .jpeg,
        suggestedCreationDate: nil
    )
    #expect(subject.isUndelivered == expected)
}

@Test("OutputRecordが全フィールドを保持する")
func outputRecordHoldsAllFields() {
    let exportID = ExportID(rawValue: UUID())
    let projectID = ProjectID(rawValue: UUID())
    let batchID = BatchID(rawValue: UUID())
    let outputFile = makeOutputFileRef()
    let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let settledAt = Date(timeIntervalSince1970: 1_700_000_200)
    let expiresAt = Date(timeIntervalSince1970: 1_700_086_400)
    let sha256 = Data(repeating: 0x22, count: 32)

    let subject = OutputRecord(
        exportID: exportID,
        projectID: projectID,
        batchID: batchID,
        outputFile: outputFile,
        outputByteSize: 2048,
        outputSHA256: sha256,
        state: .delivered,
        generatedAt: generatedAt,
        settledAt: settledAt,
        expiresAt: expiresAt,
        format: .heic,
        suggestedCreationDate: generatedAt
    )

    #expect(subject.exportID == exportID)
    #expect(subject.projectID == projectID)
    #expect(subject.batchID == batchID)
    #expect(subject.outputFile == outputFile)
    #expect(subject.outputByteSize == 2048)
    #expect(subject.outputSHA256 == sha256)
    #expect(subject.state == .delivered)
    #expect(subject.generatedAt == generatedAt)
    #expect(subject.settledAt == settledAt)
    #expect(subject.expiresAt == expiresAt)
    #expect(subject.format == .heic)
    #expect(subject.suggestedCreationDate == generatedAt)
}

@Test("ExportRecordが全フィールドを保持する")
func exportRecordHoldsAllFields() {
    let exportID = ExportID(rawValue: UUID())
    let projectID = ProjectID(rawValue: UUID())
    let exportedAt = Date(timeIntervalSince1970: 1_700_000_300)

    let subject = ExportRecord(
        exportID: exportID,
        projectID: projectID,
        batchID: nil,
        exportedAt: exportedAt,
        accountingMode: .batchTrial,
        format: .png,
        outputByteSize: 4096
    )

    #expect(subject.exportID == exportID)
    #expect(subject.projectID == projectID)
    #expect(subject.batchID == nil)
    #expect(subject.exportedAt == exportedAt)
    #expect(subject.accountingMode == .batchTrial)
    #expect(subject.format == .png)
    #expect(subject.outputByteSize == 4096)
}
