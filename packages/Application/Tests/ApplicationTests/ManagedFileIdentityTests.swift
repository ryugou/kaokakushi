import Testing
import Foundation
import Domain
@testable import Application

// ManagedFileIdentity.swift の isDistinctManagedFile（ManagedFileRef の同一性判定。codex レビュー
// S-1の集約先）の単体テスト。
//
// isDistinctManagedFile は kind + fileID の完全一致で削除可否を判定する共通述語である
// （ManagedFileIdentity.swift 冒頭コメント参照）。fileID のみの一致では同一UUID・異なるkindの
// 参照を誤って同一実体とみなしてしまう（codex レビュー W-1）。
//
// Import Saga側（SourceImportCoordinatorImportCleanupTests.swift の
// importDeletesWhenLoaderReturnsSameFileIDButDifferentKind）はこの述語を
// coordinator.importPickedPhoto 経由のSagaレベルテストで「同一UUID・異なるkindなら削除実行」を
// 検証できている。`PickedPhotoInput.importedFile` が kind 制約の無い `ManagedFileRef` を受理する
// ため、kindの異なる入力を実際に組み立てられるからである。
//
// 一方、Reselect Saga側（SourceImportCoordinator+Reselect.swift の replacedSourceFileToDelete）は
// 同型のSagaレベル回帰テストを組み立てられない: この関数が比較する2値
// （existing.sourceFile.ref / normalizedSourceFile.ref）はいずれも型 `WorkingSourceFileRef`
// （packages/Domain/Sources/Domain/ManagedFileRef.swift の失敗可能イニシャライザ
// `guard ref.kind == .processingTemporary else { return nil }`）を経由するため、型システムに
// より常に kind `.processingTemporary` に固定される。したがって `reselectSource` 経由で
// kind差のあるケースを構築することは型上不可能であり、Sagaレベルでは到達不能である。到達可能に
// するには本番型 `WorkingSourceFileRef` にガード迂回用の初期化子を足すしかないが、それは W-1 が
// 守る型不変条件そのものを壊すため採らない。ゆえにこのファイルで述語そのものを直接検証する。
//
// SourceImportCoordinatorReselectTests.swift から移動した（このテストの主題は Reselect Saga固有の
// 振る舞いではなく isDistinctManagedFile 単体の性質であり、かつ同ファイルが400行制限
// 〈Global Constraints〉ちょうどに達していたため）。

// MARK: - W-1回帰: 同一UUID・異なるkindは別実体と判定される

@Test("W-1回帰: isDistinctManagedFileは同一UUID・異なるkindを別実体と判定する")
func isDistinctManagedFileTreatsSameFileIDDifferentKindAsDistinct() {
    let fileID = ManagedFileID(rawValue: UUID())
    let candidate = ManagedFileRef(kind: .historyThumbnail, fileID: fileID)
    #expect(isDistinctManagedFile(candidate, from: ManagedFileRef(kind: .processingTemporary, fileID: fileID)))
}
