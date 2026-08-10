import Foundation

// RecoveryGate — 起動時復旧の完了を待ち合わせる窓口（architecture.md 4.3「完了まで他の
// すべてを開始させない」、export-saga.md 5章。Issue #7 Task 12。Task 12 レビュー C-1 で
// async throws へ変更）。
//
// ExportCoordinator / OutputDeliveryCoordinator はこのプロトコル越しに
// StartupRecoveryCoordinator を参照する。StartupRecoveryCoordinator 自身はこのファイルを
// 含め、他の Coordinator を一切知らない（循環依存を作らないため。依存の向きは常に
// 変更系 Coordinator → RecoveryGate ← StartupRecoveryCoordinator の一方向）。準拠
// （`extension StartupRecoveryCoordinator: RecoveryGate {}`）は StartupRecoveryCoordinator.swift
// 側に置く（S-1。抽象側のこのファイルが具象型を知る配置は上記の依存の向きと食い違うため）。
//
// `RecoveryGate` を注入する側は、起動時に必ず `runStartupRecovery()` を呼ぶ責務を負う。
// 呼ばれなければゲートは永久に閉じたままとなり、全変更系操作が待ち続ける（合成ルートは
// UI サブプロジェクトで実装されるため、呼び忘れをコード側から警告できるのはこの doc コメントが
// 唯一の場所である。W-3）。

/// 起動時復旧の完了を待つゲート。`StartupRecoveryCoordinator.awaitRecoveryCompleted()` を
/// 抽象化する。
public protocol RecoveryGate: Sendable {
    /// 復旧が完了するまで呼び出し元を保留する。既に完了していれば即座に返る。
    /// 復旧が失敗で確定している場合は待たずに即座に `StartupRecoveryFailedError` を throw する
    /// （「新しい書き出しを開始させない」が正本の要求であり、無応答にすることではない。C-1）。
    /// キャンセル時は `CancellationError` を throw する。
    func awaitRecoveryCompleted() async throws
}

/// 起動時復旧が失敗で確定した後に `awaitRecoveryCompleted()` を呼んだ場合に返すエラー
/// （Task 12 レビュー C-1）。復旧は再試行されないため、以後この状態のままプロセス生存中は
/// 変わらない。原因エラーを cause として保持し握りつぶさない（Global Constraints「エラーの
/// 握りつぶし禁止」）。
public struct StartupRecoveryFailedError: Error {
    public let cause: Error

    public init(cause: Error) {
        self.cause = cause
    }
}
