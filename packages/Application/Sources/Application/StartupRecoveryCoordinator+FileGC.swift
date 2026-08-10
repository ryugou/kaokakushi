import Foundation
import Domain

// StartupRecoveryCoordinator+FileGC — 孤児ファイルGC（architecture.md 7.5 手順(1)〜(3)）の
// 実装（Issue #7 Task 11）。StartupRecoveryCoordinator.swift 冒頭コメントの正本一覧を参照。
//
// (1) loadPendingFileDeletions で未処理分の実体削除を再試行し、成功したものだけ
// clearPendingFileDeletion で消す。(2) 孤児GC対象の種別ごとに listExistingFileIDs と
// listReferencedFileIDs の差集合を求め registerOrphan で削除候補へ登録する。(3) (2) が
// 登録した ref のうち、(1) で削除を試行済みの ref を除いたものだけを (1) と同じ削除経路
// （deleteManagedFiles）へ渡して削除する。(1) で失敗した ref は実体がディスクに残るため
// (2) の差集合が必ず拾って再登録してしまうが、(3) の対象から除外することで同一起動内での
// 二重削除試行を防ぐ（Task 11 レビュー C-1）。
//
// loadPendingFileDeletions / listExistingFileIDs / listReferencedFileIDs / registerOrphan の
// throw は GC 手順(1)〜(3)全体を中断するが、復旧全体は止めない。それまでに完走した分の
// 集計は保持したまま、原因を fileGCFailure として呼び出し元（performRecovery）へ返す
// （Task 11 レビュー W-3）。

/// 孤児ファイルGC 1 回分の集計。実体削除自体の失敗（failedFileDeletions）と
/// PendingFileDeletion 登録行の削除失敗（pendingRecordClearFailures）を区別する
/// （Task 11 レビュー W-2）。
struct FileDeletionTally {
    var deletedCount = 0
    var failedFileDeletions: [FileDeletionFailure] = []
    var pendingRecordClearFailures: [FileDeletionFailure] = []

    mutating func merge(_ other: FileDeletionTally) {
        deletedCount += other.deletedCount
        failedFileDeletions += other.failedFileDeletions
        pendingRecordClearFailures += other.pendingRecordClearFailures
    }
}

/// runOrphanFileGC の結果（performRecovery が StartupRecoveryReport へ写す。large_tuple
/// 回避のため struct にまとめる。TestSupport.swift の SucceedingGenerationPipeline と同じ方針）。
struct FileGCOutcome {
    let deletedCount: Int
    let failedFileDeletions: [FileDeletionFailure]
    let pendingRecordClearFailures: [FileDeletionFailure]
    let gcFailure: Error?
}

extension StartupRecoveryCoordinator {
    /// architecture.md 7.5 手順(1)〜(3)を実行する。GC 手順自体がストアの throw で完走できな
    /// かった場合も throw せず、それまでの集計と原因（gcFailure）を返す（W-3。呼び出し元は
    /// これを見て後続の手順を続行する）。
    func runOrphanFileGC() async -> FileGCOutcome {
        var tally = FileDeletionTally()
        var gcFailure: Error?
        do {
            let pending = try await maintenanceStore.loadPendingFileDeletions()
            let attemptedRefs = Set(pending.map(\.file))
            tally.merge(await deleteManagedFiles(pending.map(\.file)))

            let registeredRefs = try await registerOrphanFiles()
            let secondPassTargets = registeredRefs.filter { !attemptedRefs.contains($0) }
            tally.merge(await deleteManagedFiles(secondPassTargets))
        } catch {
            gcFailure = error
        }
        return FileGCOutcome(
            deletedCount: tally.deletedCount,
            failedFileDeletions: tally.failedFileDeletions,
            pendingRecordClearFailures: tally.pendingRecordClearFailures,
            gcFailure: gcFailure
        )
    }

    /// 与えられた ref を順に実削除する。実体削除自体の失敗と clearPendingFileDeletion の
    /// 失敗を別の do/catch で区別する（W-2）。前者は端末に実体が残り続ける
    /// （failedFileDeletions に計上）。後者は実体は既に消えているが登録行だけが残るケースで、
    /// 意味が異なるため pendingRecordClearFailures へ分ける。個々の失敗は catch して
    /// 次の項目へ進む（復旧全体を止めない。登録は次回起動で再試行される）。
    private func deleteManagedFiles(_ refs: [ManagedFileRef]) async -> FileDeletionTally {
        var tally = FileDeletionTally()
        for ref in refs {
            do {
                try await managedFileStore.delete(ref)
            } catch {
                tally.failedFileDeletions.append(FileDeletionFailure(kind: ref.kind, cause: error))
                continue
            }
            do {
                try await maintenanceStore.clearPendingFileDeletion(ref)
                tally.deletedCount += 1
            } catch {
                tally.pendingRecordClearFailures.append(FileDeletionFailure(kind: ref.kind, cause: error))
            }
        }
        return tally
    }

    /// 孤児GC対象の種別ごとに listExistingFileIDs と listReferencedFileIDs の差集合を求め、
    /// registerOrphan で削除候補へ登録し、登録した ref を呼び出し元へ返す
    /// （`.historyThumbnail` は orphanGCKinds に含めない）。
    private func registerOrphanFiles() async throws -> [ManagedFileRef] {
        var registeredRefs: [ManagedFileRef] = []
        for kind in Self.orphanGCKinds {
            let existingFileIDs = try await maintenanceStore.listExistingFileIDs(kind: kind)
            let referencedFileIDs = try await maintenanceStore.listReferencedFileIDs(kind: kind)
            let orphanFileIDs = existingFileIDs.subtracting(referencedFileIDs)
            for fileID in orphanFileIDs {
                let ref = ManagedFileRef(kind: kind, fileID: fileID)
                try await maintenanceStore.registerOrphan(ref)
                registeredRefs.append(ref)
            }
        }
        return registeredRefs
    }
}
