import Foundation

// 顔単位の共通モデル（image-pipeline.md 1 章「顔検出境界」）。
//
// Vision の型（FaceObservation）を Domain へ流さない。角度は非 Optional
// （FaceObservation.yaw / pitch / roll は Measurement<UnitAngle> で必ず値を持つ。
// 新旧 Vision API の型を混在させないため、Optional な角度が必要になった場合は
// 全体を旧 API へ戻す）。
//
// `expand()` 関数本体は Task 7 の担当のためここには置かない。

/// 検出された顔 1 件分の共通モデル。
public struct DetectedFace: Sendable, Equatable {
    public let faceTrackID: FaceTrackID  // アーキテクチャ設計 6.5
    public let bounds: NormalizedRect    // 左上原点へ変換済み（4 章）
    public let confidence: Double        // 0.0〜1.0
    public let yawDegrees: Double
    public let pitchDegrees: Double
    public let rollDegrees: Double
    public let isSmallFace: Bool         // 検出用画像上の短辺で判定

    public init(
        faceTrackID: FaceTrackID,
        bounds: NormalizedRect,
        confidence: Double,
        yawDegrees: Double,
        pitchDegrees: Double,
        rollDegrees: Double,
        isSmallFace: Bool
    ) {
        self.faceTrackID = faceTrackID
        self.bounds = bounds
        self.confidence = confidence
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
        self.rollDegrees = rollDegrees
        self.isSmallFace = isSmallFace
    }
}
