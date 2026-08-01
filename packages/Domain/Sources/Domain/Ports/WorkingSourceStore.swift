import Foundation

// 処理用素材の永続化ポート（image-pipeline.md 5 章「写真選択と PhotoKit 境界」の
// 「処理用ファイルの寿命を DB で管理する」「実装の所在」「再編集にはハッシュではなく
// 平文の参照が要る」各小節）。
//
// `OriginalCaptureMetadata` / `RenderSpec` は既に実装済み（Task 2、Rendering/Boundary.swift・
// Rendering/RenderSpec.swift）のため再宣言しない。
//
// 【実装中の判断】`SourceRepresentation`（architecture.md 1969 行目、
// `enum SourceRepresentation: Sendable, Equatable { case original, transcoded }`）は
// spec 上「Task 2 で実装済み」とされていたが、実際には packages/Domain 全体に存在しない
// （grep で確認済み）。Task 2 の実装コメント（Rendering/Boundary.swift 冒頭）は
// 「`SourceRepresentation` は…Task 4 の担当であるため今回は追加しない」と明記しており、
// Task 2 の実装者自身が Task 4 へ委譲している。一方で `OutputMetadata`（同じ疑似コード
// ブロック内の別の型）は `ImageEncoder`（Task 4 のスコープ外の UI/画像処理境界）専用で
// どのタスクにも割り当てが無いため、ここには含めない（spec の除外方針どおり）。
// `CreateWorkingSourceInput` 等（このファイルで Produces として明示されている入力型）は
// `representation: SourceRepresentation` を持つため、この型が無いとこのファイル自体が
// コンパイルできない。定義は architecture.md のコードブロックからの一字一句転記であり
// 設計判断を伴わないため、ここに追加して実装を完遂した。誤りであれば差し戻してほしい。
public enum SourceRepresentation: Sendable, Equatable {
    case original      // プロバイダーが返した原データ
    case transcoded    // OS が変換した派生データしか取得できなかった
}

/// 再編集のための参照（image-pipeline.md 5 章「再編集にはハッシュではなく平文の参照が要る」）。
public struct ProjectSourceLocator: Sendable, Equatable {
    /// PHAsset.localIdentifier。ファイル取り込み等で取得できない場合は nil
    public let photoLibraryLocalIdentifier: String?

    public init(photoLibraryLocalIdentifier: String?) {
        self.photoLibraryLocalIdentifier = photoLibraryLocalIdentifier
    }
}

/// 復元したキュー項目が参照する処理用ファイルを表す永続モデル（image-pipeline.md 5 章
/// 「処理用ファイルの寿命を DB で管理する」）。正本は Sendable のみ
public struct WorkingSourceRecord: Sendable {
    public let projectID: ProjectID
    public let sourceFile: WorkingSourceFileRef
    public let createdAt: Date               // 作成・最終置換時刻

    public init(projectID: ProjectID, sourceFile: WorkingSourceFileRef, createdAt: Date) {
        self.projectID = projectID
        self.sourceFile = sourceFile
        self.createdAt = createdAt
    }
}

/// Domain — 永続化ポート（image-pipeline.md 5 章「実装の所在」）。
public protocol WorkingSourceStore: Sendable {
    /// インポート Saga の手順 3。単一 DB トランザクション
    func createProjectWithWorkingSource(_ input: CreateWorkingSourceInput) async throws

    /// 素材更新 Saga の手順 2。単一 DB トランザクション
    func replaceWorkingSource(_ input: ReplaceWorkingSourceInput) async throws

    /// 履歴の既存 Project へ処理用素材を再接続する（下記）
    func attachWorkingSourceToExistingProject(
        _ input: AttachWorkingSourceInput
    ) async throws

    /// projectID の処理用素材を返す（無ければ nil）。再選択後の分岐と実体の存在確認に使う
    func loadWorkingSource(for projectID: ProjectID) async throws -> WorkingSourceRecord?

    /// 破棄。呼び出し契機は 2 つ: 完了操作（settle。[書き出し Saga](export-saga.md) 側の契約）、プロジェクトの破棄
    func deleteWorkingSource(_ projectID: ProjectID) async throws

