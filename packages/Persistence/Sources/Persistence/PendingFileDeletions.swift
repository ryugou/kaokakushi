import Foundation
import Domain
import GRDB

// PendingFileDeletionへの登録を1経路へ集約する共有ヘルパー（architecture.md 7.5
// 「出力の削除経路」・image-pipeline.md 5章「削除の経路」が正本）。
//
// ExportSagaStore / HistoryDeletionStore / OutputDeliveryStore / MaintenanceStore /
// StampStore / WorkingSourceStoreのすべてが同一のINSERT文を個別に持っていたため、SQL文と
// 引数の組み立てをここへ一本化する（kindの取り違えや`OR IGNORE`の付け忘れが1箇所の
// 修正で防げるようにするため）。実ファイルの削除はここでは行わない（コミット後に
// MaintenanceStore経由のGC・呼び出し元のパイプラインが担当する）。
//
// いずれの関数も呼び出し元のdbQueue.writeクロージャ内から呼ばれるため、ここで発行する
// INSERTは呼び出し元と同一トランザクションに含まれる（Storeごとのトランザクション境界は
// 変えない）。Schema+*.swiftのテーブル定義関数と同じく、特定のStore型に属さない
// モジュール共有の関数としてトップレベルに置く。

/// `PendingFileDeletion`へ1件登録する。重複登録による主キー制約違反を避けるため
/// `INSERT OR IGNORE`にする（同じ参照を何度登録しても安全＝冪等）。
func registerPendingFileDeletion(_ connection: Database, kind: ManagedFileKind, fileID: UUID) throws {
    try connection.execute(
        sql: "INSERT OR IGNORE INTO PendingFileDeletion (kind, fileID) VALUES (?, ?)",
        arguments: [kind.rawValue, fileID]
    )
}

/// `PendingFileDeletion`へ複数件を1文（複数行VALUES）で登録する。1件ずつのINSERTを
/// 繰り返す場合と登録される行は同一で、`OR IGNORE`により配列内に同じ参照が重複していても
/// 安全（冪等）。空配列のときはSQLを発行せず何もしない（`VALUES`の中身が空の不正なSQLを
/// 組み立てないため。呼び出し元から見れば「登録すべきファイルが無い」＝no-op）。
func registerPendingFileDeletions(_ connection: Database, files: [ManagedFileRef]) throws {
    guard !files.isEmpty else { return }
    // 1行ぶんのプレースホルダ`(?, ?)`を件数分並べる（値はarguments経由で束縛するため、
    // SQL文へ値を埋め込む経路は作らない）。GRDBのdatabaseQuestionMarks(count:)は
    // `?,?,...`の平坦な並びを作るヘルパーで、行のグループ化には使えないためここでは使わない。
    let valuesClause = Array(repeating: "(?, ?)", count: files.count).joined(separator: ", ")
    var arguments = StatementArguments()
    for file in files {
        arguments += [file.kind.rawValue, file.fileID.rawValue]
    }
    try connection.execute(
        sql: "INSERT OR IGNORE INTO PendingFileDeletion (kind, fileID) VALUES \(valuesClause)",
        arguments: arguments
    )
}
