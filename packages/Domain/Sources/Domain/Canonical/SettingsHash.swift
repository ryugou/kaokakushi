import Foundation

// 設定ハッシュ（ProjectSettingsHash / PreviewRenderHash）の正準バイト列構築とハッシュ計算
// （canonical-schema.md 5.2「設定ハッシュ（2種類）」が正本）。
//
// SHA-256 の実体計算は Domain 内に置かない（packages/Domain/Sources は Foundation 以外の
// import が禁止されており CryptoKit を使えないため）。実体計算は Sha256Digest プロトコル
// 経由でアダプタへ注入する。ハッシュ計算関数（projectSettingsHash / previewRenderHash）は
// このプロトコルを引数で受け取る純粋関数として実装する。
//
// projectSettingsHash / previewRenderHash はいずれも ExportSetting をまるごと受け取る
// シグネチャにしている。PreviewRenderHash の計算では内部で exportSetting.outputAspect
// だけを読む（outputFormat / compressionQuality / metadataPolicy は使わない）。
// 呼び出し側が同じ値を2回渡す必要をなくすための設計判断であり、docs の型宣言・
// 符号化規則とは矛盾しない（オーケストレータ確定済み）。

/// SHA-256 の実体計算をアダプタへ注入するためのプロトコル。
/// Domain は Foundation のみに依存し CryptoKit を import できないため、
/// ハッシュ計算そのものはアダプタ側の実装へ委譲する（canonical-schema.md 5.2）。
public protocol Sha256Digest: Sendable {
    /// 32 バイトの SHA-256 ダイジェストを返す。
    func digest(_ input: Data) -> Data
}

/// ProjectSettingsHash のドメイン分離子（canonical-schema.md 5.2 最終式）。
private let projectSettingsDomainSeparator = "project-settings-v1"

/// PreviewRenderHash のドメイン分離子（canonical-schema.md 5.2 最終式）。
private let previewRenderDomainSeparator = "preview-render-v1"

// MARK: - enum の固定 UInt32 タグ（宣言順に依存させない。canonical-schema.md 5.2 が正本）

private func encodeMaskShape(_ shape: MaskShape) -> Data {
    switch shape {
    case .ellipse:
        return CanonicalEncoder.bigEndianUInt32(1)
    case .circle:
        return CanonicalEncoder.bigEndianUInt32(2)
    case .rectangle:
        return CanonicalEncoder.bigEndianUInt32(3)
    case .rounded(let cornerRatio):
        return CanonicalEncoder.bigEndianUInt32(4) + CanonicalEncoder.double(cornerRatio.value)
    }
}

private func encodeRegionOrigin(_ origin: RegionOrigin) -> Data {
    switch origin {
    case .auto:
        return CanonicalEncoder.bigEndianUInt32(1)
    case .manual:
        return CanonicalEncoder.bigEndianUInt32(2)
    }
}

private func encodeStampSource(_ source: StampSource) -> Data {
    switch source {
    case .builtIn(let code):
        return CanonicalEncoder.bigEndianUInt32(1) + CanonicalEncoder.string(code)
    case .custom(let assetHash):
        // StampAssetHash は 32 バイト固定長。長さ前置きしない（canonical-schema.md 5.2）。
        return CanonicalEncoder.bigEndianUInt32(2) + assetHash.bytes
    }
}

private func encodeRenderOpSpec(_ op: RenderOpSpec) -> Data {
    switch op {
    case .mosaic(let cellRatio):
        return CanonicalEncoder.bigEndianUInt32(1) + CanonicalEncoder.double(cellRatio.value)
    case .blur(let sigmaRatio):
        return CanonicalEncoder.bigEndianUInt32(2) + CanonicalEncoder.double(sigmaRatio.value)
    case .solid(let color, let opacity):
        return CanonicalEncoder.bigEndianUInt32(3)
            + CanonicalEncoder.bigEndianUInt32(color.value)
            + CanonicalEncoder.double(opacity.value)
    case .stamp(let source, let opacity):
        return CanonicalEncoder.bigEndianUInt32(4)
            + encodeStampSource(source)
            + CanonicalEncoder.double(opacity.value)
    }
}

private func encodeBackgroundSpec(_ background: BackgroundSpec) -> Data {
    switch background {
    case .none:
        return CanonicalEncoder.bigEndianUInt32(1)
    case .blur(let sigmaRatio):
        return CanonicalEncoder.bigEndianUInt32(2) + CanonicalEncoder.double(sigmaRatio.value)
    case .solid(let color):
        return CanonicalEncoder.bigEndianUInt32(3) + CanonicalEncoder.bigEndianUInt32(color.value)
    }
}

private func encodeSourceScaleMode(_ mode: SourceScaleMode) -> Data {
    switch mode {
    case .fit:
        return CanonicalEncoder.bigEndianUInt32(1)
    case .fill:
        return CanonicalEncoder.bigEndianUInt32(2)
    }
}

