import Testing
@testable import Domain
import Foundation

/// Task 1: `ManagedFileRef` とその周辺型（architecture.md 7.3「ManagedFileStore」）。
///
/// `ManagedFileKind` の固定値、`ManagedFileRef` の Sendable/Hashable、
/// 種別つき参照（`OutputFileRef` / `WorkingSourceFileRef` / `RasterFileRef` /
/// `StampAssetFileRef`）の failable init が対応する `kind` のみを受理することを検証する。
/// `ThumbnailFileRef` は正本の 7.3 コードブロックに存在しないため作らない
/// （計画メモの記述は正本ではない）。

private func assertSendableHashable<T: Sendable & Hashable>(_ value: T) -> T { value }

/// 正本（architecture.md 7.3）に列挙された全 6 ケース。`ManagedFileKind` は
/// `CaseIterable` に適合させていない（正本のコードブロックに無い適合を追加しないため）ので、
/// テスト側で手動列挙する。
private let allManagedFileKinds: [ManagedFileKind] = [
    .output, .stampAsset, .historyThumbnail, .stampThumbnail, .processingTemporary, .rasterTemporary
]

// MARK: - ManagedFileKind の固定値（architecture.md 7.3）

@Test(
    "ManagedFileKindのrawValueが正本どおり",
    arguments: [
        (ManagedFileKind.output, UInt32(1)),
        (ManagedFileKind.stampAsset, UInt32(2)),
        (ManagedFileKind.historyThumbnail, UInt32(3)),
        (ManagedFileKind.stampThumbnail, UInt32(4)),
        (ManagedFileKind.processingTemporary, UInt32(5)),
        (ManagedFileKind.rasterTemporary, UInt32(6))
    ]
)
func managedFileKindRawValueMatchesCanonicalDoc(kind: ManagedFileKind, expected: UInt32) {
    #expect(kind.rawValue == expected)
}

// MARK: - ManagedFileID / ManagedFileRef / PendingFileDeletion

@Test("ManagedFileIDがSendable/Hashableでraw値を保持する")
func managedFileIDHoldsRawValue() {
    let id = UUID()
    let subject = assertSendableHashable(ManagedFileID(rawValue: id))
    #expect(subject.rawValue == id)
}

@Test("ManagedFileRefがSendable/Hashableでkindとfileidを保持する")
func managedFileRefHoldsKindAndFileID() {
    let fileID = ManagedFileID(rawValue: UUID())
    let subject = assertSendableHashable(ManagedFileRef(kind: .output, fileID: fileID))
    #expect(subject.kind == .output)
    #expect(subject.fileID == fileID)
}

@Test("kindまたはfileIDが異なるManagedFileRefはHashableとして区別される")
func managedFileRefDistinguishesByKindAndFileID() {
    let fileID = ManagedFileID(rawValue: UUID())
    let sameFileDifferentKind = ManagedFileRef(kind: .stampAsset, fileID: fileID)
    let sameKindDifferentFile = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    let original = ManagedFileRef(kind: .output, fileID: fileID)

    #expect(original != sameFileDifferentKind)
    #expect(original != sameKindDifferentFile)
    #expect(Set([original, sameFileDifferentKind, sameKindDifferentFile]).count == 3)
}

@Test("PendingFileDeletionがManagedFileRefを保持する")
func pendingFileDeletionHoldsFile() {
    let ref = ManagedFileRef(kind: .rasterTemporary, fileID: ManagedFileID(rawValue: UUID()))
    let subject = PendingFileDeletion(file: ref)
    #expect(subject.file == ref)
}

// MARK: - 種別つき参照の failable init（kind 不一致は nil。architecture.md 7.3 本文）

@Test(
    "OutputFileRefはkind=.outputのみ受理する",
    arguments: allManagedFileKinds
)
func outputFileRefAcceptsOnlyOutputKind(kind: ManagedFileKind) {
    let ref = ManagedFileRef(kind: kind, fileID: ManagedFileID(rawValue: UUID()))
    let subject = OutputFileRef(ref)
    if kind == .output {
        #expect(subject?.ref == ref)
    } else {
        #expect(subject == nil)
    }
}

@Test(
    "WorkingSourceFileRefはkind=.processingTemporaryのみ受理する",
    arguments: allManagedFileKinds
)
func workingSourceFileRefAcceptsOnlyProcessingTemporaryKind(kind: ManagedFileKind) {
    let ref = ManagedFileRef(kind: kind, fileID: ManagedFileID(rawValue: UUID()))
    let subject = WorkingSourceFileRef(ref)
    if kind == .processingTemporary {
        #expect(subject?.ref == ref)
    } else {
        #expect(subject == nil)
    }
}

@Test(
    "RasterFileRefはkind=.rasterTemporaryのみ受理する",
    arguments: allManagedFileKinds
)
func rasterFileRefAcceptsOnlyRasterTemporaryKind(kind: ManagedFileKind) {
    let ref = ManagedFileRef(kind: kind, fileID: ManagedFileID(rawValue: UUID()))
    let subject = RasterFileRef(ref)
    if kind == .rasterTemporary {
        #expect(subject?.ref == ref)
    } else {
        #expect(subject == nil)
    }
}

@Test(
    "StampAssetFileRefはkind=.stampAssetのみ受理する",
    arguments: allManagedFileKinds
)
func stampAssetFileRefAcceptsOnlyStampAssetKind(kind: ManagedFileKind) {
    let ref = ManagedFileRef(kind: kind, fileID: ManagedFileID(rawValue: UUID()))
    let subject = StampAssetFileRef(ref)
    if kind == .stampAsset {
        #expect(subject?.ref == ref)
    } else {
        #expect(subject == nil)
    }
}

@Test("種別つき参照はSendable/Hashableである")
func typedFileRefsAreSendableAndHashable() {
    let outputRef = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    _ = assertSendableHashable(OutputFileRef(outputRef)!)

    let workingRef = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))
    _ = assertSendableHashable(WorkingSourceFileRef(workingRef)!)

    let rasterRef = ManagedFileRef(kind: .rasterTemporary, fileID: ManagedFileID(rawValue: UUID()))
    _ = assertSendableHashable(RasterFileRef(rasterRef)!)

    let stampRef = ManagedFileRef(kind: .stampAsset, fileID: ManagedFileID(rawValue: UUID()))
    _ = assertSendableHashable(StampAssetFileRef(stampRef)!)
}
