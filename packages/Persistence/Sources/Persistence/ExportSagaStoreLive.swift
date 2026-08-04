import Foundation
import Domain
import GRDB

// ExportSagaStoreの実装（export-saga.md 0章「Application が使う永続化ポート」・
// 2章「ExportJobとOutputRecord」・3章「手順」・4章「中断・やり直し・破棄」・
// 5章「起動時復旧」が正本。Issue #6 Task 5）。
//
// 全7メソッド（startExport / recordGeneratedOutput / discardExport / settleExport /
// settleBatch / loadRunningJobs / deleteRunningJobs）を実装する。
//
// `ExportSagaStore` のポートシグネチャには時刻引数が無いが、ExportJob.authorization.
// authorizedAt / OutputRecord.generatedAt / settledAt には実行時点の時刻が必要なため、
// 実装側だけの依存注入として `now: @escaping @Sendable () -> Date` をinitへ追加する
// （Domainのプロトコル自体は変更しない。オーケストレーター確定判断）。同様に月間枠判定
// （evaluateMonthlyQuota）が要求する端末タイムゾーンも `deviceTimeZone: @escaping
// @Sendable () -> TimeZone` として注入する（裸のTimeZone.currentを直接使わない。
// オーケストレーター確定判断）。
//
// export-saga.md 3章の手順表にある「Projectの最終更新時刻の更新」は実装対象に含めない。
// architecture.md 7.1のProjectテーブル定義（Schema+Project.swift）にこれに対応する列が
// 存在せず、`ExportSagaStore`プロトコルのdocコメント（Domain側、確定済みで変更不可）にも
// この文言が登場しないため（オーケストレーター確定判断。列が存在せず実装不能）。
//
// 400行制限のため、メソッド群を以下へ分割する（StampStoreLiveの分割パターンを踏襲）:
//   - ExportSagaStoreLive.swift（このファイル）: 型定義・エラー型・raw value割当・
//     struct定義・init
//   - ExportSagaStoreLive+Mapping.swift: ExportJob行の共通デコード（loadExportJob /
//     makeExportJob）とraw value変換の共通ヘルパー
//   - ExportSagaStoreLive+Start.swift: startExport
//   - ExportSagaStoreLive+Accounting.swift: startExportが使う勘定（accountingMode）の
//     解決ロジック（月間枠判定を含む）
//   - ExportSagaStoreLive+Output.swift: recordGeneratedOutput / discardExport
//   - ExportSagaStoreLive+Settle.swift: settleExport / settleBatch
//   - ExportSagaStoreLive+Ledger.swift: UsageLedgerの読み書き・BLOBエンコード/デコード
//   - ExportSagaStoreLive+SettingsHash.swift: ProjectSettingsHash計算用CryptoKitアダプタ
//   - ExportSagaStoreLive+Recovery.swift: loadRunningJobs / deleteRunningJobs

