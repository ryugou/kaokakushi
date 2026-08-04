import Testing
@testable import Domain
import Foundation

/// Task 4: 処理用素材の永続化ポート（image-pipeline.md 5 章「写真選択と PhotoKit 境界」）。
///
/// `SourceRepresentation` の2ケース、`ProjectSourceLocator` / `WorkingSourceRecord` /
/// `CreateWorkingSourceInput` / `ReplaceWorkingSourceInput` / `AttachWorkingSourceInput` の
/// フィールド保持（Optional の nil 許容を含む）、`WorkingSourceStore` への最小準拠を検証する。

private func makeWorkingSourceFileRef() -> WorkingSourceFileRef {
    let ref = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))
    guard let sourceRef = WorkingSourceFileRef(ref) else {
        fatalError("test setup invariant violated: kind must be .processingTemporary")
    }
    return sourceRef
}

private func makeCaptureMetadata() -> OriginalCaptureMetadata {
    OriginalCaptureMetadata(
        dateTimeOriginal: "2026:08:01 10:00:00",
        subSecTimeOriginal: "123",
        offsetTimeOriginal: "+09:00",
        utcMillis: 1_754_017_200_000
    )
}

// MARK: - SourceRepresentation の2ケース

@Test(
    "SourceRepresentationはoriginalとtranscodedの2ケースを持つ",
    arguments: [(SourceRepresentation.original, true), (.transcoded, false)]
)
func sourceRepresentationHasTwoCases(representation: SourceRepresentation, isOriginal: Bool) {
    // 網羅的な switch であるため、正本に無い3つめの case が追加されればコンパイルが壊れ検出できる。
    switch representation {
    case .original:
        #expect(isOriginal)
    case .transcoded:
        #expect(!isOriginal)
    }
}

@Test("SourceRepresentationのoriginalとtranscodedは区別される")
func sourceRepresentationDistinguishesCases() {
    #expect(SourceRepresentation.original != .transcoded)
}

// MARK: - ProjectSourceLocator（PHAsset.localIdentifier が取得できない場合は nil）

@Test("ProjectSourceLocatorはphotoLibraryLocalIdentifierのnilを許容する")
func projectSourceLocatorAllowsNilIdentifier() {
    let subject = ProjectSourceLocator(photoLibraryLocalIdentifier: nil)
    #expect(subject.photoLibraryLocalIdentifier == nil)
}

@Test("ProjectSourceLocatorはphotoLibraryLocalIdentifierを保持する")
func projectSourceLocatorHoldsIdentifier() {
    let subject = ProjectSourceLocator(photoLibraryLocalIdentifier: "local-asset-1")
    #expect(subject.photoLibraryLocalIdentifier == "local-asset-1")
}

// MARK: - WorkingSourceRecord

@Test("WorkingSourceRecordが全フィールドを保持する")
func workingSourceRecordHoldsAllFields() {
    let projectID = ProjectID(rawValue: UUID())
    let sourceFile = makeWorkingSourceFileRef()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    let subject = WorkingSourceRecord(projectID: projectID, sourceFile: sourceFile, createdAt: createdAt)

    #expect(subject.projectID == projectID)
    #expect(subject.sourceFile == sourceFile)
    #expect(subject.createdAt == createdAt)
}

// MARK: - CreateWorkingSourceInput / ReplaceWorkingSourceInput / AttachWorkingSourceInput

@Test("CreateWorkingSourceInputが全フィールドを保持し単体書き出しではbatchIDとqueueItemIDにnilを許容する")
func createWorkingSourceInputHoldsAllFieldsAndAllowsNilOptionals() throws {
    let projectID = ProjectID(rawValue: UUID())
    let sourceFile = makeWorkingSourceFileRef()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let locator = ProjectSourceLocator(photoLibraryLocalIdentifier: nil)
    let capture = makeCaptureMetadata()
    let initialSpec = try makeRenderSpec()

    let subject = CreateWorkingSourceInput(
        projectID: projectID,
        batchID: nil,
        queueItemID: nil,
        sourceFile: sourceFile,
        createdAt: createdAt,
        sourceLocator: locator,
        capture: capture,
        libraryCreationDate: nil,
        representation: .original,
        initialSpec: initialSpec
    )

    #expect(subject.projectID == projectID)
    #expect(subject.batchID == nil)
    #expect(subject.queueItemID == nil)
    #expect(subject.sourceFile == sourceFile)
    #expect(subject.createdAt == createdAt)
    #expect(subject.sourceLocator == locator)
    #expect(subject.capture == capture)
    #expect(subject.libraryCreationDate == nil)
    #expect(subject.representation == .original)
    #expect(subject.initialSpec == initialSpec)
}

