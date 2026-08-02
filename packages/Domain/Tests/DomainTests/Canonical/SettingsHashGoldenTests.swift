import Testing
@testable import Domain
import Foundation

// Task 5: ProjectSettingsHash / PreviewRenderHash のゴールデンテスト
// （canonical-schema.md 5.2「設定ハッシュ（2種類）」が正本）。
//
// 実際の SHA-256 の暗号学的な値そのものは検証対象にしない（Domain は CryptoKit を
// import できないため、実体計算はアダプタへ委譲する）。ここで固定するのは
// 「ドメイン分離子＋正準バイト列」が正本の符号化仕様どおりに構築されることで
// あり、フェイクの Sha256Digest（受け取った入力をそのままキャプチャするスタブ）
// を注入して digest.digest(...) に渡された入力バイト列を検証する。
//
// 期待バイト列は SettingsHash.swift のロジックを呼ばず、CanonicalEncoder の
// プリミティブをこのテストファイル側で手動に field 順で呼び出して組み立てる
// （circular にしないため）。

/// テスト用の決定的な SHA-256 スタブ。ハッシュ値そのものではなく
/// 「digest.digest(...) に渡された入力バイト列」を検証するため、受け取った入力を
/// キャプチャして固定の32バイトを返すだけにする。テストは単一スレッドから
/// 同期的に1回呼ぶ用途のみなので @unchecked Sendable とする。
private final class FakeSha256Digest: Sha256Digest, @unchecked Sendable {
    private(set) var capturedInput: Data?

    func digest(_ input: Data) -> Data {
        capturedInput = input
        return Data(repeating: 0x00, count: 32)
    }
}

// MARK: - 固定フィクスチャ

// sourceCrop は常に (0,0,1,1) を使う。
private func fixtureSourceCrop() throws -> NormalizedRect {
    try NormalizedRect(left: 0, top: 0, rightExclusive: 1, bottomExclusive: 1)
}

// region1: solid オペレーション・ellipse・auto 由来。
private func fixtureRegion1() throws -> RenderRegionSpec {
    RenderRegionSpec(
        bounds: try NormalizedRect(left: 0.1, top: 0.1, rightExclusive: 0.4, bottomExclusive: 0.4),
        rotationDegrees: try RotationDegrees(0),
        shape: .ellipse,
        featherRatio: try FeatherRatio(0.05),
        origin: .auto,
        op: .solid(color: try VisibleColor(0xFFFF_0000), opacity: try EffectOpacity(0.8))
    )
}

// region2: stamp(.builtIn) オペレーション・rounded・manual 由来。
private func fixtureRegion2() throws -> RenderRegionSpec {
    RenderRegionSpec(
        bounds: try NormalizedRect(left: 0.5, top: 0.5, rightExclusive: 0.9, bottomExclusive: 0.9),
        rotationDegrees: try RotationDegrees(15),
        shape: .rounded(cornerRatio: try CornerRatio(0.25)),
        featherRatio: try FeatherRatio(0.1),
        origin: .manual,
        op: .stamp(source: .builtIn(code: "cat"), opacity: try EffectOpacity(1.0))
    )
}

private func fixtureRenderSpec(regions: [RenderRegionSpec]) throws -> RenderSpec {
    RenderSpec(
        sourceCrop: try fixtureSourceCrop(),
        scaleMode: .fit,
        background: .none,
        regions: regions
    )
}

private func fixtureExportSetting(
    outputFormat: ImageFormat = .jpeg,
    compressionQuality: Double = 1.0,
    metadataPolicy: MetadataPolicy = MetadataPolicy(
        removeLocation: false,
        removeDeviceInfo: false,
        removeSoftwareInfo: false,
        keepCaptureDate: false
    )
) -> ExportSetting {
    ExportSetting(
        outputAspect: .original,
        outputFormat: outputFormat,
        compressionQuality: compressionQuality,
        metadataPolicy: metadataPolicy
    )
}

// MARK: - 期待バイト列（CanonicalEncoder のプリミティブを field 順で手動に呼び出す）

