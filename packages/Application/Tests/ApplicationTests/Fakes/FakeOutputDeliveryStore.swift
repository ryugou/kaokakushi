import Foundation
import Domain

// FakeOutputDeliveryStore — `OutputDeliveryStore`（Domain/Ports/OutputDeliveryStore.swift）の
// in-memory 偽実装（Issue #7 Task 3）。
//
// 正本は `OutputDeliveryStore` の各メソッドの doc コメント。実 Persistence には依存しない。
// テストは `seedOutput(_:)` で settle 済み（または任意状態）の `OutputRecord` を注入してから
// 各メソッドの事前条件・状態遷移を検証する。`DeliveryAttempt.startedAt` /
// `UnknownLibrarySave.occurredAt` に必要な時刻は `now` クロックで注入する（裸の Date() 禁止）。
//
// Fakes 配下の型はテストターゲット外から参照されないため internal で足りる
// （DomainTests/TestSupport.swift と同じ方針。Task 3 レビュー Suggestion 2）。

/// この偽実装が検査する事前条件違反。
enum FakeOutputDeliveryStoreError: Error, Sendable, Equatable {
    /// 対象 exportID の OutputRecord が seedOutput / seedUnknownLibrarySave 未注入
    case outputNotFound(ExportID)
    /// 対象 OutputRecord.settledAt が nil（beginDeliveryAttempt / completeShare / deleteOutput の
    /// 共通事前条件）
    case outputNotSettled(ExportID)
    /// beginDeliveryAttempt / deleteOutput: 対象 exportID に DeliveryAttempt が既に存在する
    case deliveryAttemptAlreadyInProgress(ExportID)
    /// completeLibrarySave / abandonDeliveryAttempt: 対象 exportID に DeliveryAttempt が無い
    case deliveryAttemptNotFound(ExportID)
}

