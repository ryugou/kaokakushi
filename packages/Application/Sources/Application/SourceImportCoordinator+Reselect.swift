import Foundation
import Domain

// SourceImportCoordinator+Reselect — 素材再選択・再接続 Saga（Issue #8 サブプロジェクト5 A2
// Task 3・Task 4。手順3・4の後始末の非対称性を解消する追加実装は Issue #36）。
//
// 正本: image-pipeline.md 5章「再選択後の Saga」（手順1〜4）・「実装の所在」
// （WorkingSourceStore プロトコル）。SourceImportCoordinator.swift（Task 2）と同じ actor を
// extension で拡張する（プロパティを internal へ揃えた理由は SourceImportCoordinator.swift
// 冒頭のプロパティ宣言コメント参照）。
//
// キュー構成（Task 2 と揃える。SourceImportCoordinator.swift 冒頭コメントの「W1」と同型の判断）:
// 手順2の分岐判定（loadWorkingSource）・手順1（load）・手順2の書き込み（replaceWorkingSource
// または attachWorkingSourceToExistingProject。分岐は下記「論点1」参照）を単一の `queue.run` の
// op としてまとめる（performReselect）。分岐判定をキューの外で行うと、判定後に別の直列化された
// 操作が割り込んで古い判定のまま書き込む TOCTOU 競合が起こりうるため（architecture.md 4.2
// 「変更を伴うすべての操作は単一のグローバル直列キュー1本で直列化する」の対象は「読んで分岐して
// 書く」一連の流れ全体に及ぶ）。手順3（旧 sourceFile の削除）・手順4（取り込みファイルの削除）は
// performReselect の完了後に、それぞれ独立した `queue.run` 呼び出しとして直列化する
// （deleteReplacedSourceFile / deleteReselectedImportedFile。Task 2 の deleteImportedFile と同型で、
// 削除に失敗したら runShieldedFromCancellation で守った registerOrphan を試みる。この2メソッドは
// SourceImportCoordinator.swift の deleteImportedFile と同じ理由で private のまま本ファイルに
// 置く。以前は SourceImportCoordinator+ReselectCleanup.swift へ分離していたが、分離の根拠だった
// 「本ファイルに全部書くとファイル400行制限〈Global Constraints〉を超える」は実測（統合後292+50=
// 343行）と食い違っており誤りだったため、reviewer 指摘 W-2 で本ファイルへ統合し、分離のために
// internal へ広げていたアクセスレベルも private へ戻した。isDistinctManagedFile によるデータ損失
// 防止ガードを通さずに実体を直接削除する2メソッドを Application モジュール内のどこからでも呼べる
// 状態にしておくと、将来別の Coordinator が誤って直接呼びガードを迂回できてしまうため）。
//
// 【論点1: 再選択と再接続の分岐（Task 3 で骨格、Task 4 で「なし」側を実装済み）】
// WorkingSourceRecord が存在する場合（実体が欠損している場合を含む）は replaceWorkingSource を、
// 存在しない場合（履歴からの再編集・完了操作で削除済み）は attachWorkingSourceToExistingProject
// を呼ぶ（image-pipeline.md 5章の表）。両分岐とも本ファイルで実装済み。
//
// 【Issue #36: 手順3・4の削除可否判定と「両方試みる」方針】
// 正本（image-pipeline.md 5章「再選択後の Saga」手順3・4）は、旧 sourceFile（手順3。置換された
// 既存 WorkingSourceRecord の実体）と取り込みファイル（手順4。PickedPhotoInput.importedFile。
// 今回選び直した写真そのもの）を、別々の実体として両方削除すると明記する。performReselect が
// 返す ReselectOutcome はこの2つの削除対象を独立したフィールドとして持ち、reselectSource は
// どちらか一方の削除（+ 失敗時のregisterOrphan後始末）が失敗しても、他方の削除を諦めずに試みる
// （SourceImportCoordinator.swift の performImport が「1件のregisterOrphan失敗が2件目の試行を
// 妨げない」としているW2と同じ思想を、独立した2つの削除操作に当てはめたもの。最初に発生した
// 失敗だけを呼び出し元へ伝える）。削除可否の判定（同一 `ManagedFileRef` なら削除しない。
// PickedPhotoLoader.load の契約には入力と異なる参照を返す保証が無いため）は、手順3側は既存の
// replacedSourceFileToDelete をそのまま使い、手順4側は同じ基準の newlyImportedFileToDelete を
// 新設して使う（SourceImportCoordinator.swift の importedFileToDelete と同名にすると、同じ actor
// を拡張する別ファイルに同シグネチャの private メソッドが2つ存在することになり紛らわしいため、
// 呼び出し元を含めて意図が読み取れるよう別名にした）。
//
// 【Issue #36: 手順2（performReselect）失敗時の後始末】
// SourceImportCoordinator.swift の performImport と同型: load 成功直後に正規化ファイルの参照を
// createdFiles へ積み、以降のどの失敗（型不整合・replaceWorkingSource /
// attachWorkingSourceToExistingProject の失敗）でも、input.importedFile と createdFiles を
// ベストエフォートで registerOrphan へ積む（1件が失敗しても残りの登録を試みる。W2と同型）。
// 後始末を終えた後は必ず ReselectFailureAlreadyHandled（ImportFailureAlreadyHandled と同じ役割の
// マーカー。Swift の private はファイルスコープのためあちらの型をこのファイルから再利用できず、
// 同じ役割の型をこのファイル専用に新設した）へ包んで rethrow し、reselectSource側の外側catch
// （queue.run自身のキャンセルチェックでperformReselectが一度も実行されなかった窓の安全網）との
// 二重登録を防ぐ。

