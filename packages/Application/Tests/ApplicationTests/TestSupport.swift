import Foundation
import Domain

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
