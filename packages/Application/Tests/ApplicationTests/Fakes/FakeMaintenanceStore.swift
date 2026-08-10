import Foundation
import Domain

// FakeMaintenanceStore — `MaintenanceStore`（Domain/Ports/MaintenanceStore.swift）の in-memory
// 偽実装（Issue #7 Task 11）。
//
// 正本は `MaintenanceStore` の各メソッドの doc コメント（architecture.md「MaintenanceStore」節）。
// 実 Persistence には依存しない。`listExistingFileIDs(kind:)` は注入された `FakeManagedFileStore`
// の実在ファイル集合から導出する（Task 11 レビュー W-5）。production では
// `MaintenanceStoreLive.listExistingFileIDs` が管理ディレクトリを実走査し、
// `ManagedFileStoreLive.delete` が指す実体と同じ場所を見ているのに対応させるため、
// 別々に seed する集合を持たせず実体の所在を単一の真実にする。
// `registerOrphan(_:)` は登録した参照を内部の pending 集合へ追加し、以後の
// `loadPendingFileDeletions()` の一覧に反映する（本物の DB の INSERT を模す。
// `containsPendingFileDeletion(_:)` で登録・解除の検証に使う）。
// `listReferencedFileIDs(kind:)` は kind ごとに事前に seed した集合を返し、
// 未 seed の kind は空集合を返す。
//
// Fakes 配下の型はテストターゲット外から参照されないため internal で足りる
// （FakeExportSagaStore.swift と同じ方針）。

actor FakeMaintenanceStore: MaintenanceStore {
    // MARK: - 呼び出し記録

    private(set) var loadPendingFileDeletionsCallCount = 0
    private(set) var clearPendingFileDeletionCalls: [ManagedFileRef] = []
    private(set) var listExistingFileIDsCalls: [ManagedFileKind] = []
    private(set) var listReferencedFileIDsCalls: [ManagedFileKind] = []
    private(set) var registerOrphanCalls: [ManagedFileRef] = []

    // MARK: - 注入可能な失敗

    var loadPendingFileDeletionsFailure: Error?
    var clearPendingFileDeletionFailure: Error?
    var listExistingFileIDsFailure: Error?
    var listReferencedFileIDsFailure: Error?
    var registerOrphanFailure: Error?

    // MARK: - in-memory 状態

    /// 実体の所在の単一の真実（W-5）。listExistingFileIDs はここから導出する。
    private let managedFileStore: FakeManagedFileStore
    /// 未処理の PendingFileDeletion 相当の集合（registerOrphan で追加される）
    private var pendingDeletions: Set<ManagedFileRef> = []
    private var referencedFileIDsByKind: [ManagedFileKind: Set<ManagedFileID>] = [:]

    init(managedFileStore: FakeManagedFileStore) {
        self.managedFileStore = managedFileStore
    }

    // MARK: - 失敗注入セッター（actor 隔離のため外部から直接代入できない）

    func setLoadPendingFileDeletionsFailure(_ value: Error?) { loadPendingFileDeletionsFailure = value }
    func setClearPendingFileDeletionFailure(_ value: Error?) { clearPendingFileDeletionFailure = value }
    func setListExistingFileIDsFailure(_ value: Error?) { listExistingFileIDsFailure = value }
    func setListReferencedFileIDsFailure(_ value: Error?) { listReferencedFileIDsFailure = value }
    func setRegisterOrphanFailure(_ value: Error?) { registerOrphanFailure = value }

    /// テストが未処理の PendingFileDeletion をあらかじめ登録する
    func seedPendingFileDeletion(_ file: ManagedFileRef) {
        pendingDeletions.insert(file)
    }

    /// テストが種別ごとの「DB上で参照されているファイルID」を注入する
    /// （未 seed の kind は空集合を返す）
    func seedReferencedFileIDs(kind: ManagedFileKind, ids: Set<ManagedFileID>) {
        referencedFileIDsByKind[kind] = ids
    }

    /// 指定した参照がまだ pending 一覧に残っているかをテストが確認する
    /// （削除失敗時に登録が残ること・削除成功時に消えたことの検証用）
    func containsPendingFileDeletion(_ file: ManagedFileRef) -> Bool {
        pendingDeletions.contains(file)
    }

    // MARK: - MaintenanceStore

    func loadPendingFileDeletions() async throws -> [PendingFileDeletion] {
        loadPendingFileDeletionsCallCount += 1
        if let failure = loadPendingFileDeletionsFailure { throw failure }
        return pendingDeletions.map(PendingFileDeletion.init(file:))
    }

    func clearPendingFileDeletion(_ file: ManagedFileRef) async throws {
        clearPendingFileDeletionCalls.append(file)
        if let failure = clearPendingFileDeletionFailure { throw failure }
        pendingDeletions.remove(file)
    }

    func listExistingFileIDs(kind: ManagedFileKind) async throws -> Set<ManagedFileID> {
        listExistingFileIDsCalls.append(kind)
        if let failure = listExistingFileIDsFailure { throw failure }
        return await managedFileStore.existingFileIDs(kind: kind)
    }

    func listReferencedFileIDs(kind: ManagedFileKind) async throws -> Set<ManagedFileID> {
        listReferencedFileIDsCalls.append(kind)
        if let failure = listReferencedFileIDsFailure { throw failure }
        return referencedFileIDsByKind[kind] ?? []
    }

    func registerOrphan(_ file: ManagedFileRef) async throws {
        registerOrphanCalls.append(file)
        if let failure = registerOrphanFailure { throw failure }
        pendingDeletions.insert(file)
    }
}
