import Foundation
import Domain

// ExportCoordinator+Settle — 書き出しの完了操作と確定後の実体喪失（Issue #7 Task 6）。
//
// 正本: export-saga.md 3章「手順」手順5（settleExport / settleBatch は store の単一
// トランザクションへ委譲する。ここが唯一の確定境界）、6章「確定後に出力実体が失われた場合」。
//
// settleExport / settleBatch は exportSagaStore への薄い委譲（discardExport と同じ方針。
// ExportCoordinator+Generate.swift 参照）。settleBatch の settledAt は呼び出し側であるこの
// Coordinator が注入されたクロックから決め、対象バッチ内の全件へ同一の値を渡す
// （export-saga.md 3章「settledAt は呼び出し側が渡した時刻で全件に統一する」）。
//
// verifyOutputIntegrity は完了済み出力の提示前に呼ばれる想定（6章はこの章の対象を settledAt
// != nil の出力に限る）。削除の根拠は OutputFileVerificationError の missing / emptyFile /
// undecodable と測定値（byteSize / sha256）不一致のみであり、.ioFailure は削除しない
// （Task 1 レビューでの決定。catch-all で削除経路へ入れない）。

/// verifyOutputIntegrity の判定結果（export-saga.md 6章）。
public enum OutputIntegrityOutcome: Sendable, Equatable {
    /// 実体が確認でき、測定値が OutputRecord と一致する
    case intact
    /// 実体が無い、または測定値が不一致。OutputRecord を削除済み
    case lost
    /// 読み取り中の一時的な I/O 障害で健全性を確認できなかった。削除はしていない
    case verificationUnavailable
}

extension ExportCoordinator {
    /// 単体書き出しの完了操作（export-saga.md 3章 手順5）。exportSagaStore.settleExport への
    /// 薄い委譲。二重確定等の事前条件違反は握りつぶさず呼び出し元へ伝播する。
    public func settleExport(_ exportID: ExportID) async throws {
        try await queue.run {
            try await self.exportSagaStore.settleExport(exportID)
        }
    }

    /// バッチの完了操作（export-saga.md 3章 手順5）。settledAt は注入されたクロックから取得し、
    /// 対象バッチ内の確定対象全件へ同一の値で渡す。
    public func settleBatch(_ batchID: BatchID) async throws {
        try await queue.run {
            try await self.exportSagaStore.settleBatch(batchID, settledAt: self.now())
        }
    }

    /// 完了済み出力の健全性を確認する（export-saga.md 6章）。実体喪失（missing / emptyFile /
    /// undecodable、または測定値不一致）なら OutputDeliveryStore.deleteOutput で物理削除して
    /// `.lost` を返す。台帳には触れない（store の契約どおり deleteOutput は台帳を変更しない）。
    /// 読み取り専用の verify 呼び出しは queue を経由しない（SerialTaskQueue.swift「読み取りは
    /// 経由しない」）。削除だけを queue 経由にする。verify（queue 外の読み取り）→ deleteOutput
    /// （queue 内の書き込み）の間は排他が保持されない read-then-write のため、原子性は無い
    /// （レビュー第2ラウンド D）。実害は無い: その間に別の書き出し試行が走れば store 側が
    /// throw し、既に削除済みなら deleteOutput から outputNotFound が伝播するだけで、
    /// 呼び出し元へは握りつぶさず伝わる。
    public func verifyOutputIntegrity(_ output: OutputRecord) async throws -> OutputIntegrityOutcome {
        switch await verifiedMeasurementResult(for: output.outputFile) {
        case .success(let measurement):
            guard measurement.byteSize == output.outputByteSize, measurement.sha256 == output.outputSHA256 else {
                try await deleteLostOutput(output.exportID)
                return .lost
            }
            return .intact
        case .failure(.missing), .failure(.emptyFile), .failure(.undecodable):
            try await deleteLostOutput(output.exportID)
            return .lost
        case .failure(.ioFailure):
            return .verificationUnavailable
        }
    }

    /// typed throws の verify 結果を Result へ変換する（呼び出し元の switch で ioFailure だけを
    /// 分岐させるため。エラー型を保ったまま Result に包み、削除経路の catch-all 化を避ける）。
    private func verifiedMeasurementResult(
        for file: OutputFileRef
    ) async -> Result<VerifiedOutputMeasurement, OutputFileVerificationError> {
        do {
            return .success(try await outputFileVerifier.verify(file))
        } catch {
            return .failure(error)
        }
    }

    /// W-1（Task 12 レビュー）: OutputDeliveryCoordinator.deleteOutput と同じ store 操作を
    /// 呼ぶが、こちらはゲートを待っていなかった（verifyOutputIntegrity は完了済み出力の履歴
    /// 表示前に呼ばれる想定であり、起動直後・復旧完了前に到達しうる唯一の未ゲート経路だった）。
    /// 復旧の resolveOrphanedAttempts より先に走ると、残存する DeliveryAttempt により store が
    /// throw し、履歴の実体喪失表示が誤って失敗する。verify自体（読み取り。上の
    /// verifyOutputIntegrity 冒頭コメント参照）はゲートを待たず、削除だけをキュー投入前で待つ。
    private func deleteLostOutput(_ exportID: ExportID) async throws {
        try await recoveryGate.awaitRecoveryCompleted()
        try await queue.run {
            try await self.outputDeliveryStore.deleteOutput(exportID)
        }
    }
}
