import Foundation

// ManagedFileStore が扱う参照型群（architecture.md 7.3「ManagedFileStore」）。
//
// CustomStringConvertible には適合させない（architecture.md 6.5 の指示を全識別子・
// 値型へ適用する。文字列補間で自動的にログや診断へ流れる経路を作らないため）。

public enum ManagedFileKind: UInt32, Sendable, Hashable, CaseIterable {
    case output = 1
    case stampAsset = 2
    case historyThumbnail = 3
    case stampThumbnail = 4
    case processingTemporary = 5
    case rasterTemporary = 6
}

/// 文字列にしない。任意の値を作れる型では専用ディレクトリ外へ出られる
public struct ManagedFileID: Sendable, Hashable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct ManagedFileRef: Sendable, Hashable {
    public let kind: ManagedFileKind
    public let fileID: ManagedFileID
    public init(kind: ManagedFileKind, fileID: ManagedFileID) {
        self.kind = kind
        self.fileID = fileID
    }
}

public struct PendingFileDeletion: Sendable {
    public let file: ManagedFileRef
    public init(file: ManagedFileRef) { self.file = file }
}

// MARK: - 種別つきの参照（architecture.md 7.3「種別つきの参照」）
//
// `ManagedFileRef` を汎用のまま各所へ渡すと kind の取り違えをコンパイラが検出できない。
// 各 initializer は kind を検証し一致しなければ nil を返す
// （デコード時も同じ検証を通し kind 不一致の行は不正として扱う）。
//
// 種別つき参照は正本コードブロックにある以下の 4 種のみ。`ThumbnailFileRef` は
// 正本（architecture.md 7.3 のコードブロック）に存在しないため作らない。

public struct OutputFileRef: Sendable, Hashable {        // .output
    public let ref: ManagedFileRef
    public init?(_ ref: ManagedFileRef) {
        guard ref.kind == .output else { return nil }
        self.ref = ref
    }
}

public struct WorkingSourceFileRef: Sendable, Hashable {  // .processingTemporary
    public let ref: ManagedFileRef
    public init?(_ ref: ManagedFileRef) {
        guard ref.kind == .processingTemporary else { return nil }
        self.ref = ref
    }
}

public struct RasterFileRef: Sendable, Hashable {         // .rasterTemporary
    public let ref: ManagedFileRef
    public init?(_ ref: ManagedFileRef) {
        guard ref.kind == .rasterTemporary else { return nil }
        self.ref = ref
    }
}

public struct StampAssetFileRef: Sendable, Hashable {     // .stampAsset
    public let ref: ManagedFileRef
    public init?(_ ref: ManagedFileRef) {
        guard ref.kind == .stampAsset else { return nil }
        self.ref = ref
    }
}
