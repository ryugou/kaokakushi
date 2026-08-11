import Foundation

// 利用者への受け渡しポート（image-pipeline.md「プロトコルのシグネチャ」節・
// 「@MainActor のプロトコル」節、export-saga.md 7章「利用者への受け渡し」）。
//
// `MediaSaver` は他の Domain の protocol と同じく非 UI の永続化寄りの境界だが、
// `SharePresenter` は `UIActivityViewController` を包む都合上 `@MainActor` の `AnyObject`
// プロトコルとして正本が定義している（`OutputDeliveryCoordinator` という actor から
// `await` して呼ぶため、`@MainActor` の型はアクタによって状態が保護され `Sendable` として
// 扱える）。実装は別サブプロジェクト（MediaKit）が担当する。
//
// `AdPresenter`（同じ正本節にある）は Ads モジュールの担当であり、今回の対象ファイルに
// 含まれないため宣言しない（計画のスコープ外）。
//
// アクセス修飾（public）の方針は ExportSagaStore.swift と同じ。

/// image-pipeline.md「プロトコルのシグネチャ」節
public protocol MediaSaver: Sendable {
    /// 追加のみの権限で足りる。読み取り権限を要求しない（5 章）
    func saveToPhotoLibrary(_ file: OutputFile) async throws
}

/// image-pipeline.md「@MainActor のプロトコル」節
@MainActor
public protocol SharePresenter: AnyObject {
    func share(_ file: OutputFile) async -> ShareResult
}

/// export-saga.md 7章「利用者への受け渡し」。`UIActivityViewController` の
/// `completionWithItemsHandler` からの写像（export-saga.md 7.1）。
/// `.completed` は `generated` / `deliveryUnknown` → `delivered`。
/// `.canceled` / `.failed` / `.unknown` は現在の状態を維持する（安全側へ倒す）。
public enum ShareResult: Sendable, Equatable {
    case completed
    case canceled
    case unknown
    case failed
}
