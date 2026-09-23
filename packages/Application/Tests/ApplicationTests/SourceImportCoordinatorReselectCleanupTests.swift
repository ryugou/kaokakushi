import Testing
import Foundation
import Domain
@testable import Application

// SourceImportCoordinator.reselectSource（再選択・再接続 Saga。Issue #8 サブプロジェクト5 A2
// Task 3・Task 4）手順3・4（削除・後始末）の検証（Issue #36）。
//
// 正本: image-pipeline.md 5章「再選択後の Saga」手順3「置換された旧sourceFileを削除する
// （失敗したらPendingFileDeletionへ積む）」・手順4「取り込みファイル
// （PickedPhotoInput.importedFile）を削除する（削除に失敗したらPendingFileDeletionへ積む）」・
// 「手順3・4とも、削除候補がローダーの返した正規化後ファイルと同一のManagedFileRefであれば
// 削除しません」。
//
// SourceImportCoordinatorReselectTests.swiftから分離した（そちらに追記するとファイル400行制限
// 〈Global Constraints〉を超えるため。SourceImportCoordinatorImportTests.swift /
// SourceImportCoordinatorImportCleanupTests.swiftの分割と同じ理由）。
//
// 手順4固有（procedure4単体）の削除失敗経路は、「なし」側（WorkingSourceRecordが存在せず
// attachWorkingSourceToExistingProjectを呼ぶ分岐）を使って検証する。「なし」側には手順3
// （旧sourceFileの削除）が存在しないため、FakeManagedFileStore.setDeleteFailureが手順4の
// 削除だけに影響し、手順3の副作用と混ざらずに手順4単体の挙動を検証できる
// （「あり」側では手順3・4の両方が同時に削除失敗の影響を受けるため、単体の切り分けができない）。
// 「あり」側での手順3・4同時失敗（両方試みる方針の検証）は
// SourceImportCoordinatorReselectTests.swift 側（reselectSucceedsWhenDeleteFailsBut
// RegisterOrphanSucceeds 等）が担う。

@Test("「なし」側: 手順4の削除が失敗してもregisterOrphanが成功すれば再選択全体は成功する")
func reselectAttachSucceedsWhenImportedFileDeleteFailsButRegisterOrphanSucceeds() async throws {
    struct DeleteBoom: Error, Equatable {}

    let projectID = makeProjectID()
    let store = FakeWorkingSourceStore()
    // seedWorkingSourceを呼ばない = WorkingSourceRecordが無い状態（「なし」側の分岐。手順3が
    // 存在しないため手順4単体の削除失敗経路を検証できる。ファイル冒頭コメント参照）。
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.setDeleteFailure(DeleteBoom())
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: FakePickedPhotoLoader(),
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )
    let input = makePickedPhotoInput()

    // 手順2は成功しているため、手順4の削除失敗はSaga全体を失敗させない（正本「削除に失敗したら
    // PendingFileDeletionへ積む」）。throwせず正常に完了することそのものが不変条件の主張であり、
    // ここでcatchせずtry awaitするのが検証になる。
    try await coordinator.reselectSource(projectID: projectID, input: input)

    #expect(await store.attachToExistingProjectCalls.count == 1)
    #expect(await maintenanceStore.registerOrphanCalls == [input.importedFile])
}

@Test("「なし」側: 手順4の削除もregisterOrphanも失敗したら削除失敗の理由をcauseに保持したままthrowする")
func reselectAttachThrowsCleanupPreservingErrorWhenImportedFileDeleteAndRegisterOrphanBothFail() async throws {
    struct DeleteBoom: Error, Equatable {}
    struct RegisterOrphanBoom: Error, Equatable {}

    let projectID = makeProjectID()
    let store = FakeWorkingSourceStore()
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.setDeleteFailure(DeleteBoom())
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    await maintenanceStore.setRegisterOrphanFailure(RegisterOrphanBoom())
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: FakePickedPhotoLoader(),
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )
    let input = makePickedPhotoInput()

    do {
        try await coordinator.reselectSource(projectID: projectID, input: input)
        Issue.record("エラーがthrowされるはずだった")
    } catch let error as CleanupPreservingError {
        // 削除失敗（真因）を優先して保持する。registerOrphan自体の失敗理由も失わない
        // （Global Constraints「エラーの握りつぶし禁止」）。
        #expect(error.cause is DeleteBoom)
        #expect(error.cleanupFailure is RegisterOrphanBoom)
    } catch {
        Issue.record("想定外のエラー: \(error)")
    }
}

