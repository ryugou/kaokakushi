import Testing
@testable import Domain
import Foundation

/// Task 4: スタンプの永続化ポート（architecture.md「StampStore」節）。
///
/// `CustomStamp` / `StampStorageBreakdown` のフィールド保持と、`StampStore` への
/// 最小準拠（`importCustomStamp` のジェネリック body 呼び出しを含む）を検証する。
/// `StampAssetHash` は Task 1 で実装済みのためここでは組み立てにのみ使う。

private func makeStampAssetHash(fill: UInt8) -> StampAssetHash {
    StampAssetHash(bytes: Data(repeating: fill, count: 32))
}

private func makeThumbnailRef() -> ManagedFileRef {
    ManagedFileRef(kind: .stampThumbnail, fileID: ManagedFileID(rawValue: UUID()))
}

// MARK: - CustomStamp

@Test("CustomStampが全フィールドを保持し値として比較できる")
func customStampHoldsAllFieldsAndIsEquatable() {
    let customStampID = CustomStampID(rawValue: UUID())
    let assetHash = makeStampAssetHash(fill: 0x01)
    let thumbnail = makeThumbnailRef()

    let subject = CustomStamp(
        customStampID: customStampID,
        assetHash: assetHash,
        name: "誕生日スタンプ",
        sortOrder: 3,
        thumbnail: thumbnail
    )

    #expect(subject.customStampID == customStampID)
    #expect(subject.assetHash == assetHash)
    #expect(subject.name == "誕生日スタンプ")
    #expect(subject.sortOrder == 3)
    #expect(subject.thumbnail == thumbnail)
    #expect(subject == CustomStamp(
        customStampID: customStampID,
        assetHash: assetHash,
        name: "誕生日スタンプ",
        sortOrder: 3,
        thumbnail: thumbnail
    ))
}

// MARK: - StampStorageBreakdown

@Test("StampStorageBreakdownが全フィールドを保持する")
func stampStorageBreakdownHoldsAllFields() {
    let subject = StampStorageBreakdown(registeredBytes: 1_000, historyOnlyBytes: 200, totalBytes: 1_200)
    #expect(subject.registeredBytes == 1_000)
    #expect(subject.historyOnlyBytes == 200)
    #expect(subject.totalBytes == 1_200)
}

// MARK: - StampStore への最小準拠

private actor FakeStampStore: StampStore {
    private(set) var importCustomStampCallCount = 0
    private(set) var loadCustomStampsCallCount = 0
    private(set) var removeCustomStampCalls: [CustomStampID] = []
    private(set) var attachStampReferenceCalls: [(projectID: ProjectID, assetHash: StampAssetHash)] = []
    private(set) var releaseStampReferenceCalls: [(projectID: ProjectID, assetHash: StampAssetHash)] = []
    private(set) var loadStampStorageBreakdownCallCount = 0

    var importResult: (stamp: CustomStamp, assetHash: StampAssetHash)
    var customStampsResult: [CustomStamp] = []
    var storageBreakdownResult = StampStorageBreakdown(registeredBytes: 0, historyOnlyBytes: 0, totalBytes: 0)

    init(importResult: (stamp: CustomStamp, assetHash: StampAssetHash)) {
        self.importResult = importResult
    }

    func importCustomStamp(
        _ body: @Sendable (URL) async throws -> Void
    ) async throws -> (stamp: CustomStamp, assetHash: StampAssetHash) {
        importCustomStampCallCount += 1
        try await body(URL(fileURLWithPath: "/tmp/stamp-store-tests/import"))
        return importResult
    }

    func loadCustomStamps() async throws -> [CustomStamp] {
        loadCustomStampsCallCount += 1
        return customStampsResult
    }

    func removeCustomStamp(_ id: CustomStampID) async throws {
        removeCustomStampCalls.append(id)
    }

    func attachStampReference(projectID: ProjectID, assetHash: StampAssetHash) async throws {
        attachStampReferenceCalls.append((projectID, assetHash))
    }

    func releaseStampReference(projectID: ProjectID, assetHash: StampAssetHash) async throws {
        releaseStampReferenceCalls.append((projectID, assetHash))
    }

    func loadStampStorageBreakdown() async throws -> StampStorageBreakdown {
        loadStampStorageBreakdownCallCount += 1
        return storageBreakdownResult
    }
}

@Test("StampStoreへの最小準拠が全メソッドの引数を渡された値どおりに記録する")
func fakeStampStoreForwardsArguments() async throws {
    let expectedStamp = CustomStamp(
        customStampID: CustomStampID(rawValue: UUID()),
        assetHash: makeStampAssetHash(fill: 0x02),
        name: "スター",
        sortOrder: 1,
        thumbnail: makeThumbnailRef()
    )
    let store = FakeStampStore(importResult: (expectedStamp, expectedStamp.assetHash))

    nonisolated(unsafe) var bodyReceivedURL: URL?
    let result = try await store.importCustomStamp { url in
        bodyReceivedURL = url
    }
    #expect(result.stamp == expectedStamp)
    #expect(bodyReceivedURL?.lastPathComponent == "import")

    _ = try await store.loadCustomStamps()

    let removedID = CustomStampID(rawValue: UUID())
    try await store.removeCustomStamp(removedID)

    let projectID = ProjectID(rawValue: UUID())
    let assetHash = makeStampAssetHash(fill: 0x03)
    try await store.attachStampReference(projectID: projectID, assetHash: assetHash)
    try await store.releaseStampReference(projectID: projectID, assetHash: assetHash)

    _ = try await store.loadStampStorageBreakdown()

    #expect(await store.importCustomStampCallCount == 1)
    #expect(await store.loadCustomStampsCallCount == 1)
    #expect(await store.removeCustomStampCalls == [removedID])

    let attachCalls = await store.attachStampReferenceCalls
    #expect(attachCalls.count == 1)
    #expect(attachCalls[0].projectID == projectID)
    #expect(attachCalls[0].assetHash == assetHash)

    let releaseCalls = await store.releaseStampReferenceCalls
    #expect(releaseCalls.count == 1)
    #expect(releaseCalls[0].projectID == projectID)
    #expect(releaseCalls[0].assetHash == assetHash)

    #expect(await store.loadStampStorageBreakdownCallCount == 1)
}
