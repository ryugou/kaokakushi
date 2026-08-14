import Foundation
import Domain
import GRDB

// beginDeliveryAttempt / completeLibrarySave / requireSettled / completeShare /
// abandonDeliveryAttempt（export-saga.md 7章「利用者への受け渡し」・7.0「写真ライブラリ
// 保存の結果不明」が正本）。
//
// decodeOutputState / updateOutputRecordState / deleteDeliveryAttempt / deliveryAttemptCountは
// internal（モジュール内既定アクセス）で公開する。resolveOrphanedAttempts
// （OutputDeliveryStoreLive+Recovery.swift）・deleteOutput
// （OutputDeliveryStoreLive+LibrarySaveAndDelete.swift）も同じロジックを使うため
// （ExportSagaStoreLive+Mapping.swiftのloadExportJobと同じ分割方針）。

extension OutputDeliveryStoreLive {
    /// previousStateを記録する（7.0 手順1）。事前条件: settledAt != nil（nilならthrow）。
    /// グローバル直列キューの前提（4.2/7.0）が崩れていないかを、既存attemptの有無で防御的に
    /// 検査する。
    public func beginDeliveryAttempt(_ exportID: ExportID) async throws {
        let startedAt = now()
        try await database.dbQueue.write { connection in
            guard let row = try Row.fetchOne(
                connection,
                sql: "SELECT state, settledAt FROM OutputRecord WHERE exportID = ?",
                arguments: [exportID.rawValue]
            ) else {
                throw OutputDeliveryStoreError.outputRecordNotFound(exportID: exportID)
            }
            let settledAt: Date? = row["settledAt"]
            guard settledAt != nil else {
                throw OutputDeliveryStoreError.notSettled(exportID: exportID)
            }
            guard try Self.deliveryAttemptCount(connection, exportID: exportID) == 0 else {
                throw OutputDeliveryStoreError.deliveryAttemptAlreadyInProgress(exportID: exportID)
            }
            // previousStateにはOutputRecord.stateの生の値をそのままコピーする。Domainの
            // enumへデコードする必要は無い（ここでは値の複製だけで分岐判断はしないため）。
            let stateRaw: Int = row["state"]
            try connection.execute(
                sql: "INSERT INTO DeliveryAttempt (exportID, startedAt, previousState) VALUES (?, ?, ?)",
                arguments: [exportID.rawValue, startedAt, stateRaw]
            )
        }
    }

    /// generated/deliveryUnknown → delivered。DeliveryAttemptを削除する（同一トランザクション。
    /// 7.0 手順3）。「attempt削除」の効果を果たすには対応するattemptの存在が前提のため、
    /// 事前条件として要求する（settleBatchNothingToSettleと同じフェイルクローズ方針）。
    public func completeLibrarySave(_ exportID: ExportID) async throws {
        try await database.dbQueue.write { connection in
            try Self.requireSettled(connection, exportID: exportID)
            guard try Self.deliveryAttemptCount(connection, exportID: exportID) > 0 else {
                throw OutputDeliveryStoreError.deliveryAttemptNotFound(exportID: exportID)
            }
            try Self.updateOutputRecordState(connection, exportID: exportID, state: .delivered)
            try Self.deleteDeliveryAttempt(connection, exportID: exportID)
        }
    }

    /// 共有（外部提示）の開始前に呼ぶ（Issue #32 C-1。Domain/Ports/OutputDeliveryStore.swiftの
    /// docコメントが正）。settledAt == nilならthrowする。completeShareが使うrequireSettled
    /// （このファイル下部のprivate static関数）と同じ判定ロジックをそのまま再利用し、判定を
    /// 二重に持たない。状態は変更しないため読み取り専用のdbQueue.readで完結させる。
    public func requireSettled(_ exportID: ExportID) async throws {
        try await database.dbQueue.read { connection in
            try Self.requireSettled(connection, exportID: exportID)
        }
    }

    /// generated/deliveryUnknown → delivered。共有自体は DeliveryAttempt を作らないが、
    /// 既存の DeliveryAttempt があれば拒否する（試行中の共有・破棄・別保存の排他は
    /// export-saga.md 7.0「delivered を後退させない・直列化・保存結果不明の永続化」の
    /// 不変条件）。事前条件: settledAt != nil。
    public func completeShare(_ exportID: ExportID) async throws {
        try await database.dbQueue.write { connection in
            try Self.requireSettled(connection, exportID: exportID)
            guard try Self.deliveryAttemptCount(connection, exportID: exportID) == 0 else {
                throw OutputDeliveryStoreError.deliveryAttemptAlreadyInProgress(exportID: exportID)
            }
            try Self.updateOutputRecordState(connection, exportID: exportID, state: .delivered)
        }
    }

