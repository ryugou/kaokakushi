import Testing
@testable import Domain
import Foundation

/// Task 4: `ManagedFileStore`（architecture.md 7.3「スコープ付きアクセス」）。
///
/// ジェネリックメソッド（`withReadAccess<R>` / `createFile<R>`）が `@Sendable (URL) async
/// throws -> R` の body を実際に呼び出し、戻り値・生成した `ManagedFileRef` を伝えることを
/// 検証する。`ManagedFileRef` 等の型は Task 1 で実装済みのためここでは組み立てにのみ使う。

private actor FakeManagedFileStore: ManagedFileStore {
    private(set) var withReadAccessCalls: [ManagedFileRef] = []
    private(set) var createFileCalls: [ManagedFileKind] = []
    private(set) var deleteCalls: [ManagedFileRef] = []

    func withReadAccess<R: Sendable>(
        _ ref: ManagedFileRef,
        _ body: @Sendable (URL) async throws -> R
    ) async throws -> R {
        withReadAccessCalls.append(ref)
        return try await body(URL(fileURLWithPath: "/tmp/managed-file-store-tests/read"))
    }

    func createFile<R: Sendable>(
        kind: ManagedFileKind,
        _ body: @Sendable (URL) async throws -> R
    ) async throws -> (ref: ManagedFileRef, result: R) {
        createFileCalls.append(kind)
        let result = try await body(URL(fileURLWithPath: "/tmp/managed-file-store-tests/create"))
        return (ManagedFileRef(kind: kind, fileID: ManagedFileID(rawValue: UUID())), result)
    }

    func delete(_ ref: ManagedFileRef) async throws {
        deleteCalls.append(ref)
    }
}

@Test("withReadAccessはbodyへURLを渡しbodyの戻り値をそのまま返す")
func withReadAccessInvokesBodyAndReturnsItsResult() async throws {
    let store = FakeManagedFileStore()
    let ref = ManagedFileRef(kind: .stampAsset, fileID: ManagedFileID(rawValue: UUID()))

    let result = try await store.withReadAccess(ref) { url in
        url.lastPathComponent
    }

    #expect(result == "read")
    #expect(await store.withReadAccessCalls == [ref])
}

@Test("createFileはbodyへURLを渡しkindが一致するManagedFileRefとbodyの戻り値を返す")
func createFileInvokesBodyAndReturnsRefAndResult() async throws {
    let store = FakeManagedFileStore()

    let outcome = try await store.createFile(kind: .rasterTemporary) { url in
        url.lastPathComponent.count
    }

    #expect(outcome.ref.kind == .rasterTemporary)
    #expect(outcome.result == "create".count)
    #expect(await store.createFileCalls == [.rasterTemporary])
}

@Test("deleteは渡されたManagedFileRefをそのまま記録する")
func deleteRecordsPassedRef() async throws {
    let store = FakeManagedFileStore()
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))

    try await store.delete(ref)

    #expect(await store.deleteCalls == [ref])
}
