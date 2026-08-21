import Foundation
import Domain

// ManagedFileIdentity — ManagedFileRef の同一性判定という共通基準の集約先（Issue #8 codex レビュー
// S-1）。
//
// SourceImportCoordinator.swift の importedFileToDelete と SourceImportCoordinator+Reselect.swift
// の replacedSourceFileToDelete は、いずれも「削除候補とローダーが返した正規化後ファイルが同一
// 実体かどうか」を判定してから削除を実行する。集約前はこの判定ロジックを2箇所が個別に持っており、
// どちらも `fileID` のみを比較していた。`ManagedFileRef` の同一性は `kind` + `fileID` の両方で
// 決まる（ManagedFileRef.swift）ことを踏まえていなかったため、この集約と同時に kind + fileID の
// 完全一致判定へ修正した（codex レビュー W-1。詳細は下記 isDistinctManagedFile の doc コメント
// 参照）。

/// 削除候補（`candidate`）が、保持すべき参照（`kept`）と別実体かどうかを判定する。
///
/// `ManagedFileRef` の同一性は kind + fileID の両方で決まる（ManagedFileRef.swift）。fileID
/// だけを比較すると、同一UUID・異なるkindの参照を「同一実体」と誤認し、削除すべき別実体の
/// ファイルを削除し損ねる（孤児ファイル化。多くのkindは起動時GCの対象だが `.historyThumbnail`
/// はGC対象外 — StartupRecoveryCoordinator の orphanGCKinds 判定。codex レビュー W-1）。
///
/// 呼び出し元（SourceImportCoordinator.importedFileToDelete /
/// SourceImportCoordinator+Reselect.replacedSourceFileToDelete）はいずれも「ローダーが返した
/// 正規化後ファイルと偶然同じ参照が返った場合、削除候補を無条件削除すると DB がまだ有効な参照
/// として持つ実体そのものを消してしまい、再編集不能になるデータ損失事故になる」ことへの防御と
/// してこれを使う。true（別実体）を返した場合のみ削除を実行してよい。
func isDistinctManagedFile(_ candidate: ManagedFileRef, from kept: ManagedFileRef) -> Bool {
    candidate != kept
}
