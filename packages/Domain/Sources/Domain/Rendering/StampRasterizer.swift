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
