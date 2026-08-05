import Foundation
import Domain

// FakeWorkingSourceStore — `WorkingSourceStore`（Domain/Ports/WorkingSourceStore.swift）の
// in-memory 偽実装（Issue #7 Task 3）。
//
// 正本は `WorkingSourceStore` の各メソッドの doc コメント。実 Persistence には依存しない。
// 各作成系入力（CreateWorkingSourceInput 等）は createdAt / replacedAt / attachedAt を
// 自前で持つため、この偽実装は時刻を自分で生成しない（裸の Date() 禁止に抵触しない）。

public actor FakeWorkingSourceStore: WorkingSourceStore {
    // MARK: - 呼び出し記録

    public private(set) var createProjectWithWorkingSourceCalls: [CreateWorkingSourceInput] = []
    public private(set) var replaceWorkingSourceCalls: [ReplaceWorkingSourceInput] = []
    public private(set) var attachWorkingSourceToExistingProjectCalls: [AttachWorkingSourceInput] = []
    public private(set) var loadWorkingSourceCalls: [ProjectID] = []
    public private(set) var deleteWorkingSourceCalls: [ProjectID] = []
    public private(set) var invalidateWorkingSourceCalls: [ProjectID] = []

    // MARK: - 注入可能な失敗

    public var createProjectWithWorkingSourceFailure: Error?
    public var replaceWorkingSourceFailure: Error?
    public var attachWorkingSourceToExistingProjectFailure: Error?
    public var loadWorkingSourceFailure: Error?
    public var deleteWorkingSourceFailure: Error?
    public var invalidateWorkingSourceFailure: Error?

    // MARK: - in-memory 状態

    private var records: [ProjectID: WorkingSourceRecord] = [:]

    public init() {}

    /// テストが再選択・履歴再接続前提のシナリオ用に直接注入する
    public func seedWorkingSource(_ record: WorkingSourceRecord) {
        records[record.projectID] = record
    }

    // MARK: - WorkingSourceStore

    public func createProjectWithWorkingSource(_ input: CreateWorkingSourceInput) async throws {
        createProjectWithWorkingSourceCalls.append(input)
        if let failure = createProjectWithWorkingSourceFailure { throw failure }
        records[input.projectID] = WorkingSourceRecord(
            projectID: input.projectID, sourceFile: input.sourceFile, createdAt: input.createdAt
        )
    }

    public func replaceWorkingSource(_ input: ReplaceWorkingSourceInput) async throws {
        replaceWorkingSourceCalls.append(input)
        if let failure = replaceWorkingSourceFailure { throw failure }
        records[input.projectID] = WorkingSourceRecord(
            projectID: input.projectID, sourceFile: input.newSourceFile, createdAt: input.replacedAt
        )
    }

    public func attachWorkingSourceToExistingProject(_ input: AttachWorkingSourceInput) async throws {
        attachWorkingSourceToExistingProjectCalls.append(input)
        if let failure = attachWorkingSourceToExistingProjectFailure { throw failure }
        records[input.projectID] = WorkingSourceRecord(
            projectID: input.projectID, sourceFile: input.sourceFile, createdAt: input.attachedAt
        )
    }

    public func loadWorkingSource(for projectID: ProjectID) async throws -> WorkingSourceRecord? {
        loadWorkingSourceCalls.append(projectID)
        if let failure = loadWorkingSourceFailure { throw failure }
        return records[projectID]
    }

    public func deleteWorkingSource(_ projectID: ProjectID) async throws {
        deleteWorkingSourceCalls.append(projectID)
        if let failure = deleteWorkingSourceFailure { throw failure }
        // 対応する行が無くても許容する（完了操作・プロジェクト破棄のどちらから来ても冪等に扱う）
        records.removeValue(forKey: projectID)
    }

    public func invalidateWorkingSource(_ projectID: ProjectID) async throws {
        invalidateWorkingSourceCalls.append(projectID)
        if let failure = invalidateWorkingSourceFailure { throw failure }
        // (b) 非終端キュー項目の paused 更新・(c) PendingFileDeletion 登録は Queue/削除経路の
        // 別ポートの責務でありこのストアの状態には現れない。(a) の行削除だけをここで再現する
        records.removeValue(forKey: projectID)
    }
}