/// ExportSagaStoreLiveが送出する専用エラー。運用者が次のアクションを判断できるよう、
/// 契約違反の詳細を持つ（WorkingSourceStoreError/MaintenanceStoreErrorと同じ方針:
/// Sendable, Equatable, LocalizedError）。
public enum ExportSagaStoreError: Error, Sendable, Equatable {
    /// startExport: expectedProjectRevisionと比較する対象のProject行が存在しない。
    case projectNotFound(projectID: ProjectID)
    /// startExport: expectedProjectRevisionが実際のprojectRevisionと一致しない
    /// （export-saga.md 1.6 手順5。開始前にプロジェクトが変更された）。
    case projectRevisionMismatch(projectID: ProjectID, expected: Int64, actual: Int64)
    /// startExport: input.batchIDに対応するBatch行が存在しない。
    case batchNotFound(batchID: BatchID)
    /// recordGeneratedOutput: 対象のExportJob行が存在しない（手順0が完了していない
    /// exportIDが渡された）。
    case exportJobNotFound(exportID: ExportID)
    /// recordGeneratedOutput: OutputRecordのINSERTが部分UNIQUE制約違反
    /// （SQLITE_CONSTRAINT_UNIQUE。同一projectIDに未確定のOutputRecordが既に存在する。
    /// 3章）で失敗した。GRDBのDatabaseError.extendedResultCodeで確定的に判定した結果
    /// であり、他のDBエラーはrecordOutputInsertUnexpectedFailureで区別する。
    case recordGeneratedOutputInsertFailed(exportID: ExportID, projectID: ProjectID, underlyingMessage: String)
    /// recordGeneratedOutput: OutputRecordのINSERTが部分UNIQUE制約違反以外の
    /// DatabaseErrorで失敗した（ディスク書き込み失敗、スキーマ不整合等）。原因が
    /// 異なるため recordGeneratedOutputInsertFailed とは区別して報告する（握りつぶさない）。
    case recordOutputInsertUnexpectedFailure(
        exportID: ExportID, projectID: ProjectID, underlyingMessage: String
    )
    /// SubscriptionState.plan/.status、ExportJob.entitlementPlan/.entitlementStatus、
    /// Batch.kind、ExportJob.accountingMode/.deliveryFormatのいずれかのraw valueが
    /// Domainのenumのどのcaseにも対応しない（スキーマ移行漏れ、または手動でのDB改変が
    /// 疑われる）。
    case invalidColumnValue(table: String, column: String, rawValue: Int)
    /// UsageLedger.trialConsumedExportIDsのBLOB長が16の倍数でない、または16バイト単位に
    /// 分割した際に重複するチャンクが存在する（想定エンコード〈重複の無いユニークな
    /// ExportIDの集合を、UUIDの16バイト表現のまま連結したもの〉との不整合。データ破損、
    /// 別方式での書き込み、または同一ExportIDの二重書き込みを疑う）。このBLOBはユニーク
    /// なExportIDの集合であり重複を許さない契約。後半セッションのsettleBatchがこのBLOBへ
    /// 書き込む際もこの一意性契約を維持すること。
    case corruptUsageLedgerBlob(byteCount: Int)
    /// SubscriptionState / UsageLedgerの単一行はDBの単一行キー（id INTEGER PRIMARY KEY
    /// CHECK(id = 1)。Schema+Delivery.swift / Schema+Accounting.swift）で強制される。
    /// fetchSingletonRowの複数行検査はこれに対する二重担保であり、行が2件以上あれば
    /// 契約違反としてfail-closedでthrowする（先頭行だけを暗黙に使わない）。
    case multipleSingletonRows(table: String, count: Int)
    /// startExport: input.previewConfirmation.projectIDがinput.projectIDと一致しない
    /// （1.1 確認の一致。異なるプロジェクトのプレビュー確認情報が渡された可能性がある）。
    case previewConfirmationProjectMismatch(projectID: ProjectID, previewConfirmationProjectID: ProjectID)
    /// startExport: input.queueItemIDが指定されているのにinput.batchIDがnil。
    /// ExportQueueItem.batchIDはNOT NULL制約（Schema+Queue.swift）のため、queueItemIDを
    /// 伴うジョブは必ずbatchIDも持つ必要がある。ここで防がないと、settle時に
    /// validateQueueItemForSettleが必ず事前条件不一致でthrowするだけの、確定不能な
    /// ExportJobが残ってしまう。
    case queueItemIDRequiresBatchID(queueItemID: ExportQueueItemID)
    /// settleExport / settleBatch: 対象exportIDのExportJob行が存在しない（settleExportが
    /// 未認可のexportIDに呼ばれた、または既にsettle済み・discardExport/起動時復旧で
    /// 削除済みのexportIDへ再度settleが呼ばれた）。exportJobNotFound（recordGeneratedOutput
    /// 用）とはメッセージの文脈が異なるため専用caseにする。
    case settleExportJobNotFound(exportID: ExportID)
    /// settleExport: 渡されたexportIDのExportJob.batchIDがnilでない（settleExportは単体
    /// 書き出し専用。バッチの成果物はsettleBatchでのみ確定する。export-saga.md 3章）。
    case settleExportBatchIDNotNil(exportID: ExportID, batchID: BatchID)
    /// settleBatch: OutputRecord.batchIDが対象batchIDと一致するexportIDなのに、対応する
    /// ExportJob.batchIDが対象batchIDと一致しない（データ不整合。通常のAPI経路では
    /// OutputRecord.batchIDはrecordGeneratedOutputがExportJob.batchIDからコピーするため
    /// 一致するはずだが、その前提が崩れていないかをここで確定的に検査する）。
    case settleBatchJobBatchIDMismatch(exportID: ExportID, expectedBatchID: BatchID, actualBatchID: BatchID?)
    /// settleExport / settleBatch: 対象exportIDに対応するOutputRecordが存在しない、または
    /// 存在してもsettledAtが既に非NULL（確定対象は`settledAt IS NULL`の行のみ。3章）。
    case settlePendingOutputRecordNotFound(exportID: ExportID)
    /// settleExport / settleBatch: ExportJob.queueItemIDが指定されているのに、対応する
    /// ExportQueueItem行が存在しない、projectID/batchIDが一致しない、またはstateが
    /// `.exporting`でない（無関係なキュー項目をcompletedにしないための事前条件。3章）。
    case settleQueueItemPreconditionFailed(exportID: ExportID, queueItemID: ExportQueueItemID, detail: String)
    /// settleExport / settleBatch: accountingModeから期待される消費件数
    /// （paidUnlimited=0、freeMonthlyConsume/batchTrialは1件）の合計と、実際にUsageLedgerへ
    /// 新規追加できた件数が一致しない（数え間違いによる過不足消費を防ぐ検査。exportIDの
    /// 重複追加や想定外の状態を疑う。3章「ただし消費するクレジット・枠の枚数は…件数と
    /// 必ず一致することを検査する」）。
    case settleConsumptionMismatch(exportIDs: [ExportID], expectedConsumed: Int, actualConsumed: Int)
    /// settleBatch: 対象batchIDに一致しsettledAt IS NULLであるOutputRecordが0件（不明な
    /// batchID、または確定済みバッチを含む）。settleExportの二重確定防止
    /// （settleExportBatchIDNotNil等）と対称の安全弁。静かな成功は誤batchIDや二重呼び出しを
    /// 隠すため、明示的にthrowする（export-saga.md 3章）。
    case settleBatchNothingToSettle(batchID: BatchID)
}

