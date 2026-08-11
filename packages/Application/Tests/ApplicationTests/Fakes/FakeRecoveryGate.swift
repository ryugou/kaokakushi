import Foundation
@testable import Application

// FakeRecoveryGate — `RecoveryGate`（Application/RecoveryGate.swift）の偽実装（Issue #7 Task 12。
// Task 12 再レビュー S-3 で本物の StartupRecoveryCoordinator と同じ契約に合わせた）。
//
// 既定では常に開いている（isOpen: true）ため、復旧ゲートを検証しない既存のテストは
// 挙動が変わらない。open() を呼ぶまで awaitRecoveryCompleted() を保留させることもできる
// （SerialTaskQueueTests.swift の OneShotGate と同じ方針）。fail(_:) で復旧の失敗確定を模せる
// （RecoveryGate.swift の契約どおり、以後の awaitRecoveryCompleted は待たず
// StartupRecoveryFailedError を throw する）。待機中にキャンセルされた場合は waiters から
// 自身を除去したうえで CancellationError を throw する（本物の StartupRecoveryCoordinator の
// waiterID 方式と同じ。二重 resume を避けるため cancelWaiter / open / fail のいずれが先に
// waiters からこの waiterID を取り除いても、取り除いた側だけが resume する）。

actor FakeRecoveryGate: RecoveryGate {
    private var isOpen: Bool
    private var failure: Error?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(isOpen: Bool = true) {
        self.isOpen = isOpen
    }

    func awaitRecoveryCompleted() async throws {
        if isOpen { return }
        if let failure {
            throw StartupRecoveryFailedError(cause: failure)
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    func open() {
        guard !isOpen, failure == nil else { return }
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for continuation in pendingWaiters.values {
            continuation.resume()
        }
    }

    /// 復旧が失敗で確定したことを模す（本物の StartupRecoveryCoordinator.failGate と同じ契約）。
    func fail(_ cause: Error) {
        guard !isOpen, failure == nil else { return }
        failure = cause
        let pendingWaiters = waiters
        waiters.removeAll()
        for continuation in pendingWaiters.values {
            continuation.resume(throwing: StartupRecoveryFailedError(cause: cause))
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
    }
}
