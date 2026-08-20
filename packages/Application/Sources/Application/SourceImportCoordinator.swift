import Foundation
import Domain

// SourceImportCoordinator — 素材取り込み（インポート）Saga（Issue #8 サブプロジェクト5 A2
// Task 2）。
//
// 正本: image-pipeline.md 5章「インポートSaga」（手順1〜4）・「実装の所在」
// （WorkingSourceStore プロトコル）、architecture.md 4.2「排他区間の実装規則」・
// 4.3「Application 層」（起動時復旧ゲートと単一直列キューの利用規約）。
//
// 手順1〜2（EXIF 読み取り・向き正規化・working/ への書き込み）は PickedPhotoLoader.load(_:) へ
// 完全に委譲する（実装は MediaKit、このサブプロジェクトのスコープ外）。
//
// キュー境界（reviewer 一次レビュー W1 の反映）: load は working/ へ新規ファイルを書き込む
// 変更操作であり読み取り専用ではないため、architecture.md 4.2「変更を伴うすべての操作は
// 単一のグローバル直列キュー1本で直列化する」に従い、手順1〜3（load・正規化・
// createProjectWithWorkingSource）をまとめて単一の `queue.run` の op として実行する
// （performImport。ExportCoordinator+Generate.swift の performGeneration が
// render/encode という同じくファイル生成を伴う手順を単一 op にまとめているのと対称）。
// 手順4（取り込みファイルの削除）は performImport の完了後に別の `queue.run` 呼び出しとして
// 直列化する（deleteImportedFile）。同一 `queue.run` の op の内側から再度 `queue.run` を呼ぶと
// 自己デッドロックするため、performImport 内側の失敗後始末（registerOrphan）は queue を経由
// せず直接 maintenanceStore を呼ぶ。importPickedPhoto 側の外側 catch（queue.run 自身の
// キャンセルチェックで performImport が一度も走らない窓の安全網）だけは queue.run 経由で呼ぶ
// （ExportCoordinator+Generate.swift の外側 catch と同型。W1）。`recoveryGate` はキュー投入前
// （このメソッド冒頭）で待つ（キュー内で待つと復旧側の操作がキューを取れず自己デッドロックする。
// Global Constraints）。
//
// 後始末の失敗の扱い:
// - 手順1〜3（performImport）が失敗した場合: その時点までに作られたファイル（load 成功後の
//   正規化ファイル）と importedFile をベストエフォートで registerOrphan へ積む。1件が失敗しても
//   残りの登録は試みる（reviewer 指摘 W2。片方だけ失敗した場合の集約は、次段落のとおり
//   CleanupPreservingError が最初の失敗のみ保持する現行仕様のままで許容する）。この後始末の
//   成否に関わらず、手順1〜3の元エラーを最優先で throw する（Cleanup.swift の
//   runCleanupPreservingError。Saga 全体が失敗しているため、呼び出し元には必ず元の失敗理由が
//   伝わらなければならない）。load 自体が失敗した場合も importedFile の所有権を手放さず
//   registerOrphan へ積む（reviewer 指摘 W3。正規化ファイルはまだ作られていないためこちらのみ）。
// - 手順4（削除）が失敗した場合: registerOrphan へ積む。Project・WorkingSourceRecord は既に
//   手順3でコミット済みのため、この後始末はベストエフォートであり、成功すれば
//   importPickedPhoto 全体は成功として返す（削除失敗自体は Saga の失敗ではない。正本
//   「削除に失敗したら PendingFileDeletion へ積む」）。ただし registerOrphan 自体も失敗した
//   場合は、削除失敗の理由を握りつぶさず CleanupPreservingError へ包んで両方伝える
//   （Global Constraints「エラーの握りつぶし禁止」）。
//
// キャンセルシールド: 上記いずれの registerOrphan 呼び出しも、DB 書き込み（PendingFileDeletion
// への登録）を伴うため runShieldedFromCancellation（Cleanup.swift）で包む。呼び出し元が
// キャンセルされていても、これらの後始末は完走させる。
//
// 【手順4の削除可否判定】PickedPhotoLoader.load（Domain/Ports/ImagePipeline.swift）の契約には
// 「入力（importedFile）と異なるファイルIDを返す」保証が無い。同一IDが返った場合、手順4が
// importedFile を無条件削除すると、手順3で作った WorkingSourceRecord が指す実体（正規化後
// ファイルそのもの）を削除してしまい、再編集不能になるデータ損失事故になる。performImport は
// この判定（importedFileToDelete ヘルパー）を行い、同一IDなら削除対象なし（nil）を返す。
// SourceImportCoordinator+Reselect.swift の replacedSourceFileToDelete と同型のガード
// （両ファイルとも Persistence 側の同じガード、WorkingSourceStoreLive+Replace.swift:93-103、を
// 参照している）。
//
// 【実装中の判断: queueItemID / batchID】importPickedPhoto は PickedPhotoInput のみを受け取り
// バッチ関連の引数を持たない（計画書 147行目）ため、両方とも nil を渡す。
// packages/Persistence/Sources/Persistence/WorkingSourceStoreLive.swift の
// `WorkingSourceStoreError.batchIDMissingForQueueItem` は「queueItemID が非nilなのに
// batchID が nil」の組み合わせのみを契約違反として拒否しており、両方 nil はこの制約に
// 抵触しない。単体インポートで queueItemID を必ず新規発行するという規約は正本のどこにも
// 無いため、推測で仕様を拡張しない。この帰結として、この Saga 単体では ExportQueueItem が
// 作られず、取り込んだ写真は書き出しキューに載らない（キューへ載せる操作は別 Saga の責務。
// reviewer 指摘 S7）。
//
// 【実装中の判断: initialSpec のプレースホルダー】CreateWorkingSourceInput.initialSpec は
// EffectSetting/FaceTrack への展開（Issue #25 待ち）まではこの Saga のスコープ外だが、
// 型としては必須のため、「まだ何も編集・検出されていない」状態を表す最小の RenderSpec
// （全面クロップ・fit・背景なし・regions 空）を渡す。WorkingSourceStoreLive はこの値を
// 意図的に使わない契約（WorkingSourceStoreLive+Create.swift 冒頭コメント）のため、
// この Saga の外からは無害である。

