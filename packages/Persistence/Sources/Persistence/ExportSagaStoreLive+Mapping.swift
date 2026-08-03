import Foundation
import Domain
import GRDB

// ExportJob行の共通デコード（export-saga.md 2章「ExportJobとOutputRecord」が正本）。
// recordGeneratedOutput（+Output.swift）とloadRunningJobs（+Recovery.swift）の両方が
// 同じ行形状を読むため、ここに集約する。`decodePlanAndStatus`はExportJob行
// （entitlementPlan/entitlementStatus）とSubscriptionState行（plan/status）の両方
// （+Start.swift）から列名だけ変えて共有する。

extension ExportSagaStoreLive {
    /// exportIDに対応するExportJob行を読み、Domainの`ExportJob`へデコードする。
    /// 行が無ければnilを返す（recordGeneratedOutput / settle系が「行の存在」を
    /// 事前条件として使うため、呼び出し側でthrowを判断する）。
    static func loadExportJob(_ connection: Database, exportID: ExportID) throws -> ExportJob? {
        guard let row = try Row.fetchOne(
            connection,
            sql: """
            SELECT exportID, projectID, batchID, queueItemID, authorizedAt, accountingMode,
                entitlementPlan, entitlementStatus, entitlementExpiresAt,
                entitlementLastVerifiedAt, entitlementIsSandbox, deliveryFormat,
                deliverySuggestedCreationDate
            FROM ExportJob WHERE exportID = ?
            """,
            arguments: [exportID.rawValue]
        ) else {
            return nil
        }
        return try Self.makeExportJob(row)
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
