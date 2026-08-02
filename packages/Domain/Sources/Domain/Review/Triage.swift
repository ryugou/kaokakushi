import Foundation

// 顔単位のトリアージ判定（architecture.md 6.1「顔・レビュー状態」の「トリアージ判定」節、
// 「検出ステータスと確認ステータス」節、「要確認への対応」節から一字一句転記）。
//
// `lowConfidence` は列挙値として保持するが、`triage` は confidence を一切見ず発火させない
// （architecture.md 12 章「未決事項」: 「暫定運用: v1 初期リリースでは lowConfidence の
// トリアージを無効（閾値未設定）で出し、実測後の更新で有効化する」との確定済み方針）。
//
// `extremePose` の角度閾値（暫定 yaw / pitch 45°。12 章「実測後に確定する」）は Domain が
// 設定定数の型を参照できないため、`triage` の引数として呼び出し側から注入する
// （architecture.md 6.1 のシグネチャ）。

public enum ReviewReason: Sendable, Hashable {
    case noFaceDetected
    case lowConfidence
    case smallFace
    case extremePose
    case faceAtEdge
    case overlappingFaces
}

// 警告 1 件の同一性。理由ではなく「発生」を識別する。
public struct ReviewIssueID: Sendable, Hashable {
    public let projectID: ProjectID
    public let detectionRevision: Int64
    public let reason: ReviewReason
    public let affectedFaceTrackIDs: [FaceTrackID]   // 辞書順にソート済み

    public init(
        projectID: ProjectID,
        detectionRevision: Int64,
        reason: ReviewReason,
        affectedFaceTrackIDs: [FaceTrackID]
    ) {
        self.projectID = projectID
        self.detectionRevision = detectionRevision
        self.reason = reason
        self.affectedFaceTrackIDs = affectedFaceTrackIDs
    }
}

public struct ReviewIssue: Sendable, Equatable {
    public let id: ReviewIssueID

    public init(id: ReviewIssueID) {
        self.id = id
    }
}

extension ReviewIssue {
    // ID から導出する。二重に持たない。
    public var affectedFaceTrackIDs: [FaceTrackID] { id.affectedFaceTrackIDs }
}

// 検出ステータス（triage の結果）と確認ステータス（利用者の操作）は別の軸として持つ
// （architecture.md 6.1「検出ステータスと確認ステータス」）。
public enum DetectionStatus: Sendable { case normal, reviewRequired }
public enum ReviewStatus: Sendable { case unreviewed, reviewed }

public enum ReviewResolution: Sendable, Equatable {
    // 内容を見て、このままでよいと判断した
    case acceptedAsIs

    // 手動で隠す範囲を追加した。どの領域かを保持する
    case manualRegionAdded(regionID: RegionID)

    // 顔を隠さずそのまま保存すると選んだ
    case unmaskedExportConfirmed
}

public struct ReviewDecision: Sendable, Equatable {
    public let resolutions: [ReviewIssueID: ReviewResolution]

    public init(resolutions: [ReviewIssueID: ReviewResolution]) {
        self.resolutions = resolutions
    }
}

// 拡張率の暫定既定値（image-pipeline.md 1 章「拡張率の適用」: 上 25% / 下 15% / 左右 15%）。
// これは Task 7 の `expand(face:effect:)` の代替実装ではない。EffectSetting を必要としない
// triage 専用の簡易境界チェックのため別名にし、`private` として名前の衝突を避ける。
private let edgeCheckExpandTop = 0.25
private let edgeCheckExpandBottom = 0.15
private let edgeCheckExpandSide = 0.15

public func triage(
    _ result: DetectionResult,
    projectID: ProjectID,
    detectionRevision: Int64,
    extremePoseYawDegrees: Double,
    extremePosePitchDegrees: Double
) -> [ReviewIssue] {
    if result.faces.isEmpty {
        let id = ReviewIssueID(
            projectID: projectID,
            detectionRevision: detectionRevision,
            reason: .noFaceDetected,
            affectedFaceTrackIDs: []
        )
        return [ReviewIssue(id: id)]
    }

    let faces = result.faces
    var issues: [ReviewIssue] = []
    issues += singleFaceIssues(
        faces,
        reason: .smallFace,
        projectID: projectID,
        detectionRevision: detectionRevision,
        matches: { $0.isSmallFace }
    )
    issues += singleFaceIssues(
        faces,
        reason: .extremePose,
        projectID: projectID,
        detectionRevision: detectionRevision,
        matches: { face in
            isExtremePose(
                face,
                extremePoseYawDegrees: extremePoseYawDegrees,
                extremePosePitchDegrees: extremePosePitchDegrees
            )
        }
    )
    issues += singleFaceIssues(
        faces,
        reason: .faceAtEdge,
        projectID: projectID,
        detectionRevision: detectionRevision,
        matches: isFaceAtEdge
    )
    issues += overlappingFacesIssues(faces, projectID: projectID, detectionRevision: detectionRevision)
    return issues
}