/// `PickedPhotoLoader.load` が契約に反した種別のファイルを返した場合の診断用エラー
/// （MediaKit 実装の契約違反の検出。ここで検出しないと `WorkingSourceFileRef` を構築できず、
/// 型不整合のまま DB 書き込みへ進んでしまう）。
public enum SourceImportError: Error, Sendable, Equatable {
    case invalidNormalizedSourceKind(ManagedFileRef)
}

/// `performImport`（手順1〜3。単一 `queue.run` の op）が実際に実行され、自前で後始末
/// （registerOrphan）を終えたうえで rethrow したことを示す内部マーカー。
///
/// `importPickedPhoto` 側の外側 catch は「`queue.run` 自身のキャンセルチェックで
/// performImport が一度も実行されなかった」場合にだけ importedFile を registerOrphan する
/// 安全網であり、performImport が実際に走って（すでに importedFile を含め後始末済みの）
/// 場合にまで同じ登録をやり直すと二重登録になる。`performImport` が投げうるエラーの型
/// （呼び出し元の業務エラーや、たまたま素の `CancellationError` になるケースも含む）だけを
/// 見て「未実行」と「実行済みで後始末済み」を判別するのは信頼できない
/// （素の `CancellationError` はどちらのケースでも起こりうる）ため、後始末を終えた
/// performImport は必ずこの型へ包んで rethrow し、外側 catch は型で確実に区別する。
private struct ImportFailureAlreadyHandled: Error {
    let underlying: Error
}

/// `performImport`（手順1〜3）の成功結果。手順4（削除）が「何を削除すべきか」を判定するのに
/// 必要な情報を呼び出し元（`importPickedPhoto`）へ伝える。`importedFileToDelete` が nil の場合、
/// 削除すべき取り込みファイルは存在しない（`importedFileToDelete(input:normalizedSourceFile:)`
/// 参照）。タプル `(ProjectID, ManagedFileRef?)` でも `queue.run` の `T: Sendable` 制約は満たせるが、
/// フィールド名が無いと「削除対象の有無」という意味が呼び出し側で読み取れないため、名前つきの
/// 構造体にする。
private struct ImportOutcome: Sendable {
    let projectID: ProjectID
    let importedFileToDelete: ManagedFileRef?
}

