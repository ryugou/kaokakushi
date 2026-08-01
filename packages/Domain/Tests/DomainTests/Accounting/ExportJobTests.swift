import Testing
@testable import Domain
import Foundation

/// Task 3: 書き出しジョブの型群（export-saga.md 2 章）。
///
/// `ExportJob` / `OutputDeliveryDescriptor` のフィールド保持（`batchID` / `queueItemID` の
/// nil 許容を含む）を検証する。

@Test("ExportJobが全フィールドを保持しbatchIDとqueueItemIDはnilを許容する")
func exportJobHoldsAllFieldsAndAllowsNilOptionals() {
    let exportID = ExportID(rawValue: UUID())
    let projectID = ProjectID(rawValue: UUID())
    let entitlement = Entitlement(
        plan: .free,
        status: .active,
        expiresAt: nil,
        lastVerifiedAt: Date(timeIntervalSince1970: 0),
        isSandbox: false
    )
    let authorization = ExportAuthorization(
        entitlementSnapshot: entitlement,
        accountingMode: .freeMonthlyConsume,
        authorizedAt: Date(timeIntervalSince1970: 100)
    )
    let delivery = OutputDeliveryDescriptor(format: .heic, suggestedCreationDate: nil)

    let subject = ExportJob(
        exportID: exportID,
        projectID: projectID,
        batchID: nil,
        queueItemID: nil,
        authorization: authorization,
        delivery: delivery
    )

    #expect(subject.exportID == exportID)
    #expect(subject.projectID == projectID)
    #expect(subject.batchID == nil)
    #expect(subject.queueItemID == nil)
    #expect(subject.authorization.accountingMode == .freeMonthlyConsume)
    #expect(subject.delivery.format == .heic)
}

@Test("ExportJobはバッチ書き出しでbatchIDとqueueItemIDを保持する")
func exportJobHoldsBatchAndQueueItemIDsWhenPresent() {
    let batchID = BatchID(rawValue: UUID())
    let queueItemID = ExportQueueItemID(rawValue: UUID())
    let entitlement = Entitlement(
        plan: .pro,
        status: .active,
        expiresAt: nil,
        lastVerifiedAt: Date(timeIntervalSince1970: 0),
        isSandbox: false
    )
    let authorization = ExportAuthorization(
        entitlementSnapshot: entitlement,
        accountingMode: .paidUnlimited,
        authorizedAt: Date(timeIntervalSince1970: 200)
    )
    let subject = ExportJob(
        exportID: ExportID(rawValue: UUID()),
        projectID: ProjectID(rawValue: UUID()),
        batchID: batchID,
        queueItemID: queueItemID,
        authorization: authorization,
        delivery: OutputDeliveryDescriptor(format: .png, suggestedCreationDate: Date(timeIntervalSince1970: 300))
    )
    #expect(subject.batchID == batchID)
    #expect(subject.queueItemID == queueItemID)
    #expect(subject.delivery.suggestedCreationDate == Date(timeIntervalSince1970: 300))
}

@Test("OutputDeliveryDescriptorがformatとsuggestedCreationDateを保持する")
func outputDeliveryDescriptorHoldsFields() {
    let date = Date(timeIntervalSince1970: 400)
    let subject = OutputDeliveryDescriptor(format: .jpeg, suggestedCreationDate: date)
    #expect(subject.format == .jpeg)
    #expect(subject.suggestedCreationDate == date)
}
