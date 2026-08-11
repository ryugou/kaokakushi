import Foundation
import Testing
import Domain

// FakeOutputFileVerifier の defaultOutcome 必須化（Task 3 レビュー Suggestion 1）を検証する。
// 未設定状態を init で型として排除したため、旧実装で preconditionFailure に落ちていた
// 「未設定のまま呼び出す」経路自体が型上ありえなくなったことを、defaultOutcome だけを渡した
// 構築から verify が正常に結果を返すことで確認する。
//
// per-file の outcomes 上書きが defaultOutcome より優先される、という既存ロジック
// （`outcomes[file] ?? defaultOutcome`。このレビュー修正の対象外）は、actor 分離下では
// 呼び出し元から `outcomes` へ直接書き込めない（Swift 6 の strict concurrency は
// actor-isolated var への外部からの代入自体を禁止する。読み取り専用の `await` アクセスとは
// 非対称）。今回の修正はここに手を入れていないため、このファイルでは検証対象にしない
// （範囲外の発見としてオーケストレーターへ報告済み）。

@Suite("FakeOutputFileVerifier")
struct FakeOutputFileVerifierTests {
    @Test("defaultOutcomeだけを渡して構築でき、verifyがその結果を返す")
    func returnsDefaultOutcomeWhenConstructedWithOnlyDefault() async throws {
        let measurement = VerifiedOutputMeasurement(byteSize: 2_048, sha256: Data(repeating: 0x01, count: 32))
        let verifier = FakeOutputFileVerifier(defaultOutcome: .success(measurement))

        let result = try await verifier.verify(makeOutputFileRef())

        #expect(result.byteSize == measurement.byteSize)
        #expect(result.sha256 == measurement.sha256)
    }
}
