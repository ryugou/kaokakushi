import Foundation
import Domain
import GRDB

// ExportSagaStoreの実装（export-saga.md 0章「Application が使う永続化ポート」・
// 2章「ExportJobとOutputRecord」・3章「手順」・4章「中断・やり直し・破棄」・
// 5章「起動時復旧」が正本。Issue #6 Task 5前半）。
//
// このセッションで本実装するのは startExport / recordGeneratedOutput / discardExport /
// loadRunningJobs / deleteRunningJobs の5メソッドのみ。settleExport / settleBatch は
// 次セッションの担当のため、下記のとおり未実装エラーをthrowする仮実装に留める
// （オーケストレーター確定判断）。
//
// `ExportSagaStore` のポートシグネチャには時刻引数が無いが、ExportJob.authorization.
// authorizedAt / OutputRecord.generatedAt には実行時点の時刻が必要なため、実装側だけの
// 依存注入として `now: @escaping @Sendable () -> Date` をinitへ追加する（Domainの
// プロトコル自体は変更しない。オーケストレーター確定判断）。
//
// 400行制限のため、メソッド群を以下へ分割する（StampStoreLiveの分割パターンを踏襲）:
//   - ExportSagaStoreLive.swift（このファイル）: 型定義・エラー型・raw value割当・
//     struct定義・init・settleExport/settleBatchの仮実装
//   - ExportSagaStoreLive+Mapping.swift: ExportJob行の共通デコード（loadExportJob /
//     makeExportJob）とraw value変換の共通ヘルパー
//   - ExportSagaStoreLive+Start.swift: startExport
//   - ExportSagaStoreLive+Accounting.swift: startExportが使う勘定（accountingMode）の
//     解決ロジック
//   - ExportSagaStoreLive+Output.swift: recordGeneratedOutput / discardExport
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
    /// SubscriptionState / UsageLedgerは単一行であることをApplication層が保証する契約
    /// （Schema+Delivery.swift / Schema+Accounting.swiftのコメント参照）。行が2件以上
    /// あれば契約違反としてfail-closedでthrowする（先頭行だけを暗黙に使わない）。
    case multipleSingletonRows(table: String, count: Int)
    /// startExport: input.previewConfirmation.projectIDがinput.projectIDと一致しない
    /// （1.1 確認の一致。異なるプロジェクトのプレビュー確認情報が渡された可能性がある）。
    case previewConfirmationProjectMismatch(projectID: ProjectID, previewConfirmationProjectID: ProjectID)
    /// settleExport / settleBatch: 今回のセッションでは未実装（次セッションの担当）。
    case unimplemented(String)
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
            行存在します。Application層が単一行を保証する経路に不整合がある可能性が \
            あります（手動でのDB改変やマイグレーション不備を疑ってください）。
            """
        case .previewConfirmationProjectMismatch(let projectID, let previewConfirmationProjectID):
            return """
            ExportSagaStore: startExportに渡されたprojectID=\(projectID.rawValue.uuidString) と \
            previewConfirmation.projectID=\(previewConfirmationProjectID.rawValue.uuidString) が \
            一致しません。呼び出し元が別プロジェクトのプレビュー確認情報を渡していないか \
            確認してください（export-saga.md 1.1）。
            """
        case .unimplemented(let methodName):
            return """
            ExportSagaStore: \(methodName) はこのセッションでは未実装です \
            （export-saga.md 3章「手順5」の単一トランザクション実装は次セッションの担当）。
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

/// ExportSagaStoreの実装。GRDBのAppDatabaseとManagedFileStoreを1つずつ受け取り、全
/// メソッドをdbQueue.write / dbQueue.readとfileStoreの呼び出しだけで完結させる。
///
/// `database` / `fileStore` / `now` / `enabledStampPacks` / `hardMaxTrialCredits` は
/// publicではないが、複数ファイルへ分割したextensionから参照する必要があるため
/// （StampStoreLiveと同じ理由）モジュール内既定アクセス（internal）のままにする。
/// 外部パッケージからは見えない。
///
/// `enabledStampPacks`はresolveCapabilities(_:usageNow:enabledStampPacks:)（Domain）の
/// シグネチャ上必須のため注入する（startExportの勘定判定自体には影響しない。
/// ResolvedCapabilities.enabledStampPacksに格納されるだけ）。`hardMaxTrialCredits`は
/// Batch.trialCreditCount（DB由来の値）を無条件に信頼しないためのクランプ上限
/// （オーケストレーター確定判断）。
public struct ExportSagaStoreLive: ExportSagaStore {
    let database: AppDatabase
    let fileStore: ManagedFileStore
    let now: @Sendable () -> Date
    let enabledStampPacks: Set<String>
    let hardMaxTrialCredits: Int

    public init(
        database: AppDatabase,
        fileStore: ManagedFileStore,
        now: @escaping @Sendable () -> Date,
        enabledStampPacks: Set<String> = [],
        hardMaxTrialCredits: Int = 5
    ) {
        self.database = database
        self.fileStore = fileStore
        self.now = now
        self.enabledStampPacks = enabledStampPacks
        self.hardMaxTrialCredits = hardMaxTrialCredits
    }
}

extension ExportSagaStoreLive {
    // 未実装（後半セッション担当）: export-saga.md 3章「手順5」の単一トランザクション実装。
    // 台帳加算/クレジット消費・settledAt確定・ExportRecord作成・confirmed設定エントリ更新・
    // キュー項目completed更新・WorkingSourceRecord削除+PendingFileDeletion登録・
    // ExportJob削除を単一トランザクションで行う実装に置き換えること。
    public func settleExport(_ exportID: ExportID) async throws {
        throw ExportSagaStoreError.unimplemented("settleExport")
    }

    // 未実装（後半セッション担当）: settleExportと同内容をbatchID単位で一括確定。
    public func settleBatch(_ batchID: BatchID, settledAt: Date) async throws {
        throw ExportSagaStoreError.unimplemented("settleBatch")
    }
}
