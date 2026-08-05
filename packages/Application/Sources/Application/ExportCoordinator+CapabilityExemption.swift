import Foundation
import Domain

// ExportCoordinator+CapabilityExemption — 「変更せず再書き出し」の能力免除（Issue #7 Task 10）。
//
// 正本: export-saga.md 1.2「変更せず再書き出しの免除」の表、architecture.md 6.2
// 「比較対象を台帳へ持つ」。
//
// 免除の条件（export-saga.md 1.2 の表を一字一句反映）:
// - 確定記録の存在: ExportedSettingsEntry に当該 projectID の項目がある
// - 設定の一致: その項目の settingsHash が、いま組み立てた RenderSpec と ExportSetting から
//   計算した値と一致する
// - 対象: 同一 Project であること（素材の同一性は照合しない）。loadEntry(for:) を
//   request.projectID で呼ぶことで担保される
// - 適用範囲: 有料スタンプの能力要件のみ。月間枠・トライアルクレジットの消費は免除しない
//   （呼び出し元の ExportCoordinator.startExport(_:capabilities:) が 1.2 の blocked 判定
//   直後にのみ本メソッドを評価し、1.3 の評価は従来どおり authorizeAndStart 経由の
//   startExport に委ねる）
//
// exportedSettingsEntryStore.loadEntry は読み取りのみで store の状態を変更しないため、
// ExportCoordinator.swift 冒頭コメントの方針（1.1/1.2/実体喪失検査と同じ「読み取りのみは
// queue の外で評価する」）に倣い SerialTaskQueue を経由しない。

extension ExportCoordinator {
    /// 確定記録が存在し、settingsHash が現在の RenderSpec / ExportSetting から計算した値と
    /// 一致すれば true（export-saga.md 1.2「変更せず再書き出しの免除」）。
    func isExemptFromCapabilityBlock(_ request: SingleExportRequest) async throws -> Bool {
        guard let entry = try await exportedSettingsEntryStore.loadEntry(for: request.projectID) else {
            return false
        }
        let currentHash = try projectSettingsHash(
            renderSpec: request.renderSpec,
            exportSetting: request.exportSetting,
            digest: settingsHashDigest
        )
        return entry.settingsHash == currentHash
    }
}