extension ExportSagaStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .projectNotFound(let projectID):
            return """
            ExportSagaStore: startExportに渡されたprojectID=\(projectID.rawValue.uuidString) の \
            Project行が見つかりません。呼び出し元がProjectを作成する前にstartExportを \
            呼んでいないか確認してください。
            """
        case .projectRevisionMismatch(let projectID, let expected, let actual):
            return """
            ExportSagaStore: projectID=\(projectID.rawValue.uuidString) のprojectRevisionが \
            期待値と一致しません（期待値=\(expected), 実際の値=\(actual)）。書き出し開始前に \
            プロジェクトの設定が変更された可能性があります。呼び出し元は最新のプレビュー \
            確認からやり直してください（export-saga.md 1.6）。
            """
        case .batchNotFound(let batchID):
            return """
            ExportSagaStore: startExportに渡されたbatchID=\(batchID.rawValue.uuidString) の \
            Batch行が見つかりません。バッチが既に削除されていないか確認してください。
            """
        case .exportJobNotFound(let exportID):
            return """
            ExportSagaStore: recordGeneratedOutputに渡されたexportID=\
            \(exportID.rawValue.uuidString) のExportJob行が見つかりません。startExportが \
            成功していない、またはdiscardExport/settle系で既に削除されたexportIDが渡され \
            ていないか確認してください。
            """
        case .recordGeneratedOutputInsertFailed(let exportID, let projectID, let underlyingMessage):
            return """
            ExportSagaStore: recordGeneratedOutput（exportID=\(exportID.rawValue.uuidString), \
            projectID=\(projectID.rawValue.uuidString)）のOutputRecord挿入が部分UNIQUE制約 \
            違反で失敗しました。同一projectIDに未確定のOutputRecordが既に存在します \
            （export-saga.md 3章）。詳細: \(underlyingMessage)
            """
        case .recordOutputInsertUnexpectedFailure(let exportID, let projectID, let underlyingMessage):
            return """
            ExportSagaStore: recordGeneratedOutput（exportID=\(exportID.rawValue.uuidString), \
            projectID=\(projectID.rawValue.uuidString)）のOutputRecord挿入が部分UNIQUE制約 \
            違反以外のDBエラーで失敗しました。ディスク書き込み失敗やスキーマ不整合の \
            可能性があります。詳細: \(underlyingMessage)
            """
        case .invalidColumnValue(let table, let column, let rawValue):
            return """
            ExportSagaStore: \(table).\(column) の値 \(rawValue) はDomainのenumのどの \
            caseにも対応しません。スキーマとDomainのenum定義が不整合になっている可能性が \
            あります（マイグレーション漏れ、または手動でのDB改変を疑ってください）。
            """
        case .corruptUsageLedgerBlob(let byteCount):
            return """
            ExportSagaStore: UsageLedger.trialConsumedExportIDs（バイト長 \(byteCount)）が \
            壊れています。想定エンコード（重複の無いユニークなExportIDを16バイトずつ連結 \
            したBLOB）と一致しません（長さが16の倍数でない、または重複するExportIDの \
            チャンクが含まれています）。UsageLedger行が壊れているか、想定と異なる形式で \
            書き込まれています。
            """
        case .multipleSingletonRows(let table, let count):
            return """
            ExportSagaStore: \(table) は単一行であることが契約ですが、実際には \(count) \
            行存在します。DBの単一行キー（id INTEGER PRIMARY KEY CHECK(id = 1)）が \
            迂回されています（マイグレーション不備や手動でのDB改変を疑ってください）。
            """
        case .previewConfirmationProjectMismatch(let projectID, let previewConfirmationProjectID):
            return """
            ExportSagaStore: startExportに渡されたprojectID=\(projectID.rawValue.uuidString) と \
            previewConfirmation.projectID=\(previewConfirmationProjectID.rawValue.uuidString) が \
            一致しません。呼び出し元が別プロジェクトのプレビュー確認情報を渡していないか \
            確認してください（export-saga.md 1.1）。
            """
        case .queueItemIDRequiresBatchID(let queueItemID):
            return """
            ExportSagaStore: startExportに渡されたqueueItemID=\
            \(queueItemID.rawValue.uuidString) がありますが、batchIDがnilです。 \
            ExportQueueItem.batchIDはNOT NULL制約のため、queueItemIDを伴う書き出しには \
            batchIDも必須です。呼び出し元がキュー経路の書き出しでbatchIDを渡し忘れていないか \
            確認してください。
            """
        case .settleExportJobNotFound(let exportID):
            return """
            ExportSagaStore: settleExport/settleBatchに渡されたexportID=\
            \(exportID.rawValue.uuidString) のExportJob行が見つかりません。既にsettle済み・ \
            discardExportで破棄済み・起動時復旧で削除済みのexportIDを再度渡していないか、 \
            またはstartExportが成功していないexportIDを渡していないか確認してください。
            """
        case .settleExportBatchIDNotNil(let exportID, let batchID):
            return """
            ExportSagaStore: settleExportにexportID=\(exportID.rawValue.uuidString) が \
            渡されましたが、対応するExportJob.batchID=\(batchID.rawValue.uuidString) が \
            nilではありません。settleExportは単体書き出し専用です。バッチの成果物は \
            settleBatch(_:settledAt:)で確定してください（export-saga.md 3章）。
            """
        case .settleBatchJobBatchIDMismatch(let exportID, let expectedBatchID, let actualBatchID):
            return """
            ExportSagaStore: settleBatch(batchID=\(expectedBatchID.rawValue.uuidString))の \
            確定対象exportID=\(exportID.rawValue.uuidString) に対応するExportJob.batchIDが \
            期待値と一致しません（実際の値: \
            \(actualBatchID?.rawValue.uuidString ?? "nil")）。OutputRecord.batchIDと \
            ExportJob.batchIDの不整合が疑われます。データ破損、または手動でのDB改変を \
            確認してください。
            """
        case .settlePendingOutputRecordNotFound(let exportID):
            return """
            ExportSagaStore: settleExport/settleBatchに渡されたexportID=\
            \(exportID.rawValue.uuidString) に対応する未確定（settledAt IS NULL）の \
            OutputRecordが見つかりません。recordGeneratedOutputがまだ呼ばれていない、 \
            または既にこのexportIDが確定済みである可能性があります。呼び出し元の書き出し \
            パイプラインの進行順序を確認してください。
            """
        case .settleQueueItemPreconditionFailed(let exportID, let queueItemID, let detail):
            return """
            ExportSagaStore: settleExport/settleBatch（exportID=\
            \(exportID.rawValue.uuidString), queueItemID=\(queueItemID.rawValue.uuidString)）の \
            キュー項目の事前条件チェックに失敗しました: \(detail)。無関係なキュー項目を \
            completedへ更新しないための防御です。ExportQueueItemの状態遷移を管理する \
            呼び出し元の実装を確認してください。
            """
        case .settleConsumptionMismatch(let exportIDs, let expectedConsumed, let actualConsumed):
            return """
            ExportSagaStore: settle対象exportID群（\(exportIDs.count)件）の期待消費件数 \
            （\(expectedConsumed)）と、実際にUsageLedgerへ新規追加できた件数 \
            （\(actualConsumed)）が一致しません。exportIDの重複追加や、想定外の \
            accountingModeの混在が疑われます。UsageLedger行の内容を確認してください。 \
            このトランザクションはロールバックされ、台帳・OutputRecord・ExportJobは \
            いずれも変更されていません。
            """
        case .settleBatchNothingToSettle(let batchID):
            return """
            ExportSagaStore: settleBatch(batchID=\(batchID.rawValue.uuidString)) の確定対象 \
            （settledAt IS NULLのOutputRecord）が0件です。batchIDの指定間違い、または \
            既に確定済みのバッチへの二重呼び出しの可能性があります。呼び出し元のバッチID \
            管理・完了操作の呼び出し回数を確認してください。
            """
        }
    }
}

