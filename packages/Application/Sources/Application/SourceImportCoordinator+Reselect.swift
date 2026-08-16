import Foundation
import Domain

// SourceImportCoordinator+Reselect — 素材再選択・再接続 Saga（Issue #8 サブプロジェクト5 A2
// Task 3・Task 4）。
//
// 正本: image-pipeline.md 5章「再選択後の Saga」（手順1〜3）・「実装の所在」
// （WorkingSourceStore プロトコル）。SourceImportCoordinator.swift（Task 2）と同じ actor を
// extension で拡張する（プロパティを internal へ揃えた理由は SourceImportCoordinator.swift
// 冒頭のプロパティ宣言コメント参照）。
//
// キュー構成（Task 2 と揃える。ファイル冒頭コメントの「W1」と同型の判断）: 手順2の分岐判定
// （loadWorkingSource）・手順1（load）・手順2の書き込み（replaceWorkingSource または
// attachWorkingSourceToExistingProject。分岐は下記「論点1」参照）を単一の `queue.run` の op と
// してまとめる（performReselect）。分岐判定をキューの外で行うと、判定後に別の直列化された操作が
// 割り込んで古い判定のまま書き込む TOCTOU 競合が起こりうるため（architecture.md 4.2「変更を
// 伴うすべての操作は単一のグローバル直列キュー1本で直列化する」の対象は「読んで分岐して書く」
// 一連の流れ全体に及ぶ）。手順3（旧ファイルの削除）は performReselect の完了後に別の
// `queue.run` 呼び出しとして直列化する（deleteReplacedSourceFile。Task 2 の deleteImportedFile
// と同型で、削除に失敗したら runShieldedFromCancellation で守った registerOrphan を試みる）。
// 「なし」側（Task 4）には削除すべき旧ファイルが存在しないため、performReselect の戻り値を
// `WorkingSourceFileRef?` にして「なし」側は nil を返し、deleteReplacedSourceFile 側で
// nil をスキップする。
//
// 【論点1: 再選択と再接続の分岐（Task 3 で骨格、Task 4 で「なし」側を実装済み）】
// WorkingSourceRecord が存在する場合（実体が欠損している場合を含む）は replaceWorkingSource を、
// 存在しない場合（履歴からの再編集・完了操作で削除済み）は attachWorkingSourceToExistingProject
// を呼ぶ（image-pipeline.md 5章の表）。両分岐とも本ファイルで実装済み。
//
// 【スコープ外と判断した論点2: input.importedFile の後始末】
// input.importedFile（今回選び直した生の写真ファイル。正規化前）は pickedPhotoLoader.load で
// 正規化された後は Task 2 の手順4と同様に不要になるはずだが、正本（image-pipeline.md 5章
// 「再選択後の Saga」手順1〜3、970〜985行目）・計画書 Task 3/4 の不変条件のいずれも、削除対象を
// 「置換された旧 sourceFile」（loadWorkingSource が返した既存 record の sourceFile。「あり」側
// のみに存在する）としか明記しておらず、input.importedFile の削除には触れていない。import Saga
// （手順4で importedFile を明示的に削除する）と扱いが異なるように見えるが、推測で実装を広げず、
// 正本・計画書が明記する範囲だけを実装対象とした。「なし」側（Task 4）にも同様に適用され、
// input.importedFile の削除は実装しない（Issue #36 で追跡中）。
// オーケストレーターへの差し戻し事項として最終報告に記載する。
//
// 【スコープ外と判断した論点3: performReselect 失敗時の新規正規化ファイルの後始末】
// performReselect の手順（load・loadWorkingSource・replaceWorkingSource または
// attachWorkingSourceToExistingProject）が失敗した場合、新しく作られた正規化ファイル
// （loaded.source.file）を registerOrphan する
// 後始末は import Saga（手順3失敗時の後始末。SourceImportCoordinator.swift の performImport）
// には明記されているが、再選択 Saga の正本にも計画書 Task 3/4 の不変条件にも対応する記述が無い。
// 推測で import Saga と同じ後始末を追加せず、正本・計画書が明記する範囲のみを実装した。
// 「あり」側・「なし」側のいずれにも同様に適用される。同じくオーケストレーターへの差し戻し
// 事項として最終報告に記載する。

extension SourceImportCoordinator {
    /// image-pipeline.md 5章「再選択後の Saga」手順1〜3。
    public func reselectSource(projectID: ProjectID, input: PickedPhotoInput) async throws {
        try await recoveryGate.awaitRecoveryCompleted()

        let replacedSourceFile = try await queue.run {
            try await self.performReselect(projectID: projectID, input: input)
        }

        // 手順3: 置換された旧sourceFileを削除する。「なし」側（replacedSourceFile == nil）は
        // 削除すべき旧ファイルが存在しないため何もしない（ファイル冒頭コメント参照）。
        guard let replacedSourceFile else { return }
        try await deleteReplacedSourceFile(replacedSourceFile)
    }

