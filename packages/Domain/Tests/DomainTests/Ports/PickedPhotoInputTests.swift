import Testing
@testable import Domain
import Foundation

// PickedPhotoInput（image-pipeline.md 5章「PickedPhotoInput」節）。
// App の bridge が物質化済みファイルとして Application へ渡す唯一の型。

@Test("PickedPhotoInputは全フィールドをそのまま保持する")
func pickedPhotoInputHoldsAllFields() {
    let file = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))
    let created = Date(timeIntervalSince1970: 1_754_872_200)

    let subject = PickedPhotoInput(
        importedFile: file,
        providerAssetIdentifier: "asset-1",
        libraryCreationDate: created,
        representation: .original
    )

    #expect(subject.importedFile == file)
    #expect(subject.providerAssetIdentifier == "asset-1")
    #expect(subject.libraryCreationDate == created)
    #expect(subject.representation == .original)
}

@Test("PickedPhotoInputはOptionalフィールドをnilで構築できる")
func pickedPhotoInputAllowsNilOptionals() {
    let file = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))

    let subject = PickedPhotoInput(
        importedFile: file,
        providerAssetIdentifier: nil,
        libraryCreationDate: nil,
        representation: .transcoded
    )

    #expect(subject.providerAssetIdentifier == nil)
    #expect(subject.libraryCreationDate == nil)
    #expect(subject.representation == .transcoded)
}