// MARK: - 削除可否の判定そのものの検証（削除失敗時の後始末ではない）
//
// SourceImportCoordinatorImportCleanupTests.swift の importDoesNotDeleteWhenLoaderReturnsSameSourceFileID
// と同型の欠陥が手順4にも起こりうる: PickedPhotoLoader.load（Domain/Ports/ImagePipeline.swift）の
// 契約には「入力と異なる参照を返す」保証が無い。手順4がinput.importedFileを無条件に削除すると、
// ローダーが同一参照を返した場合、手順2で作ったWorkingSourceRecordが指す実体
// （正規化後ファイルそのもの）を手順4が削除してしまい、再編集不能になるデータ損失事故になる。

@Test("手順4はローダーが取り込みファイルと同一参照の正規化ファイルを返した場合は削除しない")
func reselectAttachDoesNotDeleteImportedFileWhenLoaderReturnsSameFile() async throws {
    let projectID = makeProjectID()
    let input = makePickedPhotoInput()
    // ローダーがinput.importedFileと同一参照のImageSourceを返す状況を模す（PickedPhotoLoader.load
    // の契約には異なる参照を返す保証が無いため、この状況を排除できない。上記MARKコメント参照）。
    let photo = LoadedPhoto(
        source: ImageSource(file: input.importedFile, pixelSize: makePixelSize(), format: .jpeg),
        capture: makeLoadedPhoto().capture
    )
    let loader = FakePickedPhotoLoader(result: photo)
    let store = FakeWorkingSourceStore()
    // seedWorkingSourceを呼ばない = WorkingSourceRecordが無い状態（「なし」側の分岐。手順3が
    // 存在しないため手順4単体の判定を検証できる）。
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )

    try await coordinator.reselectSource(projectID: projectID, input: input)

    // 書き込み（手順2）は同一参照でも通常どおり行われる。ガードが対象にするのは手順4の削除判定
    // のみである。
    let calls = await store.attachToExistingProjectCalls
    #expect(calls.count == 1)
    #expect(calls.first?.sourceFile.ref == input.importedFile)

    // 本体: 削除してはならない。削除すると新しいWorkingSourceRecordが指す実体そのものが
    // 消え、再編集不能になる。
    #expect(await managedFileStore.deleteCalls.isEmpty)
    // 削除しない＝失敗もしていないため後始末（registerOrphan）も発生しない。
    #expect(await maintenanceStore.registerOrphanCalls.isEmpty)
}

// MARK: - 不変条件5（C-1）: ローダーが既存sourceFileと同一IDを返しても実体を削除しない
//
// codex レビュー Critical 1: PickedPhotoLoader.load（Domain/Ports/ImagePipeline.swift）の契約には
// 「既存素材と異なるファイルIDを返す」保証が無い。既存のWorkingSourceRecordが指すsourceFileIDと、
// 今回ローダーが返した正規化ファイルのIDが偶然一致した場合、手順3で無条件に「旧sourceFile」として
// 削除すると、DB上は新しいWorkingSourceRecordが有効なまま実体ファイルだけを消してしまい、
// 再編集不能になる致命的なデータ損失事故になる。Persistence層
// （WorkingSourceStoreLive+Replace.swift:93-103）は既にこの状況を「新旧が同一なら登録しない」
// ガードで防いでおり、SourceImportCoordinator+Reselect.swift の replacedSourceFileToDelete が
// Application層で同じ判定を行う（本テストはそのガードの回帰テスト）。
//
// Issue #36: input.importedFile（今回選び直した写真そのもの）は既存sourceFileとは無関係な別実体
// であり続けるため、旧sourceFileの削除が起きない（ガードが働く）一方で、取り込みファイルの
// 削除（手順4）は通常どおり実行される。deleteCalls が空になる旧仕様のアサーションをそのまま
// 残すと、手順4の削除が正しく動いていないことを覆い隠してしまうため、
// deleteCalls == [input.importedFile] へ更新した。