// smallFace / extremePose / faceAtEdge は「顔ごとに 1 件」という同じ発生単位を共有する
// （architecture.md 6.1 の表）。判定述語だけを差し替えて 1 つの実装にまとめる。
private func singleFaceIssues(
    _ faces: [DetectedFace],
    reason: ReviewReason,
    projectID: ProjectID,
    detectionRevision: Int64,
    matches: (DetectedFace) -> Bool
) -> [ReviewIssue] {
    faces.filter(matches).map { face in
        let id = ReviewIssueID(
            projectID: projectID,
            detectionRevision: detectionRevision,
            reason: reason,
            affectedFaceTrackIDs: [face.faceTrackID]
        )
        return ReviewIssue(id: id)
    }
}

private func isExtremePose(
    _ face: DetectedFace,
    extremePoseYawDegrees: Double,
    extremePosePitchDegrees: Double
) -> Bool {
    // 非有限（NaN/無限大）は安全側（extremePose扱い）へ倒す（architecture.md 6.1）。
    // NaNは`abs(NaN) > threshold`が常にfalseになり素通しされるため、先に明示チェックする。
    guard face.yawDegrees.isFinite, face.pitchDegrees.isFinite else {
        return true
    }
    return abs(face.yawDegrees) > extremePoseYawDegrees || abs(face.pitchDegrees) > extremePosePitchDegrees
}

private func isFaceAtEdge(_ face: DetectedFace) -> Bool {
    isAtEdgeAfterDefaultExpansion(face.bounds)
}

// triage の境界チェック。image-pipeline.md 1 章の既定拡張率
// （上 25% / 下 15% / 左右 15%）を適用した矩形が画像境界（0...1）へ接するかを見る。
// 拡張式そのものは expandedEdges（Compile.swift）と共有する。
private func isAtEdgeAfterDefaultExpansion(_ bounds: NormalizedRect) -> Bool {
    let edges = expandedEdges(
        of: bounds,
        top: edgeCheckExpandTop,
        bottom: edgeCheckExpandBottom,
        leading: edgeCheckExpandSide,
        trailing: edgeCheckExpandSide
    )
    return edges.left <= 0 || edges.top <= 0 || edges.right >= 1 || edges.bottom >= 1
}

// overlappingFaces は「重なる顔の組み合わせごとに 1 件」（architecture.md 6.1 の表）。
// 全顔のペアを総当たりでチェックする。
private func overlappingFacesIssues(
    _ faces: [DetectedFace],
    projectID: ProjectID,
    detectionRevision: Int64
) -> [ReviewIssue] {
    var issues: [ReviewIssue] = []
    for firstIndex in 0..<faces.count {
        for secondIndex in (firstIndex + 1)..<faces.count {
            let first = faces[firstIndex]
            let second = faces[secondIndex]
            guard overlaps(first.bounds, second.bounds) else { continue }

            let pair = [first.faceTrackID, second.faceTrackID]
                .sorted { faceTrackIDBytes($0).lexicographicallyPrecedes(faceTrackIDBytes($1)) }
            let id = ReviewIssueID(
                projectID: projectID,
                detectionRevision: detectionRevision,
                reason: .overlappingFaces,
                affectedFaceTrackIDs: pair
            )
            issues.append(ReviewIssue(id: id))
        }
    }
    return issues
}

// UUID の16バイトを符号なしバイト列として辞書順に比較するための配列化
// （canonical-schema.md 2.1「unordered な集合に UUID を含む場合」の規則）。
private func faceTrackIDBytes(_ faceTrackID: FaceTrackID) -> [UInt8] {
    let raw = faceTrackID.rawValue.uuid
    return [
        raw.0, raw.1, raw.2, raw.3, raw.4, raw.5, raw.6, raw.7,
        raw.8, raw.9, raw.10, raw.11, raw.12, raw.13, raw.14, raw.15
    ]
}

private func overlaps(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Bool {
    lhs.left < rhs.rightExclusive && rhs.left < lhs.rightExclusive
        && lhs.top < rhs.bottomExclusive && rhs.top < lhs.bottomExclusive
}
