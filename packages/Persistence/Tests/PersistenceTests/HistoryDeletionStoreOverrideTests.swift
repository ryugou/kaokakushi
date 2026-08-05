import Foundation
import Testing
import Domain
import GRDB
@testable import Persistence

// deleteHistoryUnitの.userInitiated(confirmedOverrides:)分岐のテスト（architecture.md
// 「削除の可否判定」表の「利用者による手動削除」行が正本）。
//
// favorite/beingEditedはSchema+Project.swiftに対応する列が存在せず常にfalse固定のため
// （HistoryDeletionStoreLive.swift冒頭コメント参照）、このファイルではconfirmedOverridesの
// 効果をworkingSourceのみで検証する（favorite/beingEditedの上書き確認は列が追加されるまで
// 検証不能）。

@Suite("HistoryDeletionStoreLive.deleteHistoryUnit userInitiated confirmedOverrides")
struct HistoryDeletionStoreOverrideTests {
    @Test("workingSourceがconfirmedOverridesに含まれない場合はblockedByOverridableProtectionをthrowすること")
    func rejectsWhenWorkingSourceNotConfirmed() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertWorkingSourceRecord(connection, projectID: projectID.rawValue, sourceFileID: UUID())
        }
        let store = makeHistoryDeletionStore(database: database)

        do {
            try await store.deleteHistoryUnit(.project(projectID), trigger: .userInitiated(confirmedOverrides: []))
            Issue.record("workingSourceが未確認なのにdeleteHistoryUnitが成功した")
        } catch let error as HistoryDeletionStoreError {
            #expect(error == .blockedByOverridableProtection(unit: .project(projectID), reasons: [.workingSource]))
        } catch {
            Issue.record("HistoryDeletionStoreError以外がthrowされた: \(error)")
        }
        #expect(try projectRowExists(database, projectID: projectID.rawValue))
    }

    @Test("workingSourceがconfirmedOverridesに含まれる場合は削除が成功すること")
    func allowsWhenWorkingSourceConfirmed() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertWorkingSourceRecord(connection, projectID: projectID.rawValue, sourceFileID: UUID())
        }
        let store = makeHistoryDeletionStore(database: database)

        try await store.deleteHistoryUnit(
            .project(projectID), trigger: .userInitiated(confirmedOverrides: [.workingSource])
        )

        #expect(try !projectRowExists(database, projectID: projectID.rawValue))
    }

    @Test("storagePressureは上書き可能な保護があっても常にblockedByOverridableProtectionをthrowすること")
    func storagePressureCannotOverrideWorkingSource() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertWorkingSourceRecord(connection, projectID: projectID.rawValue, sourceFileID: UUID())
        }
        let store = makeHistoryDeletionStore(database: database)

        do {
            try await store.deleteHistoryUnit(.project(projectID), trigger: .storagePressure)
            Issue.record("storagePressureがworkingSourceを上書きしてdeleteHistoryUnitが成功した")
        } catch let error as HistoryDeletionStoreError {
            #expect(error == .blockedByOverridableProtection(unit: .project(projectID), reasons: [.workingSource]))
        } catch {
            Issue.record("HistoryDeletionStoreError以外がthrowされた: \(error)")
        }
        #expect(try projectRowExists(database, projectID: projectID.rawValue))
    }

    @Test("retentionExpiryも上書き可能な保護があれば常にblockedByOverridableProtectionをthrowすること")
    func retentionExpiryCannotOverrideWorkingSource() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = ProjectID(rawValue: UUID())
        try await database.dbQueue.write { connection in
            try insertProject(connection, projectID: projectID.rawValue)
            try insertWorkingSourceRecord(connection, projectID: projectID.rawValue, sourceFileID: UUID())
        }
        let store = makeHistoryDeletionStore(database: database)

        do {
            try await store.deleteHistoryUnit(.project(projectID), trigger: .retentionExpiry)
            Issue.record("retentionExpiryがworkingSourceを上書きしてdeleteHistoryUnitが成功した")
        } catch let error as HistoryDeletionStoreError {
            #expect(error == .blockedByOverridableProtection(unit: .project(projectID), reasons: [.workingSource]))
        } catch {
            Issue.record("HistoryDeletionStoreError以外がthrowされた: \(error)")
        }
        #expect(try projectRowExists(database, projectID: projectID.rawValue))
    }

    @Test("存在しないProjectIDへのdeleteHistoryUnitが冪等に成功すること")
    func deleteIsIdempotentForMissingProject() async throws {
        let (database, url) = try makeTestAppDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeHistoryDeletionStore(database: database)

        try await store.deleteHistoryUnit(
            .project(ProjectID(rawValue: UUID())),
            trigger: .userInitiated(confirmedOverrides: [])
        )
    }
}