@Test("再選択でローダーが既存sourceFileと同一IDを返しても実体ファイルを削除しない")
func reselectDoesNotDeleteWhenLoaderReturnsSameSourceFileID() async throws {
    let projectID = makeProjectID()
    let existingSourceFile = try #require(
        WorkingSourceFileRef(ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID())))
    )
    let store = FakeWorkingSourceStore()
    await store.seedWorkingSource(
        WorkingSourceRecord(projectID: projectID, sourceFile: existingSourceFile, createdAt: makeFixedClock()())
    )
    // ローダーが既存sourceFileと同一IDのImageSourceを返す状況を模す（PickedPhotoLoaderの
    // 契約には異なるIDを返す保証が無いため、この状況を排除できない。上記コメント参照）。
    let photo = LoadedPhoto(
        source: ImageSource(file: existingSourceFile.ref, pixelSize: makePixelSize(), format: .jpeg),
        capture: makeLoadedPhoto().capture
    )
    let loader = FakePickedPhotoLoader(result: photo)
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.seedExistingFile(existingSourceFile.ref)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        managedFileStore: managedFileStore
    )
    let input = makePickedPhotoInput()

    try await coordinator.reselectSource(projectID: projectID, input: input)

    // 書き込み（手順2）は同一IDでも通常どおり行われる。ガードが対象にするのは手順3の削除判定
    // のみである。
    let calls = await store.replaceWorkingSourceCalls
    #expect(calls.count == 1)
    #expect(calls.first?.newSourceFile.ref == existingSourceFile.ref)

    // C-1本体: 旧sourceFileを削除してはならない。削除すると新しいWorkingSourceRecordが指す
    // 実体そのものが消え、再編集不能になる。一方でinput.importedFile（旧sourceFileとは無関係な
    // 別実体）は手順4により通常どおり削除される（Issue #36。上記コメント参照）。
    #expect(await managedFileStore.deleteCalls == [input.importedFile])
    // W-1: FakeWorkingSourceStoreが模すPendingFileDeletion相当の記録も、Persistence層のガードと
    // 同じ理由で登録されないことを確認する（本番の挙動を反映した回帰であることの根拠）。
    #expect(await store.pendingFileDeletionFileRefs.isEmpty)
}

// MARK: - W-1回帰テスト（手順4）: 同一UUID・異なるkindは別実体として削除される
//
// SourceImportCoordinatorImportCleanupTests.swift の
// importDeletesWhenLoaderReturnsSameFileIDButDifferentKind と同型。手順3側のkind差回帰
// （existing.sourceFile / normalizedSourceFile はいずれも WorkingSourceFileRef の型制約により
// kind が常に .processingTemporary に固定される）はSagaレベルでは再現不能なため
// ManagedFileIdentityTests.swift 側で検証する。一方、手順4の削除候補 input.importedFile は
// PickedPhotoInput.swift の定義どおり kind 制約の無い ManagedFileRef であり、ローダーが返す
// 正規化後ファイル（同じく .processingTemporary に固定される）とは異なる kind・同一 UUID の
// 参照を模すことがSagaレベルで完全に再現可能である。そのため手順4側の回帰は本ファイルで検証する。

