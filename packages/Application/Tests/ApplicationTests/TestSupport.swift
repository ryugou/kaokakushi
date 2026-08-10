import Foundation
import Domain
@testable import Application

// ApplicationTests 全体で共有するテストフィクスチャ。各テストファイルへ同じ定義をコピーせず、
// ここへ集約する（DomainTests/TestSupport.swift と同じ方針。simplify レビュー指摘の踏襲）。
// 時刻はすべて固定値を渡す（裸の Date() を使わない。Global Constraints）。

func makeExportID() -> ExportID {
    ExportID(rawValue: UUID())
}

func makeProjectID() -> ProjectID {
    ProjectID(rawValue: UUID())
}

func makeBatchID() -> BatchID {
    BatchID(rawValue: UUID())
}

/// kind = .output の OutputFileRef を組み立てる。
func makeOutputFileRef() -> OutputFileRef {
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    guard let outputRef = OutputFileRef(ref) else {
        fatalError("test setup invariant violated: kind must be .output")
    }
    return outputRef
}

/// 任意状態の OutputRecord フィクスチャ。settledAt を渡さなければ確定済み扱いにする
/// （settledAt / expiresAt は固定タイムスタンプで決定的にする）。
func makeOutputRecord(
    exportID: ExportID,
    projectID: ProjectID = makeProjectID(),
    state: OutputState,
    settledAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)
) -> OutputRecord {
    OutputRecord(
        exportID: exportID,
        projectID: projectID,
        batchID: nil,
        outputFile: makeOutputFileRef(),
        outputByteSize: 1_024,
        outputSHA256: Data(repeating: 0xAB, count: 32),
        state: state,
        generatedAt: Date(timeIntervalSince1970: 1_699_999_000),
        settledAt: settledAt,
        expiresAt: settledAt.map { $0.addingTimeInterval(86_400) },
        format: .jpeg,
        suggestedCreationDate: nil
    )
}

func makeEntitlement() -> Entitlement {
    Entitlement(
        plan: .free,
        status: .active,
        expiresAt: nil,
        lastVerifiedAt: Date(timeIntervalSince1970: 1_699_997_000),
        isSandbox: false
    )
}

/// accountingMode を差し替え可能な ExportJob フィクスチャ（settle の消費カウンタ検証用）。
func makeExportJob(
    exportID: ExportID,
    projectID: ProjectID = makeProjectID(),
    batchID: BatchID? = nil,
    accountingMode: ExportAccountingMode = .paidUnlimited
) -> ExportJob {
    ExportJob(
        exportID: exportID,
        projectID: projectID,
        batchID: batchID,
        queueItemID: nil,
        authorization: ExportAuthorization(
            entitlementSnapshot: makeEntitlement(),
            accountingMode: accountingMode,
            authorizedAt: Date(timeIntervalSince1970: 1_699_998_000)
        ),
        delivery: OutputDeliveryDescriptor(format: .jpeg, suggestedCreationDate: nil)
    )
}

func makeRecordOutputInput(exportID: ExportID) -> RecordOutputInput {
    RecordOutputInput(
        exportID: exportID,
        outputFile: makeOutputFileRef(),
        outputByteSize: 1_024,
        outputSHA256: Data(repeating: 0xAB, count: 32)
    )
}

/// left=0,top=0,right=1,bottom=1 の正規化矩形（`RenderSpec.sourceCrop` 等の既定値として使う）。
func makeNormalizedRect(
    left: Double = 0,
    top: Double = 0,
    rightExclusive: Double = 1,
    bottomExclusive: Double = 1
) throws -> NormalizedRect {
    try NormalizedRect(left: left, top: top, rightExclusive: rightExclusive, bottomExclusive: bottomExclusive)
}

/// regions を省略すると能力を必要としない最小構成になる（authorizeRenderSpec が常に
/// .authorized を返す。Issue #7 Task 4 の 1.1/1.2 検査テストで多用する）。
func makeRenderSpec(regions: [RenderRegionSpec] = []) throws -> RenderSpec {
    RenderSpec(sourceCrop: try makeNormalizedRect(), scaleMode: .fit, background: .none, regions: regions)
}

