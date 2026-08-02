import Foundation

// StampRasterizer プロトコル（image-pipeline.md 3章「スタンプラスタライズ」のコードブロックが
// 正本。protocol 宣言に public を付与している点のみ、Domain 内の他の public プロトコル
// （Sha256Digest 等）との一貫性を取るためのオーケストレータ判断で、シグネチャ自体は一字一句
// 転記している）。

/// Domain — Foundation のみ。要求の同一性は StampRasterKey で表す
public protocol StampRasterizer: Sendable {
    /// 1 回の render セッションに必要なラスタを一括で作る
    func rasterize(
        _ keys: Set<StampRasterKey>
    ) async throws -> [StampRasterKey: RasterizedStampAsset]
}

// MARK: - RasterizedStampAsset（image-pipeline.md 3章「ラスタ画像の受け渡し契約」からの転記）

/// スタンプラスタライズの戻り値。`CGImage` を Domain の型へ入れられないため、
/// 実体を指す形式として定める（image-pipeline.md 3章「ラスタ画像の受け渡し契約」）。
public struct RasterizedStampAsset: Sendable {
    public let bitmapID: String
    public let rasterFile: RasterFileRef
    public let descriptor: RawBitmapDescriptor

    public init(bitmapID: String, rasterFile: RasterFileRef, descriptor: RawBitmapDescriptor) {
        self.bitmapID = bitmapID
        self.rasterFile = rasterFile
        self.descriptor = descriptor
    }
}
