import Testing
@testable import Domain
import Foundation

/// Task 6: 顔単位のトリアージ判定（architecture.md 6.1「トリアージ判定」節、
/// 「検出ステータスと確認ステータス」節）。
///
/// `triage` の6理由の単独・複合・空集合、`noFaceDetected`/`smallFace`/`extremePose`/
/// `faceAtEdge`/`overlappingFaces` それぞれの発生単位、`lowConfidence` がv1では一切
/// 発火しないこと、`ReviewIssueID` の識別性（detectionRevision / projectID）、
/// `ReviewIssue.affectedFaceTrackIDs` がidから導出されること、`triage` の結果件数から
/// `DetectionStatus` が導出されることを検証する。

private func face(
    trackID: FaceTrackID = FaceTrackID(rawValue: UUID()),
    left: Double = 0.4,
    top: Double = 0.3,
    right: Double = 0.6,
    bottom: Double = 0.7,
    confidence: Double = 0.9,
    yawDegrees: Double = 0,
    pitchDegrees: Double = 0,
    isSmallFace: Bool = false
) throws -> DetectedFace {
    let bounds = try NormalizedRect(left: left, top: top, rightExclusive: right, bottomExclusive: bottom)
    return DetectedFace(
        faceTrackID: trackID,
        bounds: bounds,
        confidence: confidence,
        yawDegrees: yawDegrees,
        pitchDegrees: pitchDegrees,
        rollDegrees: 0,
        isSmallFace: isSmallFace
    )
}

private func detectionResult(_ faces: [DetectedFace]) -> DetectionResult {
    DetectionResult(
        faces: faces,
        detectionPixelSize: PixelSize(width: 1000, height: 1000),
        revision: FaceDetectorRevision(rawValue: 3)
    )
}

// MARK: - 空集合・単独発生

@Test("要確認理由が無い写真ではtriageが空集合を返す")
func triageReturnsEmptyWhenNoIssues() throws {
    let normalFace = try face()
    let result = detectionResult([normalFace])

    let issues = triage(result, projectID: ProjectID(rawValue: UUID()), detectionRevision: 1)

    #expect(issues.isEmpty)
}

@Test("顔が1つも検出されない場合noFaceDetectedが1件だけaffectedFaceTrackIDs空で返る")
func triageReturnsNoFaceDetectedWhenFacesEmpty() {
    let result = detectionResult([])
    let projectID = ProjectID(rawValue: UUID())

    let issues = triage(result, projectID: projectID, detectionRevision: 1)

    #expect(issues.count == 1)
    #expect(issues[0].id.reason == .noFaceDetected)
    #expect(issues[0].affectedFaceTrackIDs.isEmpty)
}

@Test("isSmallFace=trueの顔ごとに1件smallFaceが発生しfaceTrackIDが対象顔のみになる")
func triageReturnsOneSmallFaceIssuePerSmallFace() throws {
    let smallOne = try face(isSmallFace: true)
    let normalOne = try face(left: 0.1, top: 0.1, right: 0.2, bottom: 0.2)
    let result = detectionResult([smallOne, normalOne])

    let issues = triage(result, projectID: ProjectID(rawValue: UUID()), detectionRevision: 1)

    #expect(issues.count == 1)
    #expect(issues[0].id.reason == .smallFace)
    #expect(issues[0].affectedFaceTrackIDs == [smallOne.faceTrackID])
}

@Test("小さい顔が3人ならsmallFaceが3件になり各件が対象顔1つだけを指す")
func triageReturnsThreeSmallFaceIssuesForThreeSmallFaces() throws {
    let smallFaces = [
        try face(left: 0.15, top: 0.15, right: 0.25, bottom: 0.25, isSmallFace: true),
        try face(left: 0.4, top: 0.4, right: 0.5, bottom: 0.5, isSmallFace: true),
        try face(left: 0.65, top: 0.65, right: 0.75, bottom: 0.75, isSmallFace: true)
    ]
    let result = detectionResult(smallFaces)

    let issues = triage(result, projectID: ProjectID(rawValue: UUID()), detectionRevision: 1)

    #expect(issues.count == 3)
    #expect(issues.allSatisfy { $0.id.reason == .smallFace })
    #expect(Set(issues.flatMap(\.affectedFaceTrackIDs)) == Set(smallFaces.map(\.faceTrackID)))
    #expect(issues.allSatisfy { $0.affectedFaceTrackIDs.count == 1 })
}

@Test(
    "yaw/pitchの絶対値が45度ちょうどでは発火せず45.01度で発火する（境界値）",
    arguments: [
        (45.0, 0.0, false),
        (45.01, 0.0, true),
        (0.0, 45.0, false),
        (0.0, 45.01, true),
        (-45.01, 0.0, true)
    ]
)
func triageExtremePoseBoundary(yawDegrees: Double, pitchDegrees: Double, expectedFires: Bool) throws {
    let target = try face(yawDegrees: yawDegrees, pitchDegrees: pitchDegrees)
    let result = detectionResult([target])

    let issues = triage(result, projectID: ProjectID(rawValue: UUID()), detectionRevision: 1)

    let fired = issues.contains { $0.id.reason == .extremePose }
    #expect(fired == expectedFires)
}

@Test(
    "confidenceがどんな値でもlowConfidenceは発火しない（v1無効化の確認）",
    arguments: [0.0, 0.3, 0.5, 1.0]
)
func triageNeverFiresLowConfidence(confidence: Double) throws {
    let target = try face(confidence: confidence)
    let result = detectionResult([target])

    let issues = triage(result, projectID: ProjectID(rawValue: UUID()), detectionRevision: 1)

    #expect(issues.allSatisfy { $0.id.reason != .lowConfidence })
}

