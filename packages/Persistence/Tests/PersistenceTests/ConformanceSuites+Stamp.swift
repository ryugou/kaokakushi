import Foundation
import Testing
import Domain
@testable import Persistence

// StampStoreの適合スイート（Issue #6 Task 7・test-plan.md 4.1が正本。設計方針の詳細は
// ConformanceSuites.swiftのファイル先頭コメントを参照）。

// MARK: - StampStore: 検証関数

/// importCustomStampの重複同一化（StampStore.swift doc コメント原文: 「body が一時ファイルへ
/// 書いた内容の SHA-256 が既存の StampAsset と一致すればそれを再利用し...重複取り込みでも
/// CustomStamp 行ごとに作る」）をloadCustomStamps()経由で確認する。ファイル実体の破棄有無は
/// プロトコル外のためここでは確認しない（呼び出し側スコープ外。spec指定どおり）。
func verifyImportCustomStampReusesAssetOnDuplicateBytes(
    _ store: some StampStore,
    firstName: String,
    secondName: String,
    body: @Sendable (URL) async throws -> Void,
    thumbnailBody: @Sendable (URL) async throws -> Void
) async throws {
    let before = try await store.loadCustomStamps().count
    let first = try await store.importCustomStamp(name: firstName, body: body, thumbnailBody: thumbnailBody)
    let second = try await store.importCustomStamp(name: secondName, body: body, thumbnailBody: thumbnailBody)
    let after = try await store.loadCustomStamps().count

    #expect(first.assetHash == second.assetHash, "同一内容の取り込みはStampAssetを再利用するはず")
    #expect(after - before == 2, "重複取り込みでもCustomStamp行は2件増えるはず")
}

/// removeCustomStampの「一覧から削除する」（StampStore.swift doc コメント原文）ことを
/// loadCustomStamps()の一覧に残っていないことで確認する。
func verifyRemoveCustomStampDisappearsFromList(
    _ store: some StampStore,
    customStampID: CustomStampID
) async throws {
    try await store.removeCustomStamp(customStampID)
    let remaining = try await store.loadCustomStamps()
    #expect(!remaining.contains { $0.customStampID == customStampID }, "removeCustomStamp後は一覧に残っていないはず")
}

// MARK: - StampStore: Liveへの適用

@Suite("ConformanceSuites: StampStore (Live)")
struct StampStoreConformanceTests {
    @Test("importCustomStampは同一内容の取り込みでStampAssetを再利用しCustomStampは行ごとに作ること")
    func importReusesAssetOnDuplicateBytesThroughProtocol() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeStampTestDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StampStoreLive(database: database, fileStore: ManagedFileStoreLive(directories: directories))
        let bytes = Data([0x50, 0x51])

        try await verifyImportCustomStampReusesAssetOnDuplicateBytes(
            store,
            firstName: "適合スイートA",
            secondName: "適合スイートB",
            body: { url in try bytes.write(to: url) },
            thumbnailBody: { url in try Data([0xFF]).write(to: url) }
        )
    }

    @Test("removeCustomStampは対象をloadCustomStampsの一覧から消すこと")
    func removeCustomStampDisappearsFromListThroughProtocol() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let (root, directories) = makeStampTestDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StampStoreLive(database: database, fileStore: ManagedFileStoreLive(directories: directories))
        let imported = try await importStamp(store, name: "削除対象", bytes: Data([0x52]))

        try await verifyRemoveCustomStampDisappearsFromList(store, customStampID: imported.stamp.customStampID)
    }
}
