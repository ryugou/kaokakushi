import Foundation
@testable import Domain

// DomainTests 全体で共有するテストヘルパー。
// 各テストファイルへ同じ定義をコピーせず、ここへ集約する（simplify レビュー指摘）。
// ファイル固有のフィクスチャ（値の意味がそのテストに閉じるもの）は各ファイルの
// private ヘルパーのままでよい。

/// コンパイル時に Sendable & Equatable への準拠を要求するアサーション。
func assertSendableEquatable<T: Sendable & Equatable>(_ value: T) -> T { value }

/// コンパイル時に Sendable & Hashable への準拠を要求するアサーション。
func assertSendableHashable<T: Sendable & Hashable>(_ value: T) -> T { value }

/// kind = .output の ManagedFileRef から OutputFileRef を組み立てる。
func makeOutputFileRef() -> OutputFileRef {
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    guard let outputRef = OutputFileRef(ref) else {
        fatalError("test setup invariant violated: kind must be .output")
    }
    return outputRef
}

/// 全面 crop・fit・背景なし・領域なしの最小 RenderSpec。
func makeRenderSpec() throws -> RenderSpec {
    let rect = try NormalizedRect(left: 0, top: 0, rightExclusive: 1, bottomExclusive: 1)
    return RenderSpec(sourceCrop: rect, scaleMode: .fit, background: .none, regions: [])
}

/// トリアージ系テストの DetectedFace フィクスチャ（既定は要確認理由の無い中央の顔）。
func face(
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

/// トリアージ系テストの DetectionResult フィクスチャ。
func detectionResult(_ faces: [DetectedFace]) -> DetectionResult {
    DetectionResult(
        faces: faces,
        detectionPixelSize: PixelSize(width: 1000, height: 1000),
        revision: FaceDetectorRevision(rawValue: 3)
    )
}

/// Free 相当を既定とした ResolvedCapabilities のビルダー。必要なフラグだけ上書きする。
func capabilities(
    canUsePremiumStamps: Bool = false,
    canUseCustomStamps: Bool = false,
    singleExportAccess: SingleExportAccess = .metered,
    canUseProBatch: Bool = false,
    canUseBatchTrial: Bool = false,
    shouldShowAds: Bool = true
) -> ResolvedCapabilities {
    ResolvedCapabilities(
        singleExportAccess: singleExportAccess,
        canUsePremiumStamps: canUsePremiumStamps,
        canUseCustomStamps: canUseCustomStamps,
        enabledStampPacks: [],
        canUseProBatch: canUseProBatch,
        canUseBatchTrial: canUseBatchTrial,
        shouldShowAds: shouldShowAds
    )
}
