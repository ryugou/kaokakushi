import Testing
@testable import Domain
import Foundation

// Task 2: 顔検出モデルとレンダリング境界型（image-pipeline.md 1 章「顔単位の共通モデル」、
// 5 章「境界型」小節）。
//
// `LoadedPhoto` は正本（image-pipeline.md 5 章）どおり Equatable ではないため、
// 等価性テストは書かず「全フィールドを保持できる」ことのみを固定する。
// `Date()`（引数なし）は packages/Domain では禁止のため、`OutputFile` のテストでは
// `Date(timeIntervalSince1970:)` を使う。

private func makeNormalizedRect() throws -> NormalizedRect {
    try NormalizedRect(left: 0.2, top: 0.2, rightExclusive: 0.6, bottomExclusive: 0.6)
}

// MARK: - DetectedFace（image-pipeline.md 1 章）

@Test("DetectedFaceは全フィールドをそのまま保持する")
func detectedFaceHoldsAllFields() throws {
    let faceTrackID = FaceTrackID(rawValue: UUID())
    let bounds = try makeNormalizedRect()

    let subject = DetectedFace(
        faceTrackID: faceTrackID,
        bounds: bounds,
        confidence: 0.92,
        yawDegrees: 5.5,
        pitchDegrees: -3.2,
        rollDegrees: 1.0,
        isSmallFace: false
    )

    #expect(subject.faceTrackID == faceTrackID)
    #expect(subject.bounds == bounds)
    #expect(subject.confidence == 0.92)
    #expect(subject.yawDegrees == 5.5)
    #expect(subject.pitchDegrees == -3.2)
    #expect(subject.rollDegrees == 1.0)
    #expect(subject.isSmallFace == false)
}

@Test("DetectedFaceは角度が非Optionalである（Double型で保持できる）")
func detectedFaceAnglesAreNonOptionalDoubles() throws {
    let subject = DetectedFace(
        faceTrackID: FaceTrackID(rawValue: UUID()),
        bounds: try makeNormalizedRect(),
        confidence: 0.5,
        yawDegrees: 0,
        pitchDegrees: 0,
        rollDegrees: 0,
        isSmallFace: true
    )
    let yaw: Double = subject.yawDegrees
    let pitch: Double = subject.pitchDegrees
    let roll: Double = subject.rollDegrees
    #expect(yaw == 0)
    #expect(pitch == 0)
    #expect(roll == 0)
}

@Test("DetectedFaceは全フィールドが一致する場合のみEquatableで等しい")
func detectedFaceEqualityRequiresAllFieldsToMatch() throws {
    let faceTrackID = FaceTrackID(rawValue: UUID())
    let bounds = try makeNormalizedRect()
    let base = DetectedFace(
        faceTrackID: faceTrackID, bounds: bounds, confidence: 0.9,
        yawDegrees: 1, pitchDegrees: 2, rollDegrees: 3, isSmallFace: false
    )
    let same = DetectedFace(
        faceTrackID: faceTrackID, bounds: bounds, confidence: 0.9,
        yawDegrees: 1, pitchDegrees: 2, rollDegrees: 3, isSmallFace: false
    )
    let differentSmallFace = DetectedFace(
        faceTrackID: faceTrackID, bounds: bounds, confidence: 0.9,
        yawDegrees: 1, pitchDegrees: 2, rollDegrees: 3, isSmallFace: true
    )
    #expect(base == same)
    #expect(base != differentSmallFace)
}

// MARK: - ImageFormat

@Test("ImageFormatはjpeg/heic/pngを区別する")
func imageFormatDistinguishesCases() {
    let cases: [ImageFormat] = [.jpeg, .heic, .png]
    for format in cases {
        _ = assertSendableHashable(format)
    }
    #expect(Set(cases).count == 3)
}

// MARK: - ImageSource

@Test("ImageSourceは向き正規化後のfile/pixelSize/formatを保持する")
func imageSourceHoldsAllFields() {
    let file = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))
    let pixelSize = PixelSize(width: 4032, height: 3024)
    let subject = ImageSource(file: file, pixelSize: pixelSize, format: .heic)
    #expect(subject.file == file)
    #expect(subject.pixelSize == pixelSize)
    #expect(subject.format == .heic)
}

