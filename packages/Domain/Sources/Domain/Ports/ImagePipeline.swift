import Foundation

// 画像処理境界のポート（image-pipeline.md「プロトコルのシグネチャ」節）。
//
// `ImageEffectRenderer` / `ImageEncoder` のシグネチャは正本コードブロックから一字一句転記する。
// 実装は別サブプロジェクト（MediaKit）が担当する（アーキテクチャ設計 4.3。Application は
// Domain のプロトコルのみに依存する）。
//
// `PickedPhotoLoader` / `FaceDetector` は素材取り込み（サブプロジェクト5）で使う。実装は
// MediaKit が担当する。
//
// アクセス修飾（public）の方針は ExportSagaStore.swift と同じ（正本の疑似コードには現れないが、
// Application 等の他パッケージが Domain の公開 API として参照するために必要）。

/// image-pipeline.md「プロトコルのシグネチャ」節
public protocol FaceDetector: Sendable {
    func detect(_ source: ImageSource) async throws -> DetectionResult
}

/// image-pipeline.md「プロトコルのシグネチャ」節
public protocol ImageEffectRenderer: Sendable {
    func render(
        source: ImageSource,
        plan: RenderPlan,
        rasterAssets: [String: RasterizedStampAsset]
    ) async throws -> RenderedImage
}

/// image-pipeline.md「プロトコルのシグネチャ」節
public protocol ImageEncoder: Sendable {
    /// メタデータは許可リストで構築する（アーキテクチャ設計 7.5）。実装は保存後に読み返し、
    /// 許可されていない namespace とキーが1つも無いことを検査する義務を負う（検査失敗は
    /// 完成扱いにせず throw し、書き出し Saga のファイル検証失敗として扱う。同節が正本）
    func encode(
        _ image: RenderedImage,
        format: ImageFormat,
        quality: Double,
        metadata: OutputMetadata
    ) async throws -> OutputFileRef
}

/// 出力メタデータ。許可フィールド以外を構造的に持てない（architecture.md 7.5「出力メタデータは
/// 許可リストで構築する」節）。ICC プロファイルの有無・ピクセル寸法・保持する場合の
/// `OriginalCaptureMetadata` のみを持つ。向きは常に通常値（1）として書くためフィールドを持たない。
/// `ImageEncoder` は元画像のメタデータ辞書を受け取らない（コピーして削除する実装を防ぐため）。
public struct OutputMetadata: Sendable, Equatable {
    public let pixelSize: PixelSize
    public let iccProfile: Data?                    // 色が変わる場合のみ埋める
    public let capture: OriginalCaptureMetadata?    // 設定で保持を選んだ場合のみ

    public init(pixelSize: PixelSize, iccProfile: Data?, capture: OriginalCaptureMetadata?) {
        self.pixelSize = pixelSize
        self.iccProfile = iccProfile
        self.capture = capture
    }
}
