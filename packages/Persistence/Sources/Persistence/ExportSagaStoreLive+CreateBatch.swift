import Foundation
import Domain
import GRDB

// createBatch（Domain/Ports/ExportSagaStore.swift docコメント・export-saga.md 1.3
// 「権限とクォータ」・1.5「バッチ開始時の認可スナップショットで全項目を完了させる」・
// architecture.md 6.4「バッチ処理」が正本。一括処理キュー簡素化 Issue #40 決定2）。
//
// バッチの認可評価（1.3）とBatch行への固定を、この関数の単一DBトランザクションで完結する。
// ここで確定した認可はBatch行へ書き込み、以降startExportのバッチ経路はこれを再評価せず
// そのまま読む（ExportSagaStoreLive+Start.swiftのloadBatchAuthorization）。これが1.5
// 「開始後の失効・昇格を無視する」の実現方法そのもの——再評価する経路自体が無い。
//
// 旧方式（同一batchIDの既存ExportJob行から認可を再利用する方式）はdiscardExportで
// 参照元のExportJobが消えると再現できなくなる欠陥があったため、この「Batch行に認可を
// 固定する」方式へ置き換えて廃棄した（Issue #40）。
//
// 認可評価ロジックはstartExport（単体経路）・createBatchで極力共有する:
//   - resolveVerifiedCapabilities（+Start.swift）: SubscriptionState行の読み取りと
//     ResolvedCapabilitiesへの解決。両者で完全に同じ処理のため共有する。
//   - resolveTrialAccountingMode（+Accounting.swift）: トライアル残クレジット判定。
//     startExportのバッチ経路（廃止済み）が呼んでいたものと同じ関数を再利用する。
// proBatchの`canUseProBatch`検査はcreateBatch専用（startExportの単体経路には存在しない
// 分岐のため共有ヘルパー化しない）。

extension ExportSagaStoreLive {
    /// バッチを作成する（レビュー指摘C-1・W-1対応: authorizedAtを評価時刻`now()`に統一する）。
    ///
    /// - 認可の評価（resolveVerifiedCapabilities・失効判定）とBatch行`authorizedAt`列の記録の
    ///   両方に、注入時計`now()`（`usageNow`）を使う。startExport（単体経路。+Start.swiftの
    ///   `let authorizedAt = now()`）と完全に同じ意味論——「authorizedAtは認可を評価した
    ///   時刻」——に揃える。評価と記録を分離する理由はない: 認可はこの関数が`now()`を
    ///   読んだ時点で確定するのであり、それ以外の時刻（呼び出し元が用意した作成時刻）を
    ///   「認可した時刻」として記録すると、障害調査で「いつ認可されたか」を追うときに
    ///   実際の評価時刻と乖離した値を見ることになる（運用時の追跡可能性を損なう）。
    /// - 旧実装は`input.createdAt`（呼び出し元が渡す作成時刻）をauthorizedAt列に記録して
    ///   いたが、この分離自体が問題の原因だったため撤回した。`CreateBatchInput.createdAt`は
    ///   この撤回により消費者が無くなったためDomainのフィールド自体を削除した
    ///   （Domain/Ports/ExportSagaStore.swift・docs/export-saga.md 0章）。
    /// - `now()`は書き込みトランザクションを開く前、この関数の呼び出し開始時点で1回だけ
    ///   読む。`database.dbQueue.write`が実際にトランザクションを開始した時点ではない。
    ///   そのため、DBキューが混雑して書き込み開始まで待機している間にentitlementが失効
    ///   すると、失効直前の`usageNow`で評価された認可がBatch行へ固定され得る（codexレビュー
    ///   指摘）。これはexport-saga.md 1.5「開始後に有料契約の失効・月間上限への到達・昇格が
    ///   起きても無視し、バッチ開始時の認可スナップショットで全項目を完了させる」が既に
    ///   明示的に受容している範囲の内側である——バッチは作成後の失効を無視して全項目を
    ///   完走する仕様であり、その許容時間はバッチ全体の実行時間（分〜時間の規模）に及ぶ。
    ///   DBキュー待機（ミリ秒〜秒の規模）はそれより桁違いに小さく、新たな損失区分を生まない。
    ///
    /// 冪等性の注意: 同一batchIDでの再呼び出しは冪等ではない。BatchのbatchIDはDB側の
    /// 主キー（Schema+Queue.swift）のため、既存のbatchIDへ再度createBatchを呼ぶと
    /// このINSERTがGRDBの`DatabaseError`（主キー制約違反）をthrowする。二重作成が
    /// 静かに成功することはない。
    public func createBatch(_ input: CreateBatchInput) async throws -> BatchCreateDecision {
        let usageNow = now()
        // 戻り値型を明示する（toolchain 差の推論割れ対策。Package.swift の GRDB ピン注記参照）
        let decision: BatchCreateDecision = try await database.dbQueue.write { connection in
            guard let (subscriptionState, capabilities) = try Self.resolveVerifiedCapabilities(
                connection, usageNow: usageNow, enabledStampPacks: enabledStampPacks
            ) else {
                return .blocked(ExportStartBlock(reason: .capabilityVerificationRequired, limit: nil))
            }

            switch try Self.resolveBatchAccountingMode(
                connection, kind: input.policy.kind, capabilities: capabilities,
                trialCreditCount: input.policy.trialCreditCount, hardMaxTrialCredits: hardMaxTrialCredits
            ) {
            case .blocked(let block):
                return .blocked(block)
            case .resolved(let accountingMode):
                // authorizedAtは認可評価に使ったusageNowをそのまま使う（startExportの
                // 単体経路と同じ意味論。関数doc参照）。
                let authorization = ExportAuthorization(
                    entitlementSnapshot: subscriptionState.entitlement,
                    accountingMode: accountingMode,
                    authorizedAt: usageNow
                )
                try Self.insertBatch(connection, input: input, authorization: authorization)
                return .created(authorization)
            }
        }
        return decision
    }

