import Testing
@testable import Domain
import Foundation

/// Task 1: 画像処理・受け渡しポートの宣言（image-pipeline.md「プロトコルのシグネチャ」節・
/// 「@MainActor のプロトコル」節、export-saga.md 7章、architecture.md 7.5）。
///
/// これらは実装を持たないプロトコル・値型の宣言のみのため、ここでは
/// (1) 値型（OutputMetadata / VerifiedOutputMeasurement / ShareResult）が Sendable で構築でき、
/// フィールドを保持すること、(2) ShareResult の4ケースが Equatable で区別できること、
/// (3) 各プロトコルへの最小準拠がコンパイルでき、引数がシグネチャどおり渡ることを検証する。

private func makeSourcePixelSize() -> PixelSize { PixelSize(width: 800, height: 600) }

private func makeImageSource() -> ImageSource {
    let ref = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))
    return ImageSource(file: ref, pixelSize: makeSourcePixelSize(), format: .jpeg)
}

private func makeRenderPlan() -> RenderPlan {
    let rect = PixelRect(left: 0, top: 0, rightExclusive: 800, bottomExclusive: 600)
    let placement = SourcePlacement(sourceRect: rect, destinationRect: rect, scaleMode: .fit)
    return RenderPlan(canvasSize: makeSourcePixelSize(), sourcePlacement: placement, background: .none, regions: [])
}

private func makeRasterFileRef() -> RasterFileRef {
    let ref = ManagedFileRef(kind: .rasterTemporary, fileID: ManagedFileID(rawValue: UUID()))
    guard let rasterRef = RasterFileRef(ref) else {
        fatalError("test setup invariant violated: kind must be .rasterTemporary")
    }
    return rasterRef
}

private func makeRenderedImage() -> RenderedImage {
    let descriptor = RawBitmapDescriptor(
        pixelSize: makeSourcePixelSize(),
        rowBytes: 800 * 4,
        channelOrder: .rgba,
        alpha: .straight,
        bitDepth: .eightPerChannel,
        colorSpace: .sRGB
    )
    return RenderedImage(file: makeRasterFileRef(), descriptor: descriptor)
}

private func makeOutputFile() -> OutputFile {
    OutputFile(
        exportID: ExportID(rawValue: UUID()),
        file: makeOutputFileRef(),
        format: .jpeg,
        byteSize: 1024,
        suggestedCreationDate: nil
    )
}

// MARK: - OutputMetadata（architecture.md 7.5「出力メタデータは許可リストで構築する」節）

@Test("OutputMetadataは許可リストのフィールドを保持する")
func outputMetadataHoldsAllowlistedFields() {
    let capture = OriginalCaptureMetadata(
        dateTimeOriginal: "2026:08:05 12:00:00",
        subSecTimeOriginal: "123",
        offsetTimeOriginal: "+09:00",
        utcMillis: 1_754_366_400_000
    )
    let icc = Data(repeating: 0x10, count: 4)

    let subject = OutputMetadata(pixelSize: makeSourcePixelSize(), iccProfile: icc, capture: capture)

    #expect(subject.pixelSize == makeSourcePixelSize())
    #expect(subject.iccProfile == icc)
    #expect(subject.capture == capture)
}

@Test("OutputMetadataはiccProfileとcaptureがnilでも構築でき値として比較できる")
func outputMetadataAllowsNilOptionalFieldsAndCompares() {
    let first = OutputMetadata(pixelSize: makeSourcePixelSize(), iccProfile: nil, capture: nil)
    let second = OutputMetadata(pixelSize: makeSourcePixelSize(), iccProfile: nil, capture: nil)

    #expect(first == second)
    #expect(first.iccProfile == nil)
    #expect(first.capture == nil)
}

// MARK: - VerifiedOutputMeasurement（新設ポートの戻り値。RecordOutputInput と同型）

@Test("VerifiedOutputMeasurementはbyteSizeとsha256を保持する")
func verifiedOutputMeasurementHoldsFields() {
    let sha256 = Data(repeating: 0x42, count: 32)

    let subject = VerifiedOutputMeasurement(byteSize: 2048, sha256: sha256)

    #expect(subject.byteSize == 2048)
    #expect(subject.sha256 == sha256)
}

// MARK: - ShareResult（export-saga.md 7章、4ケース）

@Test("ShareResultの4ケースはEquatableで互いに区別できる")
func shareResultFourCasesAreDistinguishableByEquatable() {
    let cases: [ShareResult] = [.completed, .canceled, .unknown, .failed]

    for (leftIndex, left) in cases.enumerated() {
        for (rightIndex, right) in cases.enumerated() {
            #expect((left == right) == (leftIndex == rightIndex))
        }
    }
}

// MARK: - ImageEffectRenderer への最小準拠

private struct RenderCall {
    let source: ImageSource
    let plan: RenderPlan
    let rasterAssets: [String: RasterizedStampAsset]
}

private actor FakeImageEffectRenderer: ImageEffectRenderer {
    private(set) var renderCalls: [RenderCall] = []
    var result: RenderedImage

    init(result: RenderedImage) { self.result = result }

    func render(
        source: ImageSource,
        plan: RenderPlan,
        rasterAssets: [String: RasterizedStampAsset]
    ) async throws -> RenderedImage {
        renderCalls.append(RenderCall(source: source, plan: plan, rasterAssets: rasterAssets))
        return result
    }
}

