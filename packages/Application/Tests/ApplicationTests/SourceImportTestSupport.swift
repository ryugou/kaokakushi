import Foundation
import Testing
import Domain
@testable import Application

// SourceImportCoordinator（Issue #8 サブプロジェクト5 A2 Task 2）専用のテストフィクスチャ。
//
// 分離を判断した時点で TestSupport.swift は351行、このファイルの内容は63行であり、
// そのまま追記すると 351+63=414行 となりファイル400行制限（Global Constraints）を
// 超える。そのため、他のテストファイルと共有しない SourceImportCoordinator 固有の
// フィクスチャはこちらへ分離する（TestSupport.swift 側の共有フィクスチャ makeImageSource /
// makeFixedClock 等は既存のまま再利用する）。時刻はすべて固定値を渡す（裸の Date() を
// 使わない。Global Constraints）。
// reviewer 指摘 S6: 「TestSupport.swift が既に400行制限に達している」という以前の記述は
// 実測（351行）と食い違っていたため、上記のとおり正確な根拠に直した。

/// PickedPhotoLoader.load 成功時の標準フィクスチャ（processingTemporary種別のImageSourceを
/// 持つ。FakePickedPhotoLoader の既定戻り値としても使う）。
func makeLoadedPhoto() -> LoadedPhoto {
    LoadedPhoto(
        source: makeImageSource(),
        capture: OriginalCaptureMetadata(
            dateTimeOriginal: "2026:08:14 09:00:00",
            subSecTimeOriginal: "500",
            offsetTimeOriginal: "+09:00",
            utcMillis: 1_755_126_000_500
        )
    )
}

/// PickedPhotoInput の標準フィクスチャ。importedFile は毎回新しい ManagedFileID を割り当てる。
func makePickedPhotoInput(
    importedFile: ManagedFileRef = ManagedFileRef(kind: .processingTemporary, fileID: ManagedFileID(rawValue: UUID())),
    providerAssetIdentifier: String? = "asset-1",
    libraryCreationDate: Date? = Date(timeIntervalSince1970: 1_754_872_200),
    representation: SourceRepresentation = .original
) -> PickedPhotoInput {
    PickedPhotoInput(
        importedFile: importedFile,
        providerAssetIdentifier: providerAssetIdentifier,
        libraryCreationDate: libraryCreationDate,
        representation: representation
    )
}

/// 標準構成の SourceImportCoordinator を組み立てる（makeGenerateCoordinator と同じ様式。
/// maintenanceStore 省略時は managedFileStore と紐づけて構築する。makeCoordinator と同じ理由。
/// W-5）。
func makeSourceImportCoordinator(
    pickedPhotoLoader: PickedPhotoLoader,
    workingSourceStore: FakeWorkingSourceStore = FakeWorkingSourceStore(),
    managedFileStore: FakeManagedFileStore = FakeManagedFileStore(),
    maintenanceStore: FakeMaintenanceStore? = nil,
    queue: SerialTaskQueue = SerialTaskQueue(),
    recoveryGate: RecoveryGate = FakeRecoveryGate()
) -> SourceImportCoordinator {
    let resolvedMaintenanceStore = maintenanceStore ?? FakeMaintenanceStore(managedFileStore: managedFileStore)
    return SourceImportCoordinator(
        pickedPhotoLoader: pickedPhotoLoader,
        workingSourceStore: workingSourceStore,
        managedFileStore: managedFileStore,
        maintenanceStore: resolvedMaintenanceStore,
        now: makeFixedClock(),
        queue: queue,
        recoveryGate: recoveryGate
    )
}