// MARK: - OriginalCaptureMetadata（image-pipeline.md 5 章 / architecture.md 9 章）

@Test("OriginalCaptureMetadataは全フィールドをそのまま保持する")
func originalCaptureMetadataHoldsAllFields() {
    let subject = OriginalCaptureMetadata(
        dateTimeOriginal: "2026:08:01 12:34:56",
        subSecTimeOriginal: "123",
        offsetTimeOriginal: "+09:00",
        utcMillis: 1_754_037_296_123
    )
    #expect(subject.dateTimeOriginal == "2026:08:01 12:34:56")
    #expect(subject.subSecTimeOriginal == "123")
    #expect(subject.offsetTimeOriginal == "+09:00")
    #expect(subject.utcMillis == 1_754_037_296_123)
}

@Test("OriginalCaptureMetadataは全フィールドnilも保持する（offset無しでutcMillisを算出しないケース）")
func originalCaptureMetadataHoldsAllNilFields() {
    let subject = OriginalCaptureMetadata(
        dateTimeOriginal: nil,
        subSecTimeOriginal: nil,
        offsetTimeOriginal: nil,
        utcMillis: nil
    )
    #expect(subject.dateTimeOriginal == nil)
    #expect(subject.subSecTimeOriginal == nil)
    #expect(subject.offsetTimeOriginal == nil)
    #expect(subject.utcMillis == nil)
}

@Test("OriginalCaptureMetadataは全フィールドが一致する場合のみEquatableで等しい")
func originalCaptureMetadataEqualityRequiresAllFieldsToMatch() {
    let base = OriginalCaptureMetadata(
        dateTimeOriginal: "2026:08:01 12:34:56",
        subSecTimeOriginal: "123",
        offsetTimeOriginal: "+09:00",
        utcMillis: 1_754_037_296_123
    )
    let same = OriginalCaptureMetadata(
        dateTimeOriginal: "2026:08:01 12:34:56",
        subSecTimeOriginal: "123",
        offsetTimeOriginal: "+09:00",
        utcMillis: 1_754_037_296_123
    )
    let differentUtcMillis = OriginalCaptureMetadata(
        dateTimeOriginal: "2026:08:01 12:34:56",
        subSecTimeOriginal: "123",
        offsetTimeOriginal: "+09:00",
        utcMillis: 1_754_037_296_999
    )
    #expect(base == same)
    #expect(base != differentUtcMillis)
}

// MARK: - LoadedPhoto（image-pipeline.md 5 章。正本どおりEquatableではないため等価性テストは書かない）

@Test("LoadedPhotoはsource/captureを全フィールドそのまま保持する")
func loadedPhotoHoldsAllFields() {
    let file = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))
    let source = ImageSource(file: file, pixelSize: PixelSize(width: 4032, height: 3024), format: .heic)
    let capture = OriginalCaptureMetadata(
        dateTimeOriginal: "2026:08:01 12:34:56",
        subSecTimeOriginal: "123",
        offsetTimeOriginal: "+09:00",
        utcMillis: 1_754_037_296_123
    )
    let subject = LoadedPhoto(source: source, capture: capture)
    #expect(subject.source.file == file)
    #expect(subject.source.pixelSize == source.pixelSize)
    #expect(subject.source.format == .heic)
    #expect(subject.capture.dateTimeOriginal == "2026:08:01 12:34:56")
    #expect(subject.capture.subSecTimeOriginal == "123")
    #expect(subject.capture.offsetTimeOriginal == "+09:00")
    #expect(subject.capture.utcMillis == 1_754_037_296_123)
}

// MARK: - FaceDetectorRevision

@Test("FaceDetectorRevisionはVisionのRevision生値をSendable/Hashableで保持する")
func faceDetectorRevisionHoldsRawValue() {
    let subject = assertSendableHashable(FaceDetectorRevision(rawValue: 3))
    #expect(subject.rawValue == 3)
}

// MARK: - DetectionResult