@Test("CreateWorkingSourceInputは一括処理でbatchIDとqueueItemIDを保持する")
func createWorkingSourceInputHoldsBatchAndQueueItemIDsWhenPresent() throws {
    let batchID = BatchID(rawValue: UUID())
    let queueItemID = ExportQueueItemID(rawValue: UUID())
    let libraryCreationDate = Date(timeIntervalSince1970: 1_699_999_000)

    let subject = CreateWorkingSourceInput(
        projectID: ProjectID(rawValue: UUID()),
        batchID: batchID,
        queueItemID: queueItemID,
        sourceFile: makeWorkingSourceFileRef(),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        sourceLocator: ProjectSourceLocator(photoLibraryLocalIdentifier: "asset-2"),
        capture: makeCaptureMetadata(),
        libraryCreationDate: libraryCreationDate,
        representation: .transcoded,
        initialSpec: try makeRenderSpec()
    )

    #expect(subject.batchID == batchID)
    #expect(subject.queueItemID == queueItemID)
    #expect(subject.libraryCreationDate == libraryCreationDate)
    #expect(subject.representation == .transcoded)
}

@Test("ReplaceWorkingSourceInputが全フィールドを保持しlibraryCreationDateのnilを許容する")
func replaceWorkingSourceInputHoldsAllFieldsAndAllowsNilLibraryCreationDate() {
    let projectID = ProjectID(rawValue: UUID())
    let newSourceFile = makeWorkingSourceFileRef()
    let replacedAt = Date(timeIntervalSince1970: 1_700_001_000)
    let capture = makeCaptureMetadata()
    let locator = ProjectSourceLocator(photoLibraryLocalIdentifier: "reselected-asset")

    let subject = ReplaceWorkingSourceInput(
        projectID: projectID,
        newSourceFile: newSourceFile,
        replacedAt: replacedAt,
        capture: capture,
        libraryCreationDate: nil,
        representation: .original,
        sourceLocator: locator
    )

    #expect(subject.projectID == projectID)
    #expect(subject.newSourceFile == newSourceFile)
    #expect(subject.replacedAt == replacedAt)
    #expect(subject.capture == capture)
    #expect(subject.libraryCreationDate == nil)
    #expect(subject.representation == .original)
    #expect(subject.sourceLocator == locator)
}

@Test("AttachWorkingSourceInputが全フィールドを保持しlibraryCreationDateのnilを許容する")
func attachWorkingSourceInputHoldsAllFieldsAndAllowsNilLibraryCreationDate() {
    let projectID = ProjectID(rawValue: UUID())
    let sourceFile = makeWorkingSourceFileRef()
    let attachedAt = Date(timeIntervalSince1970: 1_700_002_000)
    let capture = makeCaptureMetadata()
    let locator = ProjectSourceLocator(photoLibraryLocalIdentifier: "reconnected-asset")

    let subject = AttachWorkingSourceInput(
        projectID: projectID,
        sourceFile: sourceFile,
        attachedAt: attachedAt,
        capture: capture,
        libraryCreationDate: nil,
        representation: .transcoded,
        sourceLocator: locator
    )

    #expect(subject.projectID == projectID)
    #expect(subject.sourceFile == sourceFile)
    #expect(subject.attachedAt == attachedAt)
    #expect(subject.capture == capture)
    #expect(subject.libraryCreationDate == nil)
    #expect(subject.representation == .transcoded)
    #expect(subject.sourceLocator == locator)
}