/// 組み込みスタンプ1件だけを使う RenderRegionSpec フィクスチャ（authorizeRenderSpec の
/// 能力検査を実際に経由させたいテスト用）。
func makeBuiltInStampRegion(code: String) throws -> RenderRegionSpec {
    RenderRegionSpec(
        bounds: try makeNormalizedRect(),
        rotationDegrees: try RotationDegrees(0),
        shape: .ellipse,
        featherRatio: try FeatherRatio(0),
        origin: .auto,
        op: .stamp(source: .builtIn(code: code), opacity: try EffectOpacity(1.0))
    )
}

func makeExportSetting() -> ExportSetting {
    ExportSetting(
        outputAspect: .original,
        outputFormat: .jpeg,
        compressionQuality: 0.9,
        metadataPolicy: MetadataPolicy(
            removeLocation: true, removeDeviceInfo: true, removeSoftwareInfo: true, keepCaptureDate: true
        )
    )
}

/// 32 バイト固定の PreviewRenderHash フィクスチャ。fillByte を変えると別ハッシュになる
/// （1.1 の不一致ケースを組み立てるのに使う）。
func makePreviewRenderHash(fillByte: UInt8 = 0xCD) throws -> PreviewRenderHash {
    try PreviewRenderHash(bytes: Data(repeating: fillByte, count: 32))
}

/// 800x600 固定の PixelSize フィクスチャ（Issue #7 Task 5「生成」テスト用）。
func makePixelSize(width: Int = 800, height: Int = 600) -> PixelSize {
    PixelSize(width: width, height: height)
}

/// processingTemporary 種別の ImageSource フィクスチャ（レンダラーへの入力）。
func makeImageSource() -> ImageSource {
    ImageSource(
        file: ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID())),
        pixelSize: makePixelSize(),
        format: .jpeg
    )
}

/// rasterTemporary 種別の RasterFileRef フィクスチャ（RenderedImage.file が指す実体の参照）。
func makeRasterFileRef() -> RasterFileRef {
    let ref = ManagedFileRef(kind: .rasterTemporary, fileID: ManagedFileID(rawValue: UUID()))
    guard let rasterRef = RasterFileRef(ref) else {
        fatalError("test setup invariant violated: kind must be .rasterTemporary")
    }
    return rasterRef
}

/// ImageEffectRenderer.render の戻り値フィクスチャ。
func makeRenderedImage() -> RenderedImage {
    RenderedImage(
        file: makeRasterFileRef(),
        descriptor: RawBitmapDescriptor(
            pixelSize: makePixelSize(),
            rowBytes: 800 * 4,
            channelOrder: .rgba,
            alpha: .straight,
            bitDepth: .eightPerChannel,
            colorSpace: .sRGB
        )
    )
}

/// ImageEncoder.encode へ渡すメタデータのフィクスチャ（保持設定なしの最小構成）。
func makeOutputMetadata() -> OutputMetadata {
    OutputMetadata(pixelSize: makePixelSize(), iccProfile: nil, capture: nil)
}

/// OutputFileVerifier.verify 成功時の測定値フィクスチャ。
func makeVerifiedOutputMeasurement() -> VerifiedOutputMeasurement {
    VerifiedOutputMeasurement(byteSize: 2_048, sha256: Data(repeating: 0xCD, count: 32))
}

/// ExportCoordinator.generateOutput(_:) への標準入力フィクスチャ。regions 無しの RenderSpec
/// を使うため rasterAssets は空辞書のままで bindRasterAssets を通過できる（makeRenderSpec の
/// コメントと同じ理由）。
func makeGenerateExportInput(job: ExportJob) throws -> GenerateExportInput {
    GenerateExportInput(
        job: job,
        renderSpec: try makeRenderSpec(),
        exportSetting: makeExportSetting(),
        sourceSize: makePixelSize(),
        targetSize: makePixelSize(),
        imageSource: makeImageSource(),
        rasterAssets: [:],
        metadata: makeOutputMetadata()
    )
}