@Test("DetectionResultはfaces/detectionPixelSize/revisionを保持する")
func detectionResultHoldsAllFields() throws {
    let face = DetectedFace(
        faceTrackID: FaceTrackID(rawValue: UUID()),
        bounds: try makeNormalizedRect(),
        confidence: 0.7,
        yawDegrees: 0,
        pitchDegrees: 0,
        rollDegrees: 0,
        isSmallFace: true
    )
    let subject = DetectionResult(
        faces: [face],
        detectionPixelSize: PixelSize(width: 1920, height: 1440),
        revision: FaceDetectorRevision(rawValue: 3)
    )
    #expect(subject.faces == [face])
    #expect(subject.detectionPixelSize == PixelSize(width: 1920, height: 1440))
    #expect(subject.revision.rawValue == 3)
}

// MARK: - RawBitmapDescriptor / Raw* 列挙

@Test("RawChannelOrder/RawAlphaMode/RawBitDepth/RawColorSpaceは正本の全caseを持つ")
func rawEnumsCoverCanonicalCases() {
    let channelOrders: [RawChannelOrder] = [.rgba, .bgra]
    let alphaModes: [RawAlphaMode] = [.straight, .premultiplied]
    let bitDepths: [RawBitDepth] = [.eightPerChannel]
    let colorSpaces: [RawColorSpace] = [.sRGB]
    #expect(channelOrders[0] != channelOrders[1])
    #expect(alphaModes[0] != alphaModes[1])
    #expect(bitDepths.count == 1)
    #expect(colorSpaces.count == 1)
}

@Test("RawBitmapDescriptorは全フィールドをそのまま保持する")
func rawBitmapDescriptorHoldsAllFields() {
    let pixelSize = PixelSize(width: 1024, height: 768)
    let subject = RawBitmapDescriptor(
        pixelSize: pixelSize,
        rowBytes: 1024 * 4,
        channelOrder: .bgra,
        alpha: .premultiplied,
        bitDepth: .eightPerChannel,
        colorSpace: .sRGB
    )
    #expect(subject.pixelSize == pixelSize)
    #expect(subject.rowBytes == 4096)
    #expect(subject.channelOrder == .bgra)
    #expect(subject.alpha == .premultiplied)
    #expect(subject.bitDepth == .eightPerChannel)
    #expect(subject.colorSpace == .sRGB)
}

// MARK: - RenderedImage（file の静的型は RasterFileRef）

@Test("RenderedImage.fileの静的型はRasterFileRefである")
func renderedImageFileIsStaticallyRasterFileRef() {
    let ref = ManagedFileRef(kind: .rasterTemporary, fileID: ManagedFileID(rawValue: UUID()))
    let rasterRef = RasterFileRef(ref)!
    let descriptor = RawBitmapDescriptor(
        pixelSize: PixelSize(width: 10, height: 10),
        rowBytes: 40,
        channelOrder: .rgba,
        alpha: .straight,
        bitDepth: .eightPerChannel,
        colorSpace: .sRGB
    )
    let subject = RenderedImage(file: rasterRef, descriptor: descriptor)

    // 静的型注釈そのものが検証。RasterFileRef 以外であればコンパイルが通らない。
    let file: RasterFileRef = subject.file
    #expect(file == rasterRef)
}

// MARK: - OutputFile（Date() 直呼び出し禁止。Date(timeIntervalSince1970:) を使う）

@Test("OutputFileはsuggestedCreationDateがnilの場合も含め全フィールドを保持する")
func outputFileHoldsAllFieldsIncludingNilDate() {
    let outputRef = OutputFileRef(ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID())))!
    let subject = OutputFile(
        exportID: ExportID(rawValue: UUID()),
        file: outputRef,
        format: .jpeg,
        byteSize: 2_048_000,
        suggestedCreationDate: nil
    )
    #expect(subject.file == outputRef)
    #expect(subject.format == .jpeg)
    #expect(subject.byteSize == 2_048_000)
    #expect(subject.suggestedCreationDate == nil)
}

@Test("OutputFileはsuggestedCreationDateに決定的な日時を保持できる")
func outputFileHoldsDeterministicSuggestedCreationDate() {
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    let outputRef = OutputFileRef(ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID())))!
    let subject = OutputFile(
        exportID: ExportID(rawValue: UUID()),
        file: outputRef,
        format: .heic,
        byteSize: 1,
        suggestedCreationDate: fixedDate
    )
    #expect(subject.suggestedCreationDate == fixedDate)
}