    /// バッチの勘定判定（1.3「権限とクォータ」・1.4「勘定の使い分け」）。単体書き出しの
    /// resolveAccountingMode（+Accounting.swift）と対になる、バッチ専用の判定入口。
    private static func resolveBatchAccountingMode(
        _ connection: Database, kind: BatchKind, capabilities: ResolvedCapabilities,
        trialCreditCount: Int32, hardMaxTrialCredits: Int
    ) throws -> AccountingModeDecision {
        switch kind {
        case .proBatch:
            // 開始時点でcanUseProBatchを持たない利用者はブロックする（proBatch自体が
            // entitlementの能力に依存するため）。
            guard capabilities.canUseProBatch else {
                return .blocked(ExportStartBlock(reason: .capabilityVerificationRequired, limit: nil))
            }
            return .resolved(.paidUnlimited)
        case .trial:
            // architecture.md 6.3「Pro へ加入済みの場合は消費しない」。作成時点で
            // canUseProBatchを持つ利用者はトライアルクレジットの残数に関わらず消費せず
            // paidUnlimitedで認可する（アップグレード後もバッチを中断させないため）。
            guard !capabilities.canUseProBatch else {
                return .resolved(.paidUnlimited)
            }
            return try Self.resolveTrialAccountingMode(
                connection, trialCreditCount: trialCreditCount, hardMaxTrialCredits: hardMaxTrialCredits
            )
        }
    }

    /// Batch行へ、確定した構造的パラメータ（policy由来の4列）と認可（7列）をまとめて
    /// INSERTする。blockedの場合はこの関数自体が呼ばれない（createBatch本体のswitch文
    /// 参照）ため、「Batch行が存在する ⇒ 認可は既に固定済み」という契約が保たれる。
    ///
    /// 構造的パラメータ（policy由来の4列）の検証責任について:
    /// - `batchSizeLimit`・`concurrencyLimit`はこの関数で値域検査せず、渡された値を
    ///   そのまま保存する。この2列は認可・勘定のどちらの判定にも使われない
    ///   （resolveBatchAccountingModeが見るのは`kind`と`trialCreditCount`だけ）。
    ///   Domainの`BatchPolicySnapshot`（Queue/BatchPolicySnapshot.swift）のコメント
    ///   どおり、作成時の設定定数から作る値であるため信頼している。
    /// - 対照的に`trialCreditCount`は勘定判定に使われるため、使用時点で
    ///   `hardMaxTrialCredits`によるクランプで防御している（resolveTrialAccountingMode、
    ///   +Accounting.swift）。この非対称は意図的であり、「DB由来の値を無条件に信頼
    ///   しない」防御は勘定に影響する列にだけ適用している。
    /// - したがって、これらの列を読んでキュー実行（並列度・件数上限）に使う将来の
    ///   実装側は、0や負値を含む異常値に対する防御を自身で行う必要がある。スキーマ
    ///   （Schema+Queue.swift）にもCHECK制約は無い。
    private static func insertBatch(
        _ connection: Database, input: CreateBatchInput, authorization: ExportAuthorization
    ) throws {
        try connection.execute(
            sql: """
            INSERT INTO Batch (
                batchID, kind, batchSizeLimit, trialCreditCount, concurrencyLimit,
                authorizedAt, accountingMode, entitlementPlan, entitlementStatus,
                entitlementExpiresAt, entitlementLastVerifiedAt, entitlementIsSandbox
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                input.batchID.rawValue, input.policy.kind.rawValue, input.policy.batchSizeLimit,
                input.policy.trialCreditCount, input.policy.concurrencyLimit,
                authorization.authorizedAt, ExportAccountingModeColumn(authorization.accountingMode).rawValue,
                authorization.entitlementSnapshot.plan.rawValue, authorization.entitlementSnapshot.status.rawValue,
                authorization.entitlementSnapshot.expiresAt, authorization.entitlementSnapshot.lastVerifiedAt,
                authorization.entitlementSnapshot.isSandbox
            ]
        )
    }
}
