import Foundation
@testable import Domain

// DomainTests 全体で共有するテストヘルパー。
// 各テストファイルへ同じ定義をコピーせず、ここへ集約する（simplify レビュー指摘）。
// ファイル固有のフィクスチャ（値の意味がそのテストに閉じるもの）は各ファイルの
// private ヘルパーのままでよい。

/// コンパイル時に Sendable & Equatable への準拠を要求するアサーション。
func assertSendableEquatable<T: Sendable & Equatable>(_ value: T) -> T { value }

/// コンパイル時に Sendable & Hashable への準拠を要求するアサーション。
func assertSendableHashable<T: Sendable & Hashable>(_ value: T) -> T { value }

/// kind = .output の ManagedFileRef から OutputFileRef を組み立てる。
func makeOutputFileRef() -> OutputFileRef {
    let ref = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))
    guard let outputRef = OutputFileRef(ref) else {
        fatalError("test setup invariant violated: kind must be .output")
    }
    return outputRef
}

/// 全面 crop・fit・背景なし・領域なしの最小 RenderSpec。
func makeRenderSpec() throws -> RenderSpec {
    let rect = try NormalizedRect(left: 0, top: 0, rightExclusive: 1, bottomExclusive: 1)
    return RenderSpec(sourceCrop: rect, scaleMode: .fit, background: .none, regions: [])
}
