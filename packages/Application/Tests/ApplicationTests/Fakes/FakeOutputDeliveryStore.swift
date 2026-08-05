import Foundation
import Domain

// FakeOutputDeliveryStore — `OutputDeliveryStore`（Domain/Ports/OutputDeliveryStore.swift）の
// in-memory 偽実装（Issue #7 Task 3）。
//
// 正本は `OutputDeliveryStore` の各メソッドの doc コメント。実 Persistence には依存しない。
// テストは `seedOutput(_:)` で settle 済み（または任意状態）の `OutputRecord` を注入してから
// 各メソッドの事前条件・状態遷移を検証する。`DeliveryAttempt.startedAt` /
// `UnknownLibrarySave.occurredAt` に必要な時刻は `now` クロックで注入する（裸の Date() 禁止）。

/// この偽実装が検査する事前条件違反。
public enum FakeOutputDeliveryStoreError: Error, Sendable, Equatable {
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

public actor FakeOutputDeliveryStore: OutputDeliveryStore {
    // MARK: - 呼び出し記録

    public private(set) var beginDeliveryAttemptCalls: [ExportID] = []
    public private(set) var completeLibrarySaveCalls: [ExportID] = []
    public private(set) var completeShareCalls: [ExportID] = []
    public private(set) var abandonDeliveryAttemptCalls: [ExportID] = []
    public private(set) var resolveOrphanedAttemptsCallCount = 0
    public private(set) var loadUnknownLibrarySavesCallCount = 0
    public private(set) var clearUnknownLibrarySaveCalls: [ExportID] = []
    public private(set) var deleteOutputCalls: [ExportID] = []

    // MARK: - 注入可能な失敗

    public var beginDeliveryAttemptFailure: Error?
    public var completeLibrarySaveFailure: Error?
    public var completeShareFailure: Error?
    public var abandonDeliveryAttemptFailure: Error?
    public var resolveOrphanedAttemptsFailure: Error?
    public var loadUnknownLibrarySavesFailure: Error?
    public var clearUnknownLibrarySaveFailure: Error?
    public var deleteOutputFailure: Error?

    // MARK: - in-memory 状態

    private var outputs: [ExportID: OutputRecord] = [:]
    private var activeAttempts: [ExportID: DeliveryAttempt] = [:]
    private var unknownLibrarySaves: [ExportID: UnknownLibrarySave] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    /// テストが任意状態の OutputRecord を注入する（settledAt の有無・state を含めて呼び出し側が決める）
    public func seedOutput(_ record: OutputRecord) {
        outputs[record.exportID] = record
    }

    public func seedUnknownLibrarySave(_ save: UnknownLibrarySave) {
        unknownLibrarySaves[save.exportID] = save
    }

    public func outputSnapshot(for exportID: ExportID) -> OutputRecord? {
        outputs[exportID]
    }

    public func hasActiveAttempt(for exportID: ExportID) -> Bool {
        activeAttempts[exportID] != nil
    }

    // MARK: - OutputDeliveryStore

    public func beginDeliveryAttempt(_ exportID: ExportID) async throws {
        beginDeliveryAttemptCalls.append(exportID)
        if let failure = beginDeliveryAttemptFailure { throw failure }
        let record = try settledOutput(for: exportID)
        guard activeAttempts[exportID] == nil else {
            throw FakeOutputDeliveryStoreError.deliveryAttemptAlreadyInProgress(exportID)
        }
        activeAttempts[exportID] = DeliveryAttempt(exportID: exportID, startedAt: now(), previousState: record.state)
    }

    public func completeLibrarySave(_ exportID: ExportID) async throws {
        completeLibrarySaveCalls.append(exportID)
        if let failure = completeLibrarySaveFailure { throw failure }
        try consumeActiveAttempt(for: exportID)
        setState(.delivered, for: exportID)
    }

    public func completeShare(_ exportID: ExportID) async throws {
        completeShareCalls.append(exportID)
        if let failure = completeShareFailure { throw failure }
        _ = try settledOutput(for: exportID)
        setState(.delivered, for: exportID)
    }

    public func abandonDeliveryAttempt(_ exportID: ExportID) async throws {
        abandonDeliveryAttemptCalls.append(exportID)
        if let failure = abandonDeliveryAttemptFailure { throw failure }
        let attempt = try consumeActiveAttempt(for: exportID)
        restorePreviousState(attempt.previousState, for: exportID)
    }

    public func resolveOrphanedAttempts() async throws -> [OutputDeliverySnapshot] {
        resolveOrphanedAttemptsCallCount += 1
        if let failure = resolveOrphanedAttemptsFailure { throw failure }
        for (exportID, attempt) in activeAttempts {
            restorePreviousState(attempt.previousState, for: exportID)
        }
        activeAttempts.removeAll()
        return outputs.values.map { record in
            OutputDeliverySnapshot(output: record, hasUnknownLibrarySave: unknownLibrarySaves[record.exportID] != nil)
        }
    }

    public func loadUnknownLibrarySaves() async throws -> [UnknownLibrarySave] {
        loadUnknownLibrarySavesCallCount += 1
        if let failure = loadUnknownLibrarySavesFailure { throw failure }
        return Array(unknownLibrarySaves.values)
    }

    public func clearUnknownLibrarySave(_ exportID: ExportID) async throws {
        clearUnknownLibrarySaveCalls.append(exportID)
        if let failure = clearUnknownLibrarySaveFailure { throw failure }
        unknownLibrarySaves.removeValue(forKey: exportID)
    }

    public func deleteOutput(_ exportID: ExportID) async throws {
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

    /// previousState へ戻す。現在が delivered なら維持する（abandon / resolveOrphanedAttempts 共通）
    private func restorePreviousState(_ previousState: OutputState, for exportID: ExportID) {
        guard let record = outputs[exportID], record.state != .delivered else { return }
        outputs[exportID] = replacingState(record, state: previousState)
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
