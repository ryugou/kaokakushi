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
// コメント参照）。expectedProjectRevisionの不一致は例外ではなく
// `ExportStartDecision.staleProjectRevision`という型付きの判定結果で返す（1.6手順5。
// ExportSagaStore.swiftのdocコメントが正）。
//
// 一括処理キュー簡素化 Issue #40 決定2（1.5「開始後に有料契約の失効・月間上限への到達・
// 昇格が起きても無視し、バッチ開始時の認可スナップショットで全項目を完了させる」）:
// バッチの認可はcreateBatch（+CreateBatch.swift）がBatch作成と同一トランザクションで
// 評価・固定する。startExportのバッチ経路はBatch行に固定済みの認可（loadBatchAuthorization）
// をそのまま読むだけで、resolveVerifiedCapabilities / resolveAccountingModeのfresh評価を
// 一切行わない（開始後の失効・昇格を無視するのはこの再評価をしないことで実現する）。
// Batch行が無ければbatchNotFoundをthrowする（createBatchが先に呼ばれている契約のため、
// 無ければ異常系。旧方式にあった「fresh評価へのフォールバック」は廃止した——discardExportで
// 参照元のExportJobが消えると再現できなくなる欠陥があったため）。単体書き出し
// （batchID == nil）は対象外で常にfresh評価する。

extension ExportSagaStoreLive {
    public func startExport(
        _ input: StartExportInput,
        expectedProjectRevision: Int64
    ) async throws -> ExportStartDecision {
        try Self.validatePreviewConfirmationProjectID(input)
        let authorizedAt = now()
        // 戻り値型を明示する（toolchain 差の推論割れ対策。Package.swift の GRDB ピン注記参照）
        let decision: ExportStartDecision = try await database.dbQueue.write { connection in
            guard try Self.projectRevisionMatches(
                connection, projectID: input.projectID, expectedProjectRevision: expectedProjectRevision
            ) else {
                return .staleProjectRevision
            }

            if let batchID = input.batchID {
                guard let authorization = try Self.loadBatchAuthorization(connection, batchID: batchID) else {
                    throw ExportSagaStoreError.batchNotFound(batchID: batchID)
                }
                let job = try Self.insertExportJob(
                    connection, input: input, entitlement: authorization.entitlementSnapshot,
                    accountingMode: authorization.accountingMode, authorizedAt: authorization.authorizedAt
                )
                return .authorized(job)
            }

            guard let (subscriptionState, capabilities) = try Self.resolveVerifiedCapabilities(
                connection, usageNow: authorizedAt, enabledStampPacks: enabledStampPacks
            ) else {
                return .blocked(ExportStartBlock(reason: .capabilityVerificationRequired, limit: nil))
            }

            let accountingContext = AccountingModeContext(
                capabilities: capabilities, monthlyLimit: monthlyLimit,
                usageNow: authorizedAt, deviceTimeZone: deviceTimeZone()
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
        return decision
    }

    /// Batch行に固定済みの認可を読む（1.5。createBatchが確定させた認可をそのまま使い、
    /// 再評価しない）。行が無ければnilを返し、呼び出し元がbatchNotFoundをthrowする
    /// （createBatchが先にBatch行を作っている契約のため、無ければ異常系として扱う。
    /// 旧方式〈同一batchIDの既存ExportJob行から認可を再利用し、無ければfresh評価へ
    /// フォールバックする〉はdiscardExportで参照元のExportJobが消えると再現できなくなる
    /// 欠陥があったため廃棄した）。デコードはdecodeAuthorization（+Mapping.swift）を
    /// ExportJob/Batch間で共有し、Entitlement再構成ロジックをこのファイルへ重複させない
    /// （列名はSchema+Queue.swiftでExportJobと完全一致させてある）。
    private static func loadBatchAuthorization(
        _ connection: Database, batchID: BatchID
    ) throws -> ExportAuthorization? {
        guard let row = try Row.fetchOne(
            connection,
            sql: """
            SELECT authorizedAt, accountingMode, entitlementPlan, entitlementStatus,
                entitlementExpiresAt, entitlementLastVerifiedAt, entitlementIsSandbox
            FROM Batch WHERE batchID = ?
            """,
            arguments: [batchID.rawValue]
        ) else {
            return nil
        }
        return try Self.decodeAuthorization(row, table: "Batch")
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

    /// Project行のprojectRevisionを読み、expectedProjectRevisionと一致するかを返す
    /// （1.6 手順5）。Project行自体が無ければprojectNotFoundをthrowする（Projectの不在は
    /// revision不一致とは別の異常系のためthrowのまま）。revision不一致自体は例外ではなく
    /// 戻り値のfalseとして表現し、呼び出し元が`ExportStartDecision.staleProjectRevision`
    /// という型付きの判定結果へ変換する（旧方式はここでthrowしていたが、正常に起こりうる
    /// 分岐をthrowで表現すると呼び出し元がdo/catchで判定を強いられるため、Domainの
    /// 契約変更〈ExportSagaStore.swift〉に合わせて戻り値化した）。
    private static func projectRevisionMatches(
        _ connection: Database, projectID: ProjectID, expectedProjectRevision: Int64
    ) throws -> Bool {
        guard let actual = try Int64.fetchOne(
            connection,
            sql: "SELECT projectRevision FROM Project WHERE projectID = ?",
            arguments: [projectID.rawValue]
        ) else {
            throw ExportSagaStoreError.projectNotFound(projectID: projectID)
        }
        return actual == expectedProjectRevision
    }

    /// SubscriptionStateの唯一行を読み、DomainのSubscriptionStateへデコードする。行が
    /// 無ければnilを返す（呼び出し元がSubscriptionCacheState.missingへ変換し、
    /// resolveCapabilitiesへ渡す。store側で「行が無い＝blocked」を決め打ちしない。
    /// `status == .pending`による特別扱いは廃止した。pendingかどうかの判定は
    /// resolveCapabilitiesが行う）。行が2件以上あれば契約違反としてthrowする（7番の修正。
    /// SubscriptionStateの単一行はDBの単一行キーで強制される契約であり、この検査は
    /// その二重担保）。
    private static func loadSubscriptionState(_ connection: Database) throws -> SubscriptionState? {
        guard let row = try Self.fetchSingletonRow(
            connection,
            table: "SubscriptionState",
            sql: """
            SELECT plan, status, expiresAt, lastVerifiedAt, isSandbox, willRenew, fetchedAt
            FROM SubscriptionState
            """
        ) else {
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
    /// 必要とするため、subscriptionState自体も併せて返す。createBatch
    /// （+CreateBatch.swift）も認可評価（1.3）の入口として同じロジックを再利用するため
    /// privateにしていない（他のstatic funcと同じ流儀。認可判定の重複実装を避ける）。
    static func resolveVerifiedCapabilities(
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
                exportID, projectID, batchID, authorizedAt, accountingMode,
                entitlementPlan, entitlementStatus, entitlementExpiresAt,
                entitlementLastVerifiedAt, entitlementIsSandbox, deliveryFormat,
                deliverySuggestedCreationDate, settingsHash
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                exportID.rawValue, input.projectID.rawValue, input.batchID?.rawValue,
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
            authorization: authorization,
            delivery: delivery
        )
    }
}
