import Foundation
import Domain

// loadUnknownLibrarySaves / clearUnknownLibrarySave / deleteOutputのスタブ
// （次セッション担当。プロトコル準拠のためだけに存在し、ロジックは持たない）。

extension OutputDeliveryStoreLive {
    public func loadUnknownLibrarySaves() async throws -> [UnknownLibrarySave] {
        // 未実装（次セッション担当）
        throw OutputDeliveryStoreError.notImplemented(method: "loadUnknownLibrarySaves")
    }

    public func clearUnknownLibrarySave(_ exportID: ExportID) async throws {
        // 未実装（次セッション担当）
        throw OutputDeliveryStoreError.notImplemented(method: "clearUnknownLibrarySave")
    }

    public func deleteOutput(_ exportID: ExportID) async throws {
        // 未実装（次セッション担当）
        throw OutputDeliveryStoreError.notImplemented(method: "deleteOutput")
    }
}
