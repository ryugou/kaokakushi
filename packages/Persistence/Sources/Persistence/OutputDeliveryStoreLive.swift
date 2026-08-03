import Foundation
import Domain
import GRDB

// OutputDeliveryStoreの実装（export-saga.md 7章「利用者への受け渡し」・7.0「写真ライブラリ
// 保存の結果不明」が正本。Issue #6 Task 6 マイクロセッションA）。
//
// 今回のセッションで実装する5メソッド: beginDeliveryAttempt / completeLibrarySave /
// completeShare / abandonDeliveryAttempt / resolveOrphanedAttempts。
// loadUnknownLibrarySaves / clearUnknownLibrarySave / deleteOutputは次セッション担当のため
// スタブ（+Unimplemented.swift）にする。
//
// `OutputDeliveryStore`のポートシグネチャには時刻引数が無いが、DeliveryAttempt.startedAt /
// UnknownLibrarySave.occurredAtには実行時点の時刻が必要なため、ExportSagaStoreLiveと同じ
// 設計判断でinitへ`now: @escaping @Sendable () -> Date`を注入する（Domainのプロトコル自体は
// 変更しない）。
//
// 400行制限のため、メソッド群を以下へ分割する（ExportSagaStoreLiveの分割パターンを踏襲）:
//   - OutputDeliveryStoreLive.swift（このファイル）: 型定義・エラー型・init
//   - OutputDeliveryStoreLive+Attempt.swift: beginDeliveryAttempt / completeLibrarySave /
//     completeShare / abandonDeliveryAttempt
//   - OutputDeliveryStoreLive+Recovery.swift: resolveOrphanedAttemptsとRow→
//     OutputDeliverySnapshotデコードヘルパー
//   - OutputDeliveryStoreLive+Unimplemented.swift: loadUnknownLibrarySaves /
//     clearUnknownLibrarySave / deleteOutputのスタブ

/// OutputDeliveryStoreLiveが送出する専用エラー。運用者が次のアクションを判断できるよう、
/// 契約違反の詳細を持つ（ExportSagaStoreErrorと同じ方針: Sendable, Equatable, LocalizedError）。
public enum OutputDeliveryStoreError: Error, Sendable, Equatable {
    /// beginDeliveryAttempt / completeLibrarySave / completeShare: 対象exportIDの
    /// OutputRecord行が存在しない。
    case outputRecordNotFound(exportID: ExportID)
    /// beginDeliveryAttempt / completeLibrarySave / completeShare: 対象OutputRecordの
    /// settledAtがnil（未確定）。受け渡し系メソッドの共通事前条件（export-saga.md 7章
    /// 不変条件）。
    case notSettled(exportID: ExportID)
    /// beginDeliveryAttempt: 同一exportIDに対応するDeliveryAttempt行が既に存在する。
    /// グローバル直列キューの前提（export-saga.md 4.2/7.0）が崩れた場合の防御。
    case deliveryAttemptAlreadyInProgress(exportID: ExportID)
    /// completeLibrarySave / abandonDeliveryAttempt: 対象exportIDに対応するDeliveryAttempt
    /// 行が存在しない。
    case deliveryAttemptNotFound(exportID: ExportID)
    /// DeliveryAttempt.previousState / OutputRecord.state / OutputRecord.formatのいずれかの
    /// raw valueがDomainのenumのどのcaseにも対応しない（スキーマ移行漏れ、または手動でのDB
    /// 改変が疑われる）。
    case invalidColumnValue(table: String, column: String, rawValue: Int)
    /// loadUnknownLibrarySaves / clearUnknownLibrarySave / deleteOutput: 次セッション担当の
    /// ため未実装（本セッションのスコープ外。呼び出し元は次セッションの実装完了を待つこと）。
    case notImplemented(method: String)
}

extension OutputDeliveryStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .outputRecordNotFound(let exportID):
            return """
            OutputDeliveryStore: exportID=\(exportID.rawValue.uuidString) のOutputRecord行が \
            見つかりません。recordGeneratedOutputが成功していない、またはdeleteOutput/起動時 \
            復旧で既に削除されたexportIDが渡されていないか確認してください。
            """
        case .notSettled(let exportID):
            return """
            OutputDeliveryStore: exportID=\(exportID.rawValue.uuidString) のOutputRecordは \
            settledAtがnil（未確定）です。受け渡し（保存・共有）は完了操作（settleExport/ \
            settleBatch）の後にのみ行えます（export-saga.md 7章不変条件）。呼び出し元のUIが \
            完了前の出力に対して受け渡し操作へ到達させていないか確認してください。
            """
        case .deliveryAttemptAlreadyInProgress(let exportID):
            return """
            OutputDeliveryStore: exportID=\(exportID.rawValue.uuidString) には既に \
            DeliveryAttempt行が存在します。グローバル直列キューにより本来同時に複数の保存 \
            試行は起き得ません（export-saga.md 4.2/7.0）。前回の試行がabandonDeliveryAttempt/ \
            completeLibrarySaveで解消されずに残っている可能性があります。起動時復旧 \
            （resolveOrphanedAttempts）が実行されているか確認してください。
            """
        case .deliveryAttemptNotFound(let exportID):
            return """
            OutputDeliveryStore: exportID=\(exportID.rawValue.uuidString) に対応する \
            DeliveryAttempt行が見つかりません。beginDeliveryAttemptを呼ばずに \
            completeLibrarySave/abandonDeliveryAttemptを呼んでいないか、または既に \
            resolveOrphanedAttempts等で解消済みではないか確認してください。
            """
        case .invalidColumnValue(let table, let column, let rawValue):
            return """
            OutputDeliveryStore: \(table).\(column) の値 \(rawValue) はDomainのenumのどの \
            caseにも対応しません。スキーマとDomainのenum定義が不整合になっている可能性が \
            あります（マイグレーション漏れ、または手動でのDB改変を疑ってください）。
            """
        case .notImplemented(let method):
            return """
            OutputDeliveryStore: \(method) は本セッションのスコープ外のため未実装です。 \
            次セッションでの実装完了を待ってください。
            """
        }
    }
}

/// OutputDeliveryStoreの実装。GRDBのAppDatabaseを1つ受け取り、全メソッドを
/// dbQueue.write / dbQueue.readの呼び出しだけで完結させる。
///
/// `database` / `now`はpublicではないが、複数ファイルへ分割したextensionから参照する
/// 必要があるため（ExportSagaStoreLiveと同じ理由）モジュール内既定アクセス（internal）の
/// ままにする。外部パッケージからは見えない。
public struct OutputDeliveryStoreLive: OutputDeliveryStore {
    let database: AppDatabase
    let now: @Sendable () -> Date

    public init(database: AppDatabase, now: @escaping @Sendable () -> Date) {
        self.database = database
        self.now = now
    }
}
