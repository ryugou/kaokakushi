import Foundation
@testable import Application

// FakeRecoveryGate — `RecoveryGate`（Application/RecoveryGate.swift）の偽実装（Issue #7 Task 12）。
//
// 既定では常に開いている（isOpen: true）ため、復旧ゲートを検証しない既存のテストは
// 挙動が変わらない。open() を呼ぶまで awaitRecoveryCompleted() を保留させることもできる
// （SerialTaskQueueTests.swift の OneShotGate と同じ方針）。

actor FakeRecoveryGate: RecoveryGate {
    private var isOpen: Bool
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(isOpen: Bool = true) {
        self.isOpen = isOpen
    }

    func awaitRecoveryCompleted() async throws {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingContinuations = continuations
        continuations.removeAll()
        for continuation in pendingContinuations {
            continuation.resume()
        }
    }
}