/// `ExportJob.delivery.format` / `OutputRecord.format` 列のraw value割当（Task 5前半で
/// 確定）。DomainのImageFormatにはraw valueが無いため、Persistence側で独自に割り当てる
/// （Schema+Accounting.swiftの既存コメント「raw valueの割当はStore実装タスクの担当」）。
/// 以後この列を読み書きする実装はこの割当を再利用すること。
enum ImageFormatColumn: Int, Sendable {
    case jpeg = 1
    case heic = 2
    case png = 3

    init(_ value: ImageFormat) {
        switch value {
        case .jpeg: self = .jpeg
        case .heic: self = .heic
        case .png: self = .png
        }
    }

    var domainValue: ImageFormat {
        switch self {
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .png: return .png
        }
    }
}

/// `ExportJob.accountingMode` 列のraw value割当（Task 5前半で確定）。同上の理由で
/// Persistence側で独自に割り当てる。
enum ExportAccountingModeColumn: Int, Sendable {
    case paidUnlimited = 1
    case freeMonthlyConsume = 2
    case batchTrial = 3

    init(_ value: ExportAccountingMode) {
        switch value {
        case .paidUnlimited: self = .paidUnlimited
        case .freeMonthlyConsume: self = .freeMonthlyConsume
        case .batchTrial: self = .batchTrial
        }
    }