actor FakeOutputDeliveryStore: OutputDeliveryStore {
    // MARK: - 呼び出し記録

    private(set) var beginDeliveryAttemptCalls: [ExportID] = []
    private(set) var completeLibrarySaveCalls: [ExportID] = []
    private(set) var completeShareCalls: [ExportID] = []
    private(set) var abandonDeliveryAttemptCalls: [ExportID] = []
    private(set) var resolveOrphanedAttemptsCallCount = 0
    private(set) var loadUnknownLibrarySavesCallCount = 0
    private(set) var clearUnknownLibrarySaveCalls: [ExportID] = []
    private(set) var deleteOutputCalls: [ExportID] = []

    // MARK: - 注入可能な失敗

    var beginDeliveryAttemptFailure: Error?
    var completeLibrarySaveFailure: Error?
    var completeShareFailure: Error?
    var abandonDeliveryAttemptFailure: Error?
    var resolveOrphanedAttemptsFailure: Error?
    var loadUnknownLibrarySavesFailure: Error?
    var clearUnknownLibrarySaveFailure: Error?
    var deleteOutputFailure: Error?

    /// true の間、abandonDeliveryAttempt は呼び出された瞬間の `Task.isCancelled` を検査し、
    /// true なら何もせず `CancellationError` を throw する。実ストア
    /// （OutputDeliveryStoreLive+Attempt.swift の dbQueue.write）がキャンセル済み文脈で
    /// 必ず失敗する実装になっているかを模し、呼び出し元（OutputDeliveryCoordinator）が
    /// 後始末をキャンセル非伝播のコンテキストで実行しているかを検証するためのフック
    /// （`FakeExportSagaStore.discardExportChecksCancellation` と同型。既定 false では
    /// 既存の振る舞いを変えない。受け渡し後始末のキャンセルシールド横展開の回帰テスト用）。
    var abandonDeliveryAttemptChecksCancellation = false

    /// true の間、completeLibrarySave は呼び出された瞬間の `Task.isCancelled` を検査し、
    /// true なら何もせず `CancellationError` を throw する。abandonDeliveryAttemptChecksCancellation
    /// と同型だが、こちらは「保存成功直後の完了反映」経路を検証する（Issue #7 レビュー第2
    /// ラウンド W-1: 保存成功直後にキャンセルされても completeLibrarySave が完走することの
    /// 回帰テスト用。既定 false では既存の振る舞いを変えない）。
    var completeLibrarySaveChecksCancellation = false

    // MARK: - in-memory 状態

    private var outputs: [ExportID: OutputRecord] = [:]
    private var activeAttempts: [ExportID: DeliveryAttempt] = [:]
    private var unknownLibrarySaves: [ExportID: UnknownLibrarySave] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    // MARK: - 失敗注入セッター（actor 隔離のため外部から直接代入できない。Issue #7 Task 4 準備）

    func setBeginDeliveryAttemptFailure(_ value: Error?) { beginDeliveryAttemptFailure = value }
    func setCompleteLibrarySaveFailure(_ value: Error?) { completeLibrarySaveFailure = value }
    func setCompleteShareFailure(_ value: Error?) { completeShareFailure = value }
    func setAbandonDeliveryAttemptFailure(_ value: Error?) { abandonDeliveryAttemptFailure = value }
    func setResolveOrphanedAttemptsFailure(_ value: Error?) { resolveOrphanedAttemptsFailure = value }
    func setLoadUnknownLibrarySavesFailure(_ value: Error?) { loadUnknownLibrarySavesFailure = value }
    func setClearUnknownLibrarySaveFailure(_ value: Error?) { clearUnknownLibrarySaveFailure = value }
    func setDeleteOutputFailure(_ value: Error?) { deleteOutputFailure = value }
    func setAbandonDeliveryAttemptChecksCancellation(_ value: Bool) { abandonDeliveryAttemptChecksCancellation = value }
    func setCompleteLibrarySaveChecksCancellation(_ value: Bool) { completeLibrarySaveChecksCancellation = value }

    /// テストが任意状態の OutputRecord を注入する（settledAt の有無・state を含めて呼び出し側が決める）
    func seedOutput(_ record: OutputRecord) {
        outputs[record.exportID] = record
    }

    func seedUnknownLibrarySave(_ save: UnknownLibrarySave) {
        unknownLibrarySaves[save.exportID] = save
    }

    func outputSnapshot(for exportID: ExportID) -> OutputRecord? {
        outputs[exportID]
    }

    func hasActiveAttempt(for exportID: ExportID) -> Bool {
        activeAttempts[exportID] != nil
    }

    // MARK: - OutputDeliveryStore

    func beginDeliveryAttempt(_ exportID: ExportID) async throws {
        beginDeliveryAttemptCalls.append(exportID)
        if let failure = beginDeliveryAttemptFailure { throw failure }
        let record = try settledOutput(for: exportID)
        guard activeAttempts[exportID] == nil else {
            throw FakeOutputDeliveryStoreError.deliveryAttemptAlreadyInProgress(exportID)
        }
        activeAttempts[exportID] = DeliveryAttempt(exportID: exportID, startedAt: now(), previousState: record.state)
    }

    func completeLibrarySave(_ exportID: ExportID) async throws {
        // 呼び出し記録より前に検査する: シールドされていない実装だと、この throw により
        // completeLibrarySaveCalls に記録すら残らない（abandonDeliveryAttempt と同型の検査順序）。
        if completeLibrarySaveChecksCancellation {
            try Task.checkCancellation()
        }
        completeLibrarySaveCalls.append(exportID)
        if let failure = completeLibrarySaveFailure { throw failure }
        try consumeActiveAttempt(for: exportID)
        setState(.delivered, for: exportID)
    }

    func completeShare(_ exportID: ExportID) async throws {
        completeShareCalls.append(exportID)
        if let failure = completeShareFailure { throw failure }
        _ = try settledOutput(for: exportID)
        setState(.delivered, for: exportID)
    }

    func abandonDeliveryAttempt(_ exportID: ExportID) async throws {
        // 呼び出し記録より前に検査する: シールドされていない実装だと、この throw により
        // abandonDeliveryAttemptCalls に記録すら残らない（FakeExportSagaStore.discardExport
        // と同型の検査順序）。
        if abandonDeliveryAttemptChecksCancellation {
            try Task.checkCancellation()
        }
        abandonDeliveryAttemptCalls.append(exportID)
        if let failure = abandonDeliveryAttemptFailure { throw failure }
        let attempt = try consumeActiveAttempt(for: exportID)
        restorePreviousState(attempt.previousState, for: exportID)
    }

    /// 起動時。残存 DeliveryAttempt を previousState に応じて解決する（export-saga.md 7.0 表）。
    /// abandonDeliveryAttempt とは判定規則が異なるため restorePreviousState を再利用しない
    /// （Task 3 レビュー Critical 1: 誤って同一挙動になっていたことの修正）。実 Persistence の
    /// 対応実装は OutputDeliveryStoreLive+Recovery.swift の resolveOrphanedAttempt(_:row:resolvedAt:)。
    func resolveOrphanedAttempts() async throws -> [OutputDeliverySnapshot] {
        resolveOrphanedAttemptsCallCount += 1
        if let failure = resolveOrphanedAttemptsFailure { throw failure }
        let resolvedAt = now()
        for (exportID, attempt) in activeAttempts {
            resolveOrphanedAttempt(attempt, for: exportID, resolvedAt: resolvedAt)
        }
        activeAttempts.removeAll()
        return outputs.values.map { record in
            OutputDeliverySnapshot(output: record, hasUnknownLibrarySave: unknownLibrarySaves[record.exportID] != nil)
        }
    }

    func loadUnknownLibrarySaves() async throws -> [UnknownLibrarySave] {
        loadUnknownLibrarySavesCallCount += 1
        if let failure = loadUnknownLibrarySavesFailure { throw failure }
        return Array(unknownLibrarySaves.values)
    }

    func clearUnknownLibrarySave(_ exportID: ExportID) async throws {
        clearUnknownLibrarySaveCalls.append(exportID)
        if let failure = clearUnknownLibrarySaveFailure { throw failure }
        unknownLibrarySaves.removeValue(forKey: exportID)
    }

    func deleteOutput(_ exportID: ExportID) async throws {
        deleteOutputCalls.append(exportID)
        if let failure = deleteOutputFailure { throw failure }
        _ = try settledOutput(for: exportID)
        guard activeAttempts[exportID] == nil else {
            throw FakeOutputDeliveryStoreError.deliveryAttemptAlreadyInProgress(exportID)
        }
        outputs.removeValue(forKey: exportID)
        unknownLibrarySaves.removeValue(forKey: exportID)   // FK CASCADE 相当
    }

    // MARK: - 内部ヘルパー

    /// settledAt != nil の OutputRecord を返す。未登録・未確定なら throw する
    private func settledOutput(for exportID: ExportID) throws -> OutputRecord {
        guard let record = outputs[exportID] else {
            throw FakeOutputDeliveryStoreError.outputNotFound(exportID)
        }
        guard record.settledAt != nil else {
            throw FakeOutputDeliveryStoreError.outputNotSettled(exportID)
        }
        return record
    }

    /// DeliveryAttempt を取り出して削除する。無ければ throw する
    @discardableResult
    private func consumeActiveAttempt(for exportID: ExportID) throws -> DeliveryAttempt {
        guard let attempt = activeAttempts.removeValue(forKey: exportID) else {
            throw FakeOutputDeliveryStoreError.deliveryAttemptNotFound(exportID)
        }
        return attempt
    }

    private func setState(_ state: OutputState, for exportID: ExportID) {
        guard let record = outputs[exportID] else { return }
        outputs[exportID] = replacingState(record, state: state)
    }

    /// previousState へ戻す。現在が delivered なら維持する（abandonDeliveryAttempt 専用。
    /// resolveOrphanedAttempts は別規則のため resolveOrphanedAttempt(_:for:resolvedAt:) を使う）
    private func restorePreviousState(_ previousState: OutputState, for exportID: ExportID) {
        guard let record = outputs[exportID], record.state != .delivered else { return }
        outputs[exportID] = replacingState(record, state: previousState)
    }

    /// 1件の DeliveryAttempt を previousState と現在の OutputRecord.state に応じて解決する
    /// （export-saga.md 7.0 表）:
    /// - 現在 delivered、または previousState が delivered → UnknownLibrarySave を upsert（状態維持）
    /// - previousState が generated → OutputRecord の状態を deliveryUnknown へ更新
    /// - それ以外（previousState が deliveryUnknown かつ現在も delivered でない）→ 状態維持
    private func resolveOrphanedAttempt(_ attempt: DeliveryAttempt, for exportID: ExportID, resolvedAt: Date) {
        let currentState = outputs[exportID]?.state
        if currentState == .delivered || attempt.previousState == .delivered {
            unknownLibrarySaves[exportID] = UnknownLibrarySave(exportID: exportID, occurredAt: resolvedAt)
        } else if attempt.previousState == .generated {
            setState(.deliveryUnknown, for: exportID)
        }
    }

    private func replacingState(_ record: OutputRecord, state: OutputState) -> OutputRecord {
        OutputRecord(
            exportID: record.exportID,
            projectID: record.projectID,
            batchID: record.batchID,
            outputFile: record.outputFile,
            outputByteSize: record.outputByteSize,
            outputSHA256: record.outputSHA256,
            state: state,
            generatedAt: record.generatedAt,
            settledAt: record.settledAt,
            expiresAt: record.expiresAt,
            format: record.format,
            suggestedCreationDate: record.suggestedCreationDate
        )
    }
}