@Test("W-1回帰: 「なし」側の手順4はローダーが取り込みファイルと同一UUID・異なるkindの正規化ファイルを返しても削除する")
func reselectAttachDeletesImportedFileWhenLoaderReturnsSameFileIDButDifferentKind() async throws {
    let sharedFileID = ManagedFileID(rawValue: UUID())
    // 取り込みファイル自体は historyThumbnail 種別（processingTemporary以外なら何でもよいが、
    // GC対象外のkindを選ぶことで削除を怠った場合の実害〈孤児ファイルが永久に残る〉を明確にする。
    // SourceImportCoordinatorImportCleanupTests.swift の同型テストと同じ理由）。
    let input = makePickedPhotoInput(importedFile: ManagedFileRef(kind: .historyThumbnail, fileID: sharedFileID))
    let projectID = makeProjectID()
    let store = FakeWorkingSourceStore()
    // seedWorkingSourceを呼ばない = WorkingSourceRecordが無い状態（「なし」側の分岐。手順3が
    // 存在しないため手順4単体の判定を検証できる。ファイル冒頭コメント参照）。
    // ローダーは同一UUID・.processingTemporaryのImageSourceを返す（WorkingSourceFileRefの型制約上
    // 正規化後ファイルの kind は必ずこれになる）。
    let photo = LoadedPhoto(
        source: ImageSource(
            file: ManagedFileRef(kind: .processingTemporary, fileID: sharedFileID),
            pixelSize: makePixelSize(),
            format: .jpeg
        ),
        capture: makeLoadedPhoto().capture
    )
    let loader = FakePickedPhotoLoader(result: photo)
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )

    try await coordinator.reselectSource(projectID: projectID, input: input)

    // 書き込み（手順2）は正規化後ファイル（.processingTemporary側）で通常どおり行われる。
    let calls = await store.attachToExistingProjectCalls
    #expect(calls.count == 1)
    #expect(calls.first?.sourceFile.ref.fileID == sharedFileID)

    // 本体（W-1）: kindが異なる別実体であるため、取り込みファイル（historyThumbnail側）の
    // 削除が実行される。
    #expect(await managedFileStore.deleteCalls == [input.importedFile])
    // 削除に成功しているため後始末（registerOrphan）は発生しない。
    #expect(await maintenanceStore.registerOrphanCalls.isEmpty)
}

// MARK: - codex レビュー指摘: replacedSourceFileとinput.importedFileが同一参照の場合の冪等性固定

@Test("「あり」側: 旧sourceFileと取り込みファイルが同一参照でも手順3・4の2回削除は冪等に成功する")
func reselectSucceedsWhenReplacedSourceFileAndImportedFileAreSameRef() async throws {
    // codex レビュー指摘: replacedSourceFileとinput.importedFileが同一ManagedFileRefになることを
    // 型・ポート契約は禁止していない。この場合、手順3・4はどちらもsharedFileを削除対象と判定し、
    // managedFileStore.deleteが同じ参照へ2回呼ばれる。本テストが固定するのはApplication層の
    // SourceImportCoordinatorが重複除去をせず同一参照へ2回deleteを呼ぶこと（下記deleteCallsの
    // アサーション）であり、FakeManagedFileStoreを使うため本番アダプタの冪等性そのものはここでは
    // 検証していない（ManagedFileStoreLiveを非冪等に変更してもこのテストは落ちない）。本番
    // アダプタの「実体が無ければ成功扱い」という冪等性は、Persistence側
    // ManagedFileStoreTests.swift の deleteIsIdempotentForMissingFile が正本として固定する。
    let sharedFile = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID()))
    let existingSourceFile = try #require(WorkingSourceFileRef(sharedFile))
    let projectID = makeProjectID()
    let store = FakeWorkingSourceStore()
    await store.seedWorkingSource(
        WorkingSourceRecord(projectID: projectID, sourceFile: existingSourceFile, createdAt: makeFixedClock()())
    )
    // 取り込みファイル（input.importedFile）を旧sourceFileと同一参照にする（本テストの本体）。
    let input = makePickedPhotoInput(importedFile: sharedFile)
    // ローダーが返す正規化後ファイルは makeLoadedPhoto 内の makeImageSource が毎回新しい UUID を
    // 割り当てるため、sharedFile とは自動的に別実体になる（「通常は異なる実体だが型・ポート契約は
    // これを保証しない」というimage-pipeline.md 5章の記述どおりの通常ケース）。
    let loader = FakePickedPhotoLoader(result: makeLoadedPhoto())
    let managedFileStore = FakeManagedFileStore()
    await managedFileStore.seedExistingFile(sharedFile)
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )

    // 本体: 手順3・4がどちらもsharedFileを削除しようとしても例外を投げずに成功する。
    try await coordinator.reselectSource(projectID: projectID, input: input)

    // 手順3（旧sourceFile）・手順4（取り込みファイル）がどちらもsharedFileを削除対象と判定し、
    // 同じ参照へ2回deleteが呼ばれたことを明示的に確認する。
    #expect(await managedFileStore.deleteCalls == [sharedFile, sharedFile])
    // 2回とも削除が成功したため後始末（registerOrphan）は発生しない。
    #expect(await maintenanceStore.registerOrphanCalls.isEmpty)
}

