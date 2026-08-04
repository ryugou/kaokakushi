import Foundation
import Domain
#if os(iOS)
import UIKit
#endif

// ManagedFileStoreの実装（architecture.md 7.3「ManagedFileStore」が正本。Issue #6 Task 3）。
// GRDBには依存しない（FileManagerのみで完結する）。
//
// スコープ外（今回のTask 3では実装しない。理由をここに残す）:
// - PendingFileDeletion / 孤児GC候補の永続化（Task 4の範囲）。
//
// パス解決はkind→ディレクトリ + fileID(UUID文字列)の連結のみで完結させ、経路の
// 実行時検査は追加しない（UUID.uuidStringは"/"も".."も含みえないため、これが
// 唯一かつ十分な防御——architecture.md 7.3）。
//
// withReadAccessは呼び出しの先頭でProtectedDataAvailabilityを確認する
// （architecture.md 7.3「スコープ付きアクセス」表）。iOS以外にこの概念は無いため
// #if os(iOS)で分岐し、macOS等では常に利用可能として扱う（何もチェックしない）。

/// ManagedFileStoreLiveが解決する6種類のディレクトリ。絶対パス
/// （Application Support配下等）の決定は呼び出し元の責務とし、
/// ここでは注入されたURLを保持するだけにする（テスト容易性のため）。
/// architecture.md 7.4「配置」のレイアウト表との対応:
///
/// | kind                 | ディレクトリ                          |
/// | --------------------- | -------------------------------------- |
/// | output                | outputs/                               |
/// | stampAsset             | stamps/                                 |
/// | historyThumbnail       | thumbnails/                             |
/// | stampThumbnail         | Library/Caches/stamp-thumbnails/        |
/// | processingTemporary    | working/                                |
/// | rasterTemporary        | tmp/raster/                             |
public struct ManagedFileDirectories: Sendable {
    public let output: URL
    public let stampAsset: URL
    public let historyThumbnail: URL
    public let stampThumbnail: URL
    public let processingTemporary: URL
    public let rasterTemporary: URL

    public init(
        output: URL,
        stampAsset: URL,
        historyThumbnail: URL,
        stampThumbnail: URL,
        processingTemporary: URL,
        rasterTemporary: URL
    ) {
        self.output = output
        self.stampAsset = stampAsset
        self.historyThumbnail = historyThumbnail
        self.stampThumbnail = stampThumbnail
        self.processingTemporary = processingTemporary
        self.rasterTemporary = rasterTemporary
    }

    /// kindごとに明示的なstored propertyをそのまま返すだけの分岐（文字列キーの辞書や、
    /// switch文でディレクトリ名を動的合成する実装はしない。返す値は呼び出し元が
    /// 注入したURLそのもの）。
    func directory(for kind: ManagedFileKind) -> URL {
        switch kind {
        case .output: return output
        case .stampAsset: return stampAsset
        case .historyThumbnail: return historyThumbnail
        case .stampThumbnail: return stampThumbnail
        case .processingTemporary: return processingTemporary
        case .rasterTemporary: return rasterTemporary
        }
    }
}

/// 属性の設定・読み返し検証を行ったタイミング
/// （architecture.md 7.3 保存の順序の手順2/6）。
public enum AttributeValidationStage: String, Sendable, Equatable {
    case beforeWrite
    case afterRename
}

/// ManagedFileStoreLiveが送出する専用エラー。運用者が次のアクションを判断できるよう、
/// 対象のkind・fileIDと、該当する場合は期待値/実際値を持つ
/// （AppDatabaseErrorと同じ方針: Sendable, Equatable, LocalizedError）。
///
/// fileIDはManagedFileID（文字列表現を持たない型。ManagedFileRef.swift参照）のまま
/// 保持する。メッセージ組み立て時は明示的に`.rawValue.uuidString`を取り出す
/// （暗黙の文字列補間へ流さない方針に合わせるため）。
public enum ManagedFileStoreError: Error, Sendable, Equatable {
    /// withReadAccess: 指定されたrefに対応するファイルが存在しない。
    case fileNotFound(kind: ManagedFileKind, fileID: ManagedFileID)

    /// withReadAccess: 呼び出し時点で保護データが利用不可だった（iOSのみ。
    /// デバイスロック中等。architecture.md 7.3「スコープ付きアクセス」表）。
    case protectedDataUnavailable(kind: ManagedFileKind, fileID: ManagedFileID)

    /// createFile 手順1: 一時ファイルの作成に失敗した。
    /// FileManager.createFile(atPath:)はBoolを返すのみで失敗理由を返さないため、
    /// このエラー自体に詳細原因は含まれない
    /// （権限不足・ディスク枯渇等を調査する起点として運用者へ提示する）。
    case temporaryFileCreationFailed(kind: ManagedFileKind, fileID: ManagedFileID)

