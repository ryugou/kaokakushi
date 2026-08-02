import Testing
@testable import Domain
import Foundation

// 閾値注入の直接検証（Issue #20、codex レビュー指摘対応）。
//
// TriageTests.swift のラッパーは暫定閾値 45.0 を固定するため、注入経路そのものは
// 検証しない。ここでは Domain.triage を直接呼び、yaw / pitch の閾値を変えると同じ
// 入力に対する extremePose の発火が切り替わることを固定する（固定値への回帰や
// 引数の取り違えを検出する）。face / detectionResult は TestSupport.swift の共有ヘルパー。

// (yawDegrees, pitchDegrees, thresholdDegrees, expectedFires)
// swiftlint:disable:next large_tuple
private let triageThresholdInjectionCases: [(Double, Double, Double, Bool)] = [
    (30.0, 0.0, 20.0, true),
    (30.0, 0.0, 40.0, false),
    (0.0, 30.0, 20.0, true),
    (0.0, 30.0, 40.0, false)
]

@Test(
    "extremePoseYawDegrees/extremePosePitchDegreesの注入値で発火が切り替わる",
    arguments: triageThresholdInjectionCases
)
func triageExtremePoseRespectsInjectedThreshold(
    yawDegrees: Double,
    pitchDegrees: Double,
    thresholdDegrees: Double,
    expectedFires: Bool
) throws {
    let target = try face(yawDegrees: yawDegrees, pitchDegrees: pitchDegrees)
    let result = detectionResult([target])

    let issues = triage(
        result,
        projectID: ProjectID(rawValue: UUID()),
        detectionRevision: 1,
        extremePoseYawDegrees: thresholdDegrees,
        extremePosePitchDegrees: thresholdDegrees
    )

    let fired = issues.contains { $0.id.reason == .extremePose }
    #expect(fired == expectedFires)
}