@Test("「なし」側: 手順2失敗時、取り込みファイルと正規化ファイルが同一参照でもregisterOrphanの2回登録は冪等に成功する")
func reselectAttachFailurePreservesErrorWhenImportedFileAndNormalizedFileAreSameRef() async throws {
    // codex レビュー指摘: 手順2失敗時、performReselectのcatchは
    // [input.importedFile] + snapshot（load成功直後に積んだcreatedFiles）をregisterOrphanする。
    // ローダーがinput.importedFileと同一参照のImageSourceを返した場合、snapshotの要素は
    // input.importedFileと同一参照になり、同じ参照が2回registerOrphanされる。本テストが固定
    // するのはApplication層のSourceImportCoordinatorが重複除去をせず同一参照へ2回
    // registerOrphanを呼ぶこと（下記のregisterOrphanCallsアサーション）であり、
    // FakeMaintenanceStoreを使うため本番アダプタの冪等性そのものはここでは検証していない
    // （MaintenanceStoreLiveを非冪等に変更してもこのテストは落ちない）。本番アダプタの
    // 「INSERT OR IGNORE」という冪等性はPersistence側 MaintenanceStoreTests.swift の
    // registerOrphanIsIdempotent が正本として固定する。
    let projectID = makeProjectID()
    let input = makePickedPhotoInput()
    // ローダーがinput.importedFileと同一参照のImageSourceを返す状況を模す
    // （reselectAttachDoesNotDeleteImportedFileWhenLoaderReturnsSameFileと同じパターン。
    // PickedPhotoLoader.loadの契約には異なる参照を返す保証が無いため、この状況を排除できない）。
    let photo = LoadedPhoto(
        source: ImageSource(file: input.importedFile, pixelSize: makePixelSize(), format: .jpeg),
        capture: makeLoadedPhoto().capture
    )
    let loader = FakePickedPhotoLoader(result: photo)
    let store = FakeWorkingSourceStore()
    // seedWorkingSourceを呼ばない = WorkingSourceRecordが無い状態（「なし」側の分岐。
    // attachWorkingSourceToExistingProjectを呼ぶ経路を使い、attachToExistingProjectFailure
    // 一つで手順2失敗を再現する。ファイル冒頭コメント参照）。
    struct AttachBoom: Error, Equatable {}
    await store.setAttachToExistingProjectFailure(AttachBoom())
    let managedFileStore = FakeManagedFileStore()
    let maintenanceStore = FakeMaintenanceStore(managedFileStore: managedFileStore)
    let coordinator = makeSourceImportCoordinator(
        pickedPhotoLoader: loader,
        workingSourceStore: store,
        managedFileStore: managedFileStore,
        maintenanceStore: maintenanceStore
    )

    do {
        try await coordinator.reselectSource(projectID: projectID, input: input)
        Issue.record("エラーがthrowされるはずだった")
    } catch let error as AttachBoom {
        // performReselectのcatch → ReselectFailureAlreadyHandledに包まれ、reselectSource側で
        // unwrapされてrethrowされる。手順2失敗の理由（AttachBoom）がそのまま伝播することを
        // 確認する（Global Constraints「エラーの握りつぶし禁止」）。
        #expect(error == AttachBoom())
    } catch {
        Issue.record("想定外のエラー: \(error)")
    }

    // Suggestion対応（Issue #36 reviewer指摘）: 手順2失敗時は削除フェーズ（手順3・4）へ
    // 到達しないのが不変条件である。これが無いと「手順2失敗なのに削除してしまう」という
    // データ損失方向の回帰（例外処理の実装ミスで削除ロジックまで実行されてしまう変更等）を
    // 見逃す。
    #expect(await managedFileStore.deleteCalls.isEmpty)

    // 本体: [input.importedFile] + snapshot は同じ参照が2要素になり、registerOrphanが同じ
    // ManagedFileRefへ2回呼ばれたことを明示的に確認する（registerOrphanFailureは未設定のため
    // 2回とも成功する。ファイル冒頭の説明のとおり、これはApplication層が重複除去せず2回
    // 呼び出す挙動の固定であり、本番アダプタの冪等性の検証はPersistence側の既存テストに譲る）。
    #expect(await maintenanceStore.registerOrphanCalls == [input.importedFile, input.importedFile])
}