// 期待バイト列の組み立ては var への逐次追加で書く（長い + 連鎖は Swift の
// 型チェッカが時間内に解決できずコンパイルエラーになる）。
private func expectedRegion1Bytes() throws -> Data {
    let bounds = try NormalizedRect(left: 0.1, top: 0.1, rightExclusive: 0.4, bottomExclusive: 0.4)
    var bytes = Data()
    bytes += CanonicalEncoder.double(bounds.left)
    bytes += CanonicalEncoder.double(bounds.top)
    bytes += CanonicalEncoder.double(bounds.rightExclusive)
    bytes += CanonicalEncoder.double(bounds.bottomExclusive)
    bytes += CanonicalEncoder.double(0)                       // rotationDegrees
    bytes += CanonicalEncoder.bigEndianUInt32(1)              // shape = ellipse
    bytes += CanonicalEncoder.double(0.05)                    // featherRatio
    bytes += CanonicalEncoder.bigEndianUInt32(1)              // origin = auto
    bytes += CanonicalEncoder.bigEndianUInt32(3)              // op = solid
    bytes += CanonicalEncoder.bigEndianUInt32(0xFFFF_0000)    // color
    bytes += CanonicalEncoder.double(0.8)                     // opacity
    return bytes
}

private func expectedRegion2Bytes() throws -> Data {
    let bounds = try NormalizedRect(left: 0.5, top: 0.5, rightExclusive: 0.9, bottomExclusive: 0.9)
    var bytes = Data()
    bytes += CanonicalEncoder.double(bounds.left)
    bytes += CanonicalEncoder.double(bounds.top)
    bytes += CanonicalEncoder.double(bounds.rightExclusive)
    bytes += CanonicalEncoder.double(bounds.bottomExclusive)
    bytes += CanonicalEncoder.double(15)                      // rotationDegrees
    bytes += CanonicalEncoder.bigEndianUInt32(4)              // shape = rounded
    bytes += CanonicalEncoder.double(0.25)                    // cornerRatio
    bytes += CanonicalEncoder.double(0.1)                     // featherRatio
    bytes += CanonicalEncoder.bigEndianUInt32(2)              // origin = manual
    bytes += CanonicalEncoder.bigEndianUInt32(4)              // op = stamp
    bytes += CanonicalEncoder.bigEndianUInt32(1)              // StampSource = builtIn
    bytes += CanonicalEncoder.string("cat")                   // code
    bytes += CanonicalEncoder.double(1.0)                     // opacity
    return bytes
}

private func expectedRegionsBytes() throws -> Data {
    CanonicalEncoder.bigEndianUInt32(2)
        + CanonicalEncoder.lengthPrefixed(try expectedRegion1Bytes())
        + CanonicalEncoder.lengthPrefixed(try expectedRegion2Bytes())
}

private func expectedProjectSettingsBytes() throws -> Data {
    let sourceCrop = try fixtureSourceCrop()
    var bytes = Data()
    bytes += CanonicalEncoder.double(sourceCrop.left)
    bytes += CanonicalEncoder.double(sourceCrop.top)
    bytes += CanonicalEncoder.double(sourceCrop.rightExclusive)
    bytes += CanonicalEncoder.double(sourceCrop.bottomExclusive)
    bytes += CanonicalEncoder.bigEndianUInt32(1)              // scaleMode = fit
    bytes += CanonicalEncoder.bigEndianUInt32(1)              // background = none
    bytes += try expectedRegionsBytes()
    bytes += CanonicalEncoder.bigEndianUInt32(1)              // outputAspect = original
    bytes += CanonicalEncoder.bigEndianUInt32(1)              // outputFormat = jpeg
    bytes += CanonicalEncoder.double(1.0)                     // compressionQuality
    bytes += CanonicalEncoder.bool(false)                     // removeLocation
    bytes += CanonicalEncoder.bool(false)                     // removeDeviceInfo
    bytes += CanonicalEncoder.bool(false)                     // removeSoftwareInfo
    bytes += CanonicalEncoder.bool(false)                     // keepCaptureDate
    return bytes
}

private func expectedPreviewRenderBytes(renderRevision: UInt32) throws -> Data {
    let sourceCrop = try fixtureSourceCrop()
    var bytes = Data()
    bytes += CanonicalEncoder.bigEndianUInt32(renderRevision)
    bytes += CanonicalEncoder.double(sourceCrop.left)
    bytes += CanonicalEncoder.double(sourceCrop.top)
    bytes += CanonicalEncoder.double(sourceCrop.rightExclusive)
    bytes += CanonicalEncoder.double(sourceCrop.bottomExclusive)
    bytes += CanonicalEncoder.bigEndianUInt32(1)              // scaleMode = fit
    bytes += CanonicalEncoder.bigEndianUInt32(1)              // background = none
    bytes += try expectedRegionsBytes()
    bytes += CanonicalEncoder.bigEndianUInt32(1)              // outputAspect = original
    return bytes
}

