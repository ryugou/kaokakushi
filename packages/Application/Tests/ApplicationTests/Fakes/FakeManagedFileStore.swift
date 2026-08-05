import Foundation
import Domain

// FakeManagedFileStore — `ManagedFileStore`（Domain/Ports/ManagedFileStore.swift）の in-memory
// 偽実装（Issue #7 Task 3）。
//
// 正本は `ManagedFileStore` の doc コメント（architecture.md 7.3「スコープ付きアクセス」）。
// 実ファイル I/O は行わない。存在する `ManagedFileRef` の集合だけを in-memory に持ち、
// withReadAccess は未登録の ref を「実体欠損」として throw する（Task 4 の実体確認テストが
// これを使って invalidateWorkingSource 経路を検証する）。
//
// Fakes 配下の型はテストターゲット外から参照されないため internal で足りる
// （DomainTests/TestSupport.swift と同じ方針。Task 3 レビュー Suggestion 2）。

/// この偽実装が検査する事前条件違反。
enum FakeManagedFileStoreError: Error, Sendable, Equatable {
    /// withReadAccess: 対象 ref が存在しない（seedExistingFile 未注入、または delete 済み）
    case fileNotFound(ManagedFileRef)
}

actor FakeManagedFileStore: ManagedFileStore {
    // MARK: - 呼び出し記録

    private(set) var withReadAccessCalls: [ManagedFileRef] = []
    private(set) var createFileCalls: [ManagedFileKind] = []
    private(set) var deleteCalls: [ManagedFileRef] = []

    // MARK: - 注入可能な失敗

    var withReadAccessFailure: Error?
    var createFileFailure: Error?
    var deleteFailure: Error?

    // MARK: - in-memory 状態

    /// 存在する仮想ファイルの集合（実体は持たない。存在確認のためだけの状態）
    private var existingFiles: Set<ManagedFileRef>

    init(existingFiles: Set<ManagedFileRef> = []) {
        self.existingFiles = existingFiles
    }

    // MARK: - 失敗注入セッター（actor 隔離のため外部から直接代入できない。Issue #7 Task 4 準備）

    func setWithReadAccessFailure(_ value: Error?) { withReadAccessFailure = value }
    func setCreateFileFailure(_ value: Error?) { createFileFailure = value }
    func setDeleteFailure(_ value: Error?) { deleteFailure = value }

    /// テストが実体確認の成功系シナリオ用に存在を注入する
    func seedExistingFile(_ ref: ManagedFileRef) {
        existingFiles.insert(ref)
    }

    func containsFile(_ ref: ManagedFileRef) -> Bool {
        existingFiles.contains(ref)
    }

    // MARK: - ManagedFileStore

    func withReadAccess<R: Sendable>(
        _ ref: ManagedFileRef,
        _ body: @Sendable (URL) async throws -> R
    ) async throws -> R {
        withReadAccessCalls.append(ref)
        if let failure = withReadAccessFailure { throw failure }
        guard existingFiles.contains(ref) else {
            throw FakeManagedFileStoreError.fileNotFound(ref)
        }
        return try await body(fakeURL(for: ref))
    }

    func createFile<R: Sendable>(
        kind: ManagedFileKind,
        _ body: @Sendable (URL) async throws -> R
    ) async throws -> (ref: ManagedFileRef, result: R) {
        createFileCalls.append(kind)
        if let failure = createFileFailure { throw failure }
        let ref = ManagedFileRef(kind: kind, fileID: ManagedFileID(rawValue: UUID()))
        let result = try await body(fakeURL(for: ref))
        existingFiles.insert(ref)
        return (ref: ref, result: result)
    }

    func delete(_ ref: ManagedFileRef) async throws {
        deleteCalls.append(ref)
        if let failure = deleteFailure { throw failure }
        existingFiles.remove(ref)
    }

    /// 実ファイルを持たないため、診断用に判別可能な固定形式の URL を作るだけの用途
    private func fakeURL(for ref: ManagedFileRef) -> URL {
        URL(fileURLWithPath: "/fake-managed-files/\(ref.kind.rawValue)/\(ref.fileID.rawValue.uuidString)")
    }
}
