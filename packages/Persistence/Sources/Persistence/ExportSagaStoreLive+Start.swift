import Foundation
import Domain
import GRDB

// startExport（export-saga.md 1章「認可」・1.6「開始の順序」手順4〜5、0章
// StartExportInputが正本）。
//
// 評価スコープはオーケストレーター確定判断のとおり「時刻に依存しない部分だけをDBの実状態
// から評価する」に限定する。1.1（確認の一致）・1.2（能力）の検査はApplication層の担当
// （RenderSpec/PreviewConfirmationの純粋関数評価はPersistenceの対象外）。ただし
// previewConfirmation.projectIDとinput.projectIDの整合だけはstore側のゲートとして検査する
// （7番の修正。異なるプロジェクトのプレビュー確認情報を誤って渡すバグをここで止める）。
// 1.3（権限とクォータ）のうち月間枠チェックはコンストラクタ注入のmonthlyLimit /
// deviceTimeZoneとauthorizedAt（usageNow）をAccountingModeContext経由で+Accounting.swiftへ
// 渡し、Domainのevaluate関数（evaluateMonthlyQuota）で評価する（+Accounting.swiftの
// コメント参照）。

extension ExportSagaStoreLive {
    public func startExport(
        _ input: StartExportInput,
        expectedProjectRevision: Int64
    ) async throws -> ExportStartDecision {
        try Self.validatePreviewConfirmationProjectID(input)
        try Self.validateQueueItemRequiresBatchID(input)
        let authorizedAt = now()
        return try await database.dbQueue.write { connection in
            try Self.validateProjectRevision(
                connection, projectID: input.projectID, expectedProjectRevision: expectedProjectRevision
            )

            guard let (subscriptionState, capabilities) = try Self.resolveVerifiedCapabilities(
                connection, usageNow: authorizedAt, enabledStampPacks: enabledStampPacks
            ) else {
                return .blocked(ExportStartBlock(reason: .capabilityVerificationRequired, limit: nil))
            }

            let accountingContext = AccountingModeContext(
                input: input, capabilities: capabilities, hardMaxTrialCredits: hardMaxTrialCredits,
                monthlyLimit: monthlyLimit, usageNow: authorizedAt, deviceTimeZone: deviceTimeZone()
            )
            switch try Self.resolveAccountingMode(connection, context: accountingContext) {
            case .blocked(let block):
                return .blocked(block)
            case .resolved(let accountingMode):
                let job = try Self.insertExportJob(
                    connection, input: input, entitlement: subscriptionState.entitlement,
                    accountingMode: accountingMode, authorizedAt: authorizedAt
                )
                return .authorized(job)
            }
        }
    }

    /// previewConfirmation.projectIDがinput.projectIDと一致することを検査する（1.1
    /// 確認の一致・7番の修正）。DBアクセスを伴わない純粋な入力検査のため、書き込み
    /// トランザクションを開く前に行う。
    private static func validatePreviewConfirmationProjectID(_ input: StartExportInput) throws {
        guard input.previewConfirmation.projectID == input.projectID else {
            throw ExportSagaStoreError.previewConfirmationProjectMismatch(
                projectID: input.projectID, previewConfirmationProjectID: input.previewConfirmation.projectID
            )
        }
    }

    /// queueItemIDが指定される場合はbatchIDも必須であることを検査する。DBアクセスを
    /// 伴わない純粋な入力検査のため、書き込みトランザクションを開く前に行う。
    private static func validateQueueItemRequiresBatchID(_ input: StartExportInput) throws {
        guard let queueItemID = input.queueItemID, input.batchID == nil else { return }
        throw ExportSagaStoreError.queueItemIDRequiresBatchID(queueItemID: queueItemID)
    }

    /// Project行のprojectRevisionを読み、expectedProjectRevisionと比較する（1.6 手順5）。
    /// 行が無い、または不一致ならthrowしExportJobを作らない。
    private static func validateProjectRevision(
        _ connection: Database, projectID: ProjectID, expectedProjectRevision: Int64
    ) throws {
        guard let actual = try Int64.fetchOne(
            connection,
            sql: "SELECT projectRevision FROM Project WHERE projectID = ?",
            arguments: [projectID.rawValue]
        ) else {
            throw ExportSagaStoreError.projectNotFound(projectID: projectID)
        }
        guard actual == expectedProjectRevision else {
            throw ExportSagaStoreError.projectRevisionMismatch(
                projectID: projectID, expected: expectedProjectRevision, actual: actual
            )
        }
    }

    /// SubscriptionStateの唯一行を読み、DomainのSubscriptionStateへデコードする。行が
    /// 無ければnilを返す（呼び出し元がSubscriptionCacheState.missingへ変換し、
    /// resolveCapabilitiesへ渡す。store側で「行が無い＝blocked」を決め打ちしない。
    /// `status == .pending`による特別扱いは廃止した。pendingかどうかの判定は
    /// resolveCapabilitiesが行う）。行が2件以上あれば契約違反としてthrowする（7番の修正。
    /// SubscriptionStateは単一行であることをApplication層が保証する契約）。
    private static func loadSubscriptionState(_ connection: Database) throws -> SubscriptionState? {
        let rows = try Row.fetchAll(
            connection,
            sql: """
            SELECT plan, status, expiresAt, lastVerifiedAt, isSandbox, willRenew, fetchedAt
            FROM SubscriptionState
            """
        )
        guard rows.count <= 1 else {
            throw ExportSagaStoreError.multipleSingletonRows(table: "SubscriptionState", count: rows.count)
        }
        guard let row = rows.first else {
            return nil
        }
        let (plan, status) = try Self.decodePlanAndStatus(
            row, table: "SubscriptionState", planColumn: "plan", statusColumn: "status"
        )
        let entitlement = Entitlement(
            plan: plan,
            status: status,
            expiresAt: row["expiresAt"],
            lastVerifiedAt: row["lastVerifiedAt"],
            isSandbox: row["isSandbox"]
        )
        return SubscriptionState(entitlement: entitlement, willRenew: row["willRenew"], fetchedAt: row["fetchedAt"])
    }