/// `performReselect`（手順1〜2。単一 `queue.run` の op）が実際に実行され、自前で後始末
/// （registerOrphan）を終えたうえで rethrow したことを示す内部マーカー。
///
/// `SourceImportCoordinator.swift` の `ImportFailureAlreadyHandled` と同型・同じ役割（doc コメント
/// 参照）。`reselectSource` 側の外側 catch は「`queue.run` 自身のキャンセルチェックで
/// `performReselect` が一度も実行されなかった」場合にだけ importedFile を registerOrphan する
/// 安全網であり、`performReselect` が実際に走って（すでに後始末済みの）場合にまで同じ登録を
/// やり直すと二重登録になる。後始末を終えた `performReselect` は必ずこの型へ包んで rethrow し、
/// 外側 catch は型で確実に区別する。
private struct ReselectFailureAlreadyHandled: Error {
    let underlying: Error
}

/// `performReselect`（手順1〜2）の成功結果。手順3・4（削除）が「何を削除すべきか」を判定するのに
/// 必要な情報を呼び出し元（`reselectSource`）へ伝える。`SourceImportCoordinator.swift` の
/// `ImportOutcome` と同じ理由でタプルではなく名前つきの構造体にする。
private struct ReselectOutcome: Sendable {
    /// 手順3で削除する「置換された旧sourceFile」。「なし」側（`WorkingSourceRecord` が存在しない）
    /// には削除すべき旧ファイルが存在しないため nil。
    let replacedSourceFile: WorkingSourceFileRef?
    /// 手順4で削除する「取り込みファイル」。ローダーが `input.importedFile` と同一参照の正規化
    /// ファイルを返した場合は nil（`newlyImportedFileToDelete` 参照）。
    let importedFileToDelete: ManagedFileRef?
}