@Test(
    "拡張後の領域が画像境界に接するかどうかでfaceAtEdgeの発火が決まる（境界値）",
    arguments: [
        (0.10, 0.50, true),
        (0.11, 0.51, false)
    ]
)
func triageFaceAtEdgeBoundary(top: Double, bottom: Double, expectedFires: Bool) throws {
    let target = try face(left: 0.4, top: top, right: 0.6, bottom: bottom)
    let result = detectionResult([target])

    let issues = triage(result, projectID: ProjectID(rawValue: UUID()), detectionRevision: 1)

    let fired = issues.contains { $0.id.reason == .faceAtEdge }
    #expect(fired == expectedFires)
}

@Test("3人が互いに重なる場合overlappingFacesはペアごとに3件になりaffectedFaceTrackIDsが辞書順になる")
func triageOverlappingFacesProducesOnePerPairSortedByUUIDString() throws {
    let faceA = try face(left: 0.10, top: 0.15, right: 0.50, bottom: 0.55)
    let faceB = try face(left: 0.20, top: 0.15, right: 0.60, bottom: 0.55)
    let faceC = try face(left: 0.30, top: 0.15, right: 0.70, bottom: 0.55)
    let result = detectionResult([faceA, faceB, faceC])

    let issues = triage(result, projectID: ProjectID(rawValue: UUID()), detectionRevision: 1)

    let overlapIssues = issues.filter { $0.id.reason == .overlappingFaces }
    #expect(overlapIssues.count == 3)
    for issue in overlapIssues {
        let trackIDs = issue.affectedFaceTrackIDs
        #expect(trackIDs.count == 2)
        #expect(trackIDs == trackIDs.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString })
    }
}

// MARK: - 複合発生

@Test("1枚の写真で複数の理由が複合発生した場合それぞれ個別のReviewIssueとして返る")
func triageReturnsMultipleIssuesWhenSeveralReasonsCoOccur() throws {
    let small = try face(isSmallFace: true)
    let posed = try face(left: 0.05, top: 0.4, right: 0.15, bottom: 0.5, yawDegrees: 60)
    let result = detectionResult([small, posed])

    let issues = triage(result, projectID: ProjectID(rawValue: UUID()), detectionRevision: 1)

    #expect(issues.contains { $0.id.reason == .smallFace })
    #expect(issues.contains { $0.id.reason == .extremePose })
    #expect(issues.count == 2)
}

// MARK: - ReviewIssueID の識別性

@Test("detectionRevisionが異なればsmallFaceのReviewIssueIDも別IDになる")
func reviewIssueIDDiffersByDetectionRevision() throws {
    let target = try face(isSmallFace: true)
    let result = detectionResult([target])
    let projectID = ProjectID(rawValue: UUID())

    let issuesAtRevisionOne = triage(result, projectID: projectID, detectionRevision: 1)
    let issuesAtRevisionTwo = triage(result, projectID: projectID, detectionRevision: 2)

    #expect(issuesAtRevisionOne[0].id != issuesAtRevisionTwo[0].id)
}

@Test("同じdetectionRevisionでも別写真ならnoFaceDetectedのReviewIssueIDが別IDになる")
func reviewIssueIDDiffersByProjectIDForNoFaceDetected() {
    let result = detectionResult([])
    let projectOne = ProjectID(rawValue: UUID())
    let projectTwo = ProjectID(rawValue: UUID())

    let issuesForProjectOne = triage(result, projectID: projectOne, detectionRevision: 1)
    let issuesForProjectTwo = triage(result, projectID: projectTwo, detectionRevision: 1)

    #expect(issuesForProjectOne[0].id != issuesForProjectTwo[0].id)
}

// MARK: - ReviewIssue.affectedFaceTrackIDs の導出

@Test("ReviewIssue.affectedFaceTrackIDsはidから導出され別フィールドを持たない")
func reviewIssueAffectedFaceTrackIDsDerivesFromID() throws {
    let target = try face(isSmallFace: true)
    let result = detectionResult([target])

    let issues = triage(result, projectID: ProjectID(rawValue: UUID()), detectionRevision: 1)

    #expect(issues[0].affectedFaceTrackIDs == issues[0].id.affectedFaceTrackIDs)
}

// MARK: - DetectionStatus の導出（triage の件数として検証する）

@Test("triageが空集合ならnormal相当、1件以上ならreviewRequired相当になる")
func detectionStatusDerivesFromTriageResultCount() throws {
    let normalFace = try face()
    let smallFace = try face(isSmallFace: true)
    let projectID = ProjectID(rawValue: UUID())

    let normalIssues = triage(detectionResult([normalFace]), projectID: projectID, detectionRevision: 1)
    let reviewRequiredIssues = triage(detectionResult([smallFace]), projectID: projectID, detectionRevision: 1)

    #expect(normalIssues.isEmpty)
    #expect(!reviewRequiredIssues.isEmpty)
}

// MARK: - ReviewDecision / ReviewResolution

@Test("ReviewDecisionがresolutionsをReviewIssueIDごとに保持する")
func reviewDecisionHoldsResolutionsByIssueID() throws {
    let target = try face(isSmallFace: true)
    let issues = triage(detectionResult([target]), projectID: ProjectID(rawValue: UUID()), detectionRevision: 1)
    let issue = issues[0]
    let regionID = RegionID(rawValue: UUID())
    let decision = ReviewDecision(resolutions: [issue.id: .manualRegionAdded(regionID: regionID)])

    #expect(decision.resolutions[issue.id] == .manualRegionAdded(regionID: regionID))
}