/// 固定時刻を返すクロック（裸の Date() 禁止。ExportCoordinator.now 注入用の既定フィクスチャ）。
func makeFixedClock(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> @Sendable () -> Date {
    { date }
}

/// 標準構成の ExportCoordinator を組み立てる（Issue #7 Task 5「生成」テストの複数ファイルで
/// 共有するため TestSupport.swift へ集約する）。個別に差し替えたい fake だけを引数で渡す。
func makeGenerateCoordinator(
    exportSagaStore: FakeExportSagaStore,
    imageEffectRenderer: FakeImageEffectRenderer = FakeImageEffectRenderer(),
    imageEncoder: FakeImageEncoder = FakeImageEncoder(),
    outputFileVerifier: FakeOutputFileVerifier,
    workingSourceStore: FakeWorkingSourceStore = FakeWorkingSourceStore(),
    outputDeliveryStore: FakeOutputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock())
) -> ExportCoordinator {
    ExportCoordinator(
        exportSagaStore: exportSagaStore,
        workingSourceStore: workingSourceStore,
        managedFileStore: FakeManagedFileStore(),
        stampCatalog: FakeStampCatalog(),
        imageEffectRenderer: imageEffectRenderer,
        imageEncoder: imageEncoder,
        outputFileVerifier: outputFileVerifier,
        outputDeliveryStore: outputDeliveryStore,
        now: makeFixedClock(),
        queue: SerialTaskQueue(),
        exportedSettingsEntryStore: FakeExportedSettingsEntryStore(),
        settingsHashDigest: FakeSha256Digest(),
        recoveryGate: FakeRecoveryGate()
    )
}

/// 生成の全段階を成功させる標準構成一式（large_tuple lint 回避のため struct にまとめる）。
struct SucceedingGenerationPipeline {
    let renderer: FakeImageEffectRenderer
    let encoder: FakeImageEncoder
    let verifier: FakeOutputFileVerifier
    let rendered: RenderedImage
    let encoded: OutputFileRef
    let measurement: VerifiedOutputMeasurement
}

func makeSucceedingGenerationPipeline() -> SucceedingGenerationPipeline {
    let measurement = makeVerifiedOutputMeasurement()
    return SucceedingGenerationPipeline(
        renderer: FakeImageEffectRenderer(),
        encoder: FakeImageEncoder(),
        verifier: FakeOutputFileVerifier(defaultOutcome: .success(measurement)),
        rendered: makeRenderedImage(),
        encoded: makeOutputFileRef(),
        measurement: measurement
    )
}

/// 標準構成の StartupRecoveryCoordinator を組み立てる（Issue #7 Task 9 で導入、Task 11 で
/// maintenanceStore / managedFileStore を追加。StartupRecoveryTests.swift と
/// StartupRecoveryFileGCTests.swift の両方で共有するため TestSupport.swift へ集約する）。
func makeCoordinator(
    exportSagaStore: FakeExportSagaStore = FakeExportSagaStore(),
    outputDeliveryStore: FakeOutputDeliveryStore = FakeOutputDeliveryStore(now: makeFixedClock()),
    maintenanceStore: FakeMaintenanceStore? = nil,
    managedFileStore: FakeManagedFileStore = FakeManagedFileStore(),
    queue: SerialTaskQueue = SerialTaskQueue(),
    updateGuidanceHook: @escaping @Sendable () async -> Void = {}
) -> StartupRecoveryCoordinator {
    // FakeMaintenanceStore は managedFileStore から listExistingFileIDs を導出する
    // ため（W-5）、デフォルト引数同士では組み立てられない。maintenanceStore 省略時は
    // ここで managedFileStore と紐づけて構築する。
    let resolvedMaintenanceStore = maintenanceStore ?? FakeMaintenanceStore(managedFileStore: managedFileStore)
    return StartupRecoveryCoordinator(
        exportSagaStore: exportSagaStore,
        outputDeliveryStore: outputDeliveryStore,
        maintenanceStore: resolvedMaintenanceStore,
        managedFileStore: managedFileStore,
        queue: queue,
        updateGuidanceHook: updateGuidanceHook
    )
}

/// 単体トライアル可・広告表示ありの標準的な ResolvedCapabilities フィクスチャ。
func makeResolvedCapabilities(
    canUsePremiumStamps: Bool = true,
    canUseCustomStamps: Bool = true
) -> ResolvedCapabilities {
    ResolvedCapabilities(
        singleExportAccess: .metered,
        canUsePremiumStamps: canUsePremiumStamps,
        canUseCustomStamps: canUseCustomStamps,
        enabledStampPacks: [],
        canUseProBatch: false,
        canUseBatchTrial: true,
        shouldShowAds: true
    )
}
