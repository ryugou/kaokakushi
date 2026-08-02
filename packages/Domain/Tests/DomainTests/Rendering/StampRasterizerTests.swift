import Testing
@testable import Domain
import Foundation

// StampRasterizer プロトコルへの最小準拠のコンパイル検証（image-pipeline.md 3章
// 「スタンプラスタライズ」のコードブロックが正本）。

private struct FakeStampRasterizer: StampRasterizer {
    let assets: [StampRasterKey: RasterizedStampAsset]

    func rasterize(_ keys: Set<StampRasterKey>) async throws -> [StampRasterKey: RasterizedStampAsset] {
        var result: [StampRasterKey: RasterizedStampAsset] = [:]
        for key in keys {
            guard let asset = assets[key] else {
                throw RenderValidationError.unresolvedStampAsset
            }
            result[key] = asset
        }
        return result
    }
}

private func makeRasterizedStampAsset(bitmapID: String) -> RasterizedStampAsset {
    let fileRef = ManagedFileRef(kind: .rasterTemporary, fileID: ManagedFileID(rawValue: UUID()))
    let descriptor = RawBitmapDescriptor(
        pixelSize: PixelSize(width: 10, height: 10),
        rowBytes: 40,
        channelOrder: .rgba,
        alpha: .straight,
        bitDepth: .eightPerChannel,
        colorSpace: .sRGB
    )
    guard let rasterFile = RasterFileRef(fileRef) else {
        fatalError("rasterTemporary kindのManagedFileRefからRasterFileRefは常に構築できる")
    }
    return RasterizedStampAsset(bitmapID: bitmapID, rasterFile: rasterFile, descriptor: descriptor)
}

@Test("StampRasterizerへの最小準拠が与えたkeys全件に対応する値を返す")
func stampRasterizerMinimalConformanceReturnsAllKeys() async throws {
    let key = StampRasterKey(source: .builtIn(code: "cat"), rasterSize: PixelSize(width: 10, height: 10))
    let asset = makeRasterizedStampAsset(bitmapID: "bmp-1")
    let rasterizer = FakeStampRasterizer(assets: [key: asset])

    let result = try await rasterizer.rasterize([key])

    #expect(result[key]?.bitmapID == "bmp-1")
}

@Test("StampRasterizerへの最小準拠は未解決keyでthrowする")
func stampRasterizerMinimalConformanceThrowsOnUnresolvedKey() async throws {
    let key = StampRasterKey(source: .builtIn(code: "dog"), rasterSize: PixelSize(width: 5, height: 5))
    let rasterizer = FakeStampRasterizer(assets: [:])

    await #expect(throws: RenderValidationError.unresolvedStampAsset) {
        try await rasterizer.rasterize([key])
    }
}