// MARK: - WorkingSourceStore への最小準拠

private actor FakeWorkingSourceStore: WorkingSourceStore {
    private(set) var createCalls: [CreateWorkingSourceInput] = []
    private(set) var replaceCalls: [ReplaceWorkingSourceInput] = []
    private(set) var attachCalls: [AttachWorkingSourceInput] = []
    private(set) var loadCalls: [ProjectID] = []
    private(set) var deleteCalls: [ProjectID] = []
    private(set) var invalidateCalls: [ProjectID] = []

    var loadResult: WorkingSourceRecord?

    func createProjectWithWorkingSource(_ input: CreateWorkingSourceInput) async throws {
        createCalls.append(input)
    }

    func replaceWorkingSource(_ input: ReplaceWorkingSourceInput) async throws {
        replaceCalls.append(input)
    }

    func attachWorkingSourceToExistingProject(_ input: AttachWorkingSourceInput) async throws {
        attachCalls.append(input)
    }

    func loadWorkingSource(for projectID: ProjectID) async throws -> WorkingSourceRecord? {
        loadCalls.append(projectID)
        return loadResult
    }

    func deleteWorkingSource(_ projectID: ProjectID) async throws {
        deleteCalls.append(projectID)
    }

    func invalidateWorkingSource(_ projectID: ProjectID) async throws {
        invalidateCalls.append(projectID)
    }
}

@Test("WorkingSourceStoreへの最小準拠が全メソッドの引数を渡された値どおりに記録する")
func fakeWorkingSourceStoreForwardsArguments() async throws {
    let store = FakeWorkingSourceStore()

    let createInput = CreateWorkingSourceInput(
        projectID: ProjectID(rawValue: UUID()),
        batchID: nil,
        queueItemID: nil,
        sourceFile: makeWorkingSourceFileRef(),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        sourceLocator: ProjectSourceLocator(photoLibraryLocalIdentifier: nil),
        capture: makeCaptureMetadata(),
        libraryCreationDate: nil,
        representation: .original,
        initialSpec: try makeRenderSpec()
    )
    try await store.createProjectWithWorkingSource(createInput)

    let replaceInput = ReplaceWorkingSourceInput(
        projectID: ProjectID(rawValue: UUID()),
        newSourceFile: makeWorkingSourceFileRef(),
        replacedAt: Date(timeIntervalSince1970: 1_700_001_000),
        capture: makeCaptureMetadata(),
        libraryCreationDate: nil,
        representation: .original,
        sourceLocator: ProjectSourceLocator(photoLibraryLocalIdentifier: nil)
    )
    try await store.replaceWorkingSource(replaceInput)

    let attachInput = AttachWorkingSourceInput(
        projectID: ProjectID(rawValue: UUID()),
        sourceFile: makeWorkingSourceFileRef(),
        attachedAt: Date(timeIntervalSince1970: 1_700_002_000),
        capture: makeCaptureMetadata(),
        libraryCreationDate: nil,
        representation: .original,
        sourceLocator: ProjectSourceLocator(photoLibraryLocalIdentifier: nil)
    )
    try await store.attachWorkingSourceToExistingProject(attachInput)

    let loadProjectID = ProjectID(rawValue: UUID())
    _ = try await store.loadWorkingSource(for: loadProjectID)

    let deleteProjectID = ProjectID(rawValue: UUID())
    try await store.deleteWorkingSource(deleteProjectID)

    let invalidateProjectID = ProjectID(rawValue: UUID())
    try await store.invalidateWorkingSource(invalidateProjectID)

    #expect(await store.createCalls.count == 1)
    #expect(await store.createCalls[0].projectID == createInput.projectID)
    #expect(await store.replaceCalls.count == 1)
    #expect(await store.replaceCalls[0].projectID == replaceInput.projectID)
    #expect(await store.attachCalls.count == 1)
    #expect(await store.attachCalls[0].projectID == attachInput.projectID)
    #expect(await store.loadCalls == [loadProjectID])
    #expect(await store.deleteCalls == [deleteProjectID])
    #expect(await store.invalidateCalls == [invalidateProjectID])
}