    /// previousStateへ戻す（現在がdeliveredなら維持。後退させない。7.0表）。settledAtの
    /// 事前条件はこのメソッドには課さない（beginDeliveryAttemptが呼ばれた時点で既に
    /// settledAt != nilが検証済みのため）。
    public func abandonDeliveryAttempt(_ exportID: ExportID) async throws {
        try await database.dbQueue.write { connection in
            guard let previousStateRaw = try Int.fetchOne(
                connection, sql: "SELECT previousState FROM DeliveryAttempt WHERE exportID = ?",
                arguments: [exportID.rawValue]
            ) else {
                throw OutputDeliveryStoreError.deliveryAttemptNotFound(exportID: exportID)
            }
            let previousState = try Self.decodeOutputState(
                previousStateRaw, table: "DeliveryAttempt", column: "previousState"
            )
            // 現在の状態はcurrentOutputStateヘルパーでデコードしてから比較する（生のInt値
            // 同士の比較にしない。resolveOrphanedAttemptsと同じ判定材料・同じ失敗の仕方に
            // 揃える）。
            let currentState = try Self.currentOutputState(connection, exportID: exportID)
            if currentState != .delivered {
                try Self.updateOutputRecordState(connection, exportID: exportID, state: previousState)
            }
            try Self.deleteDeliveryAttempt(connection, exportID: exportID)
        }
    }

    /// completeLibrarySave/completeShareが共有する事前条件チェック: 対象OutputRecordが
    /// 存在しsettledAt != nilであること。
    private static func requireSettled(_ connection: Database, exportID: ExportID) throws {
        guard let row = try Row.fetchOne(
            connection, sql: "SELECT settledAt FROM OutputRecord WHERE exportID = ?",
            arguments: [exportID.rawValue]
        ) else {
            throw OutputDeliveryStoreError.outputRecordNotFound(exportID: exportID)
        }
        let settledAt: Date? = row["settledAt"]
        guard settledAt != nil else {
            throw OutputDeliveryStoreError.notSettled(exportID: exportID)
        }
    }

    /// 対象exportIDに対応するDeliveryAttempt行数を数える。deleteOutput
    /// （+LibrarySaveAndDelete.swift）も同じ「試行中は拒否する」検査に使うためinternalにする。
    static func deliveryAttemptCount(_ connection: Database, exportID: ExportID) throws -> Int {
        try Int.fetchOne(
            connection, sql: "SELECT count(*) FROM DeliveryAttempt WHERE exportID = ?",
            arguments: [exportID.rawValue]
        ) ?? 0
    }

    /// OutputRecord.stateを更新する共通ヘルパー。resolveOrphanedAttempts
    /// （+Recovery.swift）とも共有するためinternalにする。
    ///
    /// WHERE句に`state != delivered`を加え、`delivered`を後退させない（export-saga.md 7.0の
    /// 中核不変条件）をSQLレベルでも独立に守る（引き継ぎ1。防御的多重化）。呼び出し元は
    /// アプリ層の呼び出し規律により通常この分岐に触れないが、矛盾したデータ
    /// （DeliveryAttempt.previousStateとOutputRecord.stateの不整合）が万一存在しても後退させない。
    /// 既存の呼び出し箇所への影響: completeLibrarySave/completeShareは`state: .delivered`を渡す
    /// ため、現在既にdeliveredであれば「delivered→delivered」のUPDATEがWHERE句でスキップ
    /// されるだけで最終状態は変わらず実害が無い。abandonDeliveryAttemptは呼び出し側で既に
    /// `currentState != delivered`を確認してから呼ぶため影響しない。resolveOrphanedAttemptsの
    /// `.generated`ケースだけが実際にこの防御の恩恵を受ける。
    static func updateOutputRecordState(_ connection: Database, exportID: ExportID, state: OutputState) throws {
        try connection.execute(
            sql: "UPDATE OutputRecord SET state = ? WHERE exportID = ? AND state != ?",
            arguments: [state.rawValue, exportID.rawValue, OutputState.delivered.rawValue]
        )
    }

    /// DeliveryAttempt行を削除する共通ヘルパー。resolveOrphanedAttempts（+Recovery.swift）
    /// とも共有するためinternalにする。
    static func deleteDeliveryAttempt(_ connection: Database, exportID: ExportID) throws {
        try connection.execute(
            sql: "DELETE FROM DeliveryAttempt WHERE exportID = ?", arguments: [exportID.rawValue]
        )
    }

    /// Int生値をOutputStateへデコードする共通ヘルパー。abandonDeliveryAttempt/
    /// resolveOrphanedAttempts（+Recovery.swift）の両方がDeliveryAttempt.previousStateを
    /// 読むため共有する。
    static func decodeOutputState(_ rawValue: Int, table: String, column: String) throws -> OutputState {
        guard let value32 = UInt32(exactly: rawValue), let state = OutputState(rawValue: value32) else {
            throw OutputDeliveryStoreError.invalidColumnValue(table: table, column: column, rawValue: rawValue)
        }
        return state
    }

    /// 現在のOutputRecord.stateを読みデコードする共通ヘルパー。resolveOrphanedAttempts
    /// （+Recovery.swift）がDeliveryAttempt.previousStateだけでなく現在のOutputRecord.state
    /// も見て分岐するために使う。DeliveryAttemptはFK CASCADEでOutputRecordを参照するため
    /// 理論上行が存在しないことは無いが、他のヘルパー同様フェイルクローズで例外にする。
    static func currentOutputState(_ connection: Database, exportID: ExportID) throws -> OutputState {
        guard let stateRaw = try Int.fetchOne(
            connection, sql: "SELECT state FROM OutputRecord WHERE exportID = ?",
            arguments: [exportID.rawValue]
        ) else {
            throw OutputDeliveryStoreError.outputRecordNotFound(exportID: exportID)
        }
        return try Self.decodeOutputState(stateRaw, table: "OutputRecord", column: "state")
    }
}