public actor SourceImportCoordinator {
    // Task 3（SourceImportCoordinator+Reselect.swift）が同じ actor を extension で拡張し、
    // これらのプロパティへ触れる。Swift の private はファイルスコープのため、別ファイルの
    // extension からはアクセスできない。internal（既定アクセスレベル）へ揃える
    // （ExportCoordinator.swift の queue / recoveryGate / now が同じ理由で internal になっており、
    // ExportCoordinator+Generate.swift 等の extension ファイルから触れているのと同じ方針）。
    let pickedPhotoLoader: PickedPhotoLoader
    let workingSourceStore: WorkingSourceStore
    let managedFileStore: ManagedFileStore
    let maintenanceStore: MaintenanceStore
    let now: @Sendable () -> Date
    let queue: SerialTaskQueue
    /// 起動時復旧の完了ゲート。変更系操作はキュー投入前にこれを待つ（architecture.md 4.3
    /// 「完了まで他のすべてを開始させない」）。
    let recoveryGate: RecoveryGate

    public init(
        pickedPhotoLoader: PickedPhotoLoader,
        workingSourceStore: WorkingSourceStore,
        managedFileStore: ManagedFileStore,
        maintenanceStore: MaintenanceStore,
        now: @escaping @Sendable () -> Date,
        queue: SerialTaskQueue,
        recoveryGate: RecoveryGate
    ) {
        self.pickedPhotoLoader = pickedPhotoLoader
        self.workingSourceStore = workingSourceStore
        self.managedFileStore = managedFileStore
        self.maintenanceStore = maintenanceStore
        self.now = now
        self.queue = queue
        self.recoveryGate = recoveryGate
    }

    /// image-pipeline.md 5章「インポート Saga」手順1〜4。
    public func importPickedPhoto(_ input: PickedPhotoInput) async throws -> ProjectID {
        try await recoveryGate.awaitRecoveryCompleted()

        let outcome: ImportOutcome
        do {
            // 手順1〜3を単一 op として直列化する（W1。ファイル冒頭コメント参照）。
            outcome = try await queue.run {
                try await self.performImport(input)
            }
        } catch let error as ImportFailureAlreadyHandled {
            // performImport が実際に実行され、自前で後始末（registerOrphan）を終えたうえで
            // rethrow したエラー。ここで importedFile を再度 registerOrphan すると二重登録に
            // なるため、素通しする（`ImportFailureAlreadyHandled` の doc コメント参照）。
            throw error.underlying
        } catch {
            // performImport 自体が一度も呼ばれなかった場合だけがここへ来る: queue.run 自身の
            // キャンセルチェック（投入前・取り出し直前。SerialTaskQueue.run 参照）で
            // CancellationError が投げられ、op（performImport）が実行されない窓
            // （ExportCoordinator+Generate.swift の同型コメント参照）。この場合は
            // importedFile の後始末のみでよい（正規化ファイルはまだ作られていない）。
            try await runCleanupPreservingError(cause: error) {
                try await runShieldedFromCancellation {
                    try await self.queue.run {
                        try await self.maintenanceStore.registerOrphan(input.importedFile)
                    }
                }
            }
        }

        // 手順4: 取り込みファイルを削除する。ローダーが input.importedFile と同一IDの正規化
        // ファイルを返した場合（PickedPhotoLoader.load の契約には異なるIDを返す保証が無い。
        // `importedFileToDelete(input:normalizedSourceFile:)` 参照）、削除すべき取り込みファイルは
        // 存在しない。再選択Saga（SourceImportCoordinator+Reselect.swift の reselectSource、
        // `guard let replacedSourceFile else { return }`）と同型の書き方に揃える。
        guard let fileToDelete = outcome.importedFileToDelete else { return outcome.projectID }
        try await deleteImportedFile(fileToDelete)
        return outcome.projectID
    }

    /// 手順1〜3本体（load・向き正規化・createProjectWithWorkingSource を単一 `queue.run` の
    /// op として実行する。W1）。失敗時は蓄積済みの `createdFiles`（この時点までに実際に
    /// working/ へ作られたファイルの参照）と importedFile をベストエフォートで registerOrphan
    /// へ積む。1件が失敗しても残りの登録を試みる（W2）。すでに `queue.run` の op の内側にいるため
    /// registerOrphan は queue を経由せず直接呼ぶ（経由すると自己デッドロックする）。
    ///
    /// 後始末を終えた後は必ず `ImportFailureAlreadyHandled` へ包んで rethrow する
    /// （`ImportFailureAlreadyHandled` の doc コメント参照。importPickedPhoto 側の外側 catch が
    /// 「performImport が一度も実行されなかった」場合とを区別するために必須。単に元エラーを
    /// そのまま rethrow すると、たとえば workingSourceStore 呼び出しがたまたま素の
    /// `CancellationError` を投げるケースで、外側 catch が「queue.run 自身のキャンセル
    /// チェックで performImport が未実行だった」と誤認し、importedFile を二重に
    /// registerOrphan してしまう）。
    private func performImport(_ input: PickedPhotoInput) async throws -> ImportOutcome {
        var createdFiles: [ManagedFileRef] = []
        do {
            // 手順1〜2: EXIF 読み取り・向き正規化・working/ への書き込みはローダーへ完全委譲する。
            let loaded = try await pickedPhotoLoader.load(input.importedFile)
            // load 成功直後に積む（reviewer 二次レビュー W-b）。load が成功した時点で
            // loaded.source.file の実体はすでに working/ へ書き込まれているため、この後の
            // kind 検証（次の guard）が失敗しても、その後の createProjectWithWorkingSource が
            // 失敗しても、後始末の対象から漏らさない（W3 と対称）。
            createdFiles.append(loaded.source.file)
            guard let normalizedSourceFile = WorkingSourceFileRef(loaded.source.file) else {
                throw SourceImportError.invalidNormalizedSourceKind(loaded.source.file)
            }

            let projectID = ProjectID(rawValue: UUID())
            let createInput = CreateWorkingSourceInput(
                projectID: projectID,
                batchID: nil,
                queueItemID: nil,
                sourceFile: normalizedSourceFile,
                createdAt: now(),
                sourceLocator: ProjectSourceLocator(photoLibraryLocalIdentifier: input.providerAssetIdentifier),
                capture: loaded.capture,
                libraryCreationDate: input.libraryCreationDate,
                representation: input.representation,
                initialSpec: defaultInitialRenderSpec()
            )

            // 手順3: 単一 DB トランザクションで Project・キュー項目・WorkingSourceRecord を作成する。
            try await workingSourceStore.createProjectWithWorkingSource(createInput)
            return ImportOutcome(
                projectID: projectID,
                importedFileToDelete: importedFileToDelete(input: input, normalizedSourceFile: normalizedSourceFile)
            )
        } catch {
            let snapshot = createdFiles
            do {
                try await runCleanupPreservingError(cause: error) {
                    try await runShieldedFromCancellation {
                        // W2: 1件目（importedFile）が失敗しても2件目（snapshot 内の正規化
                        // ファイル。load 失敗時は空のまま）の登録を諦めない。最初に発生した
                        // 失敗だけを cleanupFailure として保持する（CleanupPreservingError の
                        // 現行仕様どおり）。
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
                throw ImportFailureAlreadyHandled(underlying: error)
            }
        }
    }

    /// 手順4で削除する「取り込みファイル」を決める。ローダーが返した正規化後ファイルと同一実体の
    /// 場合は削除対象から外す。再選択Saga（SourceImportCoordinator+Reselect.swift の
    /// replacedSourceFileToDelete、98-127行目）・Persistence層のガード
    /// （WorkingSourceStoreLive+Replace.swift:93-103、applyWorkingSourceReplacementの
    /// 「旧sourceFileIDが新sourceFileIDと同一の場合は登録しない」判定）と同じ基準をここでも
    /// 適用する（PickedPhotoLoader.load の契約（Domain/Ports/ImagePipeline.swift）には
    /// 「入力と異なるファイルIDを返す」保証が無く、同一IDが返る可能性を排除できないため）。
    /// ここで判定を怠ると、DB上は新しい WorkingSourceRecord が有効なまま実体ファイル
    /// （normalizedSourceFile そのもの）を手順4が削除してしまい、再編集不能になるデータ損失
    /// 事故になる。
    ///
    /// 同一性判定は fileID だけでなく `ManagedFileRef` 全体（kind + fileID。
    /// isDistinctManagedFile、ManagedFileIdentity.swift）で行う（codex レビュー W-1）。
    /// `input.importedFile` は kind 制約の無い `ManagedFileRef`（PickedPhotoInput の契約）であり、
    /// `normalizedSourceFile.ref` は常に `.processingTemporary` に固定されている
    /// （WorkingSourceFileRef の型制約）ため、「同一UUID・異なるkind」の入力を fileID だけで
    /// 判定すると同一実体と誤認し、削除すべき別実体（多くは起動時GCの対象だが
    /// `.historyThumbnail` はGC対象外）を削除し損ね孤児ファイル化する。
    ///
    /// 上記「Persistence層のガードと同じ基準」について: Persistence側
    /// （WorkingSourceStoreLive+Replace.swift）はkindが `.processingTemporary` に固定された文脈での
    /// fileID比較であり、実質は同一の基準である。Application層はkind非固定の値
    /// （`PickedPhotoInput.importedFile` は任意kindを受理する）を扱うため、fileIDだけでなく参照
    /// 全体（kind + fileID）で比較する必要がある。この違いを見落として「Persistenceに合わせよう」と
    /// fileIDのみの比較へ戻すと、W-1（同一UUID・異なるkindの誤同一視）を再導入することになるため
    /// 注意する。
    private func importedFileToDelete(
        input: PickedPhotoInput, normalizedSourceFile: WorkingSourceFileRef
    ) -> ManagedFileRef? {
        isDistinctManagedFile(input.importedFile, from: normalizedSourceFile.ref) ? input.importedFile : nil
    }

    /// 手順4。削除に失敗したら registerOrphan で積む（正本「削除に失敗したら
    /// PendingFileDeletion へ積む」）。registerOrphan 自体が成功すれば削除失敗は Saga 全体の
    /// 失敗にしない（Project は手順3で既にコミット済みのため、これはベストエフォートの後始末）。
    /// registerOrphan も失敗した場合のみ、削除失敗の理由を保持したまま throw する
    /// （Global Constraints「エラーの握りつぶし禁止」）。
    ///
    /// 呼び出し元がキャンセルされている場合、最初の `queue.run`（`managedFileStore.delete`）は
    /// `CancellationError` をそのまま素通しすることがある: `SerialTaskQueue.run` はキュー投入前・
    /// 取り出し直前の2箇所で `Task.checkCancellation()` を行い（SerialTaskQueue.swift）、
    /// いずれかで検出すれば `managedFileStore.delete` 自体は一度も呼ばれず素の
    /// `CancellationError` が deleteError として届く。この場合も後始末（registerOrphan）は
    /// スキップしない: `runShieldedFromCancellation` が非構造化 Task 内でキャンセル非伝播の
    /// コンテキストへ包むため、2つ目の `queue.run`（registerOrphan）は影響を受けず完走する
    /// （OutputDeliveryCoordinator.swift の `saveToPhotoLibrary` doc コメントの
    /// `SerialTaskQueue.run` の `onCancel: { current.cancel() }` に関する記述と同型。S5）。
    private func deleteImportedFile(_ importedFile: ManagedFileRef) async throws {
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

    /// initialSpec のプレースホルダー。まだ何も編集・検出されていない新規プロジェクトの
    /// 「無加工」状態を表す（sourceCrop 全面・regions 空）。ファイル冒頭コメント参照。
    /// `NormalizedRect(0,0,1,1)` はリテラル定数のみで構成され、finite・left<right・
    /// top<bottom・絶対値16以下のすべての検査を常に満たすため失敗しえない（S1。
    /// ValidatedValues.swift の NormalizedRect.init 参照）。
    private func defaultInitialRenderSpec() -> RenderSpec {
        RenderSpec(
            // 上記doc コメントのとおりリテラル定数のみで構成され失敗しえない。
            // swiftlint:disable:next force_try
            sourceCrop: try! NormalizedRect(left: 0, top: 0, rightExclusive: 1, bottomExclusive: 1),
            scaleMode: .fit,
            background: .none,
            regions: []
        )
    }
}
