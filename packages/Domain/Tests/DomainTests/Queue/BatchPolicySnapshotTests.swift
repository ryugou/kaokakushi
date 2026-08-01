import Testing
@testable import Domain
import Foundation

/// Task 3: バッチポリシースナップショットの型群（architecture.md 6.4「開始時の設定を固定する」）。
///
/// `BatchKind` の固定rawValue（1/2。列値を宣言順に依存させない規則）、
/// `BatchPolicySnapshot` のフィールド保持を検証する。

private func assertSendableEquatable<T: Sendable & Equatable>(_ value: T) -> T { value }

@Test(
    "BatchKindのrawValueが正本の表どおりproBatch=1/trial=2",
    arguments: [
        (BatchKind.proBatch, UInt32(1)),
        (BatchKind.trial, UInt32(2))
    ]
)
func batchKindRawValueMatchesCanonicalDoc(kind: BatchKind, expected: UInt32) {
    #expect(kind.rawValue == expected)
}

@Test("BatchPolicySnapshotが全フィールドを保持する")
func batchPolicySnapshotHoldsAllFields() {
    let subject = assertSendableEquatable(BatchPolicySnapshot(
        kind: .trial,
        batchSizeLimit: 5,
        trialCreditCount: 5,
        concurrencyLimit: 1
    ))
    #expect(subject.kind == .trial)
    #expect(subject.batchSizeLimit == 5)
    #expect(subject.trialCreditCount == 5)
    #expect(subject.concurrencyLimit == 1)
}

@Test("BatchPolicySnapshotはproBatchのkindでも構築できる")
func batchPolicySnapshotHoldsProBatchKind() {
    let subject = BatchPolicySnapshot(kind: .proBatch, batchSizeLimit: 50, trialCreditCount: 0, concurrencyLimit: 1)
    #expect(subject.kind == .proBatch)
    #expect(subject.batchSizeLimit == 50)
}