    var domainValue: ExportAccountingMode {
        switch self {
        case .paidUnlimited: return .paidUnlimited
        case .freeMonthlyConsume: return .freeMonthlyConsume
        case .batchTrial: return .batchTrial
        }
    }
}

/// 設定可能な閾値・機能フラグ束（引数を構造体へ束ねるlint対応パターン。
/// StampStoreLive.insertStampRowsのNewStampRowsと同じ理由。ExportSagaStoreLive.initが
/// database/now/deviceTimeZoneに加えてこれら3つも受け取ると引数が5個を超える
/// ため、既定値を持つ設定値だけをここへ束ねる）。
public struct ExportSagaStoreLimits: Sendable {
    /// resolveCapabilities(_:usageNow:enabledStampPacks:)（Domain）のシグネチャ上必須
    /// （startExportの勘定判定自体には影響しない。ResolvedCapabilities.enabledStampPacksに
    /// 格納されるだけ）。
    public let enabledStampPacks: Set<String>
    /// Batch.trialCreditCount（DB由来の値）を無条件に信頼しないためのクランプ上限
    /// （オーケストレーター確定判断）。
    public let hardMaxTrialCredits: Int
    /// 月間上限（既定5。architecture.md 6.3「月間上限（既定 5）」）。
    public let monthlyLimit: Int

