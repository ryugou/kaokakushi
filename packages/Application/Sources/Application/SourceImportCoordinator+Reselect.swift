import Foundation
import Domain

// SourceImportCoordinator+Reselect — 素材再選択 Saga（Issue #8 サブプロジェクト5 A2 Task 3）。
//
// 正本: image-pipeline.md 5章「再選択後の Saga」（手順1〜3）・「実装の所在」
// （WorkingSourceStore プロトコル）。SourceImportCoordinator.swift（Task 2）と同じ actor を
// extension で拡張する（プロパティを internal へ揃えた理由は SourceImportCoordinator.swift
// 冒頭のプロパティ宣言コメント参照）。
//
// キュー構成（Task 2 と揃える。ファイル冒頭コメントの「W1」と同型の判断）: 手順2の分岐判定
// （loadWorkingSource）・手順1（load）・手順2の書き込み（replaceWorkingSource）を単一の
// `queue.run` の op としてまとめる（performReselect）。分岐判定をキューの外で行うと、判定後に
// 別の直列化された操作が割り込んで古い判定のまま書き込む TOCTOU 競合が起こりうるため
// （architecture.md 4.2「変更を伴うすべての操作は単一のグローバル直列キュー1本で直列化する」の
// 対象は「読んで分岐して書く」一連の流れ全体に及ぶ）。手順3（旧ファイルの削除）は
// performReselect の完了後に別の `queue.run` 呼び出しとして直列化する（deleteReplacedSourceFile。
// Task 2 の deleteImportedFile と同型で、削除に失敗したら runShieldedFromCancellation で守った
// registerOrphan を試みる）。
//
// 【スコープ外と判断した論点1: 再接続経路（WorkingSourceRecord なし）】
// WorkingSourceRecord が存在しない場合（履歴からの再編集・完了操作で削除済み）は
// attachWorkingSourceToExistingProject を呼ぶ再接続経路になる（image-pipeline.md 5章の表）が、
// これは計画書 Task 4 の担当。ここでは分岐の骨格（guard let existing）だけを用意し、else 側の
// 本体（attachWorkingSourceToExistingProject 呼び出し・候補ファイルの扱い）は実装しない。
// else 側に到達した場合は SourceReselectError.workingSourceRecordNotFound を throw する
// （黙って何もしない・中途半端に attach を呼びかけたりせず、Task 4 未実装であることが
// 呼び出し元に明確に伝わるようにするため）。
//
// 【スコープ外と判断した論点2: input.importedFile の後始末】
// input.importedFile（今回選び直した生の写真ファイル。正規化前）は pickedPhotoLoader.load で
// 正規化された後は Task 2 の手順4と同様に不要になるはずだが、正本（image-pipeline.md 5章
// 「再選択後の Saga」手順1〜3、970〜985行目）・計画書 Task 3 の4つの不変条件（238〜284行目）の
// いずれも、削除対象を「置換された旧 sourceFile」（loadWorkingSource が返した既存 record の
// sourceFile）としか明記しておらず、input.importedFile の削除には触れていない。import Saga
// （手順4で importedFile を明示的に削除する）と扱いが異なるように見えるが、推測で実装を広げず、
// 正本・計画書が明記する範囲（旧 record の sourceFile の削除）だけを実装対象とした。
// オーケストレーターへの差し戻し事項として最終報告に記載する。
//
// 【スコープ外と判断した論点3: performReselect 失敗時の新規正規化ファイルの後始末】
// performReselect の手順（load・replaceWorkingSource）が失敗した場合、新しく作られた正規化
// ファイル（loaded.source.file）を registerOrphan する後始末は import Saga（手順3失敗時の
// 後始末。SourceImportCoordinator.swift の performImport）には明記されているが、再選択 Saga の
// 正本にも計画書 Task 3 の4つの不変条件にも対応する記述が無い。推測で import Saga と同じ後始末を
// 追加せず、正本・計画書が明記する範囲のみを実装した。同じくオーケストレーターへの差し戻し
// 事項として最終報告に記載する。

/// 再選択 Saga の分岐（image-pipeline.md 5章「再選択後の Saga」表）で `WorkingSourceRecord` が
/// 見つからなかった場合に投げる診断用エラー。この経路（`attachWorkingSourceToExistingProject`
/// を呼ぶ再接続）は計画書 Task 4 の担当であり、このタスク（Task 3）では実装しない
/// （ファイル冒頭コメント「論点1」参照）。
public enum SourceReselectError: Error, Sendable, Equatable {
    case workingSourceRecordNotFound(ProjectID)
}

extension SourceImportCoordinator {
    /// image-pipeline.md 5章「再選択後の Saga」手順1〜3。
    public func reselectSource(projectID: ProjectID, input: PickedPhotoInput) async throws {
        try await recoveryGate.awaitRecoveryCompleted()

        let replacedSourceFile = try await queue.run {
            try await self.performReselect(projectID: projectID, input: input)
        }

        // 手順3: 置換された旧sourceFileを削除する。
        try await deleteReplacedSourceFile(replacedSourceFile)
    }

    /// 手順1〜2本体（分岐判定・load・向き正規化・replaceWorkingSource を単一 `queue.run` の
    /// op として実行する。ファイル冒頭コメント参照）。戻り値は置換された旧 sourceFile
    /// （呼び出し元が手順3で削除するために必要）。
    private func performReselect(
        projectID: ProjectID, input: PickedPhotoInput
    ) async throws -> WorkingSourceFileRef {
        // 「なし」側（Task 4 の担当）はファイル冒頭コメント「論点1」参照。
        guard let existing = try await workingSourceStore.loadWorkingSource(for: projectID) else {
            throw SourceReselectError.workingSourceRecordNotFound(projectID)
        }

        // 手順1: EXIF読み取り・向き正規化・working/への書き込みはローダーへ完全委譲する
        // （Task 2 の performImport と同じ）。
        let loaded = try await pickedPhotoLoader.load(input.importedFile)
        guard let normalizedSourceFile = WorkingSourceFileRef(loaded.source.file) else {
            throw SourceImportError.invalidNormalizedSourceKind(loaded.source.file)
        }

        // 手順2: 単一DBトランザクションでWorkingSourceRecordを置換する。FaceTrack /
        // ReviewIssue / ReviewDecision / ReviewStatus の破棄・detectionRevision /
        // projectRevision の増加は WorkingSourceStoreLive（Persistence層）がこのポート契約の
        // 内部実装として担う。Application層はreplaceWorkingSourceを正しい入力で呼ぶだけでよい
        // （正本の注記。SourceImportTestSupport.swift冒頭のスコープ注記と同型）。
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
        return existing.sourceFile
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
