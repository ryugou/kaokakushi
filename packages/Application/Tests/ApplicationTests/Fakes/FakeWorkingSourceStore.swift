import Foundation
import Domain

// FakeWorkingSourceStore — `WorkingSourceStore`（Domain/Ports/WorkingSourceStore.swift）の
// in-memory 偽実装（Issue #7 Task 3）。
//
// 正本は `WorkingSourceStore` の各メソッドの doc コメント。実 Persistence には依存しない。
// 各作成系入力（CreateWorkingSourceInput 等）は createdAt / replacedAt / attachedAt を
// 自前で持つため、この偽実装は時刻を自分で生成しない（裸の Date() 禁止に抵触しない）。
//
// Fakes 配下の型はテストターゲット外から参照されないため internal で足りる
// （DomainTests/TestSupport.swift と同じ方針。Task 3 レビュー Suggestion 2）。

actor FakeWorkingSourceStore: WorkingSourceStore {
    // MARK: - 呼び出し記録

    private(set) var createProjectWithWorkingSourceCalls: [CreateWorkingSourceInput] = []
    private(set) var replaceWorkingSourceCalls: [ReplaceWorkingSourceInput] = []
    private(set) var attachToExistingProjectCalls: [AttachWorkingSourceInput] = []
    private(set) var loadWorkingSourceCalls: [ProjectID] = []
    private(set) var deleteWorkingSourceCalls: [ProjectID] = []
    private(set) var invalidateWorkingSourceCalls: [ProjectID] = []

    // MARK: - 注入可能な失敗

    var createProjectWithWorkingSourceFailure: Error?
    var replaceWorkingSourceFailure: Error?
    var attachToExistingProjectFailure: Error?
    var loadWorkingSourceFailure: Error?
    var deleteWorkingSourceFailure: Error?
    var invalidateWorkingSourceFailure: Error?

    // MARK: - in-memory 状態

    private var records: [ProjectID: WorkingSourceRecord] = [:]

    /// createProjectWithWorkingSource / replaceWorkingSource / attachWorkingSourceToExistingProject
    /// 呼び出し中に足止めするゲート。設定しなければ足止めしない（FakeMediaSaver.gate と同じ方針。
    /// Issue #8 サブプロジェクト5 A2 Task 2: インポートSagaが「DB確定より前に取り込みファイルを
    /// 削除しない」「DB登録の完了前に成功を返さない」ことを決定的に検証するために使う。Task 3 で
    /// replaceWorkingSource にも同じゲートを適用し、再選択Sagaの「DB確定より前に旧ファイルを
    /// 削除しない」の検証に流用する。Task 4 で attachWorkingSourceToExistingProject にも同じ
    /// ゲートを適用し、再接続Sagaの「DB登録の完了前に成功を返さない」の検証に流用する）。
    var gate: OneShotGate?

    init() {}

    // MARK: - 失敗注入セッター（actor 隔離のため外部から直接代入できない。Issue #7 Task 4 準備）

    func setGate(_ value: OneShotGate?) { gate = value }
    func setCreateProjectWithWorkingSourceFailure(_ value: Error?) { createProjectWithWorkingSourceFailure = value }
    func setReplaceWorkingSourceFailure(_ value: Error?) { replaceWorkingSourceFailure = value }
    func setAttachToExistingProjectFailure(_ value: Error?) { attachToExistingProjectFailure = value }
    func setLoadWorkingSourceFailure(_ value: Error?) { loadWorkingSourceFailure = value }
    func setDeleteWorkingSourceFailure(_ value: Error?) { deleteWorkingSourceFailure = value }
    func setInvalidateWorkingSourceFailure(_ value: Error?) { invalidateWorkingSourceFailure = value }

    /// テストが再選択・履歴再接続前提のシナリオ用に直接注入する
    func seedWorkingSource(_ record: WorkingSourceRecord) {
        records[record.projectID] = record
    }

    // MARK: - WorkingSourceStore

    func createProjectWithWorkingSource(_ input: CreateWorkingSourceInput) async throws {
        createProjectWithWorkingSourceCalls.append(input)
        if let gate { await gate.wait() }
        if let failure = createProjectWithWorkingSourceFailure { throw failure }
        records[input.projectID] = WorkingSourceRecord(
            projectID: input.projectID, sourceFile: input.sourceFile, createdAt: input.createdAt
        )
    }

    func replaceWorkingSource(_ input: ReplaceWorkingSourceInput) async throws {
        replaceWorkingSourceCalls.append(input)
        if let gate { await gate.wait() }
        if let failure = replaceWorkingSourceFailure { throw failure }
        records[input.projectID] = WorkingSourceRecord(
            projectID: input.projectID, sourceFile: input.newSourceFile, createdAt: input.replacedAt
        )
    }

    func attachWorkingSourceToExistingProject(_ input: AttachWorkingSourceInput) async throws {
        attachToExistingProjectCalls.append(input)
        if let gate { await gate.wait() }
        if let failure = attachToExistingProjectFailure { throw failure }
        records[input.projectID] = WorkingSourceRecord(
            projectID: input.projectID, sourceFile: input.sourceFile, createdAt: input.attachedAt
        )
    }

    func loadWorkingSource(for projectID: ProjectID) async throws -> WorkingSourceRecord? {
        loadWorkingSourceCalls.append(projectID)
        if let failure = loadWorkingSourceFailure { throw failure }
        return records[projectID]
    }

    func deleteWorkingSource(_ projectID: ProjectID) async throws {
        deleteWorkingSourceCalls.append(projectID)
        if let failure = deleteWorkingSourceFailure { throw failure }
        // 対応する行が無くても許容する（完了操作・プロジェクト破棄のどちらから来ても冪等に扱う）
        records.removeValue(forKey: projectID)
    }

    func invalidateWorkingSource(_ projectID: ProjectID) async throws {
        invalidateWorkingSourceCalls.append(projectID)
        if let failure = invalidateWorkingSourceFailure { throw failure }
        // (b) 非終端キュー項目の paused 更新・(c) PendingFileDeletion 登録は Queue/削除経路の
        // 別ポートの責務でありこのストアの状態には現れない。(a) の行削除だけをここで再現する
        records.removeValue(forKey: projectID)
    }
}
