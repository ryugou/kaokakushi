import Foundation
import Domain

// FakeSha256Digest — `Sha256Digest`（Domain/Canonical/SettingsHash.swift）の
// テスト用決定的実装（Issue #7 Task 10）。
//
// DomainTests の FakeSha256Digest（入力をキャプチャして固定値を返すだけのスタブ）とは方針が
// 異なる。Task 10 の免除判定テストは「同じ設定なら同じ settingsHash」「異なる設定なら異なる
// settingsHash」を実際に区別する必要があるため、入力バイト列から 32 バイトを決定的に導出する
// （暗号学的な SHA-256 である必要はない。衝突しにくい決定的な変換であれば十分）。

private let fakeDigestSeeds: [UInt64] = [
    0xcbf2_9ce4_8422_2325,
    0x0000_0001_0000_01b3,
    0x9e37_79b9_7f4a_7c15,
    0x85eb_ca6b_c2b2_ae35
]

final class FakeSha256Digest: Sha256Digest, @unchecked Sendable {
    func digest(_ input: Data) -> Data {
        var result = Data()
        for seed in fakeDigestSeeds {
            var hash = seed
            for byte in input {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            withUnsafeBytes(of: hash.bigEndian) { result.append(contentsOf: $0) }
        }
        return result
    }
}