    public init(enabledStampPacks: Set<String> = [], hardMaxTrialCredits: Int = 5, monthlyLimit: Int = 5) {
        self.enabledStampPacks = enabledStampPacks
        self.hardMaxTrialCredits = hardMaxTrialCredits
        self.monthlyLimit = monthlyLimit
    }
}

/// ExportSagaStoreの実装。GRDBのAppDatabaseを1つ受け取り、全メソッドをdbQueue.write /
/// dbQueue.readの呼び出しだけで完結させる（全7メソッドともファイル実体には一切触れない。
/// 出力ファイルの実削除はPendingFileDeletion経由の別タスクの担当のため、ManagedFileStoreへの
/// 依存は持たない）。
///
/// `database` / `now` / `deviceTimeZone` / `enabledStampPacks` / `hardMaxTrialCredits` /
/// `monthlyLimit` はpublicではないが、複数ファイルへ分割したextensionから参照する必要が
/// あるため（StampStoreLiveと同じ理由）モジュール内既定アクセス（internal）のままにする。
/// 外部パッケージからは見えない。
///
/// `deviceTimeZone`は`now`と同じ設計判断（デフォルト値なし、呼び出し側が必ず注入する。
/// 裸のTimeZone.currentをコード内で直接使わない。オーケストレーター確定判断）。
public struct ExportSagaStoreLive: ExportSagaStore {
    let database: AppDatabase
    let now: @Sendable () -> Date
    let deviceTimeZone: @Sendable () -> TimeZone
    let enabledStampPacks: Set<String>
    let hardMaxTrialCredits: Int
    let monthlyLimit: Int

    public init(
        database: AppDatabase,
        now: @escaping @Sendable () -> Date,
        deviceTimeZone: @escaping @Sendable () -> TimeZone,
        limits: ExportSagaStoreLimits = ExportSagaStoreLimits()
    ) {
        self.database = database
        self.now = now
        self.deviceTimeZone = deviceTimeZone
        self.enabledStampPacks = limits.enabledStampPacks
        self.hardMaxTrialCredits = limits.hardMaxTrialCredits
        self.monthlyLimit = limits.monthlyLimit
    }
}
