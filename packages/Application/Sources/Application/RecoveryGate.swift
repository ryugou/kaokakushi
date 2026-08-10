import Foundation

// RecoveryGate — 起動時復旧の完了を待ち合わせる窓口（architecture.md 4.3「完了まで他の
// すべてを開始させない」、export-saga.md 5章。Issue #7 Task 12）。
//
// ExportCoordinator / OutputDeliveryCoordinator はこのプロトコル越しに
// StartupRecoveryCoordinator を参照する。StartupRecoveryCoordinator 自身はこのファイルを
// 含め、他の Coordinator を一切知らない（循環依存を作らないため。依存の向きは常に
// 変更系 Coordinator → RecoveryGate ← StartupRecoveryCoordinator の一方向）。

/// 起動時復旧の完了を待つゲート。`StartupRecoveryCoordinator.awaitRecoveryCompleted()` を
/// 抽象化する。
public protocol RecoveryGate: Sendable {
    /// 復旧が完了するまで呼び出し元を保留する。既に完了していれば即座に返る。
    func awaitRecoveryCompleted() async
}

extension StartupRecoveryCoordinator: RecoveryGate {}