    /// createFile 手順2/6: isExcludedFromBackupを設定し読み返したが期待値(true)と
    /// 一致しなかった。
    case backupExclusionValidationFailed(
        kind: ManagedFileKind,
        fileID: ManagedFileID,
        stage: AttributeValidationStage,
        actual: Bool?
    )

    /// createFile 手順2/6（iOSのみthrow対象）: FileProtectionTypeを設定し読み返したが
    /// .completeと一致しなかった。
    case fileProtectionValidationFailed(
        kind: ManagedFileKind,
        fileID: ManagedFileID,
        stage: AttributeValidationStage,
        actual: String
    )
}

extension ManagedFileStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let kind, let fileID):
            return """
            ManagedFileStore: kind=\(kind) fileID=\(fileID.rawValue.uuidString) \
            に対応するファイルが見つかりません。refが指す実体が削除済み、または \
            不正なrefが渡された可能性があります。呼び出し元でのrefの発行・保存経路を \
            確認してください。
            """
        case .protectedDataUnavailable(let kind, let fileID):
            return """
            ManagedFileStore: kind=\(kind) fileID=\(fileID.rawValue.uuidString) \
            への読み取りアクセス時点で保護データが利用不可でした \
            （デバイスロック中等）。デバイスのロックを解除してから \
            再試行してください。
            """
        case .temporaryFileCreationFailed(let kind, let fileID):
            return """
            ManagedFileStore: kind=\(kind) fileID=\(fileID.rawValue.uuidString) \
            の一時ファイル作成に失敗しました。ディスク空き容量、または対象 \
            ディレクトリの書き込み権限を確認してください。
            """
        case .backupExclusionValidationFailed(let kind, let fileID, let stage, let actual):
            let actualDescription = actual.map(String.init(describing:)) ?? "nil"
            return """
            ManagedFileStore: kind=\(kind) fileID=\(fileID.rawValue.uuidString) \
            （stage=\(stage.rawValue)）でisExcludedFromBackupの設定が反映されませんでした \
            （期待値: true, 実際の値: \(actualDescription)）。ファイルシステムまたは \
            リソース値APIの異常の可能性があります。
            """
        case .fileProtectionValidationFailed(let kind, let fileID, let stage, let actual):
            return """
            ManagedFileStore: kind=\(kind) fileID=\(fileID.rawValue.uuidString) \
            （stage=\(stage.rawValue)）でFileProtectionType.completeの設定が \
            反映されませんでした（実際の値: \(actual)）。デバイスのデータ保護機能が \
            有効か確認してください。
            """
        }
    }
}

/// ManagedFileStoreの実装。GRDBを使わずFileManagerのみで完結する
/// （architecture.md 7.3）。
public struct ManagedFileStoreLive: ManagedFileStore {
    private let directories: ManagedFileDirectories

    public init(directories: ManagedFileDirectories) {
        self.directories = directories
    }

