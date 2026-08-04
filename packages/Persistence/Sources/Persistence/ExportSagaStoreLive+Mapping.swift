import Foundation
import Domain
import GRDB

// 複数ファイルが共有する行の読み取り・デコード（export-saga.md 2章「ExportJobと
// OutputRecord」が正本）。
// recordGeneratedOutput（+Output.swift）とloadRunningJobs（+Recovery.swift）の両方が
// 同じExportJob行の形状を読むため、SELECT列リストとデコードをここに集約する。
// `decodePlanAndStatus`はExportJob行（entitlementPlan/entitlementStatus）と
// SubscriptionState行（plan/status）の両方（+Start.swift）から列名だけ変えて共有する。
// `fetchSingletonRow`は単一行契約のテーブル（SubscriptionState / UsageLedger）の読み取りを
// +Start.swift / +Ledger.swift / +Accounting.swiftから共有する。

extension ExportSagaStoreLive {
    /// ExportJob行のSELECT列リスト。loadExportJob（このファイル）とloadRunningJobs
    /// （+Recovery.swift）は同じ行形状をmakeExportJobでデコードするため、列を1箇所へ
    /// 集約し、片方だけ列が増減して壊れる事故を防ぐ。settingsHashはDomainの`ExportJob`には
    /// 現れないPersistence内部専用列（Schema+Accounting.swift）で、settle時の
    /// ExportedSettingsEntry更新に使うためExportJob本体と同じSELECTで読む。
    /// +Recovery.swiftから参照するためprivateにしていない（他のstatic funcと同じ流儀）。
    static let exportJobColumns = """
    exportID, projectID, batchID, queueItemID, authorizedAt, accountingMode,
        entitlementPlan, entitlementStatus, entitlementExpiresAt,
        entitlementLastVerifiedAt, entitlementIsSandbox, deliveryFormat,
        deliverySuggestedCreationDate, settingsHash
    """

    /// loadExportJobの戻り値。Domainの`ExportJob`と、同じ行から読んだPersistence内部専用の
    /// settingsHash列を組にして返す（settle時に再度SELECTし直さないため）。
    struct LoadedExportJob {
        let job: ExportJob
        /// ExportJob.settingsHash列（startExport時点で計算済み。Schema+Accounting.swift）。
        /// settle（3章 手順5「confirmed設定エントリの更新」）がExportedSettingsEntryへ
        /// そのままコピーする。
        let settingsHash: Data
    }

    /// exportIDに対応するExportJob行を読み、Domainの`ExportJob`とsettingsHashへデコードする。
    /// 行が無ければnilを返す（recordGeneratedOutput / settle系が「行の存在」を
    /// 事前条件として使うため、呼び出し側でthrowを判断する）。
    static func loadExportJob(_ connection: Database, exportID: ExportID) throws -> LoadedExportJob? {
        guard let row = try Row.fetchOne(
            connection,
            sql: "SELECT \(Self.exportJobColumns) FROM ExportJob WHERE exportID = ?",
            arguments: [exportID.rawValue]
        ) else {
            return nil
        }
        return LoadedExportJob(job: try Self.makeExportJob(row), settingsHash: row["settingsHash"])
    }

    /// 単一行であることをApplication層が保証する契約のテーブル（SubscriptionState /
    /// UsageLedger。Schema+Delivery.swift / Schema+Accounting.swiftのコメント参照）から
    /// 唯一行を読む。行が2件以上あれば契約違反としてfail-closedでthrowし、先頭行だけを
    /// 暗黙に使わない。行が無ければnilを返し、「行が無い場合」の意味づけ（新規作成と
    /// みなす／0件とみなす）は呼び出し元が決める。
    ///
    /// `table`はエラーメッセージ専用（運用者がどのテーブルを見ればよいか分かるようにする）。
    /// `sql`はコード内のリテラルのみを渡す前提で、呼び出し元の入力値をSQLへ組み立てる経路は
    /// 作らない。
    static func fetchSingletonRow(_ connection: Database, table: String, sql: String) throws -> Row? {
        let rows = try Row.fetchAll(connection, sql: sql)
        guard rows.count <= 1 else {
            throw ExportSagaStoreError.multipleSingletonRows(table: table, count: rows.count)
        }
        return rows.first
    }

    /// ExportJob行（loadExportJob / loadRunningJobsの両方のSELECT列と同じ形）をDomainの
    /// `ExportJob`へデコードする。
    static func makeExportJob(_ row: Row) throws -> ExportJob {
        let batchIDRaw: UUID? = row["batchID"]
        let queueItemIDRaw: UUID? = row["queueItemID"]
        return ExportJob(
            exportID: ExportID(rawValue: row["exportID"]),
            projectID: ProjectID(rawValue: row["projectID"]),
            batchID: batchIDRaw.map(BatchID.init(rawValue:)),
            queueItemID: queueItemIDRaw.map(ExportQueueItemID.init(rawValue:)),
            authorization: try Self.decodeAuthorization(row),
            delivery: try Self.decodeDelivery(row)
        )
    }

    /// plan/status列のペアをDomainのenumへデコードする共通ヘルパー。呼び出し元ごとに
    /// テーブル名・列名が異なる（ExportJob.entitlementPlan/Status、
    /// SubscriptionState.plan/status）ため引数で受け取る。
    static func decodePlanAndStatus(
        _ row: Row, table: String, planColumn: String, statusColumn: String
    ) throws -> (plan: Plan, status: PlanStatus) {
        let planRaw: Int = row[planColumn]
        let statusRaw: Int = row[statusColumn]
        guard let plan32 = UInt32(exactly: planRaw), let plan = Plan(rawValue: plan32) else {
            throw ExportSagaStoreError.invalidColumnValue(table: table, column: planColumn, rawValue: planRaw)
        }
        guard let status32 = UInt32(exactly: statusRaw), let status = PlanStatus(rawValue: status32) else {
            throw ExportSagaStoreError.invalidColumnValue(table: table, column: statusColumn, rawValue: statusRaw)
        }
        return (plan, status)
    }

    private static func decodeAuthorization(_ row: Row) throws -> ExportAuthorization {
        let accountingModeRaw: Int = row["accountingMode"]
        guard let accountingModeColumn = ExportAccountingModeColumn(rawValue: accountingModeRaw) else {
            throw ExportSagaStoreError.invalidColumnValue(
                table: "ExportJob", column: "accountingMode", rawValue: accountingModeRaw
            )
        }
        let (plan, status) = try Self.decodePlanAndStatus(
            row, table: "ExportJob", planColumn: "entitlementPlan", statusColumn: "entitlementStatus"
        )
        let entitlement = Entitlement(
            plan: plan,
            status: status,
            expiresAt: row["entitlementExpiresAt"],
            lastVerifiedAt: row["entitlementLastVerifiedAt"],
            isSandbox: row["entitlementIsSandbox"]
        )
        return ExportAuthorization(
            entitlementSnapshot: entitlement,
            accountingMode: accountingModeColumn.domainValue,
            authorizedAt: row["authorizedAt"]
        )
    }

    private static func decodeDelivery(_ row: Row) throws -> OutputDeliveryDescriptor {
        let formatRaw: Int = row["deliveryFormat"]
        guard let formatColumn = ImageFormatColumn(rawValue: formatRaw) else {
            throw ExportSagaStoreError.invalidColumnValue(
                table: "ExportJob", column: "deliveryFormat", rawValue: formatRaw
            )
        }
        return OutputDeliveryDescriptor(
            format: formatColumn.domainValue,
            suggestedCreationDate: row["deliverySuggestedCreationDate"]
        )
    }
}