// stamp(.custom) 検証用の単一領域フィクスチャ
// （32バイト固定長・長さ前置きなしの確認）。
private func expectedStampCustomRegionBytes(assetHash: StampAssetHash) throws -> Data {
    let bounds = try fixtureSourceCrop()
    var bytes = Data()
    bytes += CanonicalEncoder.double(bounds.left)
    bytes += CanonicalEncoder.double(bounds.top)
    bytes += CanonicalEncoder.double(bounds.rightExclusive)
    bytes += CanonicalEncoder.double(bounds.bottomExclusive)
    bytes += CanonicalEncoder.double(0)                       // rotationDegrees
    bytes += CanonicalEncoder.bigEndianUInt32(2)              // shape = circle
    bytes += CanonicalEncoder.double(0.0)                     // featherRatio
    bytes += CanonicalEncoder.bigEndianUInt32(1)              // origin = auto
    bytes += CanonicalEncoder.bigEndianUInt32(4)              // op = stamp
    bytes += CanonicalEncoder.bigEndianUInt32(2)              // StampSource = custom
    bytes += assetHash.bytes                                  // 32バイト固定長。長さ前置きなし
    bytes += CanonicalEncoder.double(1.0)                     // opacity
    return bytes
}

private func expectedStampCustomProjectSettingsBytes(assetHash: StampAssetHash) throws -> Data {
    let sourceCrop = try fixtureSourceCrop()
    let regionBytes = try expectedStampCustomRegionBytes(assetHash: assetHash)
    var bytes = Data()
    bytes += CanonicalEncoder.double(sourceCrop.left)
    bytes += CanonicalEncoder.double(sourceCrop.top)
    bytes += CanonicalEncoder.double(sourceCrop.rightExclusive)
    bytes += CanonicalEncoder.double(sourceCrop.bottomExclusive)
    bytes += CanonicalEncoder.bigEndianUInt32(1)              // scaleMode = fit
    bytes += CanonicalEncoder.bigEndianUInt32(1)              // background = none
    bytes += CanonicalEncoder.bigEndianUInt32(1)              // regions.count = 1
    bytes += CanonicalEncoder.lengthPrefixed(regionBytes)
    bytes += CanonicalEncoder.bigEndianUInt32(1)              // outputAspect = original
    bytes += CanonicalEncoder.bigEndianUInt32(1)              // outputFormat = jpeg
    bytes += CanonicalEncoder.double(1.0)                     // compressionQuality
    bytes += CanonicalEncoder.bool(false)
    bytes += CanonicalEncoder.bool(false)
    bytes += CanonicalEncoder.bool(false)
    bytes += CanonicalEncoder.bool(false)
    return bytes
}

/// 戻り値長を意図的に壊すフェイク（不正長 digest 注入の拒否テスト用）。
private final class WrongLengthSha256Digest: Sha256Digest, @unchecked Sendable {
    func digest(_ input: Data) -> Data {
        Data(repeating: 0x00, count: 31)
    }
}

@Test("projectSettingsHashは注入digestの戻り値が32バイトでなければ拒否する")
func projectSettingsHashRejectsWrongLengthDigest() throws {
    let renderSpec = try fixtureRenderSpec(regions: [try fixtureRegion1()])
    let exportSetting = fixtureExportSetting()
    let wrongDigest = WrongLengthSha256Digest()

    #expect(throws: HashByteLengthError.invalidLength(actual: 31)) {
        try projectSettingsHash(renderSpec: renderSpec, exportSetting: exportSetting, digest: wrongDigest)
    }
}

@Test("previewRenderHashは注入digestの戻り値が32バイトでなければ拒否する")
func previewRenderHashRejectsWrongLengthDigest() throws {
    let renderSpec = try fixtureRenderSpec(regions: [try fixtureRegion1()])
    let exportSetting = fixtureExportSetting()
    let wrongDigest = WrongLengthSha256Digest()

    #expect(throws: HashByteLengthError.invalidLength(actual: 31)) {
        try previewRenderHash(
            renderSpec: renderSpec, exportSetting: exportSetting, renderRevision: 1, digest: wrongDigest
        )
    }
}

