import Foundation

// PickedPhotoInput — App の bridge が Application へ渡す唯一の型
// （image-pipeline.md 5章「PickedPhotoInput」節）。
//
// providerAssetIdentifier は PickedPhotoInput の寿命の中でのみ使う。ログへ出さず永続化しない
// （ADR 0006 により素材同一性の識別に使わなくなったため、ハッシュ化して保存することもない）。
//
// 再編集用の参照は別枠である。ProjectSourceLocator.photoLibraryLocalIdentifier は同じ
// PHAsset.localIdentifier を平文で保持し、app.db の Project へのみ保存してよい
// （image-pipeline.md 5章「再編集にはハッシュではなく平文の参照が要る」の規約表）。
// この型の providerAssetIdentifier をそのまま永続化してよいという意味ではない。
// ProjectSourceLocator を経由すること。ログ・分析・診断へ出さない点は両者に共通する。

/// image-pipeline.md 5章「`PickedPhotoInput`」節
public struct PickedPhotoInput: Sendable {
    public let importedFile: ManagedFileRef          // 7.3 で物質化済み
    public let providerAssetIdentifier: String?      // 一時的にのみ保持。保存・ログ禁止
    public let libraryCreationDate: Date?
    public let representation: SourceRepresentation  // architecture.md 7.5

    public init(
        importedFile: ManagedFileRef,
        providerAssetIdentifier: String?,
        libraryCreationDate: Date?,
        representation: SourceRepresentation
    ) {
        self.importedFile = importedFile
        self.providerAssetIdentifier = providerAssetIdentifier
        self.libraryCreationDate = libraryCreationDate
        self.representation = representation
    }
}