    /// 手順1〜2本体（分岐判定・load・向き正規化・書き込みを単一 `queue.run` の op として
    /// 実行する。ファイル冒頭コメント参照）。分岐判定（loadWorkingSource）だけをここで行い、
    /// 実際の書き込みは「あり」側・「なし」側それぞれの private メソッドへ委譲する
    /// （50行制限のため）。戻り値は置換された旧 sourceFile（呼び出し元が手順3で削除するために
    /// 必要）。「なし」側には削除すべき旧ファイルが存在しないため nil を返す。
    private func performReselect(
        projectID: ProjectID, input: PickedPhotoInput
    ) async throws -> WorkingSourceFileRef? {
        let loaded = try await pickedPhotoLoader.load(input.importedFile)
        guard let normalizedSourceFile = WorkingSourceFileRef(loaded.source.file) else {
            throw SourceImportError.invalidNormalizedSourceKind(loaded.source.file)
        }

        if let existing = try await workingSourceStore.loadWorkingSource(for: projectID) {
            try await performReplace(
                projectID: projectID, input: input, loaded: loaded, normalizedSourceFile: normalizedSourceFile
            )
            return existing.sourceFile
        } else {
            try await performAttach(
                projectID: projectID, input: input, loaded: loaded, normalizedSourceFile: normalizedSourceFile
            )
            return nil
        }
    }

    /// 「あり」側（`WorkingSourceRecord` が存在する）: 単一DBトランザクションで
    /// WorkingSourceRecordを置換する。FaceTrack / ReviewIssue / ReviewDecision / ReviewStatus の
    /// 破棄・detectionRevision / projectRevision の増加は WorkingSourceStoreLive（Persistence層）
    /// がこのポート契約の内部実装として担う。Application層はreplaceWorkingSourceを正しい入力で
    /// 呼ぶだけでよい（正本の注記。SourceImportTestSupport.swift冒頭のスコープ注記と同型）。
    private func performReplace(
        projectID: ProjectID, input: PickedPhotoInput, loaded: LoadedPhoto, normalizedSourceFile: WorkingSourceFileRef
    ) async throws {
        let replaceInput = ReplaceWorkingSourceInput(
            projectID: projectID,
            newSourceFile: normalizedSourceFile,
            replacedAt: now(),
            capture: loaded.capture,
            libraryCreationDate: input.libraryCreationDate,
            representation: input.representation,
            sourceLocator: ProjectSourceLocator(photoLibraryLocalIdentifier: input.providerAssetIdentifier)
        )
        try await workingSourceStore.replaceWorkingSource(replaceInput)
    }

    /// 「なし」側（`WorkingSourceRecord` が存在しない。完了操作で削除済み・履歴から開いた）:
    /// 単一DBトランザクションでWorkingSourceRecordを新規作成する（`attachedAt` を `createdAt` へ
    /// 設定する。正本の分岐表）。FaceTrack等の破棄・revision増加はreplaceWorkingSource側と同様
    /// WorkingSourceStoreLiveの内部実装が担う。
    private func performAttach(
        projectID: ProjectID, input: PickedPhotoInput, loaded: LoadedPhoto, normalizedSourceFile: WorkingSourceFileRef
    ) async throws {
        let attachInput = AttachWorkingSourceInput(
            projectID: projectID,
            sourceFile: normalizedSourceFile,
            attachedAt: now(),
            capture: loaded.capture,
            libraryCreationDate: input.libraryCreationDate,
            representation: input.representation,
            sourceLocator: ProjectSourceLocator(photoLibraryLocalIdentifier: input.providerAssetIdentifier)
        )
        try await workingSourceStore.attachWorkingSourceToExistingProject(attachInput)
    }

    /// 手順3。削除に失敗したら registerOrphan で積む（正本「削除に失敗したら
    /// PendingFileDeletion へ積む」）。Task 2 の deleteImportedFile と同型（詳細な理由は
    /// SourceImportCoordinator.swift の deleteImportedFile doc コメント参照）:
    /// registerOrphan が成功すれば削除失敗はSaga全体の失敗にしない（手順2で既にコミット済みの
    /// ため、これはベストエフォートの後始末）。registerOrphanも失敗した場合のみ、削除失敗の
    /// 理由を保持したままthrowする。DB書き込みを伴う後始末のため runShieldedFromCancellation
    /// （Cleanup.swift）で包み、呼び出し元がキャンセル済みでも完走させる。
    private func deleteReplacedSourceFile(_ replacedSourceFile: WorkingSourceFileRef) async throws {
        do {
            try await queue.run {
                try await self.managedFileStore.delete(replacedSourceFile.ref)
            }
        } catch let deleteError {
            do {
                try await runShieldedFromCancellation {
                    try await self.queue.run {
                        try await self.maintenanceStore.registerOrphan(replacedSourceFile.ref)
                    }
                }
            } catch let registerOrphanError {
                throw CleanupPreservingError(cause: deleteError, cleanupFailure: registerOrphanError)
            }
        }
    }
}