// MARK: - ゴールデンテスト本体

@Test("ProjectSettingsHashのcanonical bytesとdigest入力がフィールド順どおりに一致する")
func projectSettingsHashMatchesGoldenCanonicalBytes() throws {
    let renderSpec = try fixtureRenderSpec(regions: [try fixtureRegion1(), try fixtureRegion2()])
    let exportSetting = fixtureExportSetting()
    let expectedBytes = try expectedProjectSettingsBytes()

    let actualBytes = canonicalProjectSettingsBytes(renderSpec: renderSpec, exportSetting: exportSetting)
    #expect(actualBytes == expectedBytes)

    let fake = FakeSha256Digest()
    _ = try projectSettingsHash(renderSpec: renderSpec, exportSetting: exportSetting, digest: fake)
    #expect(fake.capturedInput == Data("project-settings-v1".utf8) + expectedBytes)
}

@Test("PreviewRenderHashのcanonical bytesとdigest入力がフィールド順どおりに一致する")
func previewRenderHashMatchesGoldenCanonicalBytes() throws {
    let renderSpec = try fixtureRenderSpec(regions: [try fixtureRegion1(), try fixtureRegion2()])
    let exportSetting = fixtureExportSetting()
    let renderRevision: UInt32 = 7
    let expectedBytes = try expectedPreviewRenderBytes(renderRevision: renderRevision)

    let actualBytes = canonicalPreviewRenderBytes(
        renderSpec: renderSpec,
        exportSetting: exportSetting,
        renderRevision: renderRevision
    )
    #expect(actualBytes == expectedBytes)

    let fake = FakeSha256Digest()
    _ = try previewRenderHash(
        renderSpec: renderSpec,
        exportSetting: exportSetting,
        renderRevision: renderRevision,
        digest: fake
    )
    #expect(fake.capturedInput == Data("preview-render-v1".utf8) + expectedBytes)
}

@Test("StampSource.customは内容ハッシュを32バイト固定長・長さ前置きなしで符号化する")
func stampSourceCustomEncodesAssetHashWithoutLengthPrefix() throws {
    let assetHash = try StampAssetHash(bytes: Data(repeating: 0x7A, count: 32))
    let region = RenderRegionSpec(
        bounds: try fixtureSourceCrop(),
        rotationDegrees: try RotationDegrees(0),
        shape: .circle,
        featherRatio: try FeatherRatio(0.0),
        origin: .auto,
        op: .stamp(source: .custom(assetHash: assetHash), opacity: try EffectOpacity(1.0))
    )
    let renderSpec = try fixtureRenderSpec(regions: [region])
    let bytes = canonicalProjectSettingsBytes(renderSpec: renderSpec, exportSetting: fixtureExportSetting())
    #expect(bytes == (try expectedStampCustomProjectSettingsBytes(assetHash: assetHash)))
}

// MARK: - フィールド網羅性（test-plan.md 2.5）

@Test("PreviewRenderHashは出力フォーマット・圧縮品質・メタデータ設定を含まない")
func previewRenderHashExcludesFormatQualityAndMetadata() throws {
    let renderSpec = try fixtureRenderSpec(regions: [try fixtureRegion1()])
    let baseline = fixtureExportSetting()
    let changed = fixtureExportSetting(
        outputFormat: .png,
        compressionQuality: 0.4,
        metadataPolicy: MetadataPolicy(
            removeLocation: true,
            removeDeviceInfo: true,
            removeSoftwareInfo: true,
            keepCaptureDate: true
        )
    )

    let baselineBytes = canonicalPreviewRenderBytes(renderSpec: renderSpec, exportSetting: baseline, renderRevision: 1)
    let changedBytes = canonicalPreviewRenderBytes(renderSpec: renderSpec, exportSetting: changed, renderRevision: 1)
    #expect(baselineBytes == changedBytes)
}

@Test("renderRevisionを上げるとPreviewRenderHashのcanonical bytesが変わる")
func previewRenderHashChangesWithRenderRevision() throws {
    let renderSpec = try fixtureRenderSpec(regions: [try fixtureRegion1()])
    let exportSetting = fixtureExportSetting()

    let revision1 = canonicalPreviewRenderBytes(renderSpec: renderSpec, exportSetting: exportSetting, renderRevision: 1)
    let revision2 = canonicalPreviewRenderBytes(renderSpec: renderSpec, exportSetting: exportSetting, renderRevision: 2)
    #expect(revision1 != revision2)
}