@Test("ImageEffectRendererへの最小準拠がrenderの引数を記録し戻り値を返す")
func fakeImageEffectRendererForwardsArgumentsAndReturnsResult() async throws {
    let expected = makeRenderedImage()
    let renderer = FakeImageEffectRenderer(result: expected)
    let source = makeImageSource()
    let plan = makeRenderPlan()

    let rendered = try await renderer.render(source: source, plan: plan, rasterAssets: [:])

    #expect(rendered.file == expected.file)
    let calls = await renderer.renderCalls
    #expect(calls.count == 1)
    #expect(calls[0].source.file == source.file)
    #expect(calls[0].rasterAssets.isEmpty)
}

// MARK: - ImageEncoder への最小準拠

private struct EncodeCall {
    let image: RenderedImage
    let format: ImageFormat
    let quality: Double
    let metadata: OutputMetadata
}

private actor FakeImageEncoder: ImageEncoder {
    private(set) var encodeCalls: [EncodeCall] = []
    var result: OutputFileRef

    init(result: OutputFileRef) { self.result = result }

    func encode(
        _ image: RenderedImage,
        format: ImageFormat,
        quality: Double,
        metadata: OutputMetadata
    ) async throws -> OutputFileRef {
        encodeCalls.append(EncodeCall(image: image, format: format, quality: quality, metadata: metadata))
        return result
    }
}

@Test("ImageEncoderへの最小準拠がencodeの引数を記録し戻り値を返す")
func fakeImageEncoderForwardsArgumentsAndReturnsResult() async throws {
    let expectedRef = makeOutputFileRef()
    let encoder = FakeImageEncoder(result: expectedRef)
    let image = makeRenderedImage()
    let metadata = OutputMetadata(pixelSize: makeSourcePixelSize(), iccProfile: nil, capture: nil)

    let outputRef = try await encoder.encode(image, format: .heic, quality: 0.8, metadata: metadata)

    #expect(outputRef == expectedRef)
    let calls = await encoder.encodeCalls
    #expect(calls.count == 1)
    #expect(calls[0].format == .heic)
    #expect(calls[0].quality == 0.8)
    #expect(calls[0].metadata == metadata)
}

// MARK: - MediaSaver への最小準拠

private actor FakeMediaSaver: MediaSaver {
    private(set) var savedFiles: [OutputFile] = []

    func saveToPhotoLibrary(_ file: OutputFile) async throws {
        savedFiles.append(file)
    }
}

@Test("MediaSaverへの最小準拠がsaveToPhotoLibraryへ渡されたOutputFileを記録する")
func fakeMediaSaverRecordsSavedFile() async throws {
    let saver = FakeMediaSaver()
    let file = makeOutputFile()

    try await saver.saveToPhotoLibrary(file)

    let saved = await saver.savedFiles
    #expect(saved.count == 1)
    #expect(saved[0].exportID == file.exportID)
    #expect(saved[0].file == file.file)
}

// MARK: - SharePresenter への最小準拠（@MainActor）

@MainActor
private final class FakeSharePresenter: SharePresenter {
    private(set) var sharedFiles: [OutputFile] = []
    var result: ShareResult = .completed

    func share(_ file: OutputFile) async -> ShareResult {
        sharedFiles.append(file)
        return result
    }
}

@Test("SharePresenterへの最小準拠がshareへ渡されたOutputFileを記録し結果を返す")
@MainActor
func fakeSharePresenterRecordsSharedFileAndReturnsResult() async {
    let presenter = FakeSharePresenter()
    presenter.result = .canceled
    let file = makeOutputFile()

    let result = await presenter.share(file)

    #expect(result == .canceled)
    #expect(presenter.sharedFiles.count == 1)
    #expect(presenter.sharedFiles[0].file == file.file)
}

// MARK: - OutputFileVerifier への最小準拠（本計画の新設ポート）

private actor FakeOutputFileVerifier: OutputFileVerifier {
    private(set) var verifyCalls: [OutputFileRef] = []
    var result: VerifiedOutputMeasurement

    init(result: VerifiedOutputMeasurement) { self.result = result }

    func verify(_ file: OutputFileRef) async throws(OutputFileVerificationError) -> VerifiedOutputMeasurement {
        verifyCalls.append(file)
        return result
    }
}

@Test("OutputFileVerifierへの最小準拠がverifyの引数を記録し測定値を返す")
func fakeOutputFileVerifierForwardsArgumentAndReturnsMeasurement() async throws {
    let expected = VerifiedOutputMeasurement(byteSize: 4096, sha256: Data(repeating: 0x55, count: 32))
    let verifier = FakeOutputFileVerifier(result: expected)
    let ref = makeOutputFileRef()

    let measurement = try await verifier.verify(ref)

    #expect(measurement.byteSize == 4096)
    #expect(measurement.sha256 == expected.sha256)
    let calls = await verifier.verifyCalls
    #expect(calls == [ref])
}

// MARK: - FaceDetector（image-pipeline.md 5章「プロトコルのシグネチャ」）

private actor MinimalFaceDetector: FaceDetector {
    private(set) var receivedSources: [ImageSource] = []
    private let result: DetectionResult

    init(result: DetectionResult) {
        self.result = result
    }

    func detect(_ source: ImageSource) async throws -> DetectionResult {
        receivedSources.append(source)
        return result
    }
}

@Test("FaceDetectorへの最小準拠がdetectへ渡されたImageSourceを記録し戻り値を返す")
func faceDetectorMinimalConformancePassesSourceAndReturnsResult() async throws {
    let expected = DetectionResult(
        faces: [],
        detectionPixelSize: PixelSize(width: 1920, height: 1440),
        revision: FaceDetectorRevision(rawValue: 3)
    )
    let subject = MinimalFaceDetector(result: expected)
    let source = makeImageSource()

    let actual = try await subject.detect(source)

    #expect(actual == expected)
    let received = await subject.receivedSources
    #expect(received.count == 1)
    #expect(received.first?.file == source.file)
}