private func encodeOutputAspect(_ aspect: OutputAspect) -> Data {
    switch aspect {
    case .original:
        return CanonicalEncoder.bigEndianUInt32(1)
    case .square:
        return CanonicalEncoder.bigEndianUInt32(2)
    case .fourFive:
        return CanonicalEncoder.bigEndianUInt32(3)
    case .nineSixteen:
        return CanonicalEncoder.bigEndianUInt32(4)
    }
}

private func encodeImageFormat(_ format: ImageFormat) -> Data {
    switch format {
    case .jpeg:
        return CanonicalEncoder.bigEndianUInt32(1)
    case .heic:
        return CanonicalEncoder.bigEndianUInt32(2)
    case .png:
        return CanonicalEncoder.bigEndianUInt32(3)
    }
}

private func encodeMetadataPolicy(_ policy: MetadataPolicy) -> Data {
    CanonicalEncoder.bool(policy.removeLocation)
        + CanonicalEncoder.bool(policy.removeDeviceInfo)
        + CanonicalEncoder.bool(policy.removeSoftwareInfo)
        + CanonicalEncoder.bool(policy.keepCaptureDate)
}

// MARK: - 構造体の符号化

private func encodeNormalizedRect(_ rect: NormalizedRect) -> Data {
    CanonicalEncoder.double(rect.left)
        + CanonicalEncoder.double(rect.top)
        + CanonicalEncoder.double(rect.rightExclusive)
        + CanonicalEncoder.double(rect.bottomExclusive)
}

private func encodeRenderRegionSpec(_ region: RenderRegionSpec) -> Data {
    encodeNormalizedRect(region.bounds)
        + CanonicalEncoder.double(region.rotationDegrees.value)
        + encodeMaskShape(region.shape)
        + CanonicalEncoder.double(region.featherRatio.value)
        + encodeRegionOrigin(region.origin)
        + encodeRenderOpSpec(region.op)
}

private func encodeRegions(_ regions: [RenderRegionSpec]) -> Data {
    // regions は ordered（正準スキーマの ordered array）。
    // 描画順に意味があるためソートしない。
    CanonicalEncoder.orderedCollection(regions, encode: encodeRenderRegionSpec)
}

// MARK: - 公開 API

/// canonical-schema.md 5.2「ProjectSettingsHash」の 1〜8（ドメイン分離子を含まない）。
public func canonicalProjectSettingsBytes(renderSpec: RenderSpec, exportSetting: ExportSetting) -> Data {
    encodeNormalizedRect(renderSpec.sourceCrop)
        + encodeSourceScaleMode(renderSpec.scaleMode)
        + encodeBackgroundSpec(renderSpec.background)
        + encodeRegions(renderSpec.regions)
        + encodeOutputAspect(exportSetting.outputAspect)
        + encodeImageFormat(exportSetting.outputFormat)
        + CanonicalEncoder.double(exportSetting.compressionQuality)
        + encodeMetadataPolicy(exportSetting.metadataPolicy)
}

/// canonical-schema.md 5.2「PreviewRenderHash」の 1〜6（ドメイン分離子を含まない）。
/// ProjectSettingsHash の 6〜8（outputFormat / compressionQuality / metadataPolicy）は含めない。
public func canonicalPreviewRenderBytes(
    renderSpec: RenderSpec,
    exportSetting: ExportSetting,
    renderRevision: UInt32
) -> Data {
    CanonicalEncoder.bigEndianUInt32(renderRevision)
        + encodeNormalizedRect(renderSpec.sourceCrop)
        + encodeSourceScaleMode(renderSpec.scaleMode)
        + encodeBackgroundSpec(renderSpec.background)
        + encodeRegions(renderSpec.regions)
        + encodeOutputAspect(exportSetting.outputAspect)
}

/// 認可用。出力へ影響する全設定の正準ハッシュ（canonical-schema.md 5.2 最終式）。
/// ドメイン分離子は長さ前置きしない UTF-8 バイト列として先頭に置く。
public func projectSettingsHash(
    renderSpec: RenderSpec,
    exportSetting: ExportSetting,
    digest: Sha256Digest
) -> ProjectSettingsHash {
    let input = Data(projectSettingsDomainSeparator.utf8)
        + canonicalProjectSettingsBytes(renderSpec: renderSpec, exportSetting: exportSetting)
    return ProjectSettingsHash(bytes: digest.digest(input))
}

/// プレビュー確認用。見た目に影響する値だけの正準ハッシュ
/// （canonical-schema.md 5.2 最終式）。
/// ドメイン分離子は長さ前置きしない UTF-8 バイト列として先頭に置く。
public func previewRenderHash(
    renderSpec: RenderSpec,
    exportSetting: ExportSetting,
    renderRevision: UInt32,
    digest: Sha256Digest
) -> PreviewRenderHash {
    let input = Data(previewRenderDomainSeparator.utf8)
        + canonicalPreviewRenderBytes(
            renderSpec: renderSpec,
            exportSetting: exportSetting,
            renderRevision: renderRevision
        )
    return PreviewRenderHash(bytes: digest.digest(input))
}
