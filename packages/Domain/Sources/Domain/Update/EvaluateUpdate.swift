import Foundation

// アプリ更新判定の純粋関数（architecture.md 6.6「アプリ更新の判定」）。
//
// `AppVersion` / `UpdateDecision` は Update/AppVersion.swift に実装済みのためここでは
// 再宣言しない。判定順序（1〜4）は正本の番号付きリストのまま実装する。
//
// 正本に明記が無く判断した点: `lastPromptedAt == nil` の扱い。nil は「まだ一度も
// 提示していない」ことを意味するため、「前回提示から24h」という制限自体が意味を持たない。
// 「初回提示は妨げない」という自然な読みを採用し、`lastPromptedAt` が nil のときは
// 24h制限のチェックを行わずスキップする。

private let updatePromptIntervalSeconds: TimeInterval = 24 * 60 * 60

public func evaluateUpdate(
    current: AppVersion,
    latestOnStore: AppVersion?,     // iTunes Lookup API から取得。失敗時は nil
    skippedVersion: AppVersion?,    // 利用者が「後で」を選んだバージョン
    lastPromptedAt: Date?,
    usageNow: Date
) -> UpdateDecision {
    // 1. latestOnStore == nil または current >= latestOnStore なら .none
    guard let latestOnStore, current < latestOnStore else {
        return .none
    }

    // 2. skippedVersion == latestOnStore なら .none
    guard skippedVersion != latestOnStore else {
        return .none
    }

    // 3. usageNow - lastPromptedAt < 24h なら .none（1日1回まで）。
    //    lastPromptedAt が nil（未提示）の場合はこの制限を適用しない。
    if let lastPromptedAt, usageNow.timeIntervalSince(lastPromptedAt) < updatePromptIntervalSeconds {
        return .none
    }

    // 4. それ以外は .recommended
    return .recommended(latestOnStore)
}
