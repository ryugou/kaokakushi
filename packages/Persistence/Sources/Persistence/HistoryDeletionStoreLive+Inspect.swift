import Foundation
import Domain
import GRDB

// inspectDeletion（HistoryStores.swiftの正本docコメント「確認画面の表示用。ここで得た値を
// 削除の根拠にしない」・architecture.md「Project削除Saga」直後の`DeletionInspection`定義が
// 正本）。

extension HistoryDeletionStoreLive {
    public func inspectDeletion(_ unit: HistoryUnit, trigger: DeletionTrigger) async throws -> DeletionInspection {
        let projectID = Self.projectID(for: unit)
        return try await database.dbQueue.read { connection in
            let context = try Self.loadDeletionContext(connection, unit: unit, trigger: trigger)
            let reclaimableBytes = try Self.reclaimableBytes(connection, projectID: projectID)
            return DeletionInspection(
                blockedByAbsoluteProtection: Self.absoluteProtections(in: context),
                overridableProtections: Self.overridableProtections(in: context),
                reclaimableBytes: reclaimableBytes
            )
        }
    }

    /// OutputRecord.outputByteSizeの合計（正本に算出式の指定は無く、オーケストレーター
    /// 確定判断）。解放されるのはファイルの実体であり、DBが実体を追跡しているのは
    /// OutputRecord.outputFileIDのみのため、これだけを合算する。ExportRecordを含めると
    /// settle後24時間はOutputRecordと同一ファイルを二重計上し、実体削除後は解放されない
    /// バイトを計上して過大になる（一次レビュー指摘で修正）。historyThumbnail等、DBに
    /// 列を持たないファイルサイズは含められないため、その分は少なく見積もられる
    /// （既知のギャップとして受け入れる）。
    private static func reclaimableBytes(_ connection: Database, projectID: ProjectID) throws -> Int64 {
        try Int64.fetchOne(
            connection,
            sql: "SELECT COALESCE(SUM(outputByteSize), 0) FROM OutputRecord WHERE projectID = ?",
            arguments: [projectID.rawValue]
        ) ?? 0
    }
}
