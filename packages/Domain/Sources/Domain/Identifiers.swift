import Foundation

// ドメイン識別子（architecture.md 6.5、export-saga.md）。
//
// 識別子を String と UUID で混在させない（2 つの型で表現されると DB の結合も
// ハッシュ算出時の正準化も一意に決まらない。architecture.md 6.5）。
//
// いずれの型も CustomStringConvertible に適合させない
// （文字列補間で自動的にログや診断へ流れる経路を作らないため。architecture.md 6.5）。
// アクセス修飾（public）は正本の疑似コードには現れないが、Application 等の他パッケージが
// Domain の公開 API として参照するために必要（DomainPackageMarker.swift の既存の
// public 方針に合わせる）。

public struct ProjectID: Sendable, Hashable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct BatchID: Sendable, Hashable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct ExportID: Sendable, Hashable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct RegionID: Sendable, Hashable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct FaceTrackID: Sendable, Hashable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// CustomStamp（一覧の項目）の識別子。7.5
public struct CustomStampID: Sendable, Hashable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// エクスポートキュー項目の識別子（export-saga.md）。
public struct ExportQueueItemID: Sendable, Hashable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}
