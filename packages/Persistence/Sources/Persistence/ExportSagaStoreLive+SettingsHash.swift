import Foundation
import Domain
// CryptoKitはApple platform専用API。CIのpackage-testsジョブはmacos-15で動くため現状は
// 問題ないが、将来Persistenceパッケージ内のswift testをLinux上でも実行する計画が出た
// 場合はswift-crypto（import Crypto）への置き換えが必要になる（StampStoreLive+Import.swiftと
// 同じ注記）。
import CryptoKit

// projectSettingsHash（Domainの純粋関数、SettingsHash.swift）へ注入するSHA-256アダプタ
// （canonical-schema.md 5.2「実体計算はSha256Digestプロトコル経由でアダプタへ注入する」）。
//
// startExportがExportJob.settingsHash列（Schema+Accounting.swift。オーケストレーター確定
// 判断）を計算する際に使う。settle時にRenderSpec/ExportSettingを再構築する手段が無いため、
// 平文値が手元にあるstartExport時点でここを通じて計算する。

/// StampStoreLive+Import.swiftのSHA256.hash(data:)直接呼び出しと同じパターン。
/// 保持する状態を持たないためSendable合成は自動的に成立する。
struct CryptoKitSha256Digest: Sha256Digest {
    func digest(_ input: Data) -> Data {
        Data(SHA256.hash(data: input))
    }
}