@Test("370度と10度は正規化後に同じ値になり同じcanonical bytesになる")
func rotationDegreesNormalizationProducesSameCanonicalBytes() throws {
    let bounds = try NormalizedRect(left: 0.1, top: 0.1, rightExclusive: 0.4, bottomExclusive: 0.4)
    let op = RenderOpSpec.solid(color: try VisibleColor(0xFF00_0000), opacity: try EffectOpacity(1.0))
    let region370 = RenderRegionSpec(
        bounds: bounds, rotationDegrees: try RotationDegrees(370), shape: .circle,
        featherRatio: try FeatherRatio(0.0), origin: .auto, op: op
    )
    let region10 = RenderRegionSpec(
        bounds: bounds, rotationDegrees: try RotationDegrees(10), shape: .circle,
        featherRatio: try FeatherRatio(0.0), origin: .auto, op: op
    )
    #expect(region370.rotationDegrees.value == region10.rotationDegrees.value)

    let exportSetting = fixtureExportSetting()
    let bytes370 = canonicalProjectSettingsBytes(
        renderSpec: try fixtureRenderSpec(regions: [region370]), exportSetting: exportSetting
    )
    let bytes10 = canonicalProjectSettingsBytes(
        renderSpec: try fixtureRenderSpec(regions: [region10]), exportSetting: exportSetting
    )
    #expect(bytes370 == bytes10)
}

// MARK: - 16進数リテラル固定（フィールド順の変更を検出する回帰テスト）

// Data → 16進数文字列変換ヘルパ（canonicalProjectSettingsBytes の戻り値全体を1本のリテラルと比較するため）。
private func hexString(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

@Test("ProjectSettingsHashのcanonical bytesが手計算した既知の16進数リテラルと一致する")
func projectSettingsBytesMatchesKnownHexLiteral() throws {
    let renderSpec = try fixtureRenderSpec(regions: [try fixtureRegion1()])
    let exportSetting = fixtureExportSetting()

    let actualBytes = canonicalProjectSettingsBytes(renderSpec: renderSpec, exportSetting: exportSetting)

    // 140バイトを perl の pack('N',...)/pack('d>',...) で独立に手計算（Swift 実行なし）。
    // フィールド順は expectedProjectSettingsBytes() と同一（sourceCrop→scaleMode→background→regions→…→metadataPolicy）。
    var expectedHex = ""
    expectedHex += "000000000000000000000000000000003ff00000000000003ff0000000000000"   // sourceCrop=(0,0,1,1)
    expectedHex += "00000001000000010000000100000048"   // scaleMode/background/regions.count/region1len
    expectedHex += "3fb999999999999a3fb999999999999a3fd999999999999a3fd999999999999a"   // region1.bounds
    expectedHex += "0000000000000000000000013fa999999999999a00000001"   // region1 rotation/shape/feather/origin
    expectedHex += "00000003ffff00003fe999999999999a"   // region1.op=solid color/opacity
    expectedHex += "00000001000000013ff0000000000000"   // outputAspect/outputFormat/compressionQuality
    expectedHex += "00000000"   // metadataPolicy 4bool=false

    #expect(hexString(actualBytes) == expectedHex)
}

@Test("手動領域の追加でregionsの要素数が変わりcanonical bytesが変わる")
func addingManualRegionChangesCanonicalBytes() throws {
    let exportSetting = fixtureExportSetting()
    let oneRegion = try fixtureRenderSpec(regions: [try fixtureRegion1()])
    let twoRegions = try fixtureRenderSpec(regions: [try fixtureRegion1(), try fixtureRegion2()])

    let projectOne = canonicalProjectSettingsBytes(renderSpec: oneRegion, exportSetting: exportSetting)
    let projectTwo = canonicalProjectSettingsBytes(renderSpec: twoRegions, exportSetting: exportSetting)
    #expect(projectOne != projectTwo)

    let previewOne = canonicalPreviewRenderBytes(
        renderSpec: oneRegion, exportSetting: exportSetting, renderRevision: 1
    )
    let previewTwo = canonicalPreviewRenderBytes(
        renderSpec: twoRegions, exportSetting: exportSetting, renderRevision: 1
    )
    #expect(previewOne != previewTwo)
}
