import Foundation
import Domain
import GRDB

// HistoryDeletionStoreの実装（architecture.md「削除の可否判定」〜「出力の削除経路」・
// 「Project削除Saga」・「実装の所在」が正本。Issue #6）。
//
// `HistoryUnit`はcase `.project(ProjectID)`のみ（正本Ports/HistoryStores.swift）。
// `canDeleteHistoryUnit`という名前のpublic純粋関数はHistoryStores.swiftへ追加しない
// （Issue #20で対象外、HistoryStores.swift冒頭コメントに明記）。同等の判定は
// このファイル群のprivate関数（HistoryDeletionStoreLive+Context.swiftのevaluateDeletion）
// として実装する（Persistence層のprivateロジックでありDomain公開の純粋関数ではないため
// 矛盾しない。オーケストレーター確定判断）。
//
// 400行制限のため、メソッド群を以下へ分割する（ExportSagaStoreLive/OutputDeliveryStoreLive
// の分割パターンを踏襲）:
//   - HistoryDeletionStoreLive.swift（このファイル）: 型定義・エラー型・init
//   - HistoryDeletionStoreLive+Context.swift: DeletionContext相当の値をDBから読み取る
//     privateヘルパー群・削除可否判定ロジック（evaluateDeletion）
//   - HistoryDeletionStoreLive+Inspect.swift: inspectDeletion
//   - HistoryDeletionStoreLive+Delete.swift: deleteHistoryUnit（判定＋削除本体）
//
// ProjectStampAssetの解放ロジックはStampStoreと共通のため、モジュール共有の
// StampAssetReferences.swift（StampStoreLive+References.swiftも同じ関数を呼ぶ）に置く。
//
// 既知のスキーマギャップ（実装不可。判断を求めず、コメントで明記するだけに留める）:
//   - Project.isFavorite / isBeingEdited: Schema+Project.swiftのProjectテーブルに対応する
//     列が存在しないため常にfalse固定。MaintenanceStoreLive+References.swiftの
//     `.historyThumbnail`ケースと同水準の扱い。列が追加されるまでの暫定であり、
//     オーケストレーターが最終報告でエスカレーションする。
//   - 履歴サムネイル（ManagedFileRef(.historyThumbnail, ...)）の実体解放は行わない
//     （Projectがその参照を保持する列が存在しないため。同じ理由でMaintenanceStoreLive+
//     References.swiftの`.historyThumbnail`ケースも常に空集合を返している）。

/// HistoryDeletionStoreLiveが送出する専用エラー。運用者が次のアクションを判断できるよう、
/// どの保護が原因で削除を拒否したかを持つ（OutputDeliveryStoreError/WorkingSourceStoreError
/// と同じ方針: Sendable, Equatable, LocalizedError）。
public enum HistoryDeletionStoreError: Error, Sendable, Equatable {
    /// 絶対保護（非終端キュー項目・進行中のExportJob・未受け渡しのOutputRecordのいずれか）に
    /// 該当したため、triggerの種類に関わらず削除を拒否した（architecture.md「削除の可否判定」）。
    case blockedByAbsoluteProtection(unit: HistoryUnit, reasons: Set<AbsoluteProtection>)
    /// 上書き可能な保護（favorite/beingEdited/workingSource）に該当し、`.storagePressure`/
    /// `.retentionExpiry`では上書きできない、または`.userInitiated`のconfirmedOverridesに
    /// 含まれていなかったため削除を拒否した。
    case blockedByOverridableProtection(unit: HistoryUnit, reasons: Set<OverridableProtection>)
}

extension HistoryDeletionStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .blockedByAbsoluteProtection(let unit, let reasons):
            return """
            HistoryDeletionStore: \(Self.describe(unit)) の削除を拒否しました。絶対保護 \
            （\(reasons)）に該当するためtriggerの種類に関わらず削除できません \
            （architecture.md「削除の可否判定」）。非終端のキュー項目・進行中のExportJob・ \
            未受け渡しのOutputRecordのいずれかが解消されるまで待ってください。
            """
        case .blockedByOverridableProtection(let unit, let reasons):
            return """
            HistoryDeletionStore: \(Self.describe(unit)) の削除を拒否しました。上書き可能な \
            保護（\(reasons)）に該当し、利用者による明示確認が得られていません。 \
            userInitiatedで削除する場合は該当するOverridableProtectionをconfirmedOverrides \
            へ含めて再試行してください（storagePressure/retentionExpiryの場合は上書きできず、 \
            呼び出し元のCoordinatorが次の候補へ進む必要があります）。
            """
        }
    }

    private static func describe(_ unit: HistoryUnit) -> String {
        switch unit {
        case .project(let projectID):
            return "projectID=\(projectID.rawValue.uuidString)"
        }
    }
}

/// HistoryDeletionStoreの実装。GRDBのAppDatabaseを1つ受け取り、全メソッドを
/// dbQueue.write / dbQueue.readの呼び出しだけで完結させる。
///
/// `database`はpublicではないが、複数ファイルへ分割したextensionから参照する必要が
/// あるため（ExportSagaStoreLive/OutputDeliveryStoreLiveと同じ理由）モジュール内既定
/// アクセス（internal）のままにする。外部パッケージからは見えない。
///
/// タイムスタンプを書き込む列がこのStoreの操作対象に無いため（Project削除・関連行の
/// CASCADE削除・PendingFileDeletion登録のいずれも時刻列を持たない）、
/// ExportSagaStoreLive/OutputDeliveryStoreLiveと異なり`now`は注入しない。
public struct HistoryDeletionStoreLive: HistoryDeletionStore {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }
}
