import Foundation

// レンダリング境界の型群（image-pipeline.md 5 章「写真選択と PhotoKit 境界」の
// 「境界型」小節）。
//
// すべて Foundation のみで表現する。CGImage / CIImage / URL を持たない。実体の参照は
// ManagedFileRef（の種別つきラッパー）のみ（image-pipeline.md 5 章）。
//
// `OriginalCaptureMetadata`（architecture.md 9 章「出力メタデータ」、EXIF 撮影日時。正準スキーマ 5.1）と
// `LoadedPhoto`（image-pipeline.md 5 章、PickedPhotoLoader の戻り値）はいずれも
// image-pipeline.md 5 章の境界型の一部であり、計画の Task 2 行が Produces として
// 明記しているためここに実装する（`OriginalCaptureMetadata` を Task 4 待ちとした前回の
// 判断は誤りだったため撤回）。
//
// `OutputMetadata` / `SourceRepresentation`（architecture.md 同ブロック内の他の型）と
// `PickedPhotoLoader` プロトコルは、どのタスクにも明示割当が無い、または Task 4 の
// 担当であるため今回は追加しない。
//
// `PickedPhotoLoader` / `FaceDetector` / `ImageEffectRenderer` 等のプロトコルと
// `WorkingSourceRecord` 系（Task 4）はスコープ外（spec 参照）。
// `StampRasterizer` と `RasterizedStampAsset` は Rendering/StampRasterizer.swift に
// 実装済み（3 章）。

/// 画像フォーマット。
public enum ImageFormat: Sendable, Hashable {
    case jpeg
    case heic
    case png
}

/// レンダラーへ渡す入力画像。実体は ManagedFileRef からのみ解決する。
/// この型を作れる時点で向きは正規化済み。未正規化の画像は表現できない。
public struct ImageSource: Sendable {
    public let file: ManagedFileRef
    public let pixelSize: PixelSize          // 向き正規化後
    public let format: ImageFormat

    public init(file: ManagedFileRef, pixelSize: PixelSize, format: ImageFormat) {
        self.file = file
        self.pixelSize = pixelSize
        self.format = format
    }
}

/// EXIF の撮影日時。ローカル表記とオフセットを分けて保持する（正準スキーマ 5.1）
public struct OriginalCaptureMetadata: Sendable, Equatable {
    public let dateTimeOriginal: String?      // "YYYY:MM:DD HH:MM:SS"
    public let subSecTimeOriginal: String?
    public let offsetTimeOriginal: String?    // "+09:00" など
    public let utcMillis: Int64?              // offset がある場合のみ算出する

    public init(
        dateTimeOriginal: String?,
        subSecTimeOriginal: String?,
        offsetTimeOriginal: String?,
        utcMillis: Int64?
    ) {
        self.dateTimeOriginal = dateTimeOriginal
        self.subSecTimeOriginal = subSecTimeOriginal
        self.offsetTimeOriginal = offsetTimeOriginal
        self.utcMillis = utcMillis
    }
}

/// PickedPhotoLoader の戻り値
public struct LoadedPhoto: Sendable {
    public let source: ImageSource           // 向き正規化済みの原寸。WorkingSourceRecord が指す実体
    public let capture: OriginalCaptureMetadata  // EXIF 由来（正準スキーマ 5.1）

    public init(source: ImageSource, capture: OriginalCaptureMetadata) {
        self.source = source
        self.capture = capture
    }
}

/// FaceDetector の戻り値。
public struct DetectionResult: Sendable, Equatable {
    public let faces: [DetectedFace]
    public let detectionPixelSize: PixelSize   // 検出器が内部で縮小した後の実寸。isSmallFace の判定に使う
    public let revision: FaceDetectorRevision  // 採用した Vision リビジョン

    public init(faces: [DetectedFace], detectionPixelSize: PixelSize, revision: FaceDetectorRevision) {
        self.faces = faces
        self.detectionPixelSize = detectionPixelSize
        self.revision = revision
    }
}

/// Vision のリビジョン。Vision の型を Domain へ持ち込まない。
public struct FaceDetectorRevision: Sendable, Hashable {
    public let rawValue: Int      // DetectFaceRectanglesRequest.Revision の生値

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// 生ビットマップのチャンネル順序。
public enum RawChannelOrder: Sendable, Equatable {
    case rgba
    case bgra
}

/// 生ビットマップのアルファ形式。
public enum RawAlphaMode: Sendable, Equatable {
    case straight
    case premultiplied
}

/// 生ビットマップのビット深度。
public enum RawBitDepth: Sendable, Equatable {
    case eightPerChannel
}

/// 生ビットマップの色空間。
public enum RawColorSpace: Sendable, Equatable {
    case sRGB
}

/// 生ビットマップの形式。RenderedImage と RasterizedStampAsset が共有する。
public struct RawBitmapDescriptor: Sendable, Equatable {
    public let pixelSize: PixelSize
    public let rowBytes: Int                 // >= pixelSize.width * 4
    public let channelOrder: RawChannelOrder
    public let alpha: RawAlphaMode
    public let bitDepth: RawBitDepth
    public let colorSpace: RawColorSpace

    public init(
        pixelSize: PixelSize,
        rowBytes: Int,
        channelOrder: RawChannelOrder,
        alpha: RawAlphaMode,
        bitDepth: RawBitDepth,
        colorSpace: RawColorSpace
    ) {
        self.pixelSize = pixelSize
        self.rowBytes = rowBytes
        self.channelOrder = channelOrder
        self.alpha = alpha
        self.bitDepth = bitDepth
        self.colorSpace = colorSpace
    }
}

/// ImageEffectRenderer の戻り値。エンコード前のビットマップ。
public struct RenderedImage: Sendable {
    public let file: RasterFileRef
    public let descriptor: RawBitmapDescriptor

    public init(file: RasterFileRef, descriptor: RawBitmapDescriptor) {
        self.file = file
        self.descriptor = descriptor
    }
}

/// 受け渡し対象。MediaSaver と SharePresenter が受け取る。
public struct OutputFile: Sendable {
    public let exportID: ExportID
    public let file: OutputFileRef
    public let format: ImageFormat
    public let byteSize: Int64
    public let suggestedCreationDate: Date?  // 写真ライブラリ保存時の creationDate（5 章）

    public init(
        exportID: ExportID,
        file: OutputFileRef,
        format: ImageFormat,
        byteSize: Int64,
        suggestedCreationDate: Date?
    ) {
        self.exportID = exportID
        self.file = file
        self.format = format
        self.byteSize = byteSize
        self.suggestedCreationDate = suggestedCreationDate
    }
}
