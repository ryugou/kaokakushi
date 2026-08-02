import Foundation
import Domain
import GRDB

// WorkingSourceStoreの実装（image-pipeline.md 5章「処理用ファイルの寿命をDBで管理する」
// 「インポートSaga」「再選択後のSaga」「実装の所在」「実体の存在確認」が正本。
// Issue #6 Task 4）。
//
// 各メソッドは単一の dbQueue.write トランザクションに閉じる（正本の要求どおり）。
// GRDBのDatabaseWriter.write(_:)はupdatesクロージャをGRDB内部のdb.inTransactionで包み、
// throwすればロールバックしてエラーを再送出する（GRDB本体の契約。AppDatabase.swiftの
// コメント参照）。よってメソッド内でthrowしたエラーより前の書き込みも含めコミットされない。
//
// 400行制限のため、メソッド群をテーブル操作の単位で分割する（既存のSchema+*.swiftの
// 分割パターンを踏襲）:
//   - WorkingSourceStoreLive.swift（このファイル）: 型定義・エラー型・raw value割当・
//     複数メソッドが共有する内部ヘルパー
//   - WorkingSourceStoreLive+Create.swift: createProjectWithWorkingSource
//   - WorkingSourceStoreLive+Replace.swift: replaceWorkingSource /
//     attachWorkingSourceToExistingProject
//   - WorkingSourceStoreLive+Lifecycle.swift: loadWorkingSource / deleteWorkingSource /
//     invalidateWorkingSource
//
// スコープ外（今回のTask 4では実装しない。理由をここに残す）:
// - StampStore（Domain ポートの戻り値契約に構造的ギャップがあり別途エスカレーション予定。
//   本ファイル・分割先ファイルのいずれにも手を付けない）。

/// WorkingSourceStoreLiveが送出する専用エラー。運用者が次のアクションを判断できるよう、
/// 契約違反の詳細を持つ（AppDatabaseError/ManagedFileStoreErrorと同じ方針:
/// Sendable, Equatable, LocalizedError）。
public enum WorkingSourceStoreError: Error, Sendable, Equatable {
    /// createProjectWithWorkingSource: input.queueItemIDが非nilなのにinput.batchIDが
    /// nilだった。ExportQueueItem.batchIDはNOT NULL制約のため、この組み合わせのまま
    /// 挿入するとクラッシュしてしまう。呼び出し元（SourceImportCoordinator）の契約違反
    /// として明示的にthrowし、握りつぶさない（image-pipeline.md 5章
    /// CreateWorkingSourceInput）。
    case batchIDMissingForQueueItem(queueItemID: ExportQueueItemID)
}

extension WorkingSourceStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .batchIDMissingForQueueItem(let queueItemID):
            return """
            WorkingSourceStore: queueItemID=\(queueItemID.rawValue.uuidString) を指定した \
            CreateWorkingSourceInputにbatchIDがありません。ExportQueueItem.batchIDはNOT NULL \
            制約のため挿入できません。呼び出し元（SourceImportCoordinator）でqueueItemIDと \
            batchIDを常に対で渡しているか確認してください。
            """
        }
    }
}

/// `ExportQueueItem.state` 列のraw value割当（Issue #6 Task 4で確定）。Domain
/// `Queue/ExportQueueState.swift` の `ExportQueueState` の各caseに対応する。
/// **Task 8（キュー状態機械）実装時はこの割当をそのまま再利用すること**
/// （列値はスキーマ移行をまたいで永続化されるため、後から変更すると既存行の意味が
/// 変わってしまう）。
enum ExportQueueStateColumn: Int, Sendable {
    case waiting = 1
    case analyzing = 2
    case reviewRequired = 3
    case exporting = 4
    case completed = 5
    case failed = 6
    case canceled = 7
    case paused = 8
}

/// `ExportQueueItem.pauseReason` 列のraw value割当（Issue #6 Task 4で確定）。Domain
/// `Queue/ExportQueueState.swift` の `QueuePauseReason` に対応する。Task 8実装時は
/// この割当を再利用すること。
enum QueuePauseReasonColumn: Int, Sendable {
    case entitlementExpired = 1
    case storageInsufficient = 2
    case userPaused = 3
    case sourceReselectionRequired = 4
}

/// `Project.sourceRepresentation` 列のraw value割当（Issue #6 Task 4で確定）。Domain
/// `SourceRepresentation` に対応する。以後この列を読み書きする実装が現れた場合は
/// この割当を再利用すること。
enum SourceRepresentationColumn: Int, Sendable {
    case original = 1
    case transcoded = 2

    init(_ value: SourceRepresentation) {
        switch value {
        case .original: self = .original
        case .transcoded: self = .transcoded
        }
    }
}

/// WorkingSourceStoreの実装。GRDBのAppDatabaseを1つ受け取り、全メソッドを
/// dbQueue.write / dbQueue.readで完結させる（architecture.md 7.1 正本のDB接続を
/// そのまま再利用し、Store独自の接続は持たない）。
///
/// `database` はpublicではないが、複数ファイルへ分割したextensionから参照する必要が
/// あるため（Schema+*.swiftの分割パターンと同じ理由）モジュール内既定アクセス（internal）
/// のままにする。外部パッケージからは見えない。
public struct WorkingSourceStoreLive: WorkingSourceStore {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }
}

extension WorkingSourceStoreLive {
    /// `WorkingSourceRecord.sourceFileID` を読む共通ヘルパー（replaceWorkingSource /
    /// deleteWorkingSource / invalidateWorkingSource が共有する）。行が無ければnilを
    /// 返す（呼び出し元の契約上は存在するはずのケースが多いが、無い場合も防御的に
    /// 許容しクラッシュさせない）。
    static func loadSourceFileID(_ connection: Database, projectID: ProjectID) throws -> ManagedFileID? {
        let rawValue = try UUID.fetchOne(
            connection,
            sql: "SELECT sourceFileID FROM WorkingSourceRecord WHERE projectID = ?",
            arguments: [projectID.rawValue]
        )
        return rawValue.map(ManagedFileID.init(rawValue:))
    }

    /// `PendingFileDeletion` へ `INSERT OR IGNORE` で登録する共通ヘルパー
    /// （image-pipeline.md 5章「削除の経路」の単一経路パターン。重複登録による主キー
    /// 制約違反を避けるため OR IGNORE にする）。実ファイルの削除自体は
    /// SourceImportCoordinator側（Task 5）の担当であり、ここでは行わない。
    static func registerPendingFileDeletion(_ connection: Database, fileID: ManagedFileID) throws {
        try connection.execute(
            sql: "INSERT OR IGNORE INTO PendingFileDeletion (kind, fileID) VALUES (?, ?)",
            arguments: [ManagedFileKind.processingTemporary.rawValue, fileID.rawValue]
        )
    }
}