extension SourceImportCoordinator {
    /// image-pipeline.md 5章「再選択後の Saga」手順1〜4。
    public func reselectSource(projectID: ProjectID, input: PickedPhotoInput) async throws {
        try await recoveryGate.awaitRecoveryCompleted()

        let outcome: ReselectOutcome
        do {
            // 手順1〜2を単一 op として直列化する（ファイル冒頭コメント参照）。
            outcome = try await queue.run {
                try await self.performReselect(projectID: projectID, input: input)
            }
        } catch let error as ReselectFailureAlreadyHandled {
            // performReselect が実際に実行され、自前で後始末（registerOrphan）を終えたうえで
            // rethrow したエラー。ここで importedFile を再度 registerOrphan すると二重登録に
            // なるため、素通しする（`ReselectFailureAlreadyHandled` の doc コメント参照）。
            throw error.underlying
        } catch {
            // performReselect自体が一度も呼ばれなかった場合だけがここへ来る: queue.run自身の
            // キャンセルチェックでCancellationErrorが投げられ、op（performReselect）が実行
            // されない窓（SourceImportCoordinator.swift の importPickedPhoto 外側 catch と同型）。
            // この場合はimportedFileの後始末のみでよい（正規化ファイルはまだ作られていない）。
            try await runCleanupPreservingError(cause: error) {
                try await runShieldedFromCancellation {
                    try await self.queue.run {
                        try await self.maintenanceStore.registerOrphan(input.importedFile)
                    }
                }
            }
        }

        // 手順3・4: 置換された旧sourceFile・取り込みファイルをそれぞれ削除する。どちらか一方が
        // 失敗しても他方の削除を諦めない（ファイル冒頭コメント「Issue #36」参照。W2と同じ
        // 「1件失敗しても残りを試みる」方針を2つの独立した削除操作に当てはめている）。
        // 最初に発生した失敗だけを呼び出し元へ伝える。
        var firstFailure: Error?
        if let replacedSourceFile = outcome.replacedSourceFile {
            do {
                try await deleteReplacedSourceFile(replacedSourceFile)
            } catch {
                firstFailure = error
            }
        }
        if let importedFile = outcome.importedFileToDelete {
            do {
                try await deleteReselectedImportedFile(importedFile)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    /// 手順1〜2本体（分岐判定・load・向き正規化・書き込みを単一 `queue.run` の op として
    /// 実行する。ファイル冒頭コメント参照）。分岐判定（loadWorkingSource）だけをここで行い、
    /// 実際の書き込みは「あり」側・「なし」側それぞれの private メソッドへ委譲する
    /// （50行制限のため）。失敗時は蓄積済みの `createdFiles`（この時点までに実際に working/ へ
    /// 作られたファイルの参照）と importedFile をベストエフォートで registerOrphan へ積む。
    /// 1件が失敗しても残りの登録を試みる（SourceImportCoordinator.swift の performImport W2と
    /// 同型）。すでに `queue.run` の op の内側にいるため registerOrphan は queue を経由せず
    /// 直接呼ぶ（経由すると自己デッドロックする）。
    ///
    /// 後始末を終えた後は必ず `ReselectFailureAlreadyHandled` へ包んで rethrow する
    /// （型の doc コメント参照。`reselectSource` 側の外側catchが「performReselectが一度も
    /// 実行されなかった」場合とを区別するために必須）。
    private func performReselect(
        projectID: ProjectID, input: PickedPhotoInput
    ) async throws -> ReselectOutcome {
        var createdFiles: [ManagedFileRef] = []
        do {
            let loaded = try await pickedPhotoLoader.load(input.importedFile)
            // load成功直後に積む（SourceImportCoordinator.swiftのperformImportと同じ理由。W-b）。
            createdFiles.append(loaded.source.file)
            guard let normalizedSourceFile = WorkingSourceFileRef(loaded.source.file) else {
                throw SourceImportError.invalidNormalizedSourceKind(loaded.source.file)
            }

            let replacedSourceFile: WorkingSourceFileRef?
            if let existing = try await workingSourceStore.loadWorkingSource(for: projectID) {
                try await performReplace(
                    projectID: projectID, input: input, loaded: loaded, normalizedSourceFile: normalizedSourceFile
                )
                replacedSourceFile = replacedSourceFileToDelete(
                    existing: existing, normalizedSourceFile: normalizedSourceFile
                )
            } else {
                try await performAttach(
                    projectID: projectID, input: input, loaded: loaded, normalizedSourceFile: normalizedSourceFile
                )
                replacedSourceFile = nil
            }
            return ReselectOutcome(
                replacedSourceFile: replacedSourceFile,
                importedFileToDelete: newlyImportedFileToDelete(
                    input: input, normalizedSourceFile: normalizedSourceFile
                )
            )
        } catch {
            let snapshot = createdFiles
            do {
                try await runCleanupPreservingError(cause: error) {
                    try await runShieldedFromCancellation {
                        // W2: 1件目（importedFile）が失敗しても2件目（snapshot内の正規化ファイル。
                        // load失敗時は空のまま）の登録を諦めない。
                        var firstFailure: Error?
                        for file in [input.importedFile] + snapshot {
                            do {
                                try await self.maintenanceStore.registerOrphan(file)
                            } catch {
                                if firstFailure == nil { firstFailure = error }
                            }
                        }
                        if let firstFailure { throw firstFailure }
                    }
                }
            } catch {
                throw ReselectFailureAlreadyHandled(underlying: error)
            }
        }
    }

    /// 手順3で削除する「置換された旧sourceFile」を決める。新しい正規化ファイルと同一実体の場合は
    /// 削除対象から外す。Persistence層のガード（WorkingSourceStoreLive+Replace.swift:93-103、
    /// applyWorkingSourceReplacementの「旧sourceFileIDが新sourceFileIDと同一の場合は登録しない」
    /// 判定）と同じ基準をApplication層でも適用する（PickedPhotoLoader.loadの契約
    /// （Domain/Ports/ImagePipeline.swift）には「既存素材と異なるファイルIDを返す」保証が無く、
    /// 同一IDが返る可能性を排除できないため）。ここで判定を怠ると、DB上は新しい
    /// WorkingSourceRecordが有効なまま実体ファイルだけを削除してしまい、再編集不能になる
    /// データ損失事故になる。
    ///
    /// 同一性判定は fileID だけでなく `ManagedFileRef` 全体（kind + fileID。
    /// isDistinctManagedFile、ManagedFileIdentity.swift）で行う（codex レビュー W-1。
    /// SourceImportCoordinator.swift の importedFileToDelete と同じ基準へ揃える。S-1）。
    /// `existing.sourceFile.ref` / `normalizedSourceFile.ref` はいずれも `WorkingSourceFileRef` の
    /// 型制約により常に `.processingTemporary` に固定されるため、この呼び出し元では kind が
    /// 一致しない組み合わせは現状発生しない。それでも fileID のみの比較のままにせず判定基準を
    /// 揃えるのは、削除可否判定という同一の意味を持つロジックを2箇所に別々の粒度で持たせない
    /// ため（S-1の趣旨。将来 `WorkingSourceFileRef` の kind 制約が緩んだ場合の防御にもなる）。
    ///
    /// 上記「Persistence層のガードと同じ基準」について: Persistence側
    /// （WorkingSourceStoreLive+Replace.swift）はkindが `.processingTemporary` に固定された文脈での
    /// fileID比較であり、実質は同一の基準である。Application層はkind非固定の値
    /// （`PickedPhotoInput.importedFile` は任意kindを受理する）を扱うため、fileIDだけでなく参照
    /// 全体（kind + fileID）で比較する必要がある。この違いを見落として「Persistenceに合わせよう」と
    /// fileIDのみの比較へ戻すと、W-1（同一UUID・異なるkindの誤同一視）を再導入することになるため
    /// 注意する。
    private func replacedSourceFileToDelete(
        existing: WorkingSourceRecord, normalizedSourceFile: WorkingSourceFileRef
    ) -> WorkingSourceFileRef? {
        isDistinctManagedFile(existing.sourceFile.ref, from: normalizedSourceFile.ref) ? existing.sourceFile : nil
    }

    /// 手順4で削除する「取り込みファイル」（`input.importedFile`）を決める。判定基準は
    /// 上の `replacedSourceFileToDelete` および `SourceImportCoordinator.swift` の
    /// `importedFileToDelete` と同じ（`isDistinctManagedFile`。kind + fileID の完全一致で判定する。
    /// 判定基準の詳細な根拠はいずれかの doc コメント参照）: ローダーが返した正規化後ファイルと
    /// 同一実体の場合は削除対象から外す。ここで判定を怠ると、DB上は新しい WorkingSourceRecord が
    /// 有効なまま実体ファイル（normalizedSourceFile そのもの）を手順4が削除してしまい、
    /// 再編集不能になるデータ損失事故になる。
    ///
    /// `SourceImportCoordinator.swift` の `importedFileToDelete` と同名にしていない: 同じ actor を
    /// 別ファイルの extension で拡張しているため、同名・同シグネチャの private メソッドが
    /// 2ファイルに存在すると読み手が「どちらが呼ばれているか」を混同しうる（ファイル冒頭コメント
    /// 「Issue #36」参照）。
    private func newlyImportedFileToDelete(
        input: PickedPhotoInput, normalizedSourceFile: WorkingSourceFileRef
    ) -> ManagedFileRef? {
        isDistinctManagedFile(input.importedFile, from: normalizedSourceFile.ref) ? input.importedFile : nil
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
    /// PendingFileDeletion へ積む」）。SourceImportCoordinator.swift の deleteImportedFile と
    /// 同型（詳細な理由はそちらの doc コメント参照）: registerOrphan が成功すれば削除失敗は
    /// Saga全体の失敗にしない（手順2で既にコミット済みのため、これはベストエフォートの
    /// 後始末）。registerOrphanも失敗した場合のみ、削除失敗の理由を保持したままthrowする。
    /// DB書き込みを伴う後始末のため runShieldedFromCancellation（Cleanup.swift）で包み、
    /// 呼び出し元がキャンセル済みでも完走させる。
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

    /// 手順4。削除に失敗したら registerOrphan で積む（正本「削除に失敗したら
    /// PendingFileDeletion へ積む」）。上の deleteReplacedSourceFile・
    /// SourceImportCoordinator.swift の deleteImportedFile と同型（詳細な理由はいずれかの
    /// doc コメント参照）: registerOrphan が成功すれば削除失敗はSaga全体の失敗にしない
    /// （手順2で既にコミット済みのため、これはベストエフォートの後始末）。registerOrphanも
    /// 失敗した場合のみ、削除失敗の理由を保持したままthrowする。DB書き込みを伴う後始末のため
    /// runShieldedFromCancellation（Cleanup.swift）で包み、呼び出し元がキャンセル済みでも
    /// 完走させる。
    private func deleteReselectedImportedFile(_ importedFile: ManagedFileRef) async throws {
        do {
            try await queue.run {
                try await self.managedFileStore.delete(importedFile)
            }
        } catch let deleteError {
            do {
                try await runShieldedFromCancellation {
                    try await self.queue.run {
                        try await self.maintenanceStore.registerOrphan(importedFile)
                    }
                }
            } catch let registerOrphanError {
                throw CleanupPreservingError(cause: deleteError, cleanupFailure: registerOrphanError)
            }
        }
    }
}
