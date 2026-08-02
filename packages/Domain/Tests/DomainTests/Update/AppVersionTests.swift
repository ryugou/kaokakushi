import Testing
@testable import Domain
import Foundation

/// Task 3: アプリ更新判定の型群（architecture.md 6.6）。
///
/// `AppVersion` の Comparable が文字列比較ではなく数値タプル比較であること
/// （"1.10.0" < "1.9.0" は文字列としては真になるが、数値では偽になる境界を検証する）、
/// `UpdateDecision` の2ケースを検証する。

@Test("AppVersionは数値タプル比較でminorが2桁でも正しく比較される")
func appVersionComparesNumericallyNotLexically() {
    // "1.10.0" と "1.9.0" は文字列としては "1.10.0" < "1.9.0"（先頭 "1." の次の文字 '1' < '9'）。
    // 数値タプル比較では 1.10.0 > 1.9.0 が正しい。この逆転を検出する。
    let versionTenDotZero = AppVersion(major: 1, minor: 10, patch: 0)
    let versionNineDotZero = AppVersion(major: 1, minor: 9, patch: 0)
    #expect(versionTenDotZero > versionNineDotZero)
    #expect(!(versionTenDotZero < versionNineDotZero))
}

@Test(
    "AppVersionはmajor/minor/patchの順で比較される",
    arguments: [
        (AppVersion(major: 2, minor: 0, patch: 0), AppVersion(major: 1, minor: 99, patch: 99), true),
        (AppVersion(major: 1, minor: 2, patch: 0), AppVersion(major: 1, minor: 1, patch: 99), true),
        (AppVersion(major: 1, minor: 2, patch: 3), AppVersion(major: 1, minor: 2, patch: 2), true),
        (AppVersion(major: 1, minor: 2, patch: 3), AppVersion(major: 1, minor: 2, patch: 3), false)
    ]
)
func appVersionComparesByFieldPriority(lhs: AppVersion, rhs: AppVersion, expectedGreater: Bool) {
    #expect((lhs > rhs) == expectedGreater)
}

@Test("AppVersionが全フィールドを保持しSendable/Hashableである")
func appVersionHoldsAllFields() {
    let subject = assertSendableHashable(AppVersion(major: 3, minor: 4, patch: 5))
    #expect(subject.major == 3)
    #expect(subject.minor == 4)
    #expect(subject.patch == 5)
}

@Test("UpdateDecisionはnoneとrecommendedの2ケースを持つ")
func updateDecisionHasTwoCases() {
    let none = UpdateDecision.none
    let recommended = UpdateDecision.recommended(AppVersion(major: 1, minor: 0, patch: 0))
    #expect(none != recommended)
    guard case .recommended(let version) = recommended else {
        Issue.record("recommended ケースが期待どおりに構築されていません")
        return
    }
    #expect(version == AppVersion(major: 1, minor: 0, patch: 0))
}
