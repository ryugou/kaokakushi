import Testing
@testable import Domain
import Foundation

// Task 8: アプリ更新判定の純粋関数（architecture.md 6.6「アプリ更新の判定」、
// test-plan.md 2.6「更新誘導」）。
//
// `AppVersion` 自体の比較ロジック（数値タプル比較）は Update/AppVersionTests.swift で
// 検証済みのため、ここでは evaluateUpdate がその比較結果を使って正しく分岐することのみを
// 確認する。
//
// `CFBundleShortVersionString` のパース失敗（test-plan.md 2.6 の該当行）は、文字列から
// AppVersion への変換自体が Domain の外（Application/Adapter 層の責務。evaluateUpdate は
// 既にパース済みの AppVersion を受け取る）であるため、このテストファイルでは対象外とする。

private let referenceNow = Date(timeIntervalSince1970: 1_700_000_000)
private let exactly24HoursAgo = referenceNow.addingTimeInterval(-24 * 60 * 60)
private let justUnder24HoursAgo = referenceNow.addingTimeInterval(-24 * 60 * 60 + 1)

private let versionCurrent = AppVersion(major: 1, minor: 4, patch: 0)
private let versionLatest = AppVersion(major: 1, minor: 5, patch: 0)

@Test("latestOnStoreがnil（iTunes Lookup API取得失敗）なら.noneになる")
func evaluateUpdateReturnsNoneWhenLatestOnStoreIsNil() {
    let subject = evaluateUpdate(
        current: versionCurrent,
        latestOnStore: nil,
        skippedVersion: nil,
        lastPromptedAt: nil,
        usageNow: referenceNow
    )
    #expect(subject == .none)
}

@Test(
    "currentがlatestOnStore以上なら.noneになる（境界値: 等しい場合を含む）",
    arguments: [
        (AppVersion(major: 1, minor: 5, patch: 0), AppVersion(major: 1, minor: 5, patch: 0)),
        (AppVersion(major: 2, minor: 0, patch: 0), AppVersion(major: 1, minor: 5, patch: 0))
    ]
)
func evaluateUpdateReturnsNoneWhenCurrentIsAtOrAboveLatest(current: AppVersion, latestOnStore: AppVersion) {
    let subject = evaluateUpdate(
        current: current,
        latestOnStore: latestOnStore,
        skippedVersion: nil,
        lastPromptedAt: nil,
        usageNow: referenceNow
    )
    #expect(subject == .none)
}

@Test("skippedVersionがlatestOnStoreと一致するなら.noneになる")
func evaluateUpdateReturnsNoneWhenSkippedVersionMatchesLatest() {
    let subject = evaluateUpdate(
        current: versionCurrent,
        latestOnStore: versionLatest,
        skippedVersion: versionLatest,
        lastPromptedAt: nil,
        usageNow: referenceNow
    )
    #expect(subject == .none)
}

@Test(
    "前回提示からの経過時間が24時間の境界で分岐する（未満はnone、ちょうど24時間は再提示）",
    arguments: [
        (justUnder24HoursAgo, UpdateDecision.none),
        (exactly24HoursAgo, UpdateDecision.recommended(versionLatest))
    ]
)
func evaluateUpdateRespectsTwentyFourHourBoundary(lastPromptedAt: Date, expected: UpdateDecision) {
    let subject = evaluateUpdate(
        current: versionCurrent,
        latestOnStore: versionLatest,
        skippedVersion: nil,
        lastPromptedAt: lastPromptedAt,
        usageNow: referenceNow
    )
    #expect(subject == expected)
}

@Test("lastPromptedAtがnil（未提示）なら24h制限を適用せず初回提示できる")
func evaluateUpdateAllowsInitialPromptWhenNeverPrompted() {
    // 正本に明記が無く判断した点: nil は「まだ一度も提示していない」ことを意味するため、
    // 「前回提示から24h」という制限自体が意味を持たない。初回提示は妨げない、と解釈する。
    let subject = evaluateUpdate(
        current: versionCurrent,
        latestOnStore: versionLatest,
        skippedVersion: nil,
        lastPromptedAt: nil,
        usageNow: referenceNow
    )
    #expect(subject == .recommended(versionLatest))
}

@Test("recommendedVersionが上がれば、以前スキップしたバージョンとは別物として再提示される")
func evaluateUpdateRePromptsWhenLatestVersionIncreasesPastPreviouslySkippedVersion() {
    // skippedVersion (1.5.0) は今回の latestOnStore (1.6.0) と一致しないため、
    // 「スキップ済みを再提示しない」規則には抵触しない。24h条件も満たすように
    // lastPromptedAt を十分過去にして、他の条件がブロックしていないことを確認する。
    let previouslySkipped = AppVersion(major: 1, minor: 5, patch: 0)
    let newerLatest = AppVersion(major: 1, minor: 6, patch: 0)
    let subject = evaluateUpdate(
        current: versionCurrent,
        latestOnStore: newerLatest,
        skippedVersion: previouslySkipped,
        lastPromptedAt: referenceNow.addingTimeInterval(-72 * 60 * 60),
        usageNow: referenceNow
    )
    #expect(subject == .recommended(newerLatest))
}

@Test("いずれのブロック条件にも該当しなければ.recommended(latestOnStore)を返す")
func evaluateUpdateReturnsRecommendedWhenNoBlockingConditionApplies() {
    let subject = evaluateUpdate(
        current: versionCurrent,
        latestOnStore: versionLatest,
        skippedVersion: AppVersion(major: 1, minor: 3, patch: 0),
        lastPromptedAt: exactly24HoursAgo,
        usageNow: referenceNow
    )
    #expect(subject == .recommended(versionLatest))
}
