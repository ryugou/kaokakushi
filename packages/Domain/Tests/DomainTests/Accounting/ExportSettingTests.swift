import Testing
@testable import Domain
import Foundation

/// Task 3: 書き出し設定の型群（export-saga.md 0 章）。
///
/// `OutputAspect` の4ケース、`MetadataPolicy` / `ExportSetting` のフィールド保持を検証する。

private func assertSendableEquatable<T: Sendable & Equatable>(_ value: T) -> T { value }

@Test(
    "OutputAspectはoriginal/square/fourFive/nineSixteenの4ケースを持ちHashableである",
    arguments: [OutputAspect.original, .square, .fourFive, .nineSixteen]
)
func outputAspectHasFourCases(aspect: OutputAspect) {
    #expect(Set([aspect]).contains(aspect))
}

@Test("MetadataPolicyが全フィールドを保持する")
func metadataPolicyHoldsAllFields() {
    let subject = assertSendableEquatable(MetadataPolicy(
        removeLocation: true,
        removeDeviceInfo: true,
        removeSoftwareInfo: false,
        keepCaptureDate: true
    ))
    #expect(subject.removeLocation == true)
    #expect(subject.removeDeviceInfo == true)
    #expect(subject.removeSoftwareInfo == false)
    #expect(subject.keepCaptureDate == true)
}

@Test("ExportSettingが全フィールドを保持する")
func exportSettingHoldsAllFields() {
    let policy = MetadataPolicy(
        removeLocation: true,
        removeDeviceInfo: false,
        removeSoftwareInfo: false,
        keepCaptureDate: false
    )
    let subject = assertSendableEquatable(ExportSetting(
        outputAspect: .square,
        outputFormat: .jpeg,
        compressionQuality: 0.85,
        metadataPolicy: policy
    ))
    #expect(subject.outputAspect == .square)
    #expect(subject.outputFormat == .jpeg)
    #expect(subject.compressionQuality == 0.85)
    #expect(subject.metadataPolicy == policy)
}