    public func withReadAccess<R: Sendable>(
        _ ref: ManagedFileRef,
        _ body: @Sendable (URL) async throws -> R
    ) async throws -> R {
        try await ensureProtectedDataAvailable(for: ref)
        let url = resolvedURL(for: ref)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ManagedFileStoreError.fileNotFound(kind: ref.kind, fileID: ref.fileID)
        }
        return try await body(url)
    }

    public func createFile<R: Sendable>(
        kind: ManagedFileKind,
        _ body: @Sendable (URL) async throws -> R
    ) async throws -> (ref: ManagedFileRef, result: R) {
        let fileID = ManagedFileID(rawValue: UUID())
        let ref = ManagedFileRef(kind: kind, fileID: fileID)
        let directory = directories.directory(for: kind)
        let finalURL = directory.appendingPathComponent(fileID.rawValue.uuidString)
        // 一時ファイル名の一意性はUUIDで担保する（裸のDate()は使わない。同時実行でも
        // 衝突しない）。"tmp-"接頭辞は最終ファイル名（UUIDのみ）と混同しないための
        // 可読性目的の識別子であり、パス解決には使わない。
        let temporaryURL = directory.appendingPathComponent("tmp-\(UUID().uuidString)")

        do {
            // 手順1: 最終ファイルと同じディレクトリ内に一時ファイルを作る
            // （手順4で同一ボリューム上のatomicなrenameにするため。別ボリューム
            // だとrenameがコピー+削除になり中断時に不整合が生じうる）。保護属性は
            // ディレクトリの既定値に頼らずファイル単位で明示設定・検証する設計
            // （手順2・5+6）のため、この時点ではまだ意識する必要が無い。
            // ディレクトリが無ければ先に作成する。
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw ManagedFileStoreError.temporaryFileCreationFailed(kind: kind, fileID: fileID)
            }

            // 手順2: 書き込み前に属性を設定し読み返して検証する
            // （中断時に無保護の一時ファイルを残さないため）。
            try applyProtectionAttributes(to: temporaryURL, kind: kind, fileID: fileID, stage: .beforeWrite)

            // 手順3: 呼び出し元にデータを書かせる。
            let result = try await body(temporaryURL)

            // 手順4: 同一ボリューム上のrenameとしてatomicに最終URLへ移す
            // （finalURLは新規UUIDのため既存ファイルと衝突しない）。
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)

            // 手順5+6: 最終URLへ属性を再設定し、読み返して検証する
            // （moveItemが移動元の属性を必ず引き継ぐとは限らないため、rename後の
            // 再設定を省けない）。
            try applyProtectionAttributes(to: finalURL, kind: kind, fileID: fileID, stage: .afterRename)

            return (ref: ref, result: result)
        } catch {
            // 手順7: 1〜6のいずれかで失敗したらManagedFileRefを返さない。tempURL・
            // finalURLの削除を試みる（削除自体の失敗は孤児GC対象として許容する設計
            // ——architecture.md 7.3）。ただし呼び出し元へは元のエラーを必ずthrowし、
            // 握りつぶさない。
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: finalURL)
            throw error
        }
    }

    public func delete(_ ref: ManagedFileRef) async throws {
        let url = resolvedURL(for: ref)
        // 存在しない場合は既に削除済みとして冪等に成功扱いする
        // （呼び出し元がPendingFileDeletionの再試行等で複数回deleteを呼びうるため）。
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        // それ以外のI/Oエラー（権限不足等）はFileManagerが送出した元のエラーを
        // そのまま伝播させ、握りつぶさない。
        try FileManager.default.removeItem(at: url)
    }

    /// withReadAccessの先頭で保護データの利用可否を確認する
    /// （architecture.md 7.3「スコープ付きアクセス」表）。iOS以外にはこの概念が
    /// 無いため、#if os(iOS)の外では常に利用可能として扱う（何もチェックしない）。
    private func ensureProtectedDataAvailable(for ref: ManagedFileRef) async throws {
        #if os(iOS)
        let isAvailable = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
        guard isAvailable else {
            throw ManagedFileStoreError.protectedDataUnavailable(kind: ref.kind, fileID: ref.fileID)
        }
        #endif
    }

    /// 最終URL = directory(for: kind) + fileID(UUID文字列) のみで解決する
    /// （パス脱出の唯一の防御。architecture.md 7.3）。
    private func resolvedURL(for ref: ManagedFileRef) -> URL {
        directories.directory(for: ref.kind).appendingPathComponent(ref.fileID.rawValue.uuidString)
    }

    private func applyProtectionAttributes(
        to url: URL,
        kind: ManagedFileKind,
        fileID: ManagedFileID,
        stage: AttributeValidationStage
    ) throws {
        try applyBackupExclusion(to: url, kind: kind, fileID: fileID, stage: stage)
        try applyFileProtection(to: url, kind: kind, fileID: fileID, stage: stage)
    }

    /// isExcludedFromBackupは全プラットフォームで設定・読み返し検証する
    /// （architecture.md 7.4「バックアップ」。macOSでも意味を持つ設定のため）。
    private func applyBackupExclusion(
        to url: URL,
        kind: ManagedFileKind,
        fileID: ManagedFileID,
        stage: AttributeValidationStage
    ) throws {
        var mutableURL = url
        var valuesToSet = URLResourceValues()
        valuesToSet.isExcludedFromBackup = true
        try mutableURL.setResourceValues(valuesToSet)

        // 読み返しはsetに使ったmutableURLとは別の新規URLインスタンスで行う
        // （同一URLインスタンスでのset直後のreadはキャッシュを読むだけで実ディスクへ
        // 再照会しない可能性があるため。reviewer指摘。appendingPathComponent等で
        // 別インスタンスとして再構築したURLで読み返す既存テストの前提と揃える）。
        let readBackURL = URL(fileURLWithPath: url.path)
        let readBack = try readBackURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        guard readBack.isExcludedFromBackup == true else {
            throw ManagedFileStoreError.backupExclusionValidationFailed(
                kind: kind,
                fileID: fileID,
                stage: stage,
                actual: readBack.isExcludedFromBackup
            )
        }
    }

    /// FileProtectionTypeは全プラットフォームで設定を試みるが、読み返し検証して
    /// 失敗時にthrowするのはiOSのみ（macOSでは実効性が保証されないため。
    /// plan Global Constraints 18行目）。
    private func applyFileProtection(
        to url: URL,
        kind: ManagedFileKind,
        fileID: ManagedFileID,
        stage: AttributeValidationStage
    ) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualProtection = attributes[.protectionKey] as? FileProtectionType
        guard actualProtection == .complete else {
            throw ManagedFileStoreError.fileProtectionValidationFailed(
                kind: kind,
                fileID: fileID,
                stage: stage,
                actual: actualProtection?.rawValue ?? "unknown"
            )
        }
        #else
        // macOSでも設定自体は試みるが、実効性は保証されないため読み返し検証は
        // 行わずtry?で握りつぶす（設定失敗をここでは致命扱いしない。
        // plan Global Constraints 18行目）。
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #endif
    }
}