    /// 実体欠損時の無効化（下記「実体の存在確認」）。単一 DB トランザクションで
    /// (a) `WorkingSourceRecord` を削除し、(b) 対象 `projectID` の非終端キュー項目を
    /// `paused(.sourceReselectionRequired)` へ更新し、(c) 欠損したファイル参照を
    /// `PendingFileDeletion` へ登録する。**実体が無くても (c) を行ってよい**（参照の掃除
    /// であり、孤児 GC が空振りで行を消すだけで無害。[アーキテクチャ設計](architecture.md) の
    /// 7.5「出力の削除経路」と同じ単一経路に揃える）
    func invalidateWorkingSource(_ projectID: ProjectID) async throws
}

/// インポート Saga の手順 3 の入力（image-pipeline.md 5 章）。正本は Sendable のみ
public struct CreateWorkingSourceInput: Sendable {
    public let projectID: ProjectID
    public let batchID: BatchID?
    public let queueItemID: ExportQueueItemID?
    public let sourceFile: WorkingSourceFileRef      // 向き正規化済みの原寸
    public let createdAt: Date
    public let sourceLocator: ProjectSourceLocator
    public let capture: OriginalCaptureMetadata      // EXIF 由来（正準スキーマ 5.1）。Project へ保存する
    public let libraryCreationDate: Date?            // Project へ保存する
    public let representation: SourceRepresentation  // Project へ保存する（アーキテクチャ設計 7.5）
    public let initialSpec: RenderSpec

    public init(
        projectID: ProjectID,
        batchID: BatchID?,
        queueItemID: ExportQueueItemID?,
        sourceFile: WorkingSourceFileRef,
        createdAt: Date,
        sourceLocator: ProjectSourceLocator,
        capture: OriginalCaptureMetadata,
        libraryCreationDate: Date?,
        representation: SourceRepresentation,
        initialSpec: RenderSpec
    ) {
        self.projectID = projectID
        self.batchID = batchID
        self.queueItemID = queueItemID
        self.sourceFile = sourceFile
        self.createdAt = createdAt
        self.sourceLocator = sourceLocator
        self.capture = capture
        self.libraryCreationDate = libraryCreationDate
        self.representation = representation
        self.initialSpec = initialSpec
    }
}

/// 素材更新 Saga の手順 2 の入力（image-pipeline.md 5 章）。正本は Sendable のみ
public struct ReplaceWorkingSourceInput: Sendable {
    public let projectID: ProjectID
    public let newSourceFile: WorkingSourceFileRef
    public let replacedAt: Date       // createdAt もこの値へ更新する
    public let capture: OriginalCaptureMetadata       // Project の値を新しい素材のもので置き換える
    public let libraryCreationDate: Date?
    public let representation: SourceRepresentation
    // 旧ファイルは DB トランザクション内で読む。呼び出し側から渡さない

    public init(
        projectID: ProjectID,
        newSourceFile: WorkingSourceFileRef,
        replacedAt: Date,
        capture: OriginalCaptureMetadata,
        libraryCreationDate: Date?,
        representation: SourceRepresentation
    ) {
        self.projectID = projectID
        self.newSourceFile = newSourceFile
        self.replacedAt = replacedAt
        self.capture = capture
        self.libraryCreationDate = libraryCreationDate
        self.representation = representation
    }
}

/// 履歴の既存 Project への再接続の入力（image-pipeline.md 5 章）。正本は Sendable のみ
public struct AttachWorkingSourceInput: Sendable {
    public let projectID: ProjectID
    public let sourceFile: WorkingSourceFileRef
    public let attachedAt: Date
    public let capture: OriginalCaptureMetadata
    public let libraryCreationDate: Date?
    public let representation: SourceRepresentation

    public init(
        projectID: ProjectID,
        sourceFile: WorkingSourceFileRef,
        attachedAt: Date,
        capture: OriginalCaptureMetadata,
        libraryCreationDate: Date?,
        representation: SourceRepresentation
    ) {
        self.projectID = projectID
        self.sourceFile = sourceFile
        self.attachedAt = attachedAt
        self.capture = capture
        self.libraryCreationDate = libraryCreationDate
        self.representation = representation
    }
}
