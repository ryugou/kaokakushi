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
// StampStoreは別ファイル（StampStoreLive.swift以下）で実装する（旧セッションで
// importCustomStampの戻り値契約に構造的ギャップがあるとして差し戻され、
// docs/architecture.mdの正本更新（コミット1c04e47）後に別途実装済み。本ファイルの
// 対象はWorkingSourceStoreのみで変わらない）。

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
}
