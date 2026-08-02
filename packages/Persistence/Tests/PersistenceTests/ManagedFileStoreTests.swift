import Foundation
import Testing
import Domain
@testable import Persistence

// ManagedFileStoreLiveのテスト（architecture.md 7.3「ManagedFileStore」・7.4
// 「バックアップ」が正本。Issue #6 Task 3）。
//
// isExcludedFromBackupの検証は全プラットフォームで行う。FileProtectionTypeの実効性
// 検証は#if os(iOS)ブロックの中だけに書く（macOSでは実効性が保証されないため。
// plan Global Constraints 18行目）。

/// createFileのbody内で意図的にthrowするための専用エラー
/// （ManagedFileStoreErrorとの取り違えを起こさないよう、元のエラーが
/// そのまま伝播することを型で確認できるようにする）。
private struct BodyFailure: Error, Equatable {
    let marker: String
}

@Suite("ManagedFileStoreLive")
struct ManagedFileStoreTests {

    /// テストごとに衝突しない一時ディレクトリ群を発行する。裸のDate()は使わず、
    /// ルートディレクトリ名の一意性はUUIDで担保する。
    private func makeTemporaryDirectories() -> (root: URL, directories: ManagedFileDirectories) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedFileStoreTests-\(UUID().uuidString)")
        let directories = ManagedFileDirectories(
            output: root.appendingPathComponent("outputs"),
            stampAsset: root.appendingPathComponent("stamps"),
            historyThumbnail: root.appendingPathComponent("thumbnails"),
            stampThumbnail: root.appendingPathComponent("stamp-thumbnails"),
            processingTemporary: root.appendingPathComponent("working"),
            rasterTemporary: root.appendingPathComponent("raster")
        )
        return (root, directories)
    }

    @Test("createFileで作成したファイルはisExcludedFromBackupがtrueになること")
    func createFileSetsExcludedFromBackup() async throws {
        let (root, directories) = makeTemporaryDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedFileStoreLive(directories: directories)

        let created = try await store.createFile(kind: .output) { url in
            try Data("payload".utf8).write(to: url)
        }

        let finalURL = directories.output.appendingPathComponent(created.ref.fileID.rawValue.uuidString)
        let resourceValues = try finalURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(resourceValues.isExcludedFromBackup == true)
    }

    @Test("bodyが途中でthrowした場合、最終ファイルが作られず元のエラーが伝播すること")
    func createFileDoesNotFinalizeWhenBodyThrows() async throws {
        let (root, directories) = makeTemporaryDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedFileStoreLive(directories: directories)
        let failure = BodyFailure(marker: "body-failed-\(UUID().uuidString)")

        do {
            _ = try await store.createFile(kind: .rasterTemporary) { _ in
                throw failure
            }
            Issue.record("bodyがthrowしたのにcreateFileが成功しManagedFileRefが返った")
        } catch let error as BodyFailure {
            #expect(error == failure)
        } catch {
            Issue.record("BodyFailure以外がthrowされた: \(error)")
        }

        // rename(手順4)前に中断されたため、rasterTemporaryディレクトリ配下には
        // 一時ファイルすら含め何も残っていないはず（手順7の削除が効いている）。
        let remainingEntries = try FileManager.default.contentsOfDirectory(
            at: directories.rasterTemporary,
            includingPropertiesForKeys: nil
        )
        #expect(remainingEntries.isEmpty)
    }

    @Test(
        "createFile/withReadAccessのURLの親ディレクトリがkindのディレクトリと一致すること",
        arguments: [
            ManagedFileKind.output,
            .stampAsset,
            .historyThumbnail,
            .stampThumbnail,
            .processingTemporary,
            .rasterTemporary
        ]
    )
    func resolvedURLStaysUnderExpectedDirectory(kind: ManagedFileKind) async throws {
        let (root, directories) = makeTemporaryDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedFileStoreLive(directories: directories)
        let expectedDirectory = directories.directory(for: kind)

        let expectedStandardized = expectedDirectory.standardizedFileURL

        let created = try await store.createFile(kind: kind) { url in
            #expect(url.deletingLastPathComponent().standardizedFileURL == expectedStandardized)
            try Data("payload".utf8).write(to: url)
        }

        var observedReadURL: URL?
        _ = try await store.withReadAccess(created.ref) { url in
            observedReadURL = url
        }
        let observedParent = observedReadURL?.deletingLastPathComponent().standardizedFileURL
        #expect(observedParent == expectedStandardized)
    }

    @Test("deleteが対象ファイルを実際に削除すること")
    func deleteRemovesFile() async throws {
        let (root, directories) = makeTemporaryDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedFileStoreLive(directories: directories)

        let created = try await store.createFile(kind: .stampAsset) { url in
            try Data("payload".utf8).write(to: url)
        }
        let finalURL = directories.stampAsset.appendingPathComponent(created.ref.fileID.rawValue.uuidString)
        #expect(FileManager.default.fileExists(atPath: finalURL.path))

        try await store.delete(created.ref)

        #expect(!FileManager.default.fileExists(atPath: finalURL.path))
    }

    @Test("存在しないrefへのdeleteが冪等に成功すること")
    func deleteIsIdempotentForMissingFile() async throws {
        let (root, directories) = makeTemporaryDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedFileStoreLive(directories: directories)
        let missingRef = ManagedFileRef(kind: .historyThumbnail, fileID: ManagedFileID(rawValue: UUID()))

        try await store.delete(missingRef)
    }

    @Test("存在しないrefへのwithReadAccessがManagedFileStoreError.fileNotFoundを送出すること")
    func withReadAccessThrowsWhenFileMissing() async throws {
        let (root, directories) = makeTemporaryDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedFileStoreLive(directories: directories)
        let missingRef = ManagedFileRef(kind: .output, fileID: ManagedFileID(rawValue: UUID()))

        do {
            _ = try await store.withReadAccess(missingRef) { _ in 0 }
            Issue.record("存在しないrefに対しwithReadAccessが成功した")
        } catch let error as ManagedFileStoreError {
            guard case .fileNotFound(let kind, let fileID) = error else {
                Issue.record("期待したエラーケース(fileNotFound)ではない: \(error)")
                return
            }
            #expect(kind == .output)
            #expect(fileID == missingRef.fileID)
        } catch {
            Issue.record("ManagedFileStoreError以外がthrowされた: \(error)")
        }
    }

    @Test("createFileで書いたデータをwithReadAccessで読み返せること")
    func createFileDataIsReadableViaWithReadAccess() async throws {
        let (root, directories) = makeTemporaryDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedFileStoreLive(directories: directories)
        let payload = Data("roundtrip-\(UUID().uuidString)".utf8)

        let created = try await store.createFile(kind: .historyThumbnail) { url in
            try payload.write(to: url)
        }

        let readBack = try await store.withReadAccess(created.ref) { url in
            try Data(contentsOf: url)
        }

        #expect(readBack == payload)
    }

    #if os(iOS)
    @Test("iOSではcreateFile後にFileProtectionTypeが.completeになっていること")
    func createFileSetsCompleteProtectionOnIOS() async throws {
        let (root, directories) = makeTemporaryDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedFileStoreLive(directories: directories)

        let created = try await store.createFile(kind: .processingTemporary) { url in
            try Data("payload".utf8).write(to: url)
        }

        let finalURL = directories.processingTemporary
            .appendingPathComponent(created.ref.fileID.rawValue.uuidString)
        let attributes = try FileManager.default.attributesOfItem(atPath: finalURL.path)
        #expect(attributes[.protectionKey] as? FileProtectionType == .complete)
    }
    #endif
}
