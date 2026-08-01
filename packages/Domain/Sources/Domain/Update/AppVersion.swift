import Foundation

// アプリ更新判定の型群（architecture.md 6.6「アプリ更新の判定」）。
//
// 判定関数 evaluateUpdate 本体は Task 8 の担当のためここには含めない。

/// メジャー・マイナー・パッチの数値の組で比較する（文字列比較はしない）
public struct AppVersion: Sendable, Hashable, Comparable {
    public let major: Int32
    public let minor: Int32
    public let patch: Int32

    public init(major: Int32, minor: Int32, patch: Int32) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public enum UpdateDecision: Sendable, Equatable {
    case none
    case recommended(AppVersion)   // 任意。スキップできる
}
