import Foundation

// 書き出し設定の型群（export-saga.md 0 章「Application が使う永続化ポート」）。
//
// フィールドは ProjectSettingsHash の 5〜8 と一致する（正準バイト表現と enum の固定番号は
// canonical-schema.md 5.2 が正本。ハッシュ計算そのものは Task 5 の担当）。

/// 出力の縦横比（仕様の 元比率 / 1:1 / 4:5 / 9:16）
public enum OutputAspect: Sendable, Hashable {
    case original, square, fourFive, nineSixteen
}

/// 出力メタデータの扱い
public struct MetadataPolicy: Sendable, Equatable {
    public let removeLocation: Bool
    public let removeDeviceInfo: Bool
    public let removeSoftwareInfo: Bool
    public let keepCaptureDate: Bool

    public init(removeLocation: Bool, removeDeviceInfo: Bool, removeSoftwareInfo: Bool, keepCaptureDate: Bool) {
        self.removeLocation = removeLocation
        self.removeDeviceInfo = removeDeviceInfo
        self.removeSoftwareInfo = removeSoftwareInfo
        self.keepCaptureDate = keepCaptureDate
    }
}

/// 出力形式・画質・メタデータ設定
public struct ExportSetting: Sendable, Equatable {
    public let outputAspect: OutputAspect
    public let outputFormat: ImageFormat   // Rendering/Boundary.swift の既存型
    public let compressionQuality: Double
    public let metadataPolicy: MetadataPolicy

    public init(
        outputAspect: OutputAspect,
        outputFormat: ImageFormat,
        compressionQuality: Double,
        metadataPolicy: MetadataPolicy
    ) {
        self.outputAspect = outputAspect
        self.outputFormat = outputFormat
        self.compressionQuality = compressionQuality
        self.metadataPolicy = metadataPolicy
    }
}
