import Foundation
import Domain
import GRDB

// OutputDeliveryStoreの実装（export-saga.md 7章「利用者への受け渡し」・7.0「写真ライブラリ
// 保存の結果不明」が正本。Issue #6 Task 6）。
//
// 実装する8メソッド: beginDeliveryAttempt / completeLibrarySave / completeShare /
// abandonDeliveryAttempt / resolveOrphanedAttempts / loadUnknownLibrarySaves /
// clearUnknownLibrarySave / deleteOutput。
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
//   - OutputDeliveryStoreLive+LibrarySaveAndDelete.swift: loadUnknownLibrarySaves /
//     clearUnknownLibrarySave / deleteOutput（architecture.md 7.5「出力の削除経路」）

/// OutputDeliveryStoreLiveが送出する専用エラー。運用者が次のアクションを判断できるよう、
/// 契約違反の詳細を持つ（ExportSagaStoreErrorと同じ方針: Sendable, Equatable, LocalizedError）。
public enum OutputDeliveryStoreError: Error, Sendable, Equatable {
    /// beginDeliveryAttempt / completeLibrarySave / completeShare: 対象exportIDの
    /// OutputRecord行が存在しない。
    case outputRecordNotFound(exportID: ExportID)
    /// beginDeliveryAttempt / completeLibrarySave / completeShare / deleteOutput: 対象
    /// OutputRecordのsettledAtがnil（未確定）。受け渡し系メソッドおよびdeleteOutputの
    /// 共通事前条件（export-saga.md 7章不変条件）。
    case notSettled(exportID: ExportID)
    /// beginDeliveryAttempt: 同一exportIDに対応するDeliveryAttempt行が既に存在する。
    /// グローバル直列キューの前提（export-saga.md 4.2/7.0）が崩れた場合の防御。
    /// deleteOutput: 同じ検査条件を「試行中の出力の破棄を拒否する」（7.0表）ために再利用する
    /// （意味は異なるが検査条件は同一のため）。
    case deliveryAttemptAlreadyInProgress(exportID: ExportID)
    /// completeLibrarySave / abandonDeliveryAttempt: 対象exportIDに対応するDeliveryAttempt
    /// 行が存在しない。
    case deliveryAttemptNotFound(exportID: ExportID)
    /// DeliveryAttempt.previousState / OutputRecord.state / OutputRecord.formatのいずれかの
    /// raw valueがDomainのenumのどのcaseにも対応しない（スキーマ移行漏れ、または手動でのDB
    /// 改変が疑われる）。
    case invalidColumnValue(table: String, column: String, rawValue: Int)
    /// resolveOrphanedAttempts: OutputRecord.outputFileIDから`kind = .output`固定で組み立てた
    /// `ManagedFileRef`を`OutputFileRef.init(_:)`が受け付けなかった。列値ではなく型の契約
    /// （ManagedFileRef.swift「種別つきの参照」）が食い違っている構造的不整合のため、列の
    /// raw valueを持つinvalidColumnValueとは別のcaseにする（ダミーのrawValueを詰めない）。
    case invalidOutputFileKind(exportID: ExportID)
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
            settledAtがnil（未確定）です。受け渡し（保存・共有）およびdeleteOutputによる破棄は \
            完了操作（settleExport/settleBatch）の後にのみ行えます（export-saga.md 7章不変 \
            条件）。呼び出し元のUIが完了前の出力に対してこれらの操作へ到達させていないか確認 \
            してください。
            """
        case .deliveryAttemptAlreadyInProgress(let exportID):
            return """
            OutputDeliveryStore: exportID=\(exportID.rawValue.uuidString) には既に \
            DeliveryAttempt行が存在します。グローバル直列キューにより本来同時に複数の保存 \
            試行は起き得ません（export-saga.md 4.2/7.0）。beginDeliveryAttemptであれば前回の \
            試行がabandonDeliveryAttempt/completeLibrarySaveで解消されずに残っている可能性が、 \
            deleteOutputであれば試行中の出力を破棄しようとした可能性があります。起動時復旧 \
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
        case .invalidOutputFileKind(let exportID):
            return """
            OutputDeliveryStore: exportID=\(exportID.rawValue.uuidString) のOutputRecord. \
            outputFileIDからOutputFileRefを構築できませんでした。Persistence側はkindを \
            .outputに固定して組み立てているため、Domainの種別つき参照（OutputFileRef.init(_:)。 \
            ManagedFileRef.swift）が受け付けるkindの条件と食い違っています。DomainパッケージとPersistence \
            アダプタのバージョンが一致しているか（ManagedFileKindの割当やOutputFileRefの受け入れ \
            条件の変更が片側だけ取り込まれていないか）を確認してください。
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