    /// SubscriptionStateの行有無をSubscriptionCacheState（行が無ければ`.missing`、
    /// あれば`.loaded`）に変換し、resolveCapabilitiesへ一度だけ委譲する（Warning対応:
    /// 「行が無い場合」の解決規則をstore側で早期returnとして重複実装しない。
    /// resolveCapabilities(.missing, ...)は既に`.verificationRequired`としてこの
    /// セマンティクスを表現しているため、将来Domain側でこの規則が変わっても、
    /// ここが自動的に追従する）。
    ///
    /// resolveCapabilitiesが`.resolved(...)`を返すのは`.loaded`ケースのみのはずだが
    /// （Domain側実装済み）、契約を過信せず、`.verificationRequired`が返った場合は
    /// nilを返し、呼び出し元でcapabilityVerificationRequiredのblockedへ倒す
    /// （防御的プログラミング）。insertExportJobがentitlementの生スナップショットを
    /// 必要とするため、subscriptionState自体も併せて返す。
    private static func resolveVerifiedCapabilities(
        _ connection: Database, usageNow: Date, enabledStampPacks: Set<String>
    ) throws -> (subscriptionState: SubscriptionState, capabilities: ResolvedCapabilities)? {
        let subscriptionState = try Self.loadSubscriptionState(connection)
        let cacheState: SubscriptionCacheState = subscriptionState.map { .loaded($0) } ?? .missing
        guard case .resolved(let capabilities) = resolveCapabilities(
            cacheState, usageNow: usageNow, enabledStampPacks: enabledStampPacks
        ) else {
            return nil
        }
        guard let subscriptionState else {
            // resolveCapabilitiesの契約上、cacheStateが.missingなら常に
            // .verificationRequiredが返るためここには到達しないはずだが、
            // 契約が変わってもfail-closedでblockedへ倒れるよう防御しておく。
            return nil
        }
        return (subscriptionState, capabilities)
    }

    /// 認可されたExportJob行を挿入する。exportIDはここで新規発行する（Domainのポートに
    /// 生成方法の指定が無いため。オーケストレーター確定判断）。`delivery.
    /// suggestedCreationDate`はExportSettingに相当する値が無いためnil固定
    /// （同確定判断）。entitlementはSubscriptionState行から読んだ生の値（resolveCapabilities
    /// を通す前の値）をそのまま保存する（認可時点のスナップショット契約。1番の修正）。
    ///
    /// settingsHash列（Schema+Accounting.swift）はここで計算する。settle
    /// （export-saga.md 3章 手順5「confirmed設定エントリの更新」）はRenderSpec/
    /// ExportSettingを再構築する手段を持たないため、平文値が手元にあるstartExport時点で
    /// projectSettingsHash（Domain純粋関数）を計算し内部列として保持する
    /// （オーケストレーター確定判断。Domainの`ExportJob`構造体には出現しない）。
    private static func insertExportJob(
        _ connection: Database,
        input: StartExportInput,
        entitlement: Entitlement,
        accountingMode: ExportAccountingMode,
        authorizedAt: Date
    ) throws -> ExportJob {
        let exportID = ExportID(rawValue: UUID())
        let delivery = OutputDeliveryDescriptor(format: input.exportSetting.outputFormat, suggestedCreationDate: nil)
        let authorization = ExportAuthorization(
            entitlementSnapshot: entitlement, accountingMode: accountingMode, authorizedAt: authorizedAt
        )
        let settingsHash = try projectSettingsHash(
            renderSpec: input.renderSpec, exportSetting: input.exportSetting, digest: CryptoKitSha256Digest()
        )

        try connection.execute(
            sql: """
            INSERT INTO ExportJob (
                exportID, projectID, batchID, queueItemID, authorizedAt, accountingMode,
                entitlementPlan, entitlementStatus, entitlementExpiresAt,
                entitlementLastVerifiedAt, entitlementIsSandbox, deliveryFormat,
                deliverySuggestedCreationDate, settingsHash
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                exportID.rawValue, input.projectID.rawValue, input.batchID?.rawValue, input.queueItemID?.rawValue,
                authorizedAt, ExportAccountingModeColumn(accountingMode).rawValue,
                entitlement.plan.rawValue, entitlement.status.rawValue, entitlement.expiresAt,
                entitlement.lastVerifiedAt, entitlement.isSandbox,
                ImageFormatColumn(delivery.format).rawValue, delivery.suggestedCreationDate, settingsHash.bytes
            ]
        )

        return ExportJob(
            exportID: exportID,
            projectID: input.projectID,
            batchID: input.batchID,
            queueItemID: input.queueItemID,
            authorization: authorization,
            delivery: delivery
        )
    }
}
